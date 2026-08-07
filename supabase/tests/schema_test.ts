// supabase/tests/schema_test.ts
//
// Deno tests for supabase/functions/_shared/schema.ts's model-output validation (`validateParsedTask`
// via `validateParsedTaskArray`) and request validation (`validateRequestBody`).
//
// WHY THIS FILE LIVES OUTSIDE `supabase/functions/`: `supabase functions deploy <name>` packages
// the deployed function from inside `supabase/functions/<name>/` (and its `_shared` imports); a
// `*_test.ts` file placed inside `supabase/functions/_shared/` risks being swept into that deploy
// artifact depending on the CLI version/bundling mode in use, for zero runtime benefit (it is
// never imported by any handler). Living here, next to (but outside) `functions/`, this file is
// invisible to `supabase functions deploy` under every bundling mode while still being trivially
// reachable by `deno test` via an explicit path or `deno test supabase/tests/`. There is currently
// no other test in this repo for `supabase/functions/`, so there's no existing convention this
// breaks.
//
// Run: `deno test supabase/tests/schema_test.ts` (or `deno test supabase/tests/`).

import { assertEquals, assertExists } from "jsr:@std/assert@1";
import {
  MAX_CONTEXT_TRANSCRIPT_CHARS,
  MAX_DREAD_MESSAGE_CHARS,
  MAX_EXISTING_SUBTASKS,
  MAX_NEXT_ACTION_CHARS,
  MAX_NOTES_CHARS,
  MAX_TASKS,
  MAX_TASK_TITLE_CHARS,
  type ParsedTaskOut,
  validateDreadMessage,
  validateNextActionMessage,
  validateParsedTaskArray,
  validateRequestBody,
} from "../functions/_shared/schema.ts";

// ---------------------------------------------------------------------------------------------
// Fixture builder — a single fully-populated, fully-valid ParsedTaskOut-shaped raw object (i.e.
// what we pretend the model returned, BEFORE validation). Each test starts from a deep-ish clone
// of this and mutates exactly the field under test, so a passing "valid task" case (test 1) and
// every "one field broke" case share the same baseline.
// ---------------------------------------------------------------------------------------------

function validRawTask(title = "Nộp báo cáo Q3"): Record<string, unknown> {
  return {
    title: { value: title, confidence: 0.95 },
    notes: { value: "ghi chú ngắn", confidence: 0.8 },
    deadline: { value: "2026-07-30T10:00:00", confidence: 0.7 },
    startTime: { value: "2026-07-30T09:00:00", confidence: 0.7 },
    estimateMinutes: { value: 30, confidence: 0.9 },
    priority: { value: 2, confidence: 0.9 },
    recurrence: { value: { type: "daily" }, confidence: 0.6 },
    reminderOverride: {
      value: { offsetsMinutes: [-10, -5], remindPeriodMinutes: 15 },
      confidence: 0.6,
    },
    conditions: [
      { value: { kind: "external", description: "chờ sếp duyệt" }, confidence: 0.5 },
    ],
    kind: { value: "task", confidence: 0.9 },
    subtasks: [
      {
        title: { value: "bước 1", confidence: 0.9 },
        estimateMinutes: { value: 10, confidence: 0.9 },
      },
    ],
    followUpReview: { value: false, confidence: 0.9 },
  };
}

function expectOk(v: unknown): { tasks: ParsedTaskOut[]; droppedCount: number } {
  const result = validateParsedTaskArray(v);
  assertExists(result, "expected validateParsedTaskArray to return a value, got undefined");
  return result!;
}

// ---------------------------------------------------------------------------------------------
// 1. Fully valid task -> every field survives.
// ---------------------------------------------------------------------------------------------
Deno.test("valid task: every field passes through", () => {
  const result = expectOk([validRawTask()]);
  assertEquals(result.tasks.length, 1);
  assertEquals(result.droppedCount, 0);
  const t = result.tasks[0];
  assertEquals(t.title.value, "Nộp báo cáo Q3");
  assertExists(t.notes);
  assertExists(t.deadline);
  assertExists(t.startTime);
  assertExists(t.estimateMinutes);
  assertExists(t.priority);
  assertExists(t.recurrence);
  assertExists(t.reminderOverride);
  assertEquals(t.reminderOverride!.value.remindPeriodMinutes, 15);
  assertExists(t.conditions);
  assertEquals(t.conditions!.length, 1);
  assertExists(t.kind);
  assertExists(t.subtasks);
  assertEquals(t.subtasks!.length, 1);
  assertExists(t.followUpReview);
});

