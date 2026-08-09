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

/** `task_refs_v1` capability (anh Khôi, 2026-08-02 task-refs design): "làm task này khi xong task
 *  kia", "task kia phải xong hôm nay" — the model needs to REFERENCE existing/implied tasks and
 *  express UPDATES to them, on top of the tasks it already extracts fresh. These three caps mirror
 *  `MAX_TASKS`/`MAX_TASK_TITLE_CHARS` etc above: defense-in-depth truncation of the model's own
 *  output, independent of whatever the prompt asked for. */
export const MAX_TASK_REFS = 10;
export const MAX_UPDATES = 10;
/** One year in minutes — the outer bound on `offsetMinutes` for the `taskDone`/`taskStart`
 *  condition extensions (task_refs_v1). Not a precise product number, just a sanity ceiling: a
 *  model emitting an offset bigger than this has gone off the rails (misread "2 giờ" as some huge
 *  number, unit confusion, etc.) rather than expressed a real "sau khi xong X" request, so the
 *  field is dropped (fail-open, same as every other model-output cap in this file) rather than
 *  accepted at face value. */
export const MAX_CONDITION_OFFSET_MINUTES = 525600;

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
  /** `client_caps` (task_refs_v1, anh Khôi 2026-08-02 task-refs design): a capability handshake,
   *  NOT a version number. App Store clients fragment across versions while this Edge Function
   *  redeploys freely, so compat cannot be "if client version >= X" — a client instead lists the
   *  response-shape capabilities it knows how to consume. Absent entirely -> today's behavior,
   *  BYTE-IDENTICAL (bare `ParsedTaskOut[]`, `SYSTEM_PREAMBLE`, `buildParseResponseSchema()`,
   *  `validateParsedTaskArray`). Present -> every recognized cap in it may change the RESPONSE
   *  shape (see `wantsEnvelope` in `parse/index.ts`); an UNRECOGNIZED cap string is silently
   *  ignored, never rejected — a client sent from the future naming a cap this deployed version
   *  doesn't know yet must still get a working response, not a 400. All evolution here is meant to
   *  be strictly ADDITIVE: new caps unlock more of the response, they never repurpose or remove
   *  what an older cap (or no cap) already returns. The only recognized cap as of this writing is
   *  `"task_refs_v1"` (see `TaskRefOut`/`TaskUpdateOut` below). */
  clientCaps?: string[];
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

  // `client_caps` (task_refs_v1, anh Khôi 2026-08-02): see `ParseRequest.clientCaps`'s doc comment
  // for the full capability-handshake rationale. This is a SHAPE check only — a wire-level guard
  // against a malformed/hostile array (wrong type, too many entries, an oversized or empty string
  // masquerading as a cap name) — it deliberately does NOT check individual cap strings against a
  // known-caps allowlist: an unrecognized cap is a normal, expected, forward-compatible case (a
  // future client naming a capability this deployed version doesn't act on yet), never a 400.
  let clientCaps: string[] | undefined;
  if (body.client_caps !== undefined) {
    if (
      !Array.isArray(body.client_caps) ||
      body.client_caps.length > 16 ||
      !body.client_caps.every((c) => typeof c === "string" && c.length > 0 && c.length <= 64)
    ) {
      return { ok: false, error: "client_caps must be an array of up to 16 short strings" };
    }
    clientCaps = body.client_caps as string[];
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
      clientCaps,
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
  // `"taskStart"` added for task_refs_v1 (anh Khôi, 2026-08-02 task-refs design) — see
  // `validateCondition`'s doc comment: only ever produced/accepted in ENVELOPE mode, a bare-array
  // response never carries it, matching how `SYSTEM_PREAMBLE` (not `SYSTEM_PREAMBLE_TASK_REFS`)
  // never asks for it either.
  kind: "taskDone" | "afterDate" | "external" | "taskStart";
  referenceTitle?: string; // kind === taskDone | taskStart: fuzzy title, client resolves via picker
  date?: string; // kind === afterDate: ISO8601
  description?: string; // kind === external
  /** task_refs_v1: precise pointer complementing the fuzzy `referenceTitle` above — 1-based into
   *  this response's validated `taskRefs[]` (`referenceTitle` stays REQUIRED regardless, as a
   *  cross-check + the legacy path for clients that never send `taskRefs` context back). Envelope
   *  mode only — see `validateCondition`'s doc comment for the back-compat rule. Valid on BOTH
   *  `taskDone` and `taskStart`. */
  refIndex?: number;
  /** task_refs_v1: minutes offset relative to the referenced task's completion (`taskDone`) or
   *  start (`taskStart`) — "nhắc mỗi 2h sau khi xong task kia" = 120 on a `taskDone` condition;
   *  "nhắc ít nhất 2h trước khi làm task kia" = -120 on a `taskStart` condition (negative = before
   *  the reference's start; `taskDone` offsets are always positive, since "before it's done" isn't
   *  a coherent instant). Envelope mode only. */
  offsetMinutes?: number;
  /** task_refs_v1: whether `offsetMinutes` is an exact delay (`"exact"`) or a floor/"at least"
   *  (`"atLeast"`). Envelope mode only. */
  offsetKind?: "exact" | "atLeast";
}

export interface ParsedRecurrenceOut {
  type: "daily" | "weekly" | "monthly" | "every";
  everyDays?: number; // required when type === "every"
}

