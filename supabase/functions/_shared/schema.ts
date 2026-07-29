// supabase/functions/_shared/schema.ts
//
// Hand-rolled input/output validation — no Zod, no ajv, no external schema library.
//
// Why hand-rolled instead of Zod (which is common in Supabase Deno examples): this route is the
// ONLY internet-facing surface of the product (see final report threat model) and Zod would be
// the single largest third-party dependency pulled onto that surface for what is, in the end,
// a few dozen `typeof`/`Array.isArray`/range checks. A hand-rolled validator (a) has zero
// supply-chain exposure (no transitive deps to audit/pin/get a CVE in), (b) is fully auditable
// in one file, and (c) is cheap here because the shapes are small and flat. If the schema grows
// materially (nested unions, recursive types) this tradeoff should be revisited — Zod is a fine
// choice at that point and is available via `npm:zod` under the Supabase Deno runtime.
//
// Two jobs live here:
//   1. Validate/cap CLIENT input before it ever reaches a prompt (transcript length, array caps,
//      string caps) — this is also the first line of defense against prompt injection: caps are
//      enforced here regardless of what the model does with the content.
//   2. Validate the MODEL's output against the exact contract shape before it is ever returned to
//      the client — the model is untrusted (constitution II / task brief): even though we ask
//      Gemini for JSON-schema-constrained output, a schema-constrained *request* does not
//      guarantee a conforming response (provider bugs, truncation, safety-filter substitutions),
//      so every field is re-checked here server-side. Decode failure -> opaque 502, never a
//      best-effort pass-through of unvalidated JSON.

// ---------------------------------------------------------------------------------------------
// Caps (contract "Server obligations" + task brief hardening list)
// ---------------------------------------------------------------------------------------------
export const MAX_TRANSCRIPT_CHARS = 2000;
export const MAX_OPEN_TASK_TITLES = 100;
export const MAX_OPEN_TASK_TITLE_CHARS = 200;
export const MAX_TASKS = 10;
export const MAX_TASK_TITLE_CHARS = 300;
export const MAX_NOTES_CHARS = 1000;
export const MIN_BREAKDOWN_STEPS = 3;
export const MAX_BREAKDOWN_STEPS = 9;
export const MIN_STEP_MINUTES = 5;
export const MAX_STEP_MINUTES = 15;
export const MAX_BODY_BYTES = 32 * 1024;
/** "stuck" mode, `reason: "dread"` only (anh Khôi, 2026-07-29): hard character cap on the model's
 *  one-message response, enforced HERE (not just asked-for in the prompt) for the same
 *  defense-in-depth reason every other model-output cap in this file exists — a schema-constrained
 *  *request* is a strong hint, never a guarantee, so the actual boundary is this server-side
 *  re-check. 400 chosen because this is meant to be ONE short sentence-or-two naming a specific
 *  dreaded detail plus a <=2-minute action, read at a glance in a small inline banner (see
 *  `Volar/Sources/Views/FocusOverlay.swift`'s `StuckDreadBanner`) — long enough for that, short
 *  enough that a model going off the rails (a paragraph, a bulleted plan) fails validation instead
 *  of dumping a wall of text into a UI built for one line. */
export const MAX_DREAD_MESSAGE_CHARS = 400;

/** "stuck" mode, `reason: "too_big"` ONLY (anh Khôi, 2026-07-29 REDESIGN — this reason used to
 *  reuse the breakdown machinery verbatim; it now returns exactly ONE next physical action, not a
 *  3-9 step plan — see `NEXT_ACTION_SYSTEM_PREAMBLE`'s doc comment in `gemini.ts` for the full
 *  reasoning). Deliberately SHORTER than `MAX_DREAD_MESSAGE_CHARS`: `dread`'s message does two
 *  things (name a dreaded detail, THEN propose an action), so it earns two sentences' worth of
 *  room; this reason's message is ONLY the action itself, a single imperative sentence — 160
 *  characters is generous for that in either Vietnamese or English while still catching a model
 *  that ignores the "one action, not a plan" instruction and starts listing several. */
export const MAX_NEXT_ACTION_CHARS = 160;

/** `stuck`/`breakdown` context addendum (anh Khôi, 2026-07-29): `sourceTranscript` is the user's
 *  own ORIGINAL spoken words at task-creation time — usually richer than `taskTitle`, which is
 *  frequently a compressed paraphrase of it (e.g. "làm báo cáo Q3 cho sếp Hùng trước thứ 5, số
 *  liệu lấy từ file Minh gửi" collapses to a title of just "làm báo cáo Q3"). This is a
 *  SUPPLEMENTARY, OPTIONAL field — unlike `transcript` in `parse` mode (which IS the thing being
 *  parsed, and is rejected outright over-cap so the client's own truncation stays the source of
 *  truth), an over-cap `sourceTranscript` here is truncated rather than rejected: losing the tail
 *  of some extra context must never cost the user the entire next-action/breakdown request. 1000
 *  chars (matching `MAX_NOTES_CHARS`) is ample for "richer than a title" without letting this
 *  field balloon the prompt or approach `MAX_BODY_BYTES` alongside `existingSubtasks` below. */
export const MAX_CONTEXT_TRANSCRIPT_CHARS = 1000;

/** `stuck`/`breakdown` context addendum: cap on how many `existingSubtasks` entries (title + done
 *  only, never a task id) are accepted — mirrors `ParsedTaskValidation`'s own `.prefix(20)` cap on
 *  `subtasks` in the Swift client (`Sources/Parsing/IntentParsing.swift`), so client and server
 *  agree on the same ceiling for "how many subtasks are worth telling the model about" rather than
 *  inventing a second number. */
export const MAX_EXISTING_SUBTASKS = 20;

// ---------------------------------------------------------------------------------------------
// Request (client -> us)
// ---------------------------------------------------------------------------------------------