// ---------------------------------------------------------------------------------------------
// 2. priority out of range (7, valid range is 1-4) -> task survives, only `priority` is dropped.
//    This is THE case that demonstrates anh Khôi's fail-open decision.
// ---------------------------------------------------------------------------------------------
Deno.test("priority out of range (7): task survives, only priority dropped", () => {
  const raw = validRawTask();
  raw.priority = { value: 7, confidence: 0.9 };
  const result = expectOk([raw]);
  assertEquals(result.tasks.length, 1);
  assertEquals(result.droppedCount, 0);
  assertEquals(result.tasks[0].priority, undefined);
  // everything else on the task is untouched
  assertExists(result.tasks[0].title);
  assertExists(result.tasks[0].deadline);
});

// ---------------------------------------------------------------------------------------------
// 3. deadline not ISO8601 -> task survives, only `deadline` dropped.
// ---------------------------------------------------------------------------------------------
Deno.test("deadline not ISO8601: task survives, only deadline dropped", () => {
  const raw = validRawTask();
  raw.deadline = { value: "not-a-date", confidence: 0.7 };
  const result = expectOk([raw]);
  assertEquals(result.tasks.length, 1);
  assertEquals(result.tasks[0].deadline, undefined);
  assertExists(result.tasks[0].title);
});

// ---------------------------------------------------------------------------------------------
// 4. notes too long -> task survives, only `notes` dropped.
// ---------------------------------------------------------------------------------------------
Deno.test("notes too long: task survives, only notes dropped", () => {
  const raw = validRawTask();
  raw.notes = { value: "x".repeat(MAX_NOTES_CHARS + 1), confidence: 0.5 };
  const result = expectOk([raw]);
  assertEquals(result.tasks.length, 1);
  assertEquals(result.tasks[0].notes, undefined);
  assertExists(result.tasks[0].title);
});

// ---------------------------------------------------------------------------------------------
// 5. Array of 3 tasks, task #2 (index 1) has a broken field -> all 3 tasks survive, only #2 is
//    missing the broken field.
// ---------------------------------------------------------------------------------------------
Deno.test("array of 3, middle task has broken field: all 3 survive", () => {
  const t1 = validRawTask("Task 1");
  const t2 = validRawTask("Task 2");
  t2.priority = { value: 99, confidence: 0.9 };
  const t3 = validRawTask("Task 3");
  const result = expectOk([t1, t2, t3]);
  assertEquals(result.tasks.length, 3);
  assertEquals(result.droppedCount, 0);
  assertEquals(result.tasks[0].title.value, "Task 1");
  assertExists(result.tasks[0].priority);
  assertEquals(result.tasks[1].title.value, "Task 2");
  assertEquals(result.tasks[1].priority, undefined); // only the broken field is gone
  assertEquals(result.tasks[2].title.value, "Task 3");
  assertExists(result.tasks[2].priority);
});

// ---------------------------------------------------------------------------------------------
// 6. Array of 3 tasks, task #2 has NO title -> only that task is dropped; 2 remain;
//    droppedCount === 1.
// ---------------------------------------------------------------------------------------------
Deno.test("array of 3, middle task has no title: 2 survive, droppedCount 1", () => {
  const t1 = validRawTask("Task 1");
  const t2 = validRawTask("Task 2");
  delete t2.title;
  const t3 = validRawTask("Task 3");
  const result = expectOk([t1, t2, t3]);
  assertEquals(result.tasks.length, 2);
  assertEquals(result.droppedCount, 1);
  assertEquals(result.tasks[0].title.value, "Task 1");
  assertEquals(result.tasks[1].title.value, "Task 3");
});

// ---------------------------------------------------------------------------------------------
// 7. Every task lacks a title -> whole response is untrustworthy -> undefined (-> 502 upstream).
// ---------------------------------------------------------------------------------------------
Deno.test("all tasks missing title: undefined (502)", () => {
  const t1 = validRawTask();
  delete t1.title;
  const t2 = validRawTask();
  delete t2.title;
  const result = validateParsedTaskArray([t1, t2]);
  assertEquals(result, undefined);
});

// ---------------------------------------------------------------------------------------------
// 8. conditions array: 1 broken element among 3 -> the 2 good elements survive, bad one dropped.
// ---------------------------------------------------------------------------------------------
Deno.test("conditions array: 1 broken element among 3 survives as 2", () => {
  const raw = validRawTask();
  raw.conditions = [
    { value: { kind: "external", description: "điều kiện 1" }, confidence: 0.5 },
    { value: { kind: "bogus-kind" }, confidence: 0.5 }, // invalid kind
    { value: { kind: "external", description: "điều kiện 3" }, confidence: 0.5 },
  ];
  const result = expectOk([raw]);
  assertEquals(result.tasks.length, 1);
  assertExists(result.tasks[0].conditions);
  assertEquals(result.tasks[0].conditions!.length, 2);
  assertEquals(result.tasks[0].conditions![0].value.description, "điều kiện 1");
  assertEquals(result.tasks[0].conditions![1].value.description, "điều kiện 3");
});