export interface ParsedReminderOverrideOut {
  // Relative to deadline, negative = before. NON-OPTIONAL on the wire (matches the client's
  // non-optional `[Double]` decode target) — when the model emits only `remindPeriodMinutes`
  // (e.g. "nhắc tôi mỗi 15 phút"), `validateReminderOverride` SYNTHESIZES a single entry here
  // rather than omitting the field; see that function's doc comment.
  offsetsMinutes: number[];
  repeatEveryMinutes?: number;
  // Chu kỳ nhắc TRƯỚC deadline (phút) khi user nói rõ, VD "nhắc tôi mỗi 15 phút" -> 15. Khác
  // `repeatEveryMinutes` ở trên (lặp SAU deadline, xem ReminderPolicy.repeatEvery trong
  // Volar/Sources/Model/Recurrence.swift) -- không phải cùng field đổi tên. Client dùng mặc định
  // riêng (nhắc ở 1/2 và 1/3 thời gian còn lại) khi field này vắng mặt.
  remindPeriodMinutes?: number;
  /** task_refs_v1 (anh Khôi, 2026-08-02 task-refs design): "anchor this reminder to a REFERENCED
   *  task's own done/start event, instead of to THIS task's own deadline" — e.g. "nhắc tôi 15 phút
   *  sau khi task kia xong". `refIndex` is 1-based into this response's validated `taskRefs[]`.
   *  FAIL-OPEN AS A UNIT (see `validateReminderOverride`): a malformed anchor drops only itself,
   *  never the rest of this override. Envelope mode only — never populated on a bare-array
   *  response. */
  anchor?: { refIndex: number; event: "done" | "start" };
}

/** task_refs_v1 (anh Khôi, 2026-08-02 task-refs design): one existing (or user-implied) task the
 *  model believes the utterance is pointing at — "làm task này khi xong task kia", "task kia phải
 *  xong hôm nay". The client resolves IDENTITY locally (fuzzy-matches `titleQuery` against its own
 *  task store, or treats it as "no such task yet" if nothing matches) and NEVER auto-commits any
 *  `TaskUpdateOut` off the back of a ref alone — every update is user-confirmed. This server only
 *  ever validates SHAPE; it holds no task ids and makes no matching decision itself. */
export interface TaskRefOut {
  /** The words identifying the referenced task — either an exact copy of one of the request's
   *  `open_task_titles` entries (the model recognized a real existing task), or the user's own
   *  spoken words when it can't find a match (so the client can still show "did you mean...", or
   *  treat it as a forward reference to a task not seen yet). FAIL-CLOSED: an element with no
   *  words to search by is meaningless to the client's local resolver, so the whole ref element is
   *  dropped rather than kept with an empty query. */
  titleQuery: ConfidenceValue<string>;
  /** The model's HINT that the user referred to an ALREADY-EXISTING task (vs. a brand-new one it
   *  just extracted, or one it can't find at all). Advisory only — the client's own local
   *  resolution is the source of truth, this never causes an auto-commit by itself. FAIL-OPEN: a
   *  wrong-typed value just omits the field, keeping the rest of the ref (see `validateTaskRef`). */
  assumeExisting?: boolean;
}

/** task_refs_v1: the fields of an existing task's own edit this update proposes, reusing the SAME
 *  inner validators as the matching field on `ParsedTaskOut` (see `validateTaskUpdate`) so a
 *  `deadline`/`priority`/etc value validates identically whether it lands on a brand-new task or as
 *  an edit to a referenced one. Each field is independently FAIL-OPEN. */
export interface TaskUpdateSetOut {
  deadline?: ConfidenceValue<string>;
  startTime?: ConfidenceValue<string>;
  /** APPEND semantics, not replace — the client appends this to the referenced task's EXISTING
   *  notes; named `notesAppend` (not `notes`) specifically so it is never confused with
   *  `ParsedTaskOut.notes`'s replace-the-whole-field semantics. */
  notesAppend?: ConfidenceValue<string>;
  priority?: ConfidenceValue<number>;
  reminderOverride?: ConfidenceValue<ParsedReminderOverrideOut>;
}

/** task_refs_v1: one NEW dependency this update proposes adding to the referenced (existing) task.
 *  `newTaskIndex` points into the SAME response's own freshly-extracted `tasks[]` (1-based,
 *  post-validation/truncation) — "the referenced existing task must now wait for new task #N" —
 *  deliberately a DIFFERENT index space from `TaskUpdateOut.refIndex` (which points into
 *  `taskRefs[]`); do not conflate the two. Per-element FAIL-OPEN (see `validateTaskUpdateCondition`
 *  — an element that doesn't fully validate carries no information, so it's dropped whole rather
 *  than partially kept). */
export type TaskUpdateConditionOut =
  | { kind: "taskDone"; newTaskIndex: number }
  | { kind: "afterDate"; date: string };

/** task_refs_v1 (anh Khôi, 2026-08-02 task-refs design): "task kia phải xong hôm nay" — the model
 *  expresses an UPDATE to an EXISTING task (identified via `taskRefs[refIndex - 1]`) rather than a
 *  new task. The client NEVER auto-applies this — it is always surfaced for user confirmation
 *  before touching the referenced task, mirroring the constitutional rule that untrusted model
 *  output never silently mutates user data (see `validateResolveCompletion`'s own doc comment for
 *  the same posture on a different route). An utterance that ONLY updates an existing task (e.g.
 *  "task kia phải xong hôm nay", no new task mentioned at all) legitimately produces an EMPTY
 *  `tasks[]` alongside a non-empty `updates[]` — that is a valid response, not an error (see
 *  `validateParseEnvelope`'s doc comment). */
