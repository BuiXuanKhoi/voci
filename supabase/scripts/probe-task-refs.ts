// supabase/scripts/probe-task-refs.ts
//
// Live probe for the `task_refs_v1` envelope capability — modeled directly on
// `probe-time-parsing.ts` (same env handling, same "known-answer" philosophy, same output style)
// but exercising the ENVELOPE half of the parse route instead of the bare-array half: calls Gemini
// with the EXACT prompt/schema `parse/index.ts` would build when a request opts into
// `task_refs_v1` — `SYSTEM_PREAMBLE_TASK_REFS`, `buildParseEnvelopeResponseSchema()`, the SAME
// `buildParseContents` every mode already uses, and the SAME `callGemini` — for a table of
// Vietnamese/English utterances whose correct { tasks, taskRefs, updates } shape is known, and
// diffs what comes back against that expectation.
//
// WHY THIS EXISTS (anh Khôi, 2026-08-02 task-refs design): the task-refs rules — copy an
// openTaskTitles entry EXACTLY when a paraphrase matches, never invent a reference, never fill an
// update field the user didn't mention, point refIndex/newTaskIndex into the right array — all
// live in a PROMPT, and a prompt is not a function. `deno check` passing on `gemini.ts` proves the
// SCHEMA is well-formed; it proves nothing about whether the model actually obeys "copy the title
// word for word" or "leave taskRefs/updates empty when nothing is referenced". The only way to
// know is to ask the real model, the same reason `probe-time-parsing.ts` exists for the date rules.
//
// NOTE ON VALIDATION: unlike `probe-time-parsing.ts` (which runs the model's output through
// `validateParsedTaskArray`, the SAME server-side validator `parse/index.ts` uses), this probe
// inspects the raw model JSON directly rather than through `schema.ts`'s envelope validator
// (`validateParseEnvelope`). That validator is landing as part of this SAME `task_refs_v1` change,
// in a sibling file, and was not yet finished as of this probe's writing — depending on it here
// would make this script's own type-checkability hostage to a file this script does not own. Once
// `validateParseEnvelope` lands, consider routing this probe's model output through it too, for the
// same "this probe can never pass on a response the production path would reject" guarantee
// `probe-time-parsing.ts` gets from `validateParsedTaskArray`. Until then, the lightweight local
// shape guard below (`asEnvelope`) is a deliberately thin stand-in — it checks the top-level arrays
// exist and lets each case's own `check()` inspect fields defensively.
//
// NOT deployed: `supabase functions deploy` only ships `functions/`, never `scripts/`.
// NOT run in CI: this script is never invoked automatically by any CI job in this repo — it costs
// real tokens (~1 small call per case, ~14 cases) and calls out to a live third-party API, neither
// of which belongs in an automated pipeline that runs on every push. Run it by hand after touching
// `SYSTEM_PREAMBLE_TASK_REFS` or `buildParseEnvelopeResponseSchema`.
//
// RUN (needs a Gemini API key — the same one set as the `GEMINI_API_KEY` secret on the Supabase
// project; get it from Google AI Studio):
//
//   GEMINI_API_KEY=... deno run --allow-net --allow-env supabase/scripts/probe-task-refs.ts
//
// Dry run (no key, no network — prints the fully-built envelope prompt so you can read exactly
// what the model is being told):
//
//   deno run --allow-env supabase/scripts/probe-task-refs.ts --dry-run
//
// Override the model with PARSE_MODEL, same env var the real function reads.

import {
  DEFAULT_PARSE_MODEL,
  SYSTEM_PREAMBLE_TASK_REFS,
  buildParseContents,
  buildParseEnvelopeResponseSchema,
  callGemini,
} from "../functions/_shared/gemini.ts";

// Same anchor date `probe-time-parsing.ts` uses (2026-07-28 is a Tuesday) — kept in sync
// deliberately, not because task-refs cares about date arithmetic itself, but so a probe run
// comparing both scripts' output isn't also debugging two different "now"s.
const NOW_VN = "2026-07-28T15:00:00+07:00";
const TZ_VN = "Asia/Ho_Chi_Minh";