// ---------------------------------------------------------------------------------------------
// 9. More than MAX_TASKS valid tasks -> truncated to MAX_TASKS, droppedCount reflects the excess.
// ---------------------------------------------------------------------------------------------
Deno.test("over MAX_TASKS: truncated with correct droppedCount", () => {
  const extra = 3;
  const raws = Array.from({ length: MAX_TASKS + extra }, (_, i) => validRawTask(`Task ${i + 1}`));
  const result = expectOk(raws);
  assertEquals(result.tasks.length, MAX_TASKS);
  assertEquals(result.droppedCount, extra);
});

// ---------------------------------------------------------------------------------------------
// 10. validateRequestBody: `now` zone requirement, `timezone` regex.
// ---------------------------------------------------------------------------------------------
Deno.test("validateRequestBody: now missing zone is rejected", () => {
  const result = validateRequestBody({
    mode: "parse",
    transcript: "mua sữa",
    now: "2026-07-28T15:00:00", // no Z / offset
    open_task_titles: [],
  });
  assertEquals(result.ok, false);
});

Deno.test("validateRequestBody: timezone failing the IANA regex is rejected", () => {
  const result = validateRequestBody({
    mode: "parse",
    transcript: "mua sữa",
    now: "2026-07-28T15:00:00+07:00",
    open_task_titles: [],
    timezone: "Asia/Ho Chi Minh; DROP TABLE", // spaces + punctuation -> fails the strict regex
  });
  assertEquals(result.ok, false);
});

Deno.test("validateRequestBody: valid timezone passes", () => {
  const result = validateRequestBody({
    mode: "parse",
    transcript: "mua sữa",
    now: "2026-07-28T15:00:00+07:00",
    open_task_titles: [],
    timezone: "Asia/Ho_Chi_Minh",
  });
  assertEquals(result.ok, true);
  if (result.ok && result.value.mode === "parse") {
    assertEquals(result.value.timezone, "Asia/Ho_Chi_Minh");
  }
});

Deno.test("validateRequestBody: absent timezone still passes", () => {
  const result = validateRequestBody({
    mode: "parse",
    transcript: "mua sữa",
    now: "2026-07-28T15:00:00+07:00",
    open_task_titles: [],
  });
  assertEquals(result.ok, true);
  if (result.ok && result.value.mode === "parse") {
    assertEquals(result.value.timezone, undefined);
  }
});

// ---------------------------------------------------------------------------------------------
// 11. Regression guard: startTime / remindPeriodMinutes broken -> only that field dropped (these
//     two fields were made fail-open in a prior pass; they must remain so, now as the general rule
//     rather than an exception).
// ---------------------------------------------------------------------------------------------
Deno.test("regression: broken startTime only drops startTime", () => {
  const raw = validRawTask();
  raw.startTime = { value: "not-a-time", confidence: 0.7 };
  const result = expectOk([raw]);
  assertEquals(result.tasks[0].startTime, undefined);
  assertExists(result.tasks[0].title);
  assertExists(result.tasks[0].deadline);
});

Deno.test("regression: broken remindPeriodMinutes only drops remindPeriodMinutes", () => {
  const raw = validRawTask();
  raw.reminderOverride = {
    value: { offsetsMinutes: [-10, -5], remindPeriodMinutes: -5 }, // must be > 0
    confidence: 0.6,
  };
  const result = expectOk([raw]);
  assertExists(result.tasks[0].reminderOverride);
  assertEquals(result.tasks[0].reminderOverride!.value.remindPeriodMinutes, undefined);
  assertEquals(result.tasks[0].reminderOverride!.value.offsetsMinutes, [-10, -5]);
});

// ---------------------------------------------------------------------------------------------
// 11b. reminderOverride: `offsetsMinutes` synthesis from a bare `remindPeriodMinutes` (2026-08-07
//      fix — see `validateReminderOverride`'s doc comment in schema.ts). Before this fix, a model
//      response of `{remindPeriodMinutes: 15}` alone (no `offsetsMinutes`) silently discarded the
//      ENTIRE override, because `offsetsMinutes`'s empty-array check ran before
//      `remindPeriodMinutes` was even read. The wire shape (`offsetsMinutes: number[]`,
//      non-optional) must not change, so the server now synthesizes a single entry instead.
// ---------------------------------------------------------------------------------------------
Deno.test("reminderOverride: bare remindPeriodMinutes synthesizes a single-entry offsetsMinutes", () => {
  const raw = validRawTask();
  raw.reminderOverride = {
    value: { remindPeriodMinutes: 15 }, // no offsetsMinutes at all
    confidence: 0.6,
  };
  const result = expectOk([raw]);
  const override = result.tasks[0].reminderOverride;
  assertExists(override, "reminderOverride must survive, not be discarded");
  assertEquals(override!.value.remindPeriodMinutes, 15);
  assertEquals(override!.value.offsetsMinutes, [-15]);
});