export interface ParseRequest {
  mode: "parse";
  transcript: string;
  localeHint?: "vi" | "en" | "mixed";
  now: string; // ISO8601, caller-supplied "current time" (contract field `now`)
  openTaskTitles: string[]; // capped, titles only
  // IANA timezone id of the user (e.g. "Asia/Ho_Chi_Minh"), optional so older clients that don't
  // send it still work. `now` already carries the correct local UTC offset by itself — this field
  // is extra CONTEXT for the model (DST edge cases, resolving dates further in the future than the
  // single offset in `now` implies), not the primary source of the offset.
  timezone?: string;
}

/** Optional "richer context" fields (anh Khôi, 2026-07-29 addendum), shared by `BreakdownRequest`
 *  and `StuckRequest` below via `validateTaskContextFields`. ALL THREE are OPTIONAL and
 *  FAIL-OPEN — a request from an older client that never sends them must run exactly as before
 *  (see that function's own doc comment for the field-by-field fail-open rule; this is a REQUEST
 *  field failing open, a different call from the RESPONSE per-field fail-open
 *  `validateParsedTask` already documents, but the same underlying principle: one bad/oversized/
 *  absent supplementary field must never cost the user the whole request). */
export interface TaskContextFields {
  sourceTranscript?: string;
  deadline?: string; // ISO8601 WITH ZONE — see isIso8601WithZone; dropped (not rejected) if malformed
  existingSubtasks?: { title: string; done: boolean }[]; // title + done ONLY, never a task id
}

export interface BreakdownRequest extends TaskContextFields {
  mode: "breakdown";
  taskTitle: string;
  notes?: string;
}

/** Fourth request mode (anh Khôi, 2026-07-29 "Stuck?" feature): "the user tapped Stuck on this
 *  task and told us WHY" — three reasons need three different fixes (see `spec`/task brief), but
 *  only two of them ever reach this server at all:
 *   - `"too_big"` (REDESIGNED 2026-07-29, same day, after anh Khôi challenged the first version):
 *     originally reused the breakdown machinery verbatim to produce a 3-9 step PLAN. Rejected
 *     because Volar has no real context beyond a short spoken title — for "làm báo cáo Q3" the
 *     model doesn't know which report, for whom, or where the numbers live, so steps 3+ of a full
 *     plan are fabrication dressed as advice ("viết phần phân tích", "rà soát lại" — grammatical,
 *     useless). "Stuck?" doesn't need a plan; it needs exactly one true answer to "what does my
 *     hand do right now" — a question answerable with near-zero context. Now returns exactly ONE
 *     next physical action (`buildNextActionContents`/`NEXT_ACTION_SYSTEM_PREAMBLE`/
 *     `buildNextActionResponseSchema`/`validateNextActionMessage`, all in `gemini.ts`/this file) —
 *     its own prompt, its own (shorter) cap, NOT a reuse of breakdown's schema/validator. The full
 *     multi-step plan is still reachable — via `mode: "breakdown"` / `TaskBreakdownView` on the
 *     client — this reason just no longer produces one itself; the client's "too_big" banner keeps
 *     a secondary button to open that full flow for anyone who wants it.
 *   - `"dread"`: the user is naming that they feel dread, not that the task is big. Needs an
 *     actual model call (see `buildDreadContents`/`DREAD_SYSTEM_PREAMBLE` in `gemini.ts`) — this is
 *     the one reason that's genuinely new work on this route. UNCHANGED by the 2026-07-29
 *     redesign above other than gaining the same optional `TaskContextFields` every other mode now
 *     accepts (see that interface's doc comment) — its prompt/schema/validator/cap are untouched.
 *   - `"cant_start"` ("không nhấc người lên nổi"): deliberately NOT a valid value here at all — the
 *     client's fix for this reason is a plain client-side 2-minute timer with no task content
 *     involved, so sending it to the model would just burn a quota slot for nothing. Rejecting it
 *     in `validateStuckRequest` below (rather than silently accepting-and-ignoring it) means a
 *     client bug that mistakenly sends it fails loudly (400) instead of quietly wasting a call.
 */
export interface StuckRequest extends TaskContextFields {
  mode: "stuck";
  reason: "too_big" | "dread";
  taskTitle: string;
  notes?: string;
}

/** Third request mode: "given this utterance and this numbered list of the user's open task
 *  titles, which ONE is the user saying they finished — or none?" Exists because local Jaccard
 *  token-set matching on the client cannot handle a paraphrase ("xong cái vụ report rồi" vs the
 *  real title "Viết báo cáo Q3") — it needs a model that understands meaning, not token overlap.
 *
 *  PRIVACY: `candidates` carries TITLES ONLY, never task ids — the client maps the returned
 *  1-based index back to a task id locally. Never add a task-id field to this wire shape.
 *
 *  Wire field names are snake_case (`resolve_completion`, `clear_external`, `candidates`),
 *  matching `open_task_titles`/`locale_hint` elsewhere in this file. */
export interface ResolveCompletionRequest {
  mode: "resolve_completion";
  transcript: string;
  now: string; // ISO8601 WITH ZONE — see isIso8601WithZone
  kind: "complete" | "clear_external";
  candidates: string[]; // the numbered list, in order; index 0 here == candidate "1." in the prompt
}

export type ParsedRequestBody = ParseRequest | BreakdownRequest | ResolveCompletionRequest | StuckRequest;

type ValidationResult<T> = { ok: true; value: T } | { ok: false; error: string };