// --- wouldClientLink: COPIED from probe-time-parsing.ts, not imported -----------------------------
// `probe-time-parsing.ts` does not export `tokenize`/`wouldClientLink` (they're module-local there),
// and this script deliberately avoids importing across `scripts/` files to keep each probe
// independently runnable with a single `deno run` line and no shared-module surface to keep in sync
// beyond this comment. If `wouldClientLink`'s SEMANTICS ever change on the client
// (`AppState.tokenize`/`scoredMatches` in `Volar/Sources/App/AppState.swift`) or in
// `probe-time-parsing.ts`'s own copy, this copy must be updated BY HAND to match — there is no
// compiler check tying the two together.

/** Mirrors `AppState.tokenize` (`Volar/Sources/App/AppState.swift`): lowercase, strip diacritics,
 *  split on whitespace, dedupe. `đ`/`Đ` mapped explicitly because Swift's `.folding(options:
 *  .diacriticInsensitive)` folds them to `d`, while Unicode NFD does NOT decompose U+0111 (it is
 *  its own letter, not `d` + a combining mark) — without this line the two sides would tokenize
 *  "đã"/"đơn" differently and this probe would disagree with the real client. Punctuation is
 *  deliberately NOT stripped, matching the Swift side exactly. */
function tokenize(text: string): Set<string> {
  const folded = text
    .toLowerCase()
    .replace(/đ/g, "d")
    .normalize("NFD")
    .replace(/\p{M}/gu, "");
  return new Set(folded.split(/\s+/).filter((t) => t.length > 0));
}

/** Replays the client's reference-matching decision (`AppState.preResolveConditions` ->
 *  `scoredMatches(similarity: .strict)`): Jaccard over the token sets, linked only at >= 0.7. This
 *  is why `SYSTEM_PREAMBLE_TASK_REFS` insists `titleQuery`/`referenceTitle` copy the matched
 *  `openTaskTitles` entry word for word — a shortened or reworded copy scores far under 0.7 and is
 *  dropped in silence, with no error anywhere on either side. */
function wouldClientLink(a: string, b: string): { linked: boolean; score: number } {
  const ta = tokenize(a);
  const tb = tokenize(b);
  if (ta.size === 0 || tb.size === 0) return { linked: false, score: 0 };
  let shared = 0;
  for (const t of ta) if (tb.has(t)) shared++;
  const union = new Set([...ta, ...tb]).size;
  const score = union === 0 ? 0 : shared / union;
  return { linked: score >= 0.7, score };
}

// --- Minimal local mirror of the wire contract (see schema.ts's TaskRefOut/TaskUpdateOut/
// ParsedTaskOut for the authoritative, validated shape) — deliberately loose (`unknown`-friendly,
// every field optional except what `buildParseEnvelopeResponseSchema` marks `required`) since this
// probe reads the RAW model JSON, not the server-validated output; see the module doc comment above
// for why. -----------------------------------------------------------------------------------------

interface ConfidenceLike<T> {
  value: T;
  confidence: number;
}

interface ConditionLike {
  kind?: string;
  referenceTitle?: string;
  refIndex?: number;
  offsetMinutes?: number;
  offsetKind?: string;
  date?: string;
  description?: string;
}

interface ReminderOverrideLike {
  offsetsMinutes?: number[];
  repeatEveryMinutes?: number;
  remindPeriodMinutes?: number;
  anchor?: { refIndex?: number; event?: string };
}

interface TaskLike {
  title?: ConfidenceLike<string>;
  conditions?: ConfidenceLike<ConditionLike>[];
  reminderOverride?: ConfidenceLike<ReminderOverrideLike>;
}

interface TaskRefLike {
  titleQuery?: ConfidenceLike<string>;
  assumeExisting?: boolean;
}

interface UpdateSetLike {
  deadline?: ConfidenceLike<string>;
  startTime?: ConfidenceLike<string>;
  notesAppend?: ConfidenceLike<string>;
  priority?: ConfidenceLike<number>;
  reminderOverride?: ConfidenceLike<ReminderOverrideLike>;
}