Deno.test("reminderOverride: offsetsMinutes AND remindPeriodMinutes both present -> unchanged", () => {
  const raw = validRawTask();
  raw.reminderOverride = {
    value: { offsetsMinutes: [-10, -5], remindPeriodMinutes: 15 },
    confidence: 0.6,
  };
  const result = expectOk([raw]);
  const override = result.tasks[0].reminderOverride;
  assertExists(override);
  assertEquals(override!.value.offsetsMinutes, [-10, -5]);
  assertEquals(override!.value.remindPeriodMinutes, 15);
});

Deno.test("reminderOverride: offsetsMinutes only (no remindPeriodMinutes) -> unchanged", () => {
  const raw = validRawTask();
  raw.reminderOverride = {
    value: { offsetsMinutes: [-30] },
    confidence: 0.6,
  };
  const result = expectOk([raw]);
  const override = result.tasks[0].reminderOverride;
  assertExists(override);
  assertEquals(override!.value.offsetsMinutes, [-30]);
  assertEquals(override!.value.remindPeriodMinutes, undefined);
});

Deno.test("reminderOverride: neither offsetsMinutes nor remindPeriodMinutes usable -> undefined", () => {
  const raw = validRawTask();
  raw.reminderOverride = {
    value: {},
    confidence: 0.6,
  };
  const result = expectOk([raw]);
  assertEquals(result.tasks[0].reminderOverride, undefined);
});

Deno.test("reminderOverride: malformed remindPeriodMinutes (zero) and no offsetsMinutes -> undefined, no synthesis", () => {
  const raw = validRawTask();
  raw.reminderOverride = {
    value: { remindPeriodMinutes: 0 },
    confidence: 0.6,
  };
  const result = expectOk([raw]);
  assertEquals(result.tasks[0].reminderOverride, undefined);
});

Deno.test("reminderOverride: malformed remindPeriodMinutes (negative) and no offsetsMinutes -> undefined, no synthesis", () => {
  const raw = validRawTask();
  raw.reminderOverride = {
    value: { remindPeriodMinutes: -15 },
    confidence: 0.6,
  };
  const result = expectOk([raw]);
  assertEquals(result.tasks[0].reminderOverride, undefined);
});

Deno.test("reminderOverride: malformed remindPeriodMinutes (non-numeric) and no offsetsMinutes -> undefined, no synthesis", () => {
  const raw = validRawTask();
  raw.reminderOverride = {
    value: { remindPeriodMinutes: "15" },
    confidence: 0.6,
  };
  const result = expectOk([raw]);
  assertEquals(result.tasks[0].reminderOverride, undefined);
});

Deno.test("reminderOverride: absurdly large remindPeriodMinutes and no offsetsMinutes -> undefined, no synthesis", () => {
  const raw = validRawTask();
  raw.reminderOverride = {
    // Well beyond MAX_CONDITION_OFFSET_MINUTES (525600, one year in minutes) -- the same
    // magnitude ceiling every other offset-in-minutes field in this file uses.
    value: { remindPeriodMinutes: 999_999_999 },
    confidence: 0.6,
  };
  const result = expectOk([raw]);
  assertEquals(result.tasks[0].reminderOverride, undefined);
});

// ---------------------------------------------------------------------------------------------
// 12. "stuck" mode request validation (Change: anh Khôi's "Stuck?" feature, 2026-07-29).
// ---------------------------------------------------------------------------------------------

Deno.test("validateRequestBody: stuck/too_big with valid task_title passes", () => {
  const result = validateRequestBody({
    mode: "stuck",
    reason: "too_big",
    task_title: "Nộp báo cáo Q3",
  });
  assertEquals(result.ok, true);
  if (result.ok && result.value.mode === "stuck") {
    assertEquals(result.value.reason, "too_big");
    assertEquals(result.value.taskTitle, "Nộp báo cáo Q3");
    assertEquals(result.value.notes, undefined);
  }
});

Deno.test("validateRequestBody: stuck/dread with task_title + notes passes", () => {
  const result = validateRequestBody({
    mode: "stuck",
    reason: "dread",
    task_title: "Call the landlord",
    notes: "haven't picked up the phone in weeks",
  });
  assertEquals(result.ok, true);
  if (result.ok && result.value.mode === "stuck") {
    assertEquals(result.value.reason, "dread");
    assertEquals(result.value.notes, "haven't picked up the phone in weeks");
  }
});

Deno.test("validateRequestBody: stuck with an invalid reason is rejected", () => {
  const result = validateRequestBody({
    mode: "stuck",
    reason: "cant_start", // never valid on the wire — client handles this reason locally, no model call
    task_title: "Anything",
  });
  assertEquals(result.ok, false);
});

Deno.test("validateRequestBody: stuck with a bogus/unrecognized reason is rejected", () => {
  const result = validateRequestBody({
    mode: "stuck",
    reason: "bored",
    task_title: "Anything",
  });
  assertEquals(result.ok, false);
});