function isPlainObject(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

function isNonEmptyString(v: unknown): v is string {
  return typeof v === "string" && v.trim().length > 0;
}

function isFiniteNumber(v: unknown): v is number {
  return typeof v === "number" && Number.isFinite(v);
}

/** ISO8601 check. We don't need a full RFC parser — `Date.parse` plus a check that the
 *  string round-trips through it and (loosely) looks like an ISO date is enough to reject
 *  garbage without accepting ambiguous non-ISO formats `Date.parse` is overly lenient about.
 *  Does NOT require a timezone designator — used for model-output fields (`deadline`,
 *  `afterDate`) where the contract doesn't mandate one; see `isIso8601WithZone` below for the
 *  stricter check the contract requires on the client-supplied `now` field. */
function isIso8601(v: unknown): v is string {
  if (typeof v !== "string") return false;
  if (!/^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}/.test(v)) return false;
  const ms = Date.parse(v);
  return Number.isFinite(ms);
}

/** ISO8601-WITH-ZONE check (contract: "now is required and must be ISO8601 with zone"). Requires
 *  a trailing `Z` or `±HH:MM` UTC offset in addition to `isIso8601`'s shape check — a zone-less
 *  "now" is ambiguous (local time in an unspecified timezone) and would make the server's
 *  deadline/quota-day math nondeterministic, so it's rejected outright rather than assumed UTC. */
function isIso8601WithZone(v: unknown): v is string {
  if (!isIso8601(v)) return false;
  return /(Z|[+-]\d{2}:\d{2})$/.test(v);
}

export function validateRequestBody(body: unknown): ValidationResult<ParsedRequestBody> {
  if (!isPlainObject(body)) return { ok: false, error: "body must be a JSON object" };

  const modeRaw = body.mode;
  const mode = modeRaw === undefined ? "parse" : modeRaw;
  if (mode !== "parse" && mode !== "breakdown" && mode !== "resolve_completion" && mode !== "stuck") {
    return {
      ok: false,
      error: "mode must be 'parse', 'breakdown', 'resolve_completion', or 'stuck' when present",
    };
  }

  if (mode === "breakdown") return validateBreakdownRequest(body);
  if (mode === "resolve_completion") return validateResolveCompletionRequest(body);
  if (mode === "stuck") return validateStuckRequest(body);
  return validateParseRequest(body);
}

/** Shared by `validateBreakdownRequest` and `validateStuckRequest` below — both wire shapes carry
 *  the identical `task_title`/`notes`/`source_transcript`/`deadline`/`existing_subtasks` fields
 *  with the identical caps, and this task's own instruction is "reuse the breakdown path, don't
 *  build a second one": this is the request-validation half of that reuse, so the two modes can
 *  never drift onto two different caps/error messages for the same fields.
 *
 *  `task_title`/`notes` are FAIL-CLOSED exactly as before (a malformed value rejects the whole
 *  request — unchanged behavior, existing tests for this still pass). The three NEW context
 *  fields (anh Khôi, 2026-07-29 addendum) are FAIL-OPEN instead, and deliberately so — they are
 *  supplementary context, not the primary content of the request, and a client bug/oversized value
 *  here must never take down an otherwise-good request the way a bad `task_title` legitimately
 *  does:
 *   - `source_transcript`: any non-empty string is accepted and TRUNCATED to
 *     `MAX_CONTEXT_TRANSCRIPT_CHARS` (never rejected for being too long) — mirrors how `transcript`
 *     is truncated CLIENT-side in `parse` mode rather than rejected, just enforced again here since
 *     this is a different (optional, supplementary) field with no client-side truncation guarantee
 *     of its own yet. A wrong TYPE (not a string) is simply omitted.
 *   - `deadline`: kept only if it parses as `isIso8601WithZone` (same zone requirement as `now`,
 *     for the same "an offset-less instant is ambiguous" reason) — anything else (wrong type,
 *     missing zone, unparseable) is silently omitted, never rejects the request.
 *   - `existing_subtasks`: kept only if it is an array; each ELEMENT is independently validated
 *     (non-empty `title` <= `MAX_TASK_TITLE_CHARS`, boolean `done`) and a malformed element is
 *     dropped on its own — same per-element fail-open convention `validateParsedTask`'s
 *     `conditions`/`subtasks` fields already use for MODEL output, applied here to a REQUEST field
 *     for the identical reason. Capped at `MAX_EXISTING_SUBTASKS` entries. An empty result (every
 *     element was malformed, or the field wasn't an array at all) is `undefined`, not `[]` — an
 *     absent field and a wholly-unusable field mean the same thing to every caller of this
 *     function, so they collapse to the same representation. */
function validateTaskContextFields(
  body: Record<string, unknown>,
): ValidationResult<{ taskTitle: string; notes?: string } & TaskContextFields> {
  const taskTitle = body.task_title;
  if (!isNonEmptyString(taskTitle) || taskTitle.length > MAX_TASK_TITLE_CHARS) {
    return {
      ok: false,
      error: `task_title is required, non-empty, <= ${MAX_TASK_TITLE_CHARS} chars`,
    };
  }
  let notes: string | undefined;
  if (body.notes !== undefined) {
    if (typeof body.notes !== "string" || body.notes.length > MAX_NOTES_CHARS) {
      return { ok: false, error: `notes must be a string <= ${MAX_NOTES_CHARS} chars` };
    }
    notes = body.notes;
  }

  // --- Context addendum below: all three FAIL-OPEN (drop the field, never reject the request) ---

  let sourceTranscript: string | undefined;
  if (typeof body.source_transcript === "string" && body.source_transcript.trim().length > 0) {
    sourceTranscript = body.source_transcript.slice(0, MAX_CONTEXT_TRANSCRIPT_CHARS);
  }

  let deadline: string | undefined;
  if (typeof body.deadline === "string" && isIso8601WithZone(body.deadline)) {
    deadline = body.deadline;
  }

  let existingSubtasks: { title: string; done: boolean }[] | undefined;
  if (Array.isArray(body.existing_subtasks)) {
    const cleaned: { title: string; done: boolean }[] = [];
    for (const item of body.existing_subtasks) {
      if (
        isPlainObject(item) &&
        isNonEmptyString(item.title) &&
        item.title.length <= MAX_TASK_TITLE_CHARS &&
        typeof item.done === "boolean"
      ) {
        cleaned.push({ title: item.title, done: item.done });
      }
    }
    if (cleaned.length > 0) existingSubtasks = cleaned.slice(0, MAX_EXISTING_SUBTASKS);
  }

  return { ok: true, value: { taskTitle, notes, sourceTranscript, deadline, existingSubtasks } };
}

