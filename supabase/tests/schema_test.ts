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
  MAX_NOTES_CHARS,
  MAX_TASKS,
  type ParsedTaskOut,
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