export interface TaskUpdateOut {
  /** REQUIRED, 1-based into this response's validated `taskRefs[]` (validated AFTER `taskRefs`
   *  truncation, i.e. against the truncated/validated count) — same 1-based convention + rationale
   *  as `validateResolveCompletion`'s `matchIndex`: an update that doesn't point at a real ref is
   *  meaningless, and worse, dangerous to misapply to the wrong task, so the WHOLE element is
   *  dropped (FAIL-CLOSED) rather than guessed at. See `validateTaskUpdate`. */
  refIndex: number;
  set?: TaskUpdateSetOut;
  addConditions?: TaskUpdateConditionOut[];
}

export interface ParsedSubtaskOut {
  title: ConfidenceValue<string>;
  estimateMinutes: ConfidenceValue<number>;
}

/** `task_cues_v1` capability (Opus design 2026-08-08, `specs/006-cues-and-waiting/design.md` §2
 *  Việc B — implementation-intention cues, "ngủ dậy thì test feature này"): the model's belief
 *  that this task is anchored to an EVENT in the user's day rather than to a clock time. NOT
 *  wrapped in `ConfidenceValue` like most other optional fields on `ParsedTaskOut` — see
 *  `cueSchema`'s doc comment in gemini.ts for why a confidence number doesn't map cleanly onto
 *  this field. Only ever populated when the request declared the `task_cues_v1` client cap (see
 *  `validateParsedTaskArrayWithCues` below) — a client that never declares it gets a response with
 *  no `cue` key at all, byte-identical to before this capability existed. */
