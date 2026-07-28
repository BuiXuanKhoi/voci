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

export interface BreakdownRequest {
  mode: "breakdown";
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

export type ParsedRequestBody = ParseRequest | BreakdownRequest | ResolveCompletionRequest;

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
  if (mode !== "parse" && mode !== "breakdown" && mode !== "resolve_completion") {
    return { ok: false, error: "mode must be 'parse', 'breakdown', or 'resolve_completion' when present" };
  }

  if (mode === "breakdown") return validateBreakdownRequest(body);
  if (mode === "resolve_completion") return validateResolveCompletionRequest(body);
  return validateParseRequest(body);
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
  return { ok: true, value: { mode: "breakdown", taskTitle, notes } };
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