interface UpdateConditionLike {
  kind?: string;
  newTaskIndex?: number;
  date?: string;
}

interface UpdateLike {
  refIndex?: number;
  set?: UpdateSetLike;
  addConditions?: UpdateConditionLike[];
}

interface EnvelopeLike {
  tasks: TaskLike[];
  taskRefs: TaskRefLike[];
  updates: UpdateLike[];
}

/** Thin runtime shape guard — NOT a substitute for `schema.ts`'s `validateParseEnvelope` (see
 *  module doc comment). Only checks that the three top-level arrays exist, since
 *  `buildParseEnvelopeResponseSchema` marks all three `required`; throws (caught by the per-case
 *  try/catch in `main`) on anything grosser than that, so a case's own `check()` can assume the
 *  arrays are at least present and iterate them defensively field by field. */
function asEnvelope(raw: unknown): EnvelopeLike {
  if (typeof raw !== "object" || raw === null) {
    throw new Error("response is not an object");
  }
  const r = raw as Record<string, unknown>;
  if (!Array.isArray(r.tasks) || !Array.isArray(r.taskRefs) || !Array.isArray(r.updates)) {
    throw new Error(
      `response missing one of tasks/taskRefs/updates as arrays: ${JSON.stringify(raw).slice(0, 300)}`,
    );
  }
  return { tasks: r.tasks, taskRefs: r.taskRefs, updates: r.updates };
}

/** Returns the 1-based `taskRefs` index whose `titleQuery.value` is an EXACT match for
 *  `expectedTitle`, or `undefined` if none. Used by cases that assert "the model recognized this as
 *  the given `openTaskTitles` entry", the entire point of the word-for-word copying rule. */
function findRefIndexByExactTitle(taskRefs: TaskRefLike[], expectedTitle: string): number | undefined {
  const i = taskRefs.findIndex((r) => r.titleQuery?.value === expectedTitle);
  return i === -1 ? undefined : i + 1;
}

interface Case {
  transcript: string;
  openTaskTitles: string[];
  /** WHY this case exists and what it guards against — printed alongside a FAIL so a failure is
   *  immediately legible without re-reading this file. */
  why: string;
  /** Returns a list of problems (empty = pass). Given the raw envelope and the shared
   *  `wouldClientLink` helper so cases can assert not just "a reference was emitted" but "that
   *  reference would actually resolve on the client" — the single most valuable check in this
   *  whole probe, same reasoning as `probe-time-parsing.ts`'s `expectDependencyOnFirstTask`. */
  check(env: EnvelopeLike): string[];
}