export interface CueOut {
  /** Coarse hint for WHEN this cue's moment tends to occur, used by the client
   *  (`Volar/Sources/Reminders/CueFiring.swift`, a sibling task of this same feature) to decide
   *  when it's worth surfacing — `wake`/`dayEnd` fire on their own cadence, `unknown` never fires
   *  on a timer and is only shown at a natural touch point. `unknown` is a normal, common, VALID
   *  value, never a failure state: the model failing to classify a cue's rough timing must never
   *  cost the user the cue's own words (see `verbatim` below, and `validateCue`'s fail-open rule
   *  for this exact field). */
  kind: "wake" | "dayEnd" | "unknown";
  /** The user's OWN anchor clause, verbatim — e.g. "ngủ dậy thì" from "ngủ dậy thì test feature
   *  này". This, not `kind`, is where this capability's entire value lives: it is what gets read
   *  back to the user later, unlike `kind`, which is only ever consumed internally to decide
   *  timing. FAIL-CLOSED in `validateCue` below — a `cue` with no usable `verbatim` carries no
   *  information at all and is dropped whole, never kept as "a cue with unknown wording." */
  verbatim: string;
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
  cue?: CueOut;
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

/** task_refs_v1 (anh Khôi, 2026-08-02): the context `validateParseEnvelope` threads down through
 *  `validateParsedTaskArray`'s internals to `validateParsedTask` -> `validateCondition`/
 *  `validateReminderOverride`, ONLY on the envelope path — the bare-array path never constructs
 *  one, so every call site below defaults it to `undefined` and treats that as "old behavior,
 *  exactly as before". `taskRefCount` is the TRUNCATED/validated `taskRefs.length`, i.e. valid
 *  `refIndex` values are the inclusive range `1...taskRefCount`. */
interface ParseEnvelopeCtx {
  taskRefCount: number;
}

/** Shared by `taskDone` and `taskStart` conditions in envelope mode: validates the OPTIONAL
 *  `refIndex` field — 1-based into `taskRefs[]`. FAIL-OPEN: a missing/malformed value returns
 *  `undefined` and the caller simply omits the field, keeping the rest of the condition — this is
 *  a precise pointer that COMPLEMENTS the fuzzy `referenceTitle`, which stays the required/primary
 *  signal (see `ParsedConditionOut.refIndex`'s doc comment), so losing it is never fatal to the
 *  condition as a whole. */
function validateRefIndex(v: Record<string, unknown>, ctx: ParseEnvelopeCtx): number | undefined {
  if (
    isFiniteNumber(v.refIndex) &&
    Number.isInteger(v.refIndex) &&
    v.refIndex >= 1 &&
    v.refIndex <= ctx.taskRefCount
  ) {
    return v.refIndex;
  }
  return undefined;
}

/** Shared by `taskDone` and `taskStart` conditions in envelope mode: validates the OPTIONAL
 *  `offsetMinutes`/`offsetKind` pair. `allowNegative` is the one behavioral difference between the
 *  two kinds: `taskDone`'s offset is always AFTER the referenced task finishes ("2h sau khi xong
 *  X" — positive only, "before it's done" isn't a coherent instant), while `taskStart`'s offset may
 *  be negative — "before the referenced task's start" ("nhắc ít nhất 2h trước khi làm task kia" =
 *  -120) — as well as positive. Zero is rejected in both directions: an offset of 0 minutes is
 *  indistinguishable from "at the moment", which needs no offset field at all. FAIL-OPEN, and as
 *  ONE UNIT: a malformed/missing `offsetMinutes` drops BOTH fields (an `offsetKind` with no
 *  `offsetMinutes` to modify is meaningless on its own); a malformed `offsetKind` alone drops only
 *  itself and keeps `offsetMinutes`. */
function validateOffsetFields(
  v: Record<string, unknown>,
  allowNegative: boolean,
): { offsetMinutes?: number; offsetKind?: "exact" | "atLeast" } {
  if (v.offsetMinutes === undefined) return {};
  const n = v.offsetMinutes;
  const inRange = allowNegative
    ? isFiniteNumber(n) && Number.isInteger(n) && n !== 0 &&
      n >= -MAX_CONDITION_OFFSET_MINUTES && n <= MAX_CONDITION_OFFSET_MINUTES
    : isFiniteNumber(n) && Number.isInteger(n) && n >= 1 && n <= MAX_CONDITION_OFFSET_MINUTES;
  if (!inRange) return {};
  const out: { offsetMinutes?: number; offsetKind?: "exact" | "atLeast" } = { offsetMinutes: n as number };
  if (v.offsetKind === "exact" || v.offsetKind === "atLeast") out.offsetKind = v.offsetKind;
  return out;
}

/** Validates a single `conditions[]` element. `ctx` present (envelope mode, task_refs_v1) unlocks:
 *  (a) the `"taskStart"` kind entirely, and (b) three extra OPTIONAL fields on `"taskDone"`
 *  (`refIndex`/`offsetMinutes`/`offsetKind`) — see `ParsedConditionOut`'s doc comments for what
 *  each means. `ctx` ABSENT (the bare-array path every pre-existing caller of
 *  `validateParsedTaskArray` still uses) validates EXACTLY as before this change: `"taskStart"` is
 *  an unrecognized kind and the whole element is dropped (same as any other bogus `kind` always
 *  was), and `taskDone`'s three extra fields are never even inspected, let alone emitted — this is
 *  the back-compat guarantee the task brief requires (a client that never sent `client_caps` must
 *  get a byte-identical response to before this feature existed). */
function validateCondition(v: unknown, ctx?: ParseEnvelopeCtx): ParsedConditionOut | undefined {
  if (!isPlainObject(v)) return undefined;
  const validKinds: string[] = ctx
    ? ["taskDone", "afterDate", "external", "taskStart"]
    : ["taskDone", "afterDate", "external"];
  if (typeof v.kind !== "string" || !validKinds.includes(v.kind)) return undefined;

  if (v.kind === "taskDone") {
    // Unchanged from before this feature: `referenceTitle` required, no length cap (never had
    // one) — do not add one here, that would be a behavior change on the bare-array path too.
    if (!isNonEmptyString(v.referenceTitle)) return undefined;
    const out: ParsedConditionOut = { kind: "taskDone", referenceTitle: v.referenceTitle };
    if (ctx) {
      const refIndex = validateRefIndex(v, ctx);
      if (refIndex !== undefined) out.refIndex = refIndex;
      Object.assign(out, validateOffsetFields(v, false));
    }
    return out;
  }
  if (v.kind === "afterDate") {
    if (!isIso8601(v.date)) return undefined;
    return { kind: "afterDate", date: v.date as string };
  }
  if (v.kind === "taskStart") {
    // Only reachable when ctx is present (`validKinds` excludes "taskStart" otherwise). REQUIRED,
    // FAIL-CLOSED `referenceTitle` — unlike `taskDone` above, this is a BRAND NEW kind with no
    // legacy behavior to preserve, so it gets the same cap every other model-emitted title field
    // in this file carries.
    if (!isNonEmptyString(v.referenceTitle) || (v.referenceTitle as string).length > MAX_TASK_TITLE_CHARS) {
      return undefined;
    }
    const out: ParsedConditionOut = { kind: "taskStart", referenceTitle: v.referenceTitle as string };
    const refIndex = validateRefIndex(v, ctx!);
    if (refIndex !== undefined) out.refIndex = refIndex;
    Object.assign(out, validateOffsetFields(v, true)); // negative offsets allowed ("before start")
    return out;
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

/** `offsetsMinutes` synthesis from a bare `remindPeriodMinutes` (2026-08-07): why this is done by
 *  SYNTHESIZING a value rather than making `offsetsMinutes` optional on the wire.
 *
 *  The Swift client (`Volar/Sources/Parsing/IntentParsing.swift`) declares
 *  `var offsetsMinutes: [Double]` — NON-OPTIONAL. A shipped App Store client decoding a
 *  `reminderOverride` that omits `offsetsMinutes` throws, and per the hardening rule this repo
 *  adopted on 2026-08-01 (after `RawParsedReminderOverride` was found missing this same field
 *  client-side), a decode throw doesn't just drop the one field — it loses the WHOLE task batch.
 *  So relaxing this field to optional here would trade "reminder silently dropped" for "entire
 *  response silently dropped," which is strictly worse. The wire shape must stay exactly as it is
 *  today; only the SERVER's willingness to fill it in changes.
 *
 *  Before this fix: a model response of `{remindPeriodMinutes: 15}` alone (the correct shape for
 *  "nhắc tôi mỗi 15 phút" — a repeating cadence, no single moment to name) hit the
 *  `offsetsMinutes` empty-array check above and discarded the ENTIRE override, silently, with
 *  nothing logged. The feature was dead on arrival. Do not "simplify" this back to a bare
 *  emptiness check on `offsetsMinutes` without re-reading this comment — that reintroduces the
 *  2026-08-07 bug, and making the field optional instead reintroduces the 2026-08-01 bug.
 *
 *  The synthesized single entry is `[-remindPeriodMinutes]`: one reminder one period before the
 *  deadline — the first tick of the very cadence the user asked for. */
function validateReminderOverride(v: unknown, ctx?: ParseEnvelopeCtx): ParsedReminderOverrideOut | undefined {
  if (!isPlainObject(v)) return undefined;

  const hasValidOffsets = Array.isArray(v.offsetsMinutes) && v.offsetsMinutes.length > 0 &&
    v.offsetsMinutes.every((n) => isFiniteNumber(n));

  // Eligibility for SYNTHESIS only (separate from the existing `remindPeriodMinutes` output check
  // below, which must stay byte-identical to preserve today's behavior when `offsetsMinutes` is
  // already present and valid). Same magnitude ceiling every other offset-in-minutes field in this
  // file uses (`MAX_CONDITION_OFFSET_MINUTES`, see its doc comment) — a `remindPeriodMinutes` this
  // large has gone off the rails the same way an oversized `offsetMinutes` would, so it must not be
  // trusted to synthesize a reminder from either.
  const periodUsableForSynthesis = isFiniteNumber(v.remindPeriodMinutes) &&
    (v.remindPeriodMinutes as number) > 0 &&
    (v.remindPeriodMinutes as number) <= MAX_CONDITION_OFFSET_MINUTES;

  let offsetsMinutes: number[];
  if (hasValidOffsets) {
    offsetsMinutes = v.offsetsMinutes as number[];
  } else if (periodUsableForSynthesis) {
    offsetsMinutes = [-(v.remindPeriodMinutes as number)];
  } else {
    return undefined;
  }

  const out: ParsedReminderOverrideOut = { offsetsMinutes };
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
  // `anchor` (task_refs_v1, anh Khôi 2026-08-02): ONLY inspected when `ctx` is present (envelope
  // mode) — a bare-array caller never passes `ctx`, so this block never runs there and `anchor`
  // never appears on that path, matching every other task_refs_v1 field's back-compat rule.
  // FAIL-OPEN AS A UNIT (unlike `repeatEveryMinutes` above, which fails the WHOLE override): a
  // malformed anchor drops only the anchor object, never `offsetsMinutes`/`repeatEveryMinutes`/
  // `remindPeriodMinutes` already validated above — an unresolvable anchor still leaves a perfectly
  // usable deadline-relative reminder behind.
  if (ctx && isPlainObject(v.anchor)) {
    const refIndex = v.anchor.refIndex;
    const event = v.anchor.event;
    if (
      isFiniteNumber(refIndex) &&
      Number.isInteger(refIndex) &&
      refIndex >= 1 &&
      refIndex <= ctx.taskRefCount &&
      (event === "done" || event === "start")
    ) {
      out.anchor = { refIndex, event };
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

/** Validates a single `cue` field (`task_cues_v1`, Opus design 2026-08-08). FAIL-CLOSED on
 *  `verbatim`: a cue with no quoted words is not "a cue with unknown wording," it is nothing at
 *  all — there is no anchor left to read back to the user, so the whole `cue` is dropped (the
 *  TASK itself is untouched either way, per `validateParsedTask`'s per-field fail-open convention
 *  below — losing `cue` never costs the user the rest of the task). FAIL-OPEN on `kind`: an
 *  unrecognized or missing `kind` is coerced to `"unknown"` rather than dropping the cue —
 *  `verbatim` is the field carrying the actual product value (`CueOut`'s own doc comment), so a
 *  model that writes the right words but a wrong/missing classification must not lose them. Length
 *  capped at `MAX_TASK_TITLE_CHARS` — reusing the title cap rather than inventing a new constant,
 *  since a spoken anchor clause is the same order of magnitude as a task title, never a paragraph. */
function validateCue(v: unknown): CueOut | undefined {
  if (!isPlainObject(v)) return undefined;
  if (!isNonEmptyString(v.verbatim) || v.verbatim.length > MAX_TASK_TITLE_CHARS) return undefined;
  const kind = v.kind === "wake" || v.kind === "dayEnd" || v.kind === "unknown" ? v.kind : "unknown";
  return { kind, verbatim: v.verbatim };
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
 *  `out`.
 *
 *  `ctx` (task_refs_v1, anh Khôi 2026-08-02): OPTIONAL, threaded down to `validateCondition`/
 *  `validateReminderOverride` unchanged. Absent (every pre-existing bare-array call site) ->
 *  those two functions behave EXACTLY as they did before this change. Present (only from
 *  `validateParseEnvelope` via `validateParsedTaskArray`'s internal helper) -> unlocks the
 *  `taskStart` condition kind and the `refIndex`/`offsetMinutes`/`offsetKind`/`anchor` extension
 *  fields, all of which need to resolve against `taskRefs[]`.
 *
 *  `cuesEnabled` (task_cues_v1, Opus design 2026-08-08): OPTIONAL, and DELIBERATELY a separate
 *  parameter rather than a new field on `ParseEnvelopeCtx` — `task_cues_v1` and `task_refs_v1` are
 *  INDEPENDENT capabilities (`ParseRequest.clientCaps`'s doc comment: a client may declare either,
 *  neither, or both), so folding `cue` gating into the same `ctx` object that also gates
 *  `taskStart`/`refIndex`/`anchor` would wrongly couple the two — a bare-mode caller that only
 *  wants cues must NOT also unlock envelope-only condition kinds just because `ctx` became
 *  "present" for a different reason. Falsy/absent (every pre-existing call site, and the plain
 *  `validateParsedTaskArray`/`validateParseEnvelope` entry points below) -> `v.cue` is never even
 *  inspected, so a request that never declared `task_cues_v1` gets a response with no `cue` key at
 *  all — byte-identical to before this capability existed, the same guarantee `ctx` already gives
 *  `task_refs_v1`. */
function validateParsedTask(v: unknown, ctx?: ParseEnvelopeCtx, cuesEnabled?: boolean): ParsedTaskOut | undefined {
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
    const reminderOverride = validateConfidenceValue(v.reminderOverride, (inner) =>
      validateReminderOverride(inner, ctx)
    );
    if (reminderOverride) out.reminderOverride = reminderOverride;
  }

  // `conditions` is an ARRAY field: an individual malformed element is dropped on its own, keeping
  // the rest of the array — this is a finer-grained fail-open than the scalar fields above, but the
  // same underlying rule (one bad piece must not discard the good pieces around it). If `v.conditions`
  // itself isn't an array, the whole field is omitted (nothing valid to salvage).
  if (v.conditions !== undefined && Array.isArray(v.conditions)) {
    const conditions: ConfidenceValue<ParsedConditionOut>[] = [];
    for (const c of v.conditions) {
      const cond = validateConfidenceValue(c, (inner) => validateCondition(inner, ctx));
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

  // `cue` (task_cues_v1, Opus design 2026-08-08): gated on `cuesEnabled`, NOT merely on
  // `v.cue !== undefined` — see this function's own doc comment for why a client that never
  // declared the capability must get a response with no `cue` key at all, even in the (unlikely,
  // but possible) case the model emits one unprompted.
  if (cuesEnabled && v.cue !== undefined) {
    const cue = validateCue(v.cue);
    if (cue) out.cue = cue;
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
 *  as malformed would burn a full quota slot on a request that produced a perfectly good answer.
 *
 *  Internal `ctx`-aware implementation (task_refs_v1, anh Khôi 2026-08-02): factored out so
 *  `validateParseEnvelope` below can reuse the EXACT same truncation/fail-open/502 logic for the
 *  envelope path (where `tasks[]` validation needs to know `taskRefs.length` to resolve
 *  `refIndex`/`anchor` fields) without duplicating it. `validateParsedTaskArray`, the pre-existing
 *  EXPORTED function every bare-array caller already uses, keeps its exact original signature and
 *  behavior below — it is now a one-line call into this with `ctx` left `undefined`.
 *
 *  `cuesEnabled` (task_cues_v1, Opus design 2026-08-08): threaded straight through to
 *  `validateParsedTask` unchanged — see that function's doc comment for why this is a separate
 *  parameter from `ctx` rather than a field folded into it. */
function validateParsedTaskArrayCtx(
  v: unknown,
  ctx?: ParseEnvelopeCtx,
  cuesEnabled?: boolean,
): { tasks: ParsedTaskOut[]; droppedCount: number } | undefined {
  if (!Array.isArray(v)) return undefined;
  const tasks: ParsedTaskOut[] = [];
  let invalidCount = 0;
  for (const item of v) {
    const task = validateParsedTask(item, ctx, cuesEnabled);
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

export function validateParsedTaskArray(v: unknown): { tasks: ParsedTaskOut[]; droppedCount: number } | undefined {
  return validateParsedTaskArrayCtx(v);
}

/** `task_cues_v1`-aware counterpart to `validateParsedTaskArray` above (Opus design 2026-08-08,
 *  `specs/006-cues-and-waiting/design.md` §2 Việc B) — for a `parse`-mode request that declared
 *  ONLY `task_cues_v1` (not `task_refs_v1`), i.e. the response stays the plain bare-array shape
 *  (see `buildParseResponseSchemaWithCues`/`SYSTEM_PREAMBLE_TASK_CUES` in gemini.ts), just with
 *  each task's optional `cue` field now recognized. `ctx` is deliberately left `undefined` here —
 *  `task_cues_v1` and `task_refs_v1` are INDEPENDENT capabilities (`ParseRequest.clientCaps`'s doc
 *  comment: a client may declare either, neither, or both), and `taskStart`/`refIndex`/`anchor`
 *  must not silently unlock just because a request asked for cues. A future caller wanting BOTH
 *  capabilities together in one request needs its own combined entry point — not built here; see
 *  this task's final report for why. */
export function validateParsedTaskArrayWithCues(
  v: unknown,
): { tasks: ParsedTaskOut[]; droppedCount: number } | undefined {
  return validateParsedTaskArrayCtx(v, undefined, true);
}

// ---------------------------------------------------------------------------------------------
// task_refs_v1 envelope (anh Khôi, 2026-08-02 task-refs design). See `ParseRequest.clientCaps`,
// `TaskRefOut`, `TaskUpdateOut` above for the wire contract; `validateParseEnvelope` below is the
// entry point `parse/index.ts` calls when `wantsEnvelope` is true.
// ---------------------------------------------------------------------------------------------

/** Validates a single `TaskRefOut` element. FAIL-CLOSED on `titleQuery` (an element with no words
 *  to search by is meaningless to the client's local resolver — nothing downstream can act on it),
 *  FAIL-OPEN on `assumeExisting` (a wrong-typed hint just gets dropped; it is advisory only, the
 *  client's own local resolution is the source of truth and this server never auto-commits
 *  anything off it). See `TaskRefOut`'s own doc comment for the field semantics. */
function validateTaskRef(v: unknown): TaskRefOut | undefined {
  if (!isPlainObject(v)) return undefined;
  const titleQuery = validateConfidenceValue(v.titleQuery, (s) =>
    isNonEmptyString(s) && (s as string).length <= MAX_TASK_TITLE_CHARS ? (s as string) : undefined
  );
  if (!titleQuery) return undefined;
  const out: TaskRefOut = { titleQuery };
  if (typeof v.assumeExisting === "boolean") {
    out.assumeExisting = v.assumeExisting;
  }
  return out;
}

/** Validates one element of `TaskUpdateOut.addConditions`. Each element is checked as a WHOLE
 *  (fail-closed per element — an element that doesn't fully validate carries no usable
 *  information, unlike `ParsedTaskOut`'s independently-fail-open scalar fields) but a bad element
 *  is simply dropped from the array, not fatal to the array itself (that's the caller's loop).
 *  `newTaskIndex` is 1-based into THIS RESPONSE's own freshly-extracted, validated, truncated
 *  `tasks[]` — a DIFFERENT index space from `TaskUpdateOut.refIndex` (which points into
 *  `taskRefs[]`) — "the referenced existing task must now wait for new task #N", checked against
 *  `validatedTaskCount`, the count AFTER `MAX_TASKS` truncation, matching every other
 *  index-bounds check in this file being checked against the post-truncation count, never the
 *  model's raw claim. */
function validateTaskUpdateCondition(v: unknown, validatedTaskCount: number): TaskUpdateConditionOut | undefined {
  if (!isPlainObject(v)) return undefined;
  if (v.kind === "taskDone") {
    if (
      !isFiniteNumber(v.newTaskIndex) ||
      !Number.isInteger(v.newTaskIndex) ||
      v.newTaskIndex < 1 ||
      v.newTaskIndex > validatedTaskCount
    ) {
      return undefined;
    }
    return { kind: "taskDone", newTaskIndex: v.newTaskIndex };
  }
  if (v.kind === "afterDate") {
    if (!isIso8601(v.date)) return undefined;
    return { kind: "afterDate", date: v.date as string };
  }
  return undefined;
}

/** Validates a single `TaskUpdateOut` element. `refIndex` is REQUIRED and FAIL-CLOSED — same
 *  1-based convention + rationale as `validateResolveCompletion`'s `matchIndex` below: an update
 *  that doesn't point at a real ref is meaningless, and worse, dangerous to misapply to the wrong
 *  task, so the whole element is dropped rather than guessed at. `refCount` here is already the
 *  TRUNCATED/validated `taskRefs.length` (`validateParseEnvelope` validates `taskRefs` BEFORE
 *  `updates`, specifically so this bound is available) — a `refIndex` pointing at a ref that
 *  itself got dropped (invalid) or truncated past `MAX_TASK_REFS` is therefore correctly
 *  out-of-range here too, with no separate check needed.
 *
 *  `set`/`addConditions` are each independently validated, reusing the SAME inner validators as
 *  the matching field on `ParsedTaskOut` so a value validates identically whether it lands on a
 *  brand-new task or as an edit to a referenced one — see `TaskUpdateSetOut`'s doc comment. An
 *  element whose `set` validated to nothing AND whose `addConditions` validated to nothing carries
 *  no information at all (a no-op update) and is dropped entirely, counted in the caller's
 *  `droppedCount`. */
function validateTaskUpdate(v: unknown, refCount: number, validatedTaskCount: number): TaskUpdateOut | undefined {
  if (!isPlainObject(v)) return undefined;

  if (
    !isFiniteNumber(v.refIndex) ||
    !Number.isInteger(v.refIndex) ||
    v.refIndex < 1 ||
    v.refIndex > refCount
  ) {
    return undefined;
  }

  let set: TaskUpdateSetOut | undefined;
  if (isPlainObject(v.set)) {
    const raw = v.set;
    const s: TaskUpdateSetOut = {};
    if (raw.deadline !== undefined) {
      const deadline = validateConfidenceValue(raw.deadline, (x) => (isIso8601(x) ? (x as string) : undefined));
      if (deadline) s.deadline = deadline;
    }
    if (raw.startTime !== undefined) {
      const startTime = validateConfidenceValue(raw.startTime, (x) => (isIso8601(x) ? (x as string) : undefined));
      if (startTime) s.startTime = startTime;
    }
    if (raw.notesAppend !== undefined) {
      const notesAppend = validateConfidenceValue(raw.notesAppend, (x) =>
        typeof x === "string" && x.length <= MAX_NOTES_CHARS ? x : undefined
      );
      if (notesAppend) s.notesAppend = notesAppend;
    }
    if (raw.priority !== undefined) {
      const priority = validateConfidenceValue(raw.priority, (x) =>
        isFiniteNumber(x) && Number.isInteger(x) && x >= 1 && x <= 4 ? x : undefined
      );
      if (priority) s.priority = priority;
    }
    if (raw.reminderOverride !== undefined) {
      const reminderOverride = validateConfidenceValue(raw.reminderOverride, (x) =>
        validateReminderOverride(x, { taskRefCount: refCount })
      );
      if (reminderOverride) s.reminderOverride = reminderOverride;
    }
    if (Object.keys(s).length > 0) set = s;
  }

  let addConditions: TaskUpdateConditionOut[] | undefined;
  if (Array.isArray(v.addConditions)) {
    const conds: TaskUpdateConditionOut[] = [];
    for (const c of v.addConditions) {
      const cond = validateTaskUpdateCondition(c, validatedTaskCount);
      if (cond) conds.push(cond);
    }
    if (conds.length > 0) addConditions = conds;
  }

  // No usable `set` AND no usable `addConditions` -> this element carries zero information; drop
  // it rather than emit an update that changes nothing.
  if (!set && !addConditions) return undefined;

  const out: TaskUpdateOut = { refIndex: v.refIndex };
  if (set) out.set = set;
  if (addConditions) out.addConditions = addConditions;
  return out;
}

/** Validates the model's full envelope-mode response `{ tasks, taskRefs, updates }` — the
 *  `task_refs_v1` counterpart to `validateParsedTaskArray`, used ONLY when the request carried
 *  `client_caps: ["task_refs_v1"]` (see `wantsEnvelope` in `parse/index.ts`).
 *
 *  ORDER MATTERS and is fixed deliberately: `taskRefs` validates FIRST (nothing downstream needs
 *  it to validate itself), giving a `refCount` that `tasks` needs (to resolve `refIndex`/`anchor`
 *  on conditions and reminder overrides); `tasks` validates SECOND, giving a validated/truncated
 *  count that `updates` needs (to resolve `addConditions[].newTaskIndex`); `updates` validates
 *  LAST, needing both of the above.
 *
 *  Accepts a raw envelope object `{ tasks, taskRefs, updates }` and, DEFENSIVELY, a bare array too
 *  (treated as `{ tasks: v, taskRefs: [], updates: [] }`) — `buildParseEnvelopeResponseSchema()`'s
 *  schema-constrained request to Gemini is a strong HINT, never a GUARANTEE (see this file's
 *  module doc comment): a provider bug/truncation/safety-filter substitution could still hand back
 *  a bare array even though the envelope shape was asked for, and that's still salvageable as
 *  "zero refs/updates, just tasks" rather than a hard 502.
 *
 *  Same 502 semantics as `validateParsedTaskArray`: returns `undefined` ONLY when `tasks` is not
 *  an array at all, or is a non-empty array where every task failed validation — i.e. the model
 *  produced nothing usable. Critically, an EMPTY `tasks: []` alongside non-empty `taskRefs`/
 *  `updates` is a VALID response, not a 502 — "task kia phải xong hôm nay" is a real, complete
 *  utterance that creates zero new tasks and only updates an existing one; rejecting that as
 *  malformed would burn a quota slot on a request that produced a perfectly good answer, the exact
 *  failure mode `validateParsedTaskArray`'s own doc comment already warns against for the
 *  bare-array case.
 *
 *  `droppedCount` aggregates every kind of silent loss across all three arrays (tasks
 *  dropped/truncated, refs dropped/truncated, updates dropped/truncated) — `parse/index.ts` also
 *  logs `taskRefs.length`/`updates.length` alongside it so the aggregate and the per-array shape
 *  are both visible to operators, mirroring how `validateParsedTaskArray`'s own `droppedCount` is
 *  logged today.
 *
 *  `cuesEnabled` (task_cues_v1, Opus review of T1 2026-08-08 — the combo path every REAL client
 *  actually takes, since `CloudParser.swift` always sends `["task_refs_v1", "task_cues_v1"]`
 *  together): OPTIONAL, defaults to `false`/absent, threaded straight through to
 *  `validateParsedTaskArrayCtx` exactly like `validateParsedTaskArray`/`validateParsedTaskArrayWithCues`
 *  already do for the bare-array path — see `validateParsedTask`'s own doc comment for why this is
 *  a separate parameter from `ctx` rather than a field folded into it (the two capabilities must
 *  stay independently gate-able even though THIS function's `ctx` is always present here). Every
 *  pre-existing call site (`parse/index.ts`'s `task_refs_v1`-only branch) calls this with ONE
 *  argument and is therefore byte-identical to before this parameter existed. */
export function validateParseEnvelope(
  v: unknown,
  cuesEnabled?: boolean,
): { tasks: ParsedTaskOut[]; taskRefs: TaskRefOut[]; updates: TaskUpdateOut[]; droppedCount: number } | undefined {
  const envelope: Record<string, unknown> = Array.isArray(v)
    ? { tasks: v, taskRefs: [], updates: [] }
    : isPlainObject(v)
    ? v
    : {};

  // --- taskRefs FIRST: gives `refCount`, needed by both `tasks` and `updates` below. ---
  const rawRefs = Array.isArray(envelope.taskRefs) ? envelope.taskRefs : [];
  let refInvalidCount = 0;
  const taskRefs: TaskRefOut[] = [];
  for (const item of rawRefs) {
    const ref = validateTaskRef(item);
    if (ref) {
      taskRefs.push(ref);
    } else {
      refInvalidCount++;
    }
  }
  const refDroppedCount = refInvalidCount + Math.max(0, taskRefs.length - MAX_TASK_REFS);
  const validRefs = taskRefs.slice(0, MAX_TASK_REFS);
  const ctx: ParseEnvelopeCtx = { taskRefCount: validRefs.length };

  // --- tasks SECOND, threading `ctx` down so refIndex/anchor fields can resolve against `taskRefs`,
  // and `cuesEnabled` down so `cue` is only ever read when the caller actually asked for it. ---
  const tasksResult = validateParsedTaskArrayCtx(envelope.tasks, ctx, cuesEnabled);
  if (!tasksResult) return undefined;

  // --- updates LAST: needs both `ctx.taskRefCount` and the validated/truncated task count. ---
  const rawUpdates = Array.isArray(envelope.updates) ? envelope.updates : [];
  let updateInvalidCount = 0;
  const updates: TaskUpdateOut[] = [];
  for (const item of rawUpdates) {
    const update = validateTaskUpdate(item, ctx.taskRefCount, tasksResult.tasks.length);
    if (update) {
      updates.push(update);
    } else {
      updateInvalidCount++;
    }
  }
  const updateDroppedCount = updateInvalidCount + Math.max(0, updates.length - MAX_UPDATES);
  const validUpdates = updates.slice(0, MAX_UPDATES);

  return {
    tasks: tasksResult.tasks,
    taskRefs: validRefs,
    updates: validUpdates,
    droppedCount: tasksResult.droppedCount + refDroppedCount + updateDroppedCount,
  };
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