Deno.test("validateRequestBody: stuck missing task_title is rejected", () => {
  const result = validateRequestBody({
    mode: "stuck",
    reason: "dread",
  });
  assertEquals(result.ok, false);
});

Deno.test("validateRequestBody: stuck notes over MAX_NOTES_CHARS is rejected", () => {
  const result = validateRequestBody({
    mode: "stuck",
    reason: "dread",
    task_title: "Anything",
    notes: "x".repeat(MAX_NOTES_CHARS + 1),
  });
  assertEquals(result.ok, false);
});

// ---------------------------------------------------------------------------------------------
// 13. validateDreadMessage — the "stuck"/"dread" model-output validator.
// ---------------------------------------------------------------------------------------------

Deno.test("validateDreadMessage: a well-formed message passes through trimmed", () => {
  const result = validateDreadMessage({ message: "  Open the invoice PDF and read the first line.  " });
  assertEquals(result, "Open the invoice PDF and read the first line.");
});

Deno.test("validateDreadMessage: over MAX_DREAD_MESSAGE_CHARS is rejected outright (never truncated)", () => {
  const result = validateDreadMessage({ message: "x".repeat(MAX_DREAD_MESSAGE_CHARS + 1) });
  assertEquals(result, undefined);
});

Deno.test("validateDreadMessage: exactly MAX_DREAD_MESSAGE_CHARS passes", () => {
  const result = validateDreadMessage({ message: "x".repeat(MAX_DREAD_MESSAGE_CHARS) });
  assertEquals(result, "x".repeat(MAX_DREAD_MESSAGE_CHARS));
});

Deno.test("validateDreadMessage: empty/whitespace-only message is rejected", () => {
  assertEquals(validateDreadMessage({ message: "" }), undefined);
  assertEquals(validateDreadMessage({ message: "   " }), undefined);
});

Deno.test("validateDreadMessage: model returns garbage shapes -> undefined, never passed through", () => {
  assertEquals(validateDreadMessage(null), undefined);
  assertEquals(validateDreadMessage(undefined), undefined);
  assertEquals(validateDreadMessage("just a bare string"), undefined);
  assertEquals(validateDreadMessage([]), undefined);
  assertEquals(validateDreadMessage({}), undefined);
  assertEquals(validateDreadMessage({ message: 123 }), undefined);
  assertEquals(validateDreadMessage({ message: null }), undefined);
  assertEquals(validateDreadMessage({ notMessage: "wrong field name" }), undefined);
});

// ---------------------------------------------------------------------------------------------
// 14. validateNextActionMessage — the REDESIGNED "stuck"/"too_big" model-output validator
//     (anh Khôi, 2026-07-29: replaces the old 3-9 step plan with exactly one next physical action).
// ---------------------------------------------------------------------------------------------

Deno.test("validateNextActionMessage: a well-formed single action passes through trimmed", () => {
  const result = validateNextActionMessage({ message: "  Mở file Minh gửi ra.  " });
  assertEquals(result, "Mở file Minh gửi ra.");
});

Deno.test("validateNextActionMessage: over MAX_NEXT_ACTION_CHARS is rejected outright (never truncated)", () => {
  const result = validateNextActionMessage({ message: "x".repeat(MAX_NEXT_ACTION_CHARS + 1) });
  assertEquals(result, undefined);
});

Deno.test("validateNextActionMessage: exactly MAX_NEXT_ACTION_CHARS passes", () => {
  const result = validateNextActionMessage({ message: "x".repeat(MAX_NEXT_ACTION_CHARS) });
  assertEquals(result, "x".repeat(MAX_NEXT_ACTION_CHARS));
});

Deno.test("validateNextActionMessage: a full breakdown-shaped plan (much longer than one action) is rejected", () => {
  // Regression guard for the exact failure mode this redesign exists to prevent: a model that
  // ignores "exactly ONE action" and reverts to listing several steps must be caught by the cap,
  // not silently accepted because SOME string was present. Built by repeating a step-shaped clause
  // rather than a hand-picked sentence, so the fixture is guaranteed to exceed the cap regardless
  // of exact wording (asserted below rather than assumed).
  const wouldBeAPlan =
    "Bước 1: mở file. Bước 2: đọc số liệu. Bước 3: viết phần phân tích. Bước 4: rà soát lại. " +
    "Bước 5: gửi cho sếp Hùng trước thứ 5. Bước 6: lưu bản sao. Bước 7: thông báo cho cả nhóm. " +
    "Bước 8: xin xác nhận lần cuối trước khi gửi đi chính thức.";
  assertEquals(wouldBeAPlan.length > MAX_NEXT_ACTION_CHARS, true, "sanity: this fixture must actually exceed the cap");
  assertEquals(validateNextActionMessage({ message: wouldBeAPlan }), undefined);
});