const CASES: Case[] = [
  // --- (1) Paraphrase resolution: the core promise of openTaskTitles + word-for-word copying. ----
  {
    transcript: "gọi cho khách hàng sau khi xong cái vụ report",
    openTaskTitles: ["Viết báo cáo Q3", "Dọn dẹp nhà cửa"],
    why:
      "the model's ONLY bridge from a paraphrase (\"cái vụ report\") to the real stored title -- " +
      "titleQuery must copy \"Viết báo cáo Q3\" EXACTLY, assumeExisting must be true, and the copy " +
      "must actually pass the client's 0.7 Jaccard bar (the whole point of copying it exactly)",
    check(env) {
      const problems: string[] = [];
      if (env.taskRefs.length === 0) {
        problems.push("taskRefs: expected 1 entry, got 0");
        return problems;
      }
      const ref = env.taskRefs[0];
      if (ref.titleQuery?.value !== "Viết báo cáo Q3") {
        problems.push(`titleQuery: got "${ref.titleQuery?.value}", want exact "Viết báo cáo Q3"`);
      } else {
        const { linked, score } = wouldClientLink(ref.titleQuery.value, "Viết báo cáo Q3");
        if (!linked) problems.push(`wouldClientLink: score ${score.toFixed(2)} < 0.70`);
      }
      if (ref.assumeExisting !== true) {
        problems.push(`assumeExisting: got ${ref.assumeExisting}, want true`);
      }
      if (env.tasks.length === 0) {
        problems.push("tasks: expected >=1 new task (the call), got 0");
      }
      return problems;
    },
  },

  // --- (2) Both-new intra-batch dependency: regression guard, taskRefs must stay EMPTY. -----------
  {
    transcript: "làm xong landing page rồi gửi cho khách hàng Sugashack",
    openTaskTitles: [],
    why:
      "two NEW tasks in the SAME utterance with a stated ordering -- the pre-existing " +
      "(SYSTEM_PREAMBLE) dependency rule, UNCHANGED by task_refs_v1: kind taskDone + word-for-word " +
      "referenceTitle of the earlier NEW task, WITHOUT any taskRefs entry or refIndex. If this rule " +
      "quietly migrated into taskRefs it would be a real regression, not an improvement",
    check(env) {
      const problems: string[] = [];
      if (env.tasks.length !== 2) {
        problems.push(`tasks: got ${env.tasks.length}, want 2`);
        return problems;
      }
      if (env.taskRefs.length !== 0) {
        problems.push(`taskRefs: expected 0 (both tasks are NEW), got ${env.taskRefs.length}`);
      }
      const [first, last] = env.tasks;
      const dep = last.conditions?.find((c) => c.value.kind === "taskDone");
      if (!dep) {
        problems.push(`dependency: last task carries no taskDone condition`);
      } else {
        if (dep.value.refIndex !== undefined) {
          problems.push(`dependency: refIndex=${dep.value.refIndex} present -- must be ABSENT for a NEW-vs-NEW ordering`);
        }
        const ref = dep.value.referenceTitle ?? "";
        const { linked, score } = wouldClientLink(ref, first.title?.value ?? "");
        if (!linked) {
          problems.push(`dependency: referenceTitle "${ref}" would NOT link to "${first.title?.value}" (Jaccard ${score.toFixed(2)})`);
        }
      }
      return problems;
    },
  },

  // --- (3) Update-only utterance: zero new tasks, one update, ONLY set.deadline. -------------------
  {
    transcript: "cái vụ nộp báo cáo thuế phải xong hôm nay",
    openTaskTitles: ["Nộp báo cáo thuế", "Họp nhóm dự án"],
    why:
      "\"task kia phải xong hôm nay\" changes the REFERENCED task, not a new one -- must produce " +
      "ZERO new tasks and exactly one updates entry with ONLY set.deadline populated (no " +
      "notesAppend/priority/startTime/reminderOverride the user never mentioned)",
    check(env) {
      const problems: string[] = [];
      if (env.tasks.length !== 0) {
        problems.push(`tasks: got ${env.tasks.length}, want 0 (utterance only updates an existing task)`);
      }
      if (env.updates.length === 0) {
        problems.push("updates: expected 1 entry, got 0");
        return problems;
      }
      const refIdx = findRefIndexByExactTitle(env.taskRefs, "Nộp báo cáo thuế");
      const upd = env.updates.find((u) => u.refIndex === refIdx) ?? env.updates[0];
      if (!upd.set?.deadline) {
        problems.push("updates[0].set.deadline: expected present, got absent");
      }
      const unrequested = (["startTime", "notesAppend", "priority", "reminderOverride"] as const).filter(
        (k) => upd.set?.[k] !== undefined,
      );
      if (unrequested.length > 0) {
        problems.push(`updates[0].set: unrequested field(s) present: ${unrequested.join(", ")}`);
      }
      return problems;
    },
  },

  // --- (4) Reverse dependency: NEW task must finish before an EXISTING referenced task. -----------
  {
    transcript: "gọi điện cho nhà cung cấp trước khi làm cái vụ gửi email cho khách hàng",
    openTaskTitles: ["Gửi email cho khách hàng"],
    why:
      "\"làm A trước khi làm X(existing)\" -- X does not depend on A the ordinary way; X must be " +
      "updated to WAIT ON the new task A, via updates[].addConditions=[{kind:taskDone, " +
      "newTaskIndex}] where newTaskIndex points into THIS RESPONSE's own tasks[], not taskRefs[]",
    check(env) {
      const problems: string[] = [];
      if (env.tasks.length === 0) {
        problems.push("tasks: expected >=1 new task (calling the supplier), got 0");
        return problems;
      }
      const refIdx = findRefIndexByExactTitle(env.taskRefs, "Gửi email cho khách hàng");
      if (refIdx === undefined) {
        problems.push(`taskRefs: no entry exactly matching "Gửi email cho khách hàng"`);
        return problems;
      }
      const upd = env.updates.find((u) => u.refIndex === refIdx);
      if (!upd) {
        problems.push(`updates: no entry with refIndex=${refIdx}`);
        return problems;
      }
      const addCond = upd.addConditions?.find((c) => c.kind === "taskDone");
      if (!addCond) {
        problems.push("updates[].addConditions: no taskDone entry");
      } else if (addCond.newTaskIndex !== 1) {
        problems.push(`addConditions.newTaskIndex: got ${addCond.newTaskIndex}, want 1`);
      }
      return problems;
    },
  },

  // --- (5) "N hours after finishing X" -- accept either a plain offset condition or a reminder ----
  // anchor; the point of this case is the NUMBER (120), not which of the two legal encodings the
  // model picks (SYSTEM_PREAMBLE_TASK_REFS documents both: a taskDone condition's offsetMinutes for
  // a one-off dependency, vs reminderOverride.anchor+repeatEveryMinutes for a repeating reminder).
  {
    transcript: "nhắc tôi 2 tiếng sau khi xong cái vụ deploy phiên bản mới",
    openTaskTitles: ["Deploy phiên bản mới"],
    why:
      "\"2 tiếng sau khi xong X\" must surface 120 SOMEWHERE -- either conditions[].offsetMinutes " +
      "(kind taskDone) or reminderOverride.anchor+repeatEveryMinutes/offsetsMinutes -- this case " +
      "accepts either encoding and only asserts the minute value itself is correct",
    check(env) {
      const problems: string[] = [];
      if (env.tasks.length === 0) {
        problems.push("tasks: expected >=1 new task, got 0");
        return problems;
      }
      let found = false;
      for (const t of env.tasks) {
        for (const c of t.conditions ?? []) {
          if (c.value.offsetMinutes === 120) found = true;
        }
        const anchor = t.reminderOverride?.value?.anchor;
        if (anchor) {
          if (t.reminderOverride?.value?.repeatEveryMinutes === 120) found = true;
          if (t.reminderOverride?.value?.offsetsMinutes?.includes(120)) found = true;
        }
      }
      if (!found) {
        problems.push("no task carries offsetMinutes=120 or an anchor+120-minute cadence/offset anywhere");
      }
      return problems;
    },
  },

  // --- (6) "at least N hours before X starts" -- taskStart, NEGATIVE offset, atLeast. -------------
  {
    transcript: "nhắc tôi ít nhất 2 tiếng trước khi họp với đối tác ABC",
    openTaskTitles: ["Họp với đối tác ABC"],
    why:
      "\"ít nhất 2 tiếng trước khi làm X\" is a taskStart condition (waits on X STARTING, not " +
      "finishing), offsetMinutes must be NEGATIVE (-120, before the event), and offsetKind must be " +
      "\"atLeast\" because \"ít nhất\" was said",
    check(env) {
      const problems: string[] = [];
      const refIdx = findRefIndexByExactTitle(env.taskRefs, "Họp với đối tác ABC");
      if (refIdx === undefined) {
        problems.push(`taskRefs: no entry exactly matching "Họp với đối tác ABC"`);
      }
      const cond = env.tasks
        .flatMap((t) => t.conditions ?? [])
        .find((c) => c.value.kind === "taskStart");
      if (!cond) {
        problems.push("conditions: no taskStart entry found");
        return problems;
      }
      if (cond.value.offsetMinutes !== -120) {
        problems.push(`offsetMinutes: got ${cond.value.offsetMinutes}, want -120`);
      }
      if (cond.value.offsetKind !== "atLeast") {
        problems.push(`offsetKind: got ${cond.value.offsetKind}, want "atLeast"`);
      }
      return problems;
    },
  },

  // --- (7) Plain no-reference utterance -- MOST IMPORTANT regression guard against inventing refs. -
  {
    transcript: "mua sữa và bánh mì",
    openTaskTitles: ["Nộp báo cáo thuế", "Gửi email cho khách hàng"],
    why:
      "an ordinary utterance that names no other task, WITH plausible-looking openTaskTitles " +
      "sitting right there to tempt a false positive -- taskRefs and updates must both be [] " +
      "(this is the common case the prompt explicitly calls out: never invent a reference)",
    check(env) {
      const problems: string[] = [];
      if (env.taskRefs.length !== 0) {
        problems.push(`taskRefs: expected [], got ${env.taskRefs.length} entr(y/ies) -- reference invented`);
      }
      if (env.updates.length !== 0) {
        problems.push(`updates: expected [], got ${env.updates.length} entr(y/ies) -- update invented`);
      }
      return problems;
    },
  },

  // --- (8) Update mentioning only a deadline must not grow priority/notes on the side. -------------
  {
    transcript: "đổi hạn cái vụ gửi email cho khách hàng sang hôm nay",
    openTaskTitles: ["Gửi email cho khách hàng"],
    why:
      "second no-unrequested-fields regression, distinct wording from case 3 -- \"đổi hạn ... sang " +
      "hôm nay\" states ONLY a new deadline; set must contain deadline and NOTHING else",
    check(env) {
      const problems: string[] = [];
      const refIdx = findRefIndexByExactTitle(env.taskRefs, "Gửi email cho khách hàng");
      const upd = env.updates.find((u) => u.refIndex === refIdx) ?? env.updates[0];
      if (!upd) {
        problems.push("updates: expected 1 entry, got 0");
        return problems;
      }
      if (!upd.set?.deadline) {
        problems.push("updates[0].set.deadline: expected present, got absent");
      }
      const unrequested = (["startTime", "notesAppend", "priority", "reminderOverride"] as const).filter(
        (k) => upd.set?.[k] !== undefined,
      );
      if (unrequested.length > 0) {
        problems.push(`updates[0].set: unrequested field(s) present: ${unrequested.join(", ")}`);
      }
      return problems;
    },
  },

  // --- (9) English paraphrase, symmetry check with case 1. ------------------------------------------
  {
    transcript: "call the client once that report thing is done",
    openTaskTitles: ["Write Q3 report", "Clean the garage"],
    why:
      "the paraphrase-resolution rule is language-independent -- an English paraphrase must copy " +
      "the English openTaskTitles entry exactly, same as the Vietnamese case",
    check(env) {
      const problems: string[] = [];
      const refIdx = findRefIndexByExactTitle(env.taskRefs, "Write Q3 report");
      if (refIdx === undefined) {
        problems.push(`taskRefs: no entry exactly matching "Write Q3 report" (got: ${JSON.stringify(env.taskRefs.map((r) => r.titleQuery?.value))})`);
      }
      if (env.tasks.length === 0) {
        problems.push("tasks: expected >=1 new task (the call), got 0");
      }
      return problems;
    },
  },

  // --- (10) set.startTime via "dời X sang <time>". --------------------------------------------------
  {
    transcript: "dời cái vụ họp nhóm dự án sang 3h chiều",
    openTaskTitles: ["Họp nhóm dự án"],
    why: "\"dời X sang <time>\" moves X's START time, not its deadline -- set.startTime only",
    check(env) {
      const problems: string[] = [];
      const refIdx = findRefIndexByExactTitle(env.taskRefs, "Họp nhóm dự án");
      const upd = env.updates.find((u) => u.refIndex === refIdx) ?? env.updates[0];
      if (!upd) {
        problems.push("updates: expected 1 entry, got 0");
        return problems;
      }
      if (!upd.set?.startTime) {
        problems.push("updates[0].set.startTime: expected present, got absent");
      }
      if (upd.set?.deadline !== undefined) {
        problems.push("updates[0].set.deadline: expected absent (only startTime was asked for), got present");
      }
      return problems;
    },
  },

  // --- (11) set.notesAppend via "thêm note vào X là ...". -------------------------------------------
  {
    transcript: "thêm note vào cái vụ chuẩn bị tài liệu họp là nhớ mang laptop",
    openTaskTitles: ["Chuẩn bị tài liệu họp"],
    why: "\"thêm note vào X là ...\" appends a note to X -- set.notesAppend only, no other field",
    check(env) {
      const problems: string[] = [];
      const refIdx = findRefIndexByExactTitle(env.taskRefs, "Chuẩn bị tài liệu họp");
      const upd = env.updates.find((u) => u.refIndex === refIdx) ?? env.updates[0];
      if (!upd) {
        problems.push("updates: expected 1 entry, got 0");
        return problems;
      }
      if (!upd.set?.notesAppend) {
        problems.push("updates[0].set.notesAppend: expected present, got absent");
      }
      const unrequested = (["deadline", "startTime", "priority", "reminderOverride"] as const).filter(
        (k) => upd.set?.[k] !== undefined,
      );
      if (unrequested.length > 0) {
        problems.push(`updates[0].set: unrequested field(s) present: ${unrequested.join(", ")}`);
      }
      return problems;
    },
  },

  // --- (12) Two DISTINCT references in one utterance: one dependency, one update. -------------------
  {
    transcript:
      "gọi cho khách hàng sau khi xong cái vụ report, và dời cái vụ họp nhóm dự án sang chiều mai",
    openTaskTitles: ["Viết báo cáo Q3", "Họp nhóm dự án"],
    why:
      "harder coverage case: TWO distinct references in one utterance must produce TWO taskRefs " +
      "entries (not collapsed into one, not only the first one extracted), one feeding a NEW " +
      "task's dependency and the other feeding an update -- exercises refIndex actually " +
      "disambiguating between two candidates instead of defaulting to 1",
    check(env) {
      const problems: string[] = [];
      const reportIdx = findRefIndexByExactTitle(env.taskRefs, "Viết báo cáo Q3");
      const meetingIdx = findRefIndexByExactTitle(env.taskRefs, "Họp nhóm dự án");
      if (reportIdx === undefined) problems.push(`taskRefs: no entry exactly matching "Viết báo cáo Q3"`);
      if (meetingIdx === undefined) problems.push(`taskRefs: no entry exactly matching "Họp nhóm dự án"`);
      if (reportIdx !== undefined && meetingIdx !== undefined && reportIdx === meetingIdx) {
        problems.push("taskRefs: both references collapsed into the SAME entry");
      }
      if (reportIdx !== undefined) {
        const dep = env.tasks.flatMap((t) => t.conditions ?? []).find((c) => c.value.refIndex === reportIdx);
        if (!dep) problems.push(`conditions: no condition with refIndex=${reportIdx} (the report dependency)`);
      }
      if (meetingIdx !== undefined) {
        const upd = env.updates.find((u) => u.refIndex === meetingIdx);
        if (!upd?.set?.startTime) {
          problems.push(`updates: no entry with refIndex=${meetingIdx} carrying set.startTime`);
        }
      }
      return problems;
    },
  },

  // --- (13) No plausible openTaskTitles match -- assumeExisting must stay false. --------------------
  {
    transcript: "làm cái này sau khi xong cái vụ dọn nhà",
    openTaskTitles: ["Viết báo cáo Q3"],
    why:
      "the referenced task (\"dọn nhà\") has NO plausible match in openTaskTitles at all -- " +
      "titleQuery must carry the user's own words (not the unrelated openTaskTitles entry) and " +
      "assumeExisting must be false/absent, never true on a fabricated match",
    check(env) {
      const problems: string[] = [];
      if (env.taskRefs.length === 0) {
        problems.push("taskRefs: expected 1 entry (a forward reference), got 0");
        return problems;
      }
      const ref = env.taskRefs[0];
      if (ref.titleQuery?.value === "Viết báo cáo Q3") {
        problems.push('titleQuery: fabricated a match against the unrelated "Viết báo cáo Q3" entry');
      }
      if (ref.assumeExisting === true) {
        problems.push("assumeExisting: got true, want false/absent -- no real openTaskTitles match exists");
      }
      return problems;
    },
  },

  // --- (14) English "at least ... after finishing" -- atLeast on a taskDone (not taskStart) offset. -
  {
    transcript: "remind me at least 2 hours after I finish the deploy task",
    openTaskTitles: ["Deploy new version"],
    why:
      "\"at least\" applies to a taskDone (after-completion) offset too, not just taskStart -- " +
      "offsetMinutes=120, offsetKind=\"atLeast\"",
    check(env) {
      const problems: string[] = [];
      const cond = env.tasks
        .flatMap((t) => t.conditions ?? [])
        .find((c) => c.value.kind === "taskDone" && c.value.offsetMinutes !== undefined);
      if (!cond) {
        problems.push("conditions: no taskDone entry carrying offsetMinutes");
        return problems;
      }
      if (cond.value.offsetMinutes !== 120) {
        problems.push(`offsetMinutes: got ${cond.value.offsetMinutes}, want 120`);
      }
      if (cond.value.offsetKind !== "atLeast") {
        problems.push(`offsetKind: got ${cond.value.offsetKind}, want "atLeast"`);
      }
      return problems;
    },
  },
];

