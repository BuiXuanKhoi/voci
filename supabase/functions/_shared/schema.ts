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
}

export interface BreakdownRequest {
  mode: "breakdown";
  taskTitle: string;
  notes?: string;
}

export type ParsedRequestBody = ParseRequest | BreakdownRequest;

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
  if (mode !== "parse" && mode !== "breakdown") {
    return { ok: false, error: "mode must be 'parse' or 'breakdown' when present" };
  }

  if (mode === "breakdown") return validateBreakdownRequest(body);
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
  let localeHint: ParseRequest["localeHint"];
  if (body.localeHint !== undefined) {
    if (body.localeHint !== "vi" && body.localeHint !== "en" && body.localeHint !== "mixed") {
      return { ok: false, error: "locale_hint must be one of vi|en|mixed" };
    }
    localeHint = body.localeHint;
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
}

export interface ParsedSubtaskOut {
  title: ConfidenceValue<string>;
  estimateMinutes: ConfidenceValue<number>;
}

export interface ParsedTaskOut {
  title: ConfidenceValue<string>;
  notes?: ConfidenceValue<string>;
  deadline?: ConfidenceValue<string>;
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

/** Validates a single model-produced task object. Returns undefined (never throws) on ANY
 *  structural mismatch — the caller drops/rejects rather than guessing a "best effort" shape,
 *  per constitution II: raw model output is never trusted into a partially-validated pass-through. */
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
    if (!notes) return undefined;
    out.notes = notes;
  }

  if (v.deadline !== undefined) {
    const deadline = validateConfidenceValue(v.deadline, (s) => (isIso8601(s) ? (s as string) : undefined));
    if (!deadline) return undefined;
    out.deadline = deadline;
  }

  if (v.estimateMinutes !== undefined) {
    const est = validateConfidenceValue(v.estimateMinutes, (n) =>
      isFiniteNumber(n) && n > 0 ? n : undefined
    );
    if (!est) return undefined;
    out.estimateMinutes = est;
  }

  if (v.priority !== undefined) {
    const priority = validateConfidenceValue(v.priority, (n) =>
      isFiniteNumber(n) && Number.isInteger(n) && n >= 1 && n <= 4 ? n : undefined
    );
    if (!priority) return undefined;
    out.priority = priority;
  }

  if (v.recurrence !== undefined) {
    const recurrence = validateConfidenceValue(v.recurrence, validateRecurrence);
    if (!recurrence) return undefined;
    out.recurrence = recurrence;
  }

  if (v.reminderOverride !== undefined) {
    const reminderOverride = validateConfidenceValue(v.reminderOverride, validateReminderOverride);
    if (!reminderOverride) return undefined;
    out.reminderOverride = reminderOverride;
  }

  if (v.conditions !== undefined) {
    if (!Array.isArray(v.conditions)) return undefined;
    const conditions: ConfidenceValue<ParsedConditionOut>[] = [];
    for (const c of v.conditions) {
      const cond = validateConfidenceValue(c, validateCondition);
      if (!cond) return undefined;
      conditions.push(cond);
    }
    out.conditions = conditions;
  }

  if (v.kind !== undefined) {
    const kind = validateConfidenceValue(v.kind, (s) =>
      s === "task" || s === "review" ? s : undefined
    );
    if (!kind) return undefined;
    out.kind = kind;
  }

  if (v.subtasks !== undefined) {
    if (!Array.isArray(v.subtasks)) return undefined;
    const subtasks: ParsedSubtaskOut[] = [];
    for (const s of v.subtasks) {
      const sub = validateSubtask(s);
      if (!sub) return undefined;
      subtasks.push(sub);
    }
    out.subtasks = subtasks;
  }

  if (v.followUpReview !== undefined) {
    const followUpReview = validateConfidenceValue(v.followUpReview, (b) =>
      typeof b === "boolean" ? b : undefined
    );
    if (!followUpReview) return undefined;
    out.followUpReview = followUpReview;
  }

  return out;
}

/** Validates the model's full parse-mode response. Enforces the 10-task cap by TRUNCATING
 *  (contract obligation 4: "enforce ... the 10-task cap server-side" — truncation is the safe
 *  enforcement here, since a prompt-injection attempt to make the model emit >10 tasks must not
 *  be able to smuggle task #11+ through under any circumstance; anything structurally invalid is
 *  rejected outright, not best-effort-repaired). Returns undefined on any structural failure. */
export function validateParsedTaskArray(v: unknown): { tasks: ParsedTaskOut[]; droppedCount: number } | undefined {
  if (!Array.isArray(v)) return undefined;
  if (v.length === 0) return undefined;
  const tasks: ParsedTaskOut[] = [];
  for (const item of v) {
    const task = validateParsedTask(item);
    if (!task) return undefined; // any malformed task -> whole response is untrustworthy
    tasks.push(task);
  }
  const droppedCount = Math.max(0, tasks.length - MAX_TASKS);
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