function validateParseRequest(body: Record<string, unknown>): ValidationResult<ParseRequest> {
  if (!isNonEmptyString(body.transcript)) {
    return { ok: false, error: "transcript is required and must be a non-empty string" };
  }
  if (body.transcript.length > MAX_TRANSCRIPT_CHARS) {
    return { ok: false, error: `transcript exceeds ${MAX_TRANSCRIPT_CHARS} chars` };
  }
  if (!isIso8601WithZone(body.now)) {
    return { ok: false, error: "now is required and must be ISO8601 with zone" };
  }
  // Contract + README use snake_case `locale_hint` on the wire; `body.localeHint` is accepted
  // too as a defensive fallback (in case a caller sends camelCase), but snake_case wins when both
  // are present — matching the contract is the source of truth here.
  let localeHint: ParseRequest["localeHint"];
  const localeHintRaw = body.locale_hint !== undefined ? body.locale_hint : body.localeHint;
  if (localeHintRaw !== undefined) {
    if (localeHintRaw !== "vi" && localeHintRaw !== "en" && localeHintRaw !== "mixed") {
      return { ok: false, error: "locale_hint must be one of vi|en|mixed" };
    }
    localeHint = localeHintRaw;
  }

  // `timezone` is interpolated verbatim into the Gemini prompt (see gemini.ts's
  // `buildVietnameseDateInstructions`), so it is a PROMPT-INJECTION VECTOR just like `transcript`
  // and `open_task_titles` — the difference is this field has no legitimate reason to contain
  // anything but an IANA zone id, so it can be locked down far tighter than free-text fields. The
  // regex below allows only letters/digits/underscore/plus/minus and 0-2 `/`-separated segments —
  // no whitespace, no newlines, no punctuation that could start a new "instruction" in the prompt.
  // DO NOT loosen this regex to be more permissive (e.g. to allow spaces or extra punctuation)
  // without understanding this is the only thing standing between raw user-influenced text and the
  // model's system context here; a real IANA id never needs anything outside this character set.
  let timezone: string | undefined;
  if (body.timezone !== undefined) {
    if (
      typeof body.timezone !== "string" ||
      body.timezone.length < 1 ||
      body.timezone.length > 64 ||
      !/^[A-Za-z0-9_+\-]+(?:\/[A-Za-z0-9_+\-]+){0,2}$/.test(body.timezone)
    ) {
      return { ok: false, error: "timezone must be a valid IANA timezone identifier" };
    }
    timezone = body.timezone;
  }

  let openTaskTitles: string[] = [];
  const rawTitles = body.open_task_titles;
  if (rawTitles !== undefined) {
    if (!Array.isArray(rawTitles)) {
      return { ok: false, error: "open_task_titles must be an array" };
    }
    if (rawTitles.length > MAX_OPEN_TASK_TITLES) {
      return { ok: false, error: `open_task_titles exceeds ${MAX_OPEN_TASK_TITLES} entries` };
    }
    for (const t of rawTitles) {
      if (typeof t !== "string" || t.length === 0 || t.length > MAX_OPEN_TASK_TITLE_CHARS) {
        return {
          ok: false,
          error: `open_task_titles entries must be non-empty strings <= ${MAX_OPEN_TASK_TITLE_CHARS} chars`,
        };
      }
    }
    openTaskTitles = rawTitles as string[];
  }

  return {
    ok: true,
    value: {
      mode: "parse",
      transcript: body.transcript,
      localeHint,
      now: body.now,
      openTaskTitles,
      timezone,
    },
  };
}

function validateBreakdownRequest(body: Record<string, unknown>): ValidationResult<BreakdownRequest> {
  const shared = validateTaskContextFields(body);
  if (!shared.ok) return shared;
  return { ok: true, value: { mode: "breakdown", ...shared.value } };
}

/** `mode: "stuck"` request validation — see `StuckRequest`'s doc comment above for the reason
 *  semantics. `reason` is checked BEFORE the shared title/notes/context validation purely so a
 *  malformed reason gets its own specific error message rather than being masked by whichever
 *  check happens to run first; order has no other significance here (both checks are independent,
 *  non-mutating). */
function validateStuckRequest(body: Record<string, unknown>): ValidationResult<StuckRequest> {
  if (body.reason !== "too_big" && body.reason !== "dread") {
    return { ok: false, error: "reason must be 'too_big' or 'dread'" };
  }
  const shared = validateTaskContextFields(body);
  if (!shared.ok) return shared;
  return {
    ok: true,
    value: { mode: "stuck", reason: body.reason, ...shared.value },
  };
}