async function main() {
  const dryRun = Deno.args.includes("--dry-run");
  const apiKey = Deno.env.get("GEMINI_API_KEY") ?? "";
  const model = Deno.env.get("PARSE_MODEL") || DEFAULT_PARSE_MODEL;

  if (dryRun) {
    const c = CASES[0];
    console.log("=== SYSTEM INSTRUCTION (SYSTEM_PREAMBLE_TASK_REFS) ===\n");
    console.log(SYSTEM_PREAMBLE_TASK_REFS);
    console.log("\n\n=== RESPONSE SCHEMA ===\n");
    console.log(JSON.stringify(buildParseEnvelopeResponseSchema(), null, 2));
    console.log("\n\n=== CONTENTS (case 1) ===\n");
    console.log(buildParseContents({
      transcript: c.transcript,
      now: NOW_VN,
      timezone: TZ_VN,
      openTaskTitles: c.openTaskTitles,
    }));
    console.log(`\n\n(${CASES.length} cases defined; re-run with GEMINI_API_KEY set to probe live.)`);
    return;
  }

  if (!apiKey) {
    console.error(
      "GEMINI_API_KEY is not set.\n" +
        "  Live:    GEMINI_API_KEY=... deno run --allow-net --allow-env " +
        "supabase/scripts/probe-task-refs.ts\n" +
        "  Dry run: deno run --allow-env supabase/scripts/probe-task-refs.ts --dry-run",
    );
    Deno.exit(2);
  }

  console.log(`model: ${model}\n`);
  let pass = 0;
  let fail = 0;

  for (const [i, c] of CASES.entries()) {
    const label = `[${String(i + 1).padStart(2, "0")}] "${c.transcript}"`;
    try {
      const raw = await callGemini({
        apiKey,
        model,
        systemInstruction: SYSTEM_PREAMBLE_TASK_REFS,
        contents: buildParseContents({
          transcript: c.transcript,
          now: NOW_VN,
          timezone: TZ_VN,
          openTaskTitles: c.openTaskTitles,
        }),
        responseSchema: buildParseEnvelopeResponseSchema(),
        timeoutMs: 30000,
      });

      const env = asEnvelope(raw);
      const problems = c.check(env);

      if (problems.length === 0) {
        pass++;
        console.log(
          `PASS ${label}  ->  tasks=${env.tasks.length}, taskRefs=${env.taskRefs.length}, updates=${env.updates.length}`,
        );
      } else {
        fail++;
        console.log(`FAIL ${label}\n${problems.map((p) => `     ${p}`).join("\n")}\n     (${c.why})\n`);
      }
    } catch (err) {
      fail++;
      console.log(`FAIL ${label}\n     threw: ${err instanceof Error ? err.message : String(err)}\n`);
    }
  }

  console.log(`\n${pass} passed, ${fail} failed, ${CASES.length} total`);
  Deno.exit(fail === 0 ? 0 : 1);
}

await main();