Deno.test("validateNextActionMessage: MAX_NEXT_ACTION_CHARS is deliberately shorter than MAX_DREAD_MESSAGE_CHARS", () => {
  // A next-action message is ONE clause (the action alone); a dread message is TWO clauses (name
  // the dreaded detail, then the action) — this is the one place that relationship is pinned down
  // so a future edit can't silently make them equal or invert them.
  assertEquals(MAX_NEXT_ACTION_CHARS < MAX_DREAD_MESSAGE_CHARS, true);
});

Deno.test("validateNextActionMessage: model returns garbage shapes -> undefined, never passed through", () => {
  assertEquals(validateNextActionMessage(null), undefined);
  assertEquals(validateNextActionMessage(undefined), undefined);
  assertEquals(validateNextActionMessage("just a bare string"), undefined);
  assertEquals(validateNextActionMessage([]), undefined);
  assertEquals(validateNextActionMessage({}), undefined);
  assertEquals(validateNextActionMessage({ message: 123 }), undefined);
  assertEquals(validateNextActionMessage({ steps: ["not the right field"] }), undefined);
});

// ---------------------------------------------------------------------------------------------
// 15. Context addendum (anh Khôi, 2026-07-29): `source_transcript`/`deadline`/`existing_subtasks`
//     on `breakdown` and `stuck` requests — ALL THREE optional and fail-open. Backward-compat with
//     older clients that never send them is the load-bearing property here.
// ---------------------------------------------------------------------------------------------

Deno.test("backward-compat: breakdown request with NO context fields still passes exactly as before", () => {
  const result = validateRequestBody({
    mode: "breakdown",
    task_title: "Launch landing page",
  });
  assertEquals(result.ok, true);
  if (result.ok && result.value.mode === "breakdown") {
    assertEquals(result.value.sourceTranscript, undefined);
    assertEquals(result.value.deadline, undefined);
    assertEquals(result.value.existingSubtasks, undefined);
  }
});

Deno.test("backward-compat: stuck request with NO context fields still passes exactly as before", () => {
  const result = validateRequestBody({
    mode: "stuck",
    reason: "too_big",
    task_title: "Launch landing page",
  });
  assertEquals(result.ok, true);
  if (result.ok && result.value.mode === "stuck") {
    assertEquals(result.value.sourceTranscript, undefined);
    assertEquals(result.value.deadline, undefined);
    assertEquals(result.value.existingSubtasks, undefined);
  }
});

Deno.test("context: source_transcript within cap is forwarded verbatim", () => {
  const result = validateRequestBody({
    mode: "breakdown",
    task_title: "làm báo cáo Q3",
    source_transcript: "làm báo cáo Q3 cho sếp Hùng trước thứ 5, số liệu lấy từ file Minh gửi",
  });
  assertEquals(result.ok, true);
  if (result.ok && result.value.mode === "breakdown") {
    assertEquals(
      result.value.sourceTranscript,
      "làm báo cáo Q3 cho sếp Hùng trước thứ 5, số liệu lấy từ file Minh gửi",
    );
  }
});

Deno.test("context: over-cap source_transcript is TRUNCATED, never rejects the request", () => {
  const overCap = "x".repeat(MAX_CONTEXT_TRANSCRIPT_CHARS + 500);
  const result = validateRequestBody({
    mode: "breakdown",
    task_title: "Anything",
    source_transcript: overCap,
  });
  assertEquals(result.ok, true, "an oversized supplementary context field must never take down the whole request");
  if (result.ok && result.value.mode === "breakdown") {
    assertEquals(result.value.sourceTranscript?.length, MAX_CONTEXT_TRANSCRIPT_CHARS);
    assertEquals(result.value.sourceTranscript, "x".repeat(MAX_CONTEXT_TRANSCRIPT_CHARS));
  }
});

Deno.test("context: blank/whitespace-only source_transcript is dropped, not forwarded as empty content", () => {
  const result = validateRequestBody({
    mode: "breakdown",
    task_title: "Anything",
    source_transcript: "   ",
  });
  assertEquals(result.ok, true);
  if (result.ok && result.value.mode === "breakdown") {
    assertEquals(result.value.sourceTranscript, undefined);
  }
});

Deno.test("context: wrong-type source_transcript is dropped, never rejects the request", () => {
  const result = validateRequestBody({
    mode: "stuck",
    reason: "dread",
    task_title: "Anything",
    source_transcript: 12345, // not a string
  });
  assertEquals(result.ok, true);
  if (result.ok && result.value.mode === "stuck") {
    assertEquals(result.value.sourceTranscript, undefined);
  }
});

Deno.test("context: deadline with a real UTC offset is kept", () => {
  const result = validateRequestBody({
    mode: "breakdown",
    task_title: "Anything",
    deadline: "2026-08-06T18:00:00+07:00",
  });
  assertEquals(result.ok, true);
  if (result.ok && result.value.mode === "breakdown") {
    assertEquals(result.value.deadline, "2026-08-06T18:00:00+07:00");
  }
});