function validateResolveCompletionRequest(
  body: Record<string, unknown>,
): ValidationResult<ResolveCompletionRequest> {
  if (!isNonEmptyString(body.transcript)) {
    return { ok: false, error: "transcript is required and must be a non-empty string" };
  }
  if (body.transcript.length > MAX_TRANSCRIPT_CHARS) {
    return { ok: false, error: `transcript exceeds ${MAX_TRANSCRIPT_CHARS} chars` };
  }
  if (!isIso8601WithZone(body.now)) {
    return { ok: false, error: "now is required and must be ISO8601 with zone" };
  }
  if (body.kind !== "complete" && body.kind !== "clear_external") {
    return { ok: false, error: "kind must be 'complete' or 'clear_external'" };
  }

  const rawCandidates = body.candidates;
  if (!Array.isArray(rawCandidates) || rawCandidates.length === 0) {
    // An empty/missing list is a client bug — there is nothing to match against, so this is
    // rejected outright rather than paying for a model call that can only ever answer "none".
    return { ok: false, error: "candidates is required and must be a non-empty array" };
  }
  if (rawCandidates.length > MAX_OPEN_TASK_TITLES) {
    return { ok: false, error: `candidates exceeds ${MAX_OPEN_TASK_TITLES} entries` };
  }
  for (const c of rawCandidates) {
    if (typeof c !== "string" || c.length === 0 || c.length > MAX_OPEN_TASK_TITLE_CHARS) {
      return {
        ok: false,
        error: `candidates entries must be non-empty strings <= ${MAX_OPEN_TASK_TITLE_CHARS} chars`,
      };
    }
  }

  return {
    ok: true,
    value: {
      mode: "resolve_completion",
      transcript: body.transcript,
      now: body.now,
      kind: body.kind,
      candidates: rawCandidates as string[],
    },
  };
}

// ---------------------------------------------------------------------------------------------
// Response (model -> us -> client). Mirrors data-model.md's ParsedTask v2 shape + contract's
// "every attribute carries confidence: 0..1". NOTE: `Volar/Sources/Model/NLParser.swift`'s v2
// `ParsedTask` (spec task T017) had not landed at the time this route was implemented (T004/T022
// run ahead of T017 per tasks.md dependency notes) — this is a best-effort mirror of
// contracts/parse-proxy.md + data-model.md's "Parsing contract" section. Reconcile field names
// against the real Swift `Codable` once T017 lands; see follow-ups in the implementation report.
// ---------------------------------------------------------------------------------------------

export interface ConfidenceValue<T> {
  value: T;
  confidence: number;
}

export interface ParsedConditionOut {
  kind: "taskDone" | "afterDate" | "external";
  referenceTitle?: string; // kind === taskDone: fuzzy title, client resolves via picker
  date?: string; // kind === afterDate: ISO8601
  description?: string; // kind === external
}

export interface ParsedRecurrenceOut {
  type: "daily" | "weekly" | "monthly" | "every";
  everyDays?: number; // required when type === "every"
}

export interface ParsedReminderOverrideOut {
  offsetsMinutes: number[]; // relative to deadline, negative = before
  repeatEveryMinutes?: number;
  // Chu kỳ nhắc TRƯỚC deadline (phút) khi user nói rõ, VD "nhắc tôi mỗi 15 phút" -> 15. Khác
  // `repeatEveryMinutes` ở trên (lặp SAU deadline, xem ReminderPolicy.repeatEvery trong
  // Volar/Sources/Model/Recurrence.swift) -- không phải cùng field đổi tên. Client dùng mặc định
  // riêng (nhắc ở 1/2 và 1/3 thời gian còn lại) khi field này vắng mặt.
  remindPeriodMinutes?: number;
}

export interface ParsedSubtaskOut {
  title: ConfidenceValue<string>;
  estimateMinutes: ConfidenceValue<number>;
}

export interface ParsedTaskOut {
  title: ConfidenceValue<string>;
  notes?: ConfidenceValue<string>;
  deadline?: ConfidenceValue<string>;
  startTime?: ConfidenceValue<string>;
  estimateMinutes?: ConfidenceValue<number>;
  priority?: ConfidenceValue<number>;
  recurrence?: ConfidenceValue<ParsedRecurrenceOut>;
  reminderOverride?: ConfidenceValue<ParsedReminderOverrideOut>;
  conditions?: ConfidenceValue<ParsedConditionOut>[];
  kind?: ConfidenceValue<"task" | "review">;
  subtasks?: ParsedSubtaskOut[];
  followUpReview?: ConfidenceValue<boolean>;
}

export interface BreakdownStepOut {
  title: string;
  estimateMinutes: number;
}

function isConfidence(v: unknown): v is number {
  return isFiniteNumber(v) && v >= 0 && v <= 1;
}

function validateConfidenceValue<T>(
  v: unknown,
  validateInner: (inner: unknown) => T | undefined,
): ConfidenceValue<T> | undefined {
  if (!isPlainObject(v)) return undefined;
  if (!isConfidence(v.confidence)) return undefined;
  const inner = validateInner(v.value);
  if (inner === undefined) return undefined;
  return { value: inner, confidence: v.confidence };
}

function validateCondition(v: unknown): ParsedConditionOut | undefined {
  if (!isPlainObject(v)) return undefined;
  if (v.kind !== "taskDone" && v.kind !== "afterDate" && v.kind !== "external") return undefined;
  if (v.kind === "taskDone") {
    if (!isNonEmptyString(v.referenceTitle)) return undefined;
    return { kind: "taskDone", referenceTitle: v.referenceTitle };
  }
  if (v.kind === "afterDate") {
    if (!isIso8601(v.date)) return undefined;
    return { kind: "afterDate", date: v.date as string };
  }
  if (!isNonEmptyString(v.description)) return undefined;
  return { kind: "external", description: v.description };
}

function validateRecurrence(v: unknown): ParsedRecurrenceOut | undefined {
  if (!isPlainObject(v)) return undefined;
  if (v.type !== "daily" && v.type !== "weekly" && v.type !== "monthly" && v.type !== "every") {
    return undefined;
  }
  if (v.type === "every") {
    if (!isFiniteNumber(v.everyDays) || v.everyDays <= 0) return undefined;
    return { type: "every", everyDays: v.everyDays };
  }
  return { type: v.type };
}

function validateReminderOverride(v: unknown): ParsedReminderOverrideOut | undefined {
  if (!isPlainObject(v)) return undefined;
  if (!Array.isArray(v.offsetsMinutes) || v.offsetsMinutes.length === 0) return undefined;
  if (!v.offsetsMinutes.every((n) => isFiniteNumber(n))) return undefined;
  const out: ParsedReminderOverrideOut = { offsetsMinutes: v.offsetsMinutes as number[] };
  if (v.repeatEveryMinutes !== undefined) {
    if (!isFiniteNumber(v.repeatEveryMinutes) || v.repeatEveryMinutes <= 0) return undefined;
    out.repeatEveryMinutes = v.repeatEveryMinutes;
  }
  // `remindPeriodMinutes` is a secondary/optional signal (the client already has its own default
  // reminder cadence) — a malformed value here only omits `remindPeriodMinutes` from `out`, leaving
  // `offsetsMinutes`/`repeatEveryMinutes` and every other already-validated field on this task
  // intact. Same fail-open rule every optional field follows — see `validateParsedTask`'s doc
  // comment below.
  if (v.remindPeriodMinutes !== undefined) {
    if (isFiniteNumber(v.remindPeriodMinutes) && v.remindPeriodMinutes > 0) {
      out.remindPeriodMinutes = v.remindPeriodMinutes;
    }
  }
  return out;
}

function validateSubtask(v: unknown): ParsedSubtaskOut | undefined {
  if (!isPlainObject(v)) return undefined;
  const title = validateConfidenceValue(v.title, (s) =>
    isNonEmptyString(s) && s.length <= MAX_TASK_TITLE_CHARS ? s : undefined
  );
  const estimateMinutes = validateConfidenceValue(v.estimateMinutes, (n) =>
    isFiniteNumber(n) && n > 0 ? n : undefined
  );
  if (!title || !estimateMinutes) return undefined;
  return { title, estimateMinutes };
}

/** Validates a single model-produced task object. FAIL-OPEN per field, FAIL-CLOSED on `title`
 *  only (decision: anh Khôi, 2026-07-28).
 *
 *  Every field on `ParsedTaskOut` besides `title` is OPTIONAL: if a given field's value doesn't
 *  validate, that ONE field is simply omitted from `out` — the function does not abort, and every
 *  other already-validated field on this task (and every other task in the array) is unaffected.
 *  `title` is the sole exception: with no title the task carries no user-facing meaning, so a
 *  missing/invalid title still fails the whole task (`return undefined`) one level up in
 *  `validateParsedTaskArray`, which drops just this task, not the rest of the array.
 *
 *  Why fail-open instead of the previous fail-closed-per-field behavior (any invalid field ->
 *  whole task dropped, which — before `validateParsedTaskArray` also moved to per-task fail-open —
 *  used to take the ENTIRE response down with it): the Swift client already does per-attribute
 *  fallback for exactly this reason (constitution: "A parsing error on one attribute MUST NOT
 *  discard the others") — a server that discards a whole task because one optional field (e.g.
 *  `priority: 7`) didn't validate was undermining that same principle one layer down, and every
 *  new optional field added to this schema over time only increased the odds of some model output
 *  tripping the fail-closed path and costing the user a quota slot for nothing. Dropping one bad
 *  field and keeping the rest of the task is strictly better for the user than discarding it.
 *
 *  This does NOT relax type/shape checking — a field that fails validation is omitted, never
 *  passed through with an unvalidated/partially-validated value; nothing unchecked ever reaches
 *  `out`. */
function validateParsedTask(v: unknown): ParsedTaskOut | undefined {
  if (!isPlainObject(v)) return undefined;

  const title = validateConfidenceValue(v.title, (s) =>
    isNonEmptyString(s) && (s as string).length <= MAX_TASK_TITLE_CHARS ? (s as string) : undefined
  );
  if (!title) return undefined;

  const out: ParsedTaskOut = { title };

  if (v.notes !== undefined) {
    const notes = validateConfidenceValue(v.notes, (s) =>
      typeof s === "string" && s.length <= MAX_NOTES_CHARS ? s : undefined
    );
    if (notes) out.notes = notes;
  }

  if (v.deadline !== undefined) {
    const deadline = validateConfidenceValue(v.deadline, (s) => (isIso8601(s) ? (s as string) : undefined));
    if (deadline) out.deadline = deadline;
  }

  // `startTime` uses the exact same TYPE validation as `deadline` (same confidence-wrapper shape,
  // same `isIso8601` strictness — NOT `isIso8601WithZone`, since this is model-produced output, not
  // the client-supplied `now`). Fail-open like every other optional field on this task — see the
  // doc comment above `validateParsedTask`.
  if (v.startTime !== undefined) {
    const startTime = validateConfidenceValue(v.startTime, (s) => (isIso8601(s) ? (s as string) : undefined));
    if (startTime) out.startTime = startTime;
  }

  if (v.estimateMinutes !== undefined) {
    const est = validateConfidenceValue(v.estimateMinutes, (n) =>
      isFiniteNumber(n) && n > 0 ? n : undefined
    );
    if (est) out.estimateMinutes = est;
  }

  if (v.priority !== undefined) {
    const priority = validateConfidenceValue(v.priority, (n) =>
      isFiniteNumber(n) && Number.isInteger(n) && n >= 1 && n <= 4 ? n : undefined
    );
    if (priority) out.priority = priority;
  }

  if (v.recurrence !== undefined) {
    const recurrence = validateConfidenceValue(v.recurrence, validateRecurrence);
    if (recurrence) out.recurrence = recurrence;
  }

  if (v.reminderOverride !== undefined) {
    const reminderOverride = validateConfidenceValue(v.reminderOverride, validateReminderOverride);
    if (reminderOverride) out.reminderOverride = reminderOverride;
  }

  // `conditions` is an ARRAY field: an individual malformed element is dropped on its own, keeping
  // the rest of the array — this is a finer-grained fail-open than the scalar fields above, but the
  // same underlying rule (one bad piece must not discard the good pieces around it). If `v.conditions`
  // itself isn't an array, the whole field is omitted (nothing valid to salvage).
  if (v.conditions !== undefined && Array.isArray(v.conditions)) {
    const conditions: ConfidenceValue<ParsedConditionOut>[] = [];
    for (const c of v.conditions) {
      const cond = validateConfidenceValue(c, validateCondition);
      if (cond) conditions.push(cond);
    }
    out.conditions = conditions;
  }

  if (v.kind !== undefined) {
    const kind = validateConfidenceValue(v.kind, (s) =>
      s === "task" || s === "review" ? s : undefined
    );
    if (kind) out.kind = kind;
  }

  // `subtasks` is an ARRAY field: same per-element fail-open as `conditions` above.
  if (v.subtasks !== undefined && Array.isArray(v.subtasks)) {
    const subtasks: ParsedSubtaskOut[] = [];
    for (const s of v.subtasks) {
      const sub = validateSubtask(s);
      if (sub) subtasks.push(sub);
    }
    out.subtasks = subtasks;
  }

  if (v.followUpReview !== undefined) {
    const followUpReview = validateConfidenceValue(v.followUpReview, (b) =>
      typeof b === "boolean" ? b : undefined
    );
    if (followUpReview) out.followUpReview = followUpReview;
  }

  return out;
}