Deno.test("context: deadline WITHOUT a zone is dropped, never rejects the request", () => {
  // Same zone requirement as `now` in parse mode (isIso8601WithZone) — but unlike `now`, a
  // malformed OPTIONAL deadline here degrades to "no deadline context", not a 400.
  const result = validateRequestBody({
    mode: "stuck",
    reason: "too_big",
    task_title: "Anything",
    deadline: "2026-08-06T18:00:00", // no offset/Z
  });
  assertEquals(result.ok, true);
  if (result.ok && result.value.mode === "stuck") {
    assertEquals(result.value.deadline, undefined);
  }
});

Deno.test("context: garbage deadline is dropped, never rejects the request", () => {
  const result = validateRequestBody({
    mode: "breakdown",
    task_title: "Anything",
    deadline: "not-a-date",
  });
  assertEquals(result.ok, true);
  if (result.ok && result.value.mode === "breakdown") {
    assertEquals(result.value.deadline, undefined);
  }
});

Deno.test("context: existing_subtasks — good entries kept, one bad entry among them dropped alone", () => {
  const result = validateRequestBody({
    mode: "breakdown",
    task_title: "Launch landing page",
    existing_subtasks: [
      { title: "Open Framer", done: true },
      { title: "" /* empty title */, done: false },
      { title: "Draft the headline", done: false },
      { done: true /* missing title entirely */ },
      { title: "Ship it", done: "yes" /* wrong type for done */ },
    ],
  });
  assertEquals(result.ok, true);
  if (result.ok && result.value.mode === "breakdown") {
    assertEquals(result.value.existingSubtasks, [
      { title: "Open Framer", done: true },
      { title: "Draft the headline", done: false },
    ]);
  }
});

Deno.test("context: existing_subtasks not an array is dropped entirely, never rejects the request", () => {
  const result = validateRequestBody({
    mode: "stuck",
    reason: "too_big",
    task_title: "Anything",
    existing_subtasks: "not an array",
  });
  assertEquals(result.ok, true);
  if (result.ok && result.value.mode === "stuck") {
    assertEquals(result.value.existingSubtasks, undefined);
  }
});

Deno.test("context: existing_subtasks where EVERY entry is malformed collapses to undefined, not []", () => {
  const result = validateRequestBody({
    mode: "breakdown",
    task_title: "Anything",
    existing_subtasks: [{ title: "" }, { notTitle: "x", done: true }],
  });
  assertEquals(result.ok, true);
  if (result.ok && result.value.mode === "breakdown") {
    assertEquals(result.value.existingSubtasks, undefined);
  }
});

Deno.test("context: existing_subtasks over MAX_EXISTING_SUBTASKS is capped, never rejects the request", () => {
  const many = Array.from({ length: MAX_EXISTING_SUBTASKS + 5 }, (_, i) => ({
    title: `Step ${i + 1}`,
    done: i % 2 === 0,
  }));
  const result = validateRequestBody({
    mode: "breakdown",
    task_title: "Anything",
    existing_subtasks: many,
  });
  assertEquals(result.ok, true);
  if (result.ok && result.value.mode === "breakdown") {
    assertEquals(result.value.existingSubtasks?.length, MAX_EXISTING_SUBTASKS);
  }
});

Deno.test("context: existing_subtasks title over MAX_TASK_TITLE_CHARS is dropped as an entry", () => {
  const result = validateRequestBody({
    mode: "breakdown",
    task_title: "Anything",
    existing_subtasks: [
      { title: "x".repeat(MAX_TASK_TITLE_CHARS + 1), done: false },
      { title: "A fine title", done: true },
    ],
  });
  assertEquals(result.ok, true);
  if (result.ok && result.value.mode === "breakdown") {
    assertEquals(result.value.existingSubtasks, [{ title: "A fine title", done: true }]);
  }
});

// ---------------------------------------------------------------------------------------------
// 16. `client_caps` request validation (task_refs_v1, anh Khôi 2026-08-02 task-refs design). See
//     `ParseRequest.clientCaps`'s doc comment in `_shared/schema.ts` for the full capability-
//     handshake rationale. The load-bearing property here: a request with NO `client_caps` at all
//     must validate/behave exactly as every parse-mode fixture already tested above (spot-checked
//     in the last test of this section) — this feature must be additive, never a behavior change
//     for a client that has never heard of it.
// ---------------------------------------------------------------------------------------------

Deno.test("client_caps: absent entirely -> parse request still validates, clientCaps is undefined", () => {
  const result = validateRequestBody({
    mode: "parse",
    transcript: "mua sữa",
    now: "2026-07-28T15:00:00+07:00",
    open_task_titles: [],
  });
  assertEquals(result.ok, true);
  if (result.ok && result.value.mode === "parse") {
    assertEquals(result.value.clientCaps, undefined);
  }
});