/** Validates the model's full parse-mode response. Enforces the 10-task cap by TRUNCATING
 *  (contract obligation 4: "enforce ... the 10-task cap server-side" — truncation is the safe
 *  enforcement here, since a prompt-injection attempt to make the model emit >10 tasks must not
 *  be able to smuggle task #11+ through under any circumstance).
 *
 *  Per-TASK fail-open (decision: anh Khôi, 2026-07-28): a task that fails `validateParsedTask`
 *  (i.e. has no valid `title`) is dropped individually, not the whole array — one bad task must
 *  not cost the user the other N-1 good ones. `droppedCount` counts BOTH kinds of loss the client
 *  never sees: tasks truncated past `MAX_TASKS` and tasks dropped for failing validation; it is
 *  logged in `parse/index.ts` purely as a model-quality signal ("model produced output that didn't
 *  reach the user"), and both causes belong under that same signal.
 *
 *  Returns `undefined` (-> `parse/index.ts` returns 502) only when:
 *  - `v` is not an array at all, or
 *  - `v` is a NON-EMPTY array but EVERY task in it fails validation — i.e. the model produced
 *    nothing usable at all. That is a real upstream failure, distinct from "one task in three was
 *    malformed."
 *  An empty array IS a valid, well-formed response (the model legitimately found no actionable
 *  tasks in the transcript, e.g. small talk) — it must return `200 []`, not a 502; rejecting it
 *  as malformed would burn a full quota slot on a request that produced a perfectly good answer. */
export function validateParsedTaskArray(v: unknown): { tasks: ParsedTaskOut[]; droppedCount: number } | undefined {
  if (!Array.isArray(v)) return undefined;
  const tasks: ParsedTaskOut[] = [];
  let invalidCount = 0;
  for (const item of v) {
    const task = validateParsedTask(item);
    if (task) {
      tasks.push(task);
    } else {
      invalidCount++;
    }
  }
  // Non-empty input that yielded zero usable tasks: every single task was malformed, which is a
  // genuine upstream failure, not "one bad task among good ones" — surface it as 502 rather than
  // a hollow `200 []`.
  if (v.length > 0 && tasks.length === 0) return undefined;
  const droppedCount = invalidCount + Math.max(0, tasks.length - MAX_TASKS);
  return { tasks: tasks.slice(0, MAX_TASKS), droppedCount };
}

/** Validates the model's breakdown-mode response `{ steps: [...] }`. Step COUNT outside
 *  [3, 9] is treated as a malformed response (502) rather than truncated/padded — silently
 *  dropping or inventing steps would misrepresent what the model actually produced. Individual
 *  `estimateMinutes` are clamped into [5, 15] (contract: "5-15 minutes") since clamping a
 *  slightly-off estimate is safe and preserves step count/order, unlike dropping a step. */
export function validateBreakdownSteps(v: unknown): BreakdownStepOut[] | undefined {
  if (!isPlainObject(v)) return undefined;
  if (!Array.isArray(v.steps)) return undefined;
  if (v.steps.length < MIN_BREAKDOWN_STEPS || v.steps.length > MAX_BREAKDOWN_STEPS) return undefined;
  const steps: BreakdownStepOut[] = [];
  for (const s of v.steps) {
    if (!isPlainObject(s)) return undefined;
    if (!isNonEmptyString(s.title) || s.title.length > MAX_TASK_TITLE_CHARS) return undefined;
    if (!isFiniteNumber(s.estimateMinutes)) return undefined;
    const clamped = Math.min(MAX_STEP_MINUTES, Math.max(MIN_STEP_MINUTES, Math.round(s.estimateMinutes)));
    steps.push({ title: s.title, estimateMinutes: clamped });
  }
  return steps;
}

/** Shared by `validateDreadMessage` and `validateNextActionMessage` below — both are a `stuck`
 *  sub-mode's `{ message: string }` response, differing ONLY in their character cap (dread names a
 *  detail AND proposes an action, two clauses' worth of room; a next-action is the action alone,
 *  a single sentence — see `MAX_NEXT_ACTION_CHARS`'s doc comment for why these are deliberately
 *  DIFFERENT numbers, not a shared constant). FAIL-CLOSED (returns `undefined`, never a
 *  best-effort repaired string) on ANY violation — an empty message, a non-string, or anything
 *  over `maxChars` — mirroring `validateBreakdownSteps`'s "malformed output is a genuine upstream
 *  failure, not something to silently truncate/patch" posture, NOT `validateParsedTask`'s
 *  per-FIELD fail-open posture: there is exactly one field here, so "drop the bad field" and "drop
 *  the whole response" are the same operation, and `parse/index.ts` maps `undefined` to its
 *  existing opaque 502 (the client already treats that identically to "no suggestion available"
 *  per its own fallback contract — see `Volar/Sources/Parsing/CloudParser.swift`'s
 *  `dreadDetailed`/`nextActionDetailed`). Never truncates an over-long message to fit the cap: a
 *  model that ignored the length instruction is exactly the kind of "went off the rails" output
 *  this cap exists to catch, so it is rejected outright rather than silently reshaped into
 *  something the model never actually said. Trims whitespace only (never alters content
 *  otherwise). */
function validateShortMessage(v: unknown, maxChars: number): string | undefined {
  if (!isPlainObject(v)) return undefined;
  if (!isNonEmptyString(v.message)) return undefined;
  const trimmed = v.message.trim();
  if (trimmed.length === 0 || trimmed.length > maxChars) return undefined;
  return trimmed;
}

/** Validates the model's `stuck`/`reason: "dread"` response `{ message: string }` against
 *  `MAX_DREAD_MESSAGE_CHARS`. See `validateShortMessage`'s doc comment for the full fail-closed
 *  rationale, shared verbatim with `validateNextActionMessage` below. */
export function validateDreadMessage(v: unknown): string | undefined {
  return validateShortMessage(v, MAX_DREAD_MESSAGE_CHARS);
}

/** Validates the model's `stuck`/`reason: "too_big"` response `{ message: string }` (anh Khôi,
 *  2026-07-29 REDESIGN — this reason used to produce a 3-9 step plan via `validateBreakdownSteps`;
 *  it now produces exactly ONE next physical action, this validator's job) against
 *  `MAX_NEXT_ACTION_CHARS` — its OWN, shorter cap than `validateDreadMessage`'s, see that
 *  constant's doc comment. See `validateShortMessage`'s doc comment for the full fail-closed
 *  rationale. */
export function validateNextActionMessage(v: unknown): string | undefined {
  return validateShortMessage(v, MAX_NEXT_ACTION_CHARS);
}

// ---------------------------------------------------------------------------------------------
// resolve_completion response (model -> us -> client).
//
// **`matchIndex` is 1-BASED, and this is load-bearing and dangerous.** The prompt numbers the
// candidate list "1." through "N." (matching how the request's `candidates` array is presented
// to the model), so the model answers in that 1-based space. `candidates[matchIndex - 1]` is the
// resolved title — an off-by-one here marks the WRONG task done, not a cosmetic bug. The client
// re-verifies `matchTitle` against `candidates[matchIndex - 1]` as a SECOND, INDEPENDENT check
// before acting on this response — do not "simplify" `matchTitle` away as redundant with
// `matchIndex`; it is the client's cross-check against exactly this class of indexing bug.
// ---------------------------------------------------------------------------------------------

export interface ResolveCompletionOut {
  intent: "complete" | "clear_external" | "none";
  // 1-BASED index into the request's `candidates` (i.e. candidate "1." in the prompt == index 1
  // here == `candidates[0]` in the request array). Present iff `intent !== "none"`.
  matchIndex?: number;
  // The model's verbatim echo of the matched candidate title — the client's independent
  // cross-check against `candidates[matchIndex - 1]`. Present iff `intent !== "none"`.
  matchTitle?: string;
  confidence: number; // 0.0 .. 1.0
}

/** Validates the model's resolve_completion-mode output. Returns `undefined` (never throws) on
 *  ANY structural mismatch — the caller maps `undefined` to a safe `{ intent: "none", confidence:
 *  0 }` rather than guessing or best-effort-repairing, per constitution II: this decides which of
 *  the user's tasks gets marked done, so untrusted model output is never partially trusted.
 *
 *  `candidateCount` is the length of the REQUEST's `candidates` array — `matchIndex` must be an
 *  integer in `1...candidateCount` inclusive (reject 0, reject `candidateCount + 1`, reject
 *  non-integers like 2.5). See the module-level comment above for why 1-based indexing here is
 *  load-bearing. */
export function validateResolveCompletion(
  v: unknown,
  candidateCount: number,
): ResolveCompletionOut | undefined {
  if (!isPlainObject(v)) return undefined;

  if (v.intent !== "complete" && v.intent !== "clear_external" && v.intent !== "none") {
    return undefined;
  }

  // Confidence is NEVER clamped — a model emitting e.g. 7 is a model not following instructions,
  // and this decides task completion, so it is rejected outright rather than silently coerced
  // into range.
  if (!isFiniteNumber(v.confidence) || v.confidence < 0 || v.confidence > 1) return undefined;

  if (v.intent === "none") {
    // matchIndex/matchTitle must be absent or null when intent is "none" — anything else means
    // the model is contradicting its own "none" answer with a dangling match.
    if (v.matchIndex !== undefined && v.matchIndex !== null) return undefined;
    if (v.matchTitle !== undefined && v.matchTitle !== null) return undefined;
    return { intent: "none", confidence: v.confidence };
  }

  // intent === "complete" | "clear_external": matchIndex MUST be a 1-based integer in range, and
  // matchTitle MUST be a non-empty string (the client's independent cross-check field).
  if (
    !isFiniteNumber(v.matchIndex) ||
    !Number.isInteger(v.matchIndex) ||
    v.matchIndex < 1 ||
    v.matchIndex > candidateCount
  ) {
    return undefined;
  }
  if (!isNonEmptyString(v.matchTitle)) return undefined;

  return {
    intent: v.intent,
    matchIndex: v.matchIndex,
    matchTitle: v.matchTitle,
    confidence: v.confidence,
  };
}