Deno.test("client_caps: a valid array (including the recognized task_refs_v1 cap) is forwarded verbatim", () => {
  const result = validateRequestBody({
    mode: "parse",
    transcript: "mua sữa",
    now: "2026-07-28T15:00:00+07:00",
    open_task_titles: [],
    client_caps: ["task_refs_v1"],
  });
  assertEquals(result.ok, true);
  if (result.ok && result.value.mode === "parse") {
    assertEquals(result.value.clientCaps, ["task_refs_v1"]);
  }
});

Deno.test("client_caps: an UNKNOWN cap string is accepted (never rejected) — forward compat", () => {
  const result = validateRequestBody({
    mode: "parse",
    transcript: "mua sữa",
    now: "2026-07-28T15:00:00+07:00",
    open_task_titles: [],
    client_caps: ["some_future_cap_this_deploy_does_not_know", "task_refs_v1"],
  });
  assertEquals(result.ok, true);
  if (result.ok && result.value.mode === "parse") {
    assertEquals(result.value.clientCaps, ["some_future_cap_this_deploy_does_not_know", "task_refs_v1"]);
  }
});

Deno.test("client_caps: non-array is rejected", () => {
  const result = validateRequestBody({
    mode: "parse",
    transcript: "mua sữa",
    now: "2026-07-28T15:00:00+07:00",
    open_task_titles: [],
    client_caps: "task_refs_v1", // a bare string, not an array
  });
  assertEquals(result.ok, false);
});

Deno.test("client_caps: more than 16 entries is rejected", () => {
  const result = validateRequestBody({
    mode: "parse",
    transcript: "mua sữa",
    now: "2026-07-28T15:00:00+07:00",
    open_task_titles: [],
    client_caps: Array.from({ length: 17 }, (_, i) => `cap_${i}`),
  });
  assertEquals(result.ok, false);
});

Deno.test("client_caps: exactly 16 entries passes", () => {
  const result = validateRequestBody({
    mode: "parse",
    transcript: "mua sữa",
    now: "2026-07-28T15:00:00+07:00",
    open_task_titles: [],
    client_caps: Array.from({ length: 16 }, (_, i) => `cap_${i}`),
  });
  assertEquals(result.ok, true);
});

Deno.test("client_caps: an empty-string entry is rejected", () => {
  const result = validateRequestBody({
    mode: "parse",
    transcript: "mua sữa",
    now: "2026-07-28T15:00:00+07:00",
    open_task_titles: [],
    client_caps: ["task_refs_v1", ""],
  });
  assertEquals(result.ok, false);
});

Deno.test("client_caps: an entry over 64 chars is rejected", () => {
  const result = validateRequestBody({
    mode: "parse",
    transcript: "mua sữa",
    now: "2026-07-28T15:00:00+07:00",
    open_task_titles: [],
    client_caps: ["x".repeat(65)],
  });
  assertEquals(result.ok, false);
});

Deno.test("client_caps: an entry of exactly 64 chars passes", () => {
  const result = validateRequestBody({
    mode: "parse",
    transcript: "mua sữa",
    now: "2026-07-28T15:00:00+07:00",
    open_task_titles: [],
    client_caps: ["x".repeat(64)],
  });
  assertEquals(result.ok, true);
});

Deno.test("client_caps: a non-string entry (e.g. a number) is rejected", () => {
  const result = validateRequestBody({
    mode: "parse",
    transcript: "mua sữa",
    now: "2026-07-28T15:00:00+07:00",
    open_task_titles: [],
    client_caps: [123],
  });
  assertEquals(result.ok, false);
});

// Back-compat spot-check (task brief requirement): a plain, pre-existing parse fixture with no
// `client_caps` at all validates to the exact same shape as it always has — every OTHER field on
// the validated value is untouched by this feature, `clientCaps` is simply `undefined`.
Deno.test("back-compat: a parse request with no client_caps validates identically to before this feature", () => {
  const result = validateRequestBody({
    mode: "parse",
    transcript: "mua sữa",
    locale_hint: "vi",
    now: "2026-07-28T15:00:00+07:00",
    open_task_titles: ["Nộp báo cáo"],
    timezone: "Asia/Ho_Chi_Minh",
  });
  assertEquals(result.ok, true);
  if (result.ok && result.value.mode === "parse") {
    assertEquals(result.value.transcript, "mua sữa");
    assertEquals(result.value.localeHint, "vi");
    assertEquals(result.value.now, "2026-07-28T15:00:00+07:00");
    assertEquals(result.value.openTaskTitles, ["Nộp báo cáo"]);
    assertEquals(result.value.timezone, "Asia/Ho_Chi_Minh");
    assertEquals(result.value.clientCaps, undefined);
  }
});
