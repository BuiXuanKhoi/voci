// supabase/tests/parse_envelope_test.ts
//
// Deno tests for the `task_refs_v1` envelope validation added to `_shared/schema.ts` (anh Khôi,
// 2026-08-02 task-refs design): `validateParseEnvelope` and the envelope-mode-only extensions it
// unlocks on `validateParsedTask`'s conditions/reminderOverride fields (`taskStart`, `refIndex`,
// `offsetMinutes`, `offsetKind`, `anchor`). Kept in its own file (rather than appended to
// `schema_test.ts`) purely for size/readability — see that file's own module doc comment for why
// tests live outside `supabase/functions/` at all (never swept into a deploy artifact).
//
// Run: `deno test supabase/tests/parse_envelope_test.ts` (or `deno test supabase/tests/`).

import { assertEquals, assertExists } from "jsr:@std/assert@1";
import {
  MAX_CONDITION_OFFSET_MINUTES,
  MAX_INDEX_TERM_CHARS,
  MAX_INDEX_TERMS,
  MAX_NOTES_CHARS,
  MAX_TASK_REFS,
  MAX_TASK_TITLE_CHARS,
  MAX_UPDATES,
  validateParseEnvelope,
  validateParsedTaskArray,
} from "../functions/_shared/schema.ts";

// ---------------------------------------------------------------------------------------------
// Fixture builders
// ---------------------------------------------------------------------------------------------

function rawTaskRef(title: string, assumeExisting?: boolean): Record<string, unknown> {
  const ref: Record<string, unknown> = { titleQuery: { value: title, confidence: 0.9 } };
  if (assumeExisting !== undefined) ref.assumeExisting = assumeExisting;
  return ref;
}

function rawTask(title = "Task"): Record<string, unknown> {
  return { title: { value: title, confidence: 0.9 } };
}

function envelope(overrides: {
  tasks?: unknown[];
  taskRefs?: unknown[];
  updates?: unknown[];
}): Record<string, unknown> {
  return {
    tasks: overrides.tasks ?? [],
    taskRefs: overrides.taskRefs ?? [],
    updates: overrides.updates ?? [],
  };
}

function expectOk(v: unknown) {
  const result = validateParseEnvelope(v);
  assertExists(result, "expected validateParseEnvelope to return a value, got undefined");
  return result!;
}

// ---------------------------------------------------------------------------------------------
// 1. Core validateParseEnvelope behavior
// ---------------------------------------------------------------------------------------------

Deno.test("validateParseEnvelope: happy path with tasks + refs + updates", () => {
  const result = expectOk(
    envelope({
      tasks: [rawTask("Nộp báo cáo Q3")],
      taskRefs: [rawTaskRef("Task kia")],
      updates: [{ refIndex: 1, set: { priority: { value: 2, confidence: 0.8 } } }],
    }),
  );
  assertEquals(result.tasks.length, 1);
  assertEquals(result.taskRefs.length, 1);
  assertEquals(result.updates.length, 1);
  assertEquals(result.updates[0].refIndex, 1);
  assertEquals(result.updates[0].set?.priority?.value, 2);
  assertEquals(result.droppedCount, 0);
});

Deno.test("validateParseEnvelope: defensive bare-array input is treated as {tasks: v, taskRefs: [], updates: []}", () => {
  const result = expectOk([rawTask("Task 1"), rawTask("Task 2")]);
  assertEquals(result.tasks.length, 2);
  assertEquals(result.taskRefs, []);
  assertEquals(result.updates, []);
});

Deno.test("validateParseEnvelope: empty tasks + one valid update is VALID, not 502", () => {
  // "task kia phải xong hôm nay" — no new task, only an update to an existing referenced task.
  const result = expectOk(
    envelope({
      tasks: [],
      taskRefs: [rawTaskRef("Task kia")],
      updates: [{ refIndex: 1, set: { deadline: { value: "2026-08-02T18:00:00", confidence: 0.9 } } }],
    }),
  );
  assertEquals(result.tasks.length, 0);
  assertEquals(result.updates.length, 1);
});

Deno.test("validateParseEnvelope: tasks not an array -> undefined (502)", () => {
  const result = validateParseEnvelope(envelope({ tasks: "not an array" as unknown as unknown[] }));
  assertEquals(result, undefined);
});

Deno.test("validateParseEnvelope: tasks field entirely missing (garbage top-level value) -> undefined (502)", () => {
  const result = validateParseEnvelope("just a string");
  assertEquals(result, undefined);
});

Deno.test("validateParseEnvelope: all tasks invalid (missing title) -> undefined (502)", () => {
  const result = validateParseEnvelope(
    envelope({
      tasks: [{ notes: { value: "x", confidence: 0.5 } }, { notes: { value: "y", confidence: 0.5 } }],
    }),
  );
  assertEquals(result, undefined);
});

// ---------------------------------------------------------------------------------------------
// 2. taskRefs
// ---------------------------------------------------------------------------------------------

Deno.test("taskRefs: element without titleQuery is dropped", () => {
  const result = expectOk(
    envelope({
      taskRefs: [rawTaskRef("Good ref"), { assumeExisting: true /* no titleQuery at all */ }],
    }),
  );
  assertEquals(result.taskRefs.length, 1);
  assertEquals(result.taskRefs[0].titleQuery.value, "Good ref");
  assertEquals(result.droppedCount, 1);
});

Deno.test("taskRefs: assumeExisting wrong type -> field omitted, ref itself kept", () => {
  const raw = rawTaskRef("Task kia");
  raw.assumeExisting = "yes"; // wrong type
  const result = expectOk(envelope({ taskRefs: [raw] }));
  assertEquals(result.taskRefs.length, 1);
  assertEquals(result.taskRefs[0].assumeExisting, undefined);
});

Deno.test("taskRefs: titleQuery over MAX_TASK_TITLE_CHARS is dropped", () => {
  const raw = { titleQuery: { value: "x".repeat(MAX_TASK_TITLE_CHARS + 1), confidence: 0.9 } };
  const result = expectOk(envelope({ taskRefs: [raw, rawTaskRef("Good ref")] }));
  assertEquals(result.taskRefs.length, 1);
  assertEquals(result.taskRefs[0].titleQuery.value, "Good ref");
});

Deno.test("taskRefs: over MAX_TASK_REFS is truncated, droppedCount reflects the excess", () => {
  const extra = 4;
  const refs = Array.from({ length: MAX_TASK_REFS + extra }, (_, i) => rawTaskRef(`Ref ${i + 1}`));
  const result = expectOk(envelope({ taskRefs: refs }));
  assertEquals(result.taskRefs.length, MAX_TASK_REFS);
  assertEquals(result.droppedCount, extra);
});

// ---------------------------------------------------------------------------------------------
// 3. updates
// ---------------------------------------------------------------------------------------------

function twoRefs(): unknown[] {
  return [rawTaskRef("Ref A"), rawTaskRef("Ref B")];
}

Deno.test("updates: refIndex 0 is dropped", () => {
  const result = expectOk(
    envelope({ taskRefs: twoRefs(), updates: [{ refIndex: 0, set: { priority: { value: 1, confidence: 0.9 } } }] }),
  );
  assertEquals(result.updates.length, 0);
});

Deno.test("updates: refIndex beyond refs.length is dropped", () => {
  const result = expectOk(
    envelope({
      taskRefs: twoRefs(), // length 2
      updates: [{ refIndex: 3, set: { priority: { value: 1, confidence: 0.9 } } }],
    }),
  );
  assertEquals(result.updates.length, 0);
});

Deno.test("updates: non-integer refIndex (2.5) is dropped", () => {
  const result = expectOk(
    envelope({
      taskRefs: twoRefs(),
      updates: [{ refIndex: 2.5, set: { priority: { value: 1, confidence: 0.9 } } }],
    }),
  );
  assertEquals(result.updates.length, 0);
});

Deno.test("updates: refIndex pointing at a ref that was itself dropped is out of range and dropped", () => {
  // 3 raw refs, the MIDDLE one invalid -> validated taskRefs collapses to 2. An update claiming
  // refIndex 3 (which would have been valid against the raw 3-entry list) must be rejected against
  // the VALIDATED count, not the model's raw numbering.
  const rawRefs = [rawTaskRef("Ref A"), { assumeExisting: true /* invalid: no titleQuery */ }, rawTaskRef("Ref C")];
  const result = expectOk(
    envelope({
      taskRefs: rawRefs,
      updates: [{ refIndex: 3, set: { priority: { value: 1, confidence: 0.9 } } }],
    }),
  );
  assertEquals(result.taskRefs.length, 2); // ref B dropped
  assertEquals(result.updates.length, 0); // refIndex 3 no longer valid against the validated count of 2
});

Deno.test("updates: empty set + empty addConditions -> element dropped (no information)", () => {
  const result = expectOk(envelope({ taskRefs: twoRefs(), updates: [{ refIndex: 1 }] }));
  assertEquals(result.updates.length, 0);
});

Deno.test("updates: set.priority out of range (7) is dropped, set.deadline is kept, update survives", () => {
  const result = expectOk(
    envelope({
      taskRefs: twoRefs(),
      updates: [
        {
          refIndex: 1,
          set: {
            priority: { value: 7, confidence: 0.9 },
            deadline: { value: "2026-08-02T18:00:00", confidence: 0.9 },
          },
        },
      ],
    }),
  );
  assertEquals(result.updates.length, 1);
  assertEquals(result.updates[0].set?.priority, undefined);
  assertEquals(result.updates[0].set?.deadline?.value, "2026-08-02T18:00:00");
});

Deno.test("updates: set.notesAppend over MAX_NOTES_CHARS is dropped, other set fields survive", () => {
  const result = expectOk(
    envelope({
      taskRefs: twoRefs(),
      updates: [
        {
          refIndex: 1,
          set: {
            notesAppend: { value: "x".repeat(MAX_NOTES_CHARS + 1), confidence: 0.9 },
            priority: { value: 2, confidence: 0.9 },
          },
        },
      ],
    }),
  );
  assertEquals(result.updates.length, 1);
  assertEquals(result.updates[0].set?.notesAppend, undefined);
  assertEquals(result.updates[0].set?.priority?.value, 2);
});

Deno.test("updates: set.startTime malformed is dropped independently of other fields", () => {
  const result = expectOk(
    envelope({
      taskRefs: twoRefs(),
      updates: [
        {
          refIndex: 1,
          set: {
            startTime: { value: "not-a-date", confidence: 0.9 },
            priority: { value: 3, confidence: 0.9 },
          },
        },
      ],
    }),
  );
  assertEquals(result.updates.length, 1);
  assertEquals(result.updates[0].set?.startTime, undefined);
  assertEquals(result.updates[0].set?.priority?.value, 3);
});

Deno.test("updates: addConditions newTaskIndex out of bounds vs validated tasks is dropped", () => {
  const result = expectOk(
    envelope({
      tasks: [rawTask("Only task")], // validated tasks.length === 1
      taskRefs: twoRefs(),
      updates: [
        {
          refIndex: 1,
          // set carries something usable so the update itself survives even though
          // addConditions ends up empty -- isolates the addConditions-element-drop behavior.
          set: { priority: { value: 2, confidence: 0.9 } },
          addConditions: [{ kind: "taskDone", newTaskIndex: 5 }], // only 1 validated task exists
        },
      ],
    }),
  );
  assertEquals(result.updates.length, 1);
  assertEquals(result.updates[0].addConditions, undefined);
  assertEquals(result.updates[0].set?.priority?.value, 2);
});

Deno.test("updates: addConditions with a valid taskDone newTaskIndex is kept", () => {
  const result = expectOk(
    envelope({
      tasks: [rawTask("New task 1"), rawTask("New task 2")],
      taskRefs: twoRefs(),
      updates: [
        {
          refIndex: 1,
          addConditions: [{ kind: "taskDone", newTaskIndex: 2 }],
        },
      ],
    }),
  );
  assertEquals(result.updates.length, 1);
  assertEquals(result.updates[0].addConditions, [{ kind: "taskDone", newTaskIndex: 2 }]);
});

Deno.test("updates: addConditions afterDate is kept", () => {
  const result = expectOk(
    envelope({
      taskRefs: twoRefs(),
      updates: [
        {
          refIndex: 1,
          addConditions: [{ kind: "afterDate", date: "2026-08-10T00:00:00" }],
        },
      ],
    }),
  );
  assertEquals(result.updates.length, 1);
  assertEquals(result.updates[0].addConditions, [{ kind: "afterDate", date: "2026-08-10T00:00:00" }]);
});

Deno.test("updates: over MAX_UPDATES is truncated with correct droppedCount", () => {
  const extra = 3;
  const refs = twoRefs();
  const updates = Array.from({ length: MAX_UPDATES + extra }, () => ({
    refIndex: 1,
    set: { priority: { value: 2, confidence: 0.9 } },
  }));
  const result = expectOk(envelope({ taskRefs: refs, updates }));
  assertEquals(result.updates.length, MAX_UPDATES);
  assertEquals(result.droppedCount, extra);
});

// ---------------------------------------------------------------------------------------------
// 4. Conditions: taskDone extension fields + new taskStart kind (envelope mode only)
// ---------------------------------------------------------------------------------------------

Deno.test("conditions (envelope): taskDone with refIndex/offsetMinutes/offsetKind valid, all kept", () => {
  const result = expectOk(
    envelope({
      tasks: [
        {
          title: { value: "Task", confidence: 0.9 },
          conditions: [
            {
              value: {
                kind: "taskDone",
                referenceTitle: "Task kia",
                refIndex: 1,
                offsetMinutes: 120,
                offsetKind: "atLeast",
              },
              confidence: 0.8,
            },
          ],
        },
      ],
      taskRefs: twoRefs(),
    }),
  );
  const cond = result.tasks[0].conditions![0].value;
  assertEquals(cond.kind, "taskDone");
  assertEquals(cond.refIndex, 1);
  assertEquals(cond.offsetMinutes, 120);
  assertEquals(cond.offsetKind, "atLeast");
});

Deno.test("conditions (envelope): taskDone offsetMinutes 0 is dropped, condition survives", () => {
  const result = expectOk(
    envelope({
      tasks: [
        {
          title: { value: "Task", confidence: 0.9 },
          conditions: [
            { value: { kind: "taskDone", referenceTitle: "Task kia", offsetMinutes: 0 }, confidence: 0.8 },
          ],
        },
      ],
      taskRefs: twoRefs(),
    }),
  );
  const cond = result.tasks[0].conditions![0].value;
  assertEquals(cond.kind, "taskDone");
  assertEquals(cond.offsetMinutes, undefined);
});

Deno.test("conditions (envelope): taskDone offsetMinutes negative is dropped (taskDone offsets are always positive)", () => {
  const result = expectOk(
    envelope({
      tasks: [
        {
          title: { value: "Task", confidence: 0.9 },
          conditions: [
            { value: { kind: "taskDone", referenceTitle: "Task kia", offsetMinutes: -30 }, confidence: 0.8 },
          ],
        },
      ],
      taskRefs: twoRefs(),
    }),
  );
  const cond = result.tasks[0].conditions![0].value;
  assertEquals(cond.offsetMinutes, undefined);
});

Deno.test("conditions (envelope): taskDone offsetMinutes over the cap is dropped, condition survives", () => {
  const result = expectOk(
    envelope({
      tasks: [
        {
          title: { value: "Task", confidence: 0.9 },
          conditions: [
            {
              value: {
                kind: "taskDone",
                referenceTitle: "Task kia",
                offsetMinutes: MAX_CONDITION_OFFSET_MINUTES + 1,
              },
              confidence: 0.8,
            },
          ],
        },
      ],
      taskRefs: twoRefs(),
    }),
  );
  const cond = result.tasks[0].conditions![0].value;
  assertEquals(cond.kind, "taskDone");
  assertEquals(cond.offsetMinutes, undefined);
});

Deno.test("conditions (envelope): taskStart valid, kept with all fields", () => {
  const result = expectOk(
    envelope({
      tasks: [
        {
          title: { value: "Task", confidence: 0.9 },
          conditions: [
            {
              value: { kind: "taskStart", referenceTitle: "Task kia", refIndex: 2, offsetMinutes: -120, offsetKind: "atLeast" },
              confidence: 0.8,
            },
          ],
        },
      ],
      taskRefs: twoRefs(),
    }),
  );
  const cond = result.tasks[0].conditions![0].value;
  assertEquals(cond.kind, "taskStart");
  assertEquals(cond.referenceTitle, "Task kia");
  assertEquals(cond.refIndex, 2);
  assertEquals(cond.offsetMinutes, -120);
  assertEquals(cond.offsetKind, "atLeast");
});

Deno.test("conditions (envelope): taskStart without referenceTitle is dropped entirely (fail-closed)", () => {
  const result = expectOk(
    envelope({
      tasks: [
        {
          title: { value: "Task", confidence: 0.9 },
          conditions: [{ value: { kind: "taskStart", offsetMinutes: -60 }, confidence: 0.8 }],
        },
      ],
      taskRefs: twoRefs(),
    }),
  );
  assertEquals(result.tasks[0].conditions!.length, 0);
});

Deno.test("conditions (envelope): taskStart offsetMinutes -120 is kept (negative allowed)", () => {
  const result = expectOk(
    envelope({
      tasks: [
        {
          title: { value: "Task", confidence: 0.9 },
          conditions: [
            { value: { kind: "taskStart", referenceTitle: "Task kia", offsetMinutes: -120 }, confidence: 0.8 },
          ],
        },
      ],
      taskRefs: twoRefs(),
    }),
  );
  assertEquals(result.tasks[0].conditions![0].value.offsetMinutes, -120);
});

Deno.test("conditions (envelope): taskStart offsetMinutes 0 is dropped (zero is never meaningful)", () => {
  const result = expectOk(
    envelope({
      tasks: [
        {
          title: { value: "Task", confidence: 0.9 },
          conditions: [
            { value: { kind: "taskStart", referenceTitle: "Task kia", offsetMinutes: 0 }, confidence: 0.8 },
          ],
        },
      ],
      taskRefs: twoRefs(),
    }),
  );
  assertEquals(result.tasks[0].conditions![0].value.offsetMinutes, undefined);
});

// ---------------------------------------------------------------------------------------------
// 5. Back-compat: bare-array mode via validateParsedTaskArray (no ctx at all)
// ---------------------------------------------------------------------------------------------

Deno.test("bare-array mode: a 'taskStart' condition is dropped entirely (unchanged/unrecognized kind)", () => {
  const result = validateParsedTaskArray([
    {
      title: { value: "Task", confidence: 0.9 },
      conditions: [
        { value: { kind: "taskStart", referenceTitle: "Task kia", offsetMinutes: -60 }, confidence: 0.8 },
      ],
    },
  ]);
  assertExists(result);
  assertEquals(result!.tasks[0].conditions!.length, 0);
});

Deno.test("bare-array mode: taskDone's new extension fields are never emitted, even if the model sent them", () => {
  const result = validateParsedTaskArray([
    {
      title: { value: "Task", confidence: 0.9 },
      conditions: [
        {
          value: {
            kind: "taskDone",
            referenceTitle: "Task kia",
            refIndex: 1,
            offsetMinutes: 120,
            offsetKind: "exact",
          },
          confidence: 0.8,
        },
      ],
    },
  ]);
  assertExists(result);
  const cond = result!.tasks[0].conditions![0].value;
  assertEquals(cond.kind, "taskDone");
  assertEquals(cond.referenceTitle, "Task kia");
  assertEquals(cond.refIndex, undefined);
  assertEquals(cond.offsetMinutes, undefined);
  assertEquals(cond.offsetKind, undefined);
});

Deno.test("bare-array mode: pre-existing conditions/tasks fixtures still validate identically (regression)", () => {
  const result = validateParsedTaskArray([
    {
      title: { value: "Task", confidence: 0.9 },
      conditions: [
        { value: { kind: "taskDone", referenceTitle: "Earlier task" }, confidence: 0.8 },
        { value: { kind: "afterDate", date: "2026-08-05T00:00:00" }, confidence: 0.7 },
        { value: { kind: "external", description: "chờ sếp duyệt" }, confidence: 0.6 },
      ],
    },
  ]);
  assertExists(result);
  assertEquals(result!.tasks[0].conditions!.length, 3);
});

// ---------------------------------------------------------------------------------------------
// 6. reminderOverride.anchor (envelope mode only)
// ---------------------------------------------------------------------------------------------

Deno.test("reminderOverride.anchor (envelope): valid anchor kept alongside offsets", () => {
  const result = expectOk(
    envelope({
      tasks: [
        {
          title: { value: "Task", confidence: 0.9 },
          reminderOverride: {
            value: { offsetsMinutes: [15], anchor: { refIndex: 1, event: "done" } },
            confidence: 0.7,
          },
        },
      ],
      taskRefs: twoRefs(),
    }),
  );
  const ro = result.tasks[0].reminderOverride!.value;
  assertEquals(ro.offsetsMinutes, [15]);
  assertEquals(ro.anchor, { refIndex: 1, event: "done" });
});

Deno.test("reminderOverride.anchor (envelope): bad refIndex -> anchor dropped, offsets kept", () => {
  const result = expectOk(
    envelope({
      tasks: [
        {
          title: { value: "Task", confidence: 0.9 },
          reminderOverride: {
            value: { offsetsMinutes: [15, 30], anchor: { refIndex: 99, event: "start" } },
            confidence: 0.7,
          },
        },
      ],
      taskRefs: twoRefs(), // only refIndex 1..2 valid
    }),
  );
  const ro = result.tasks[0].reminderOverride!.value;
  assertEquals(ro.offsetsMinutes, [15, 30]);
  assertEquals(ro.anchor, undefined);
});

Deno.test("reminderOverride.anchor (envelope): bad event value -> anchor dropped, offsets kept", () => {
  const result = expectOk(
    envelope({
      tasks: [
        {
          title: { value: "Task", confidence: 0.9 },
          reminderOverride: {
            value: { offsetsMinutes: [15], anchor: { refIndex: 1, event: "sometime" } },
            confidence: 0.7,
          },
        },
      ],
      taskRefs: twoRefs(),
    }),
  );
  const ro = result.tasks[0].reminderOverride!.value;
  assertEquals(ro.anchor, undefined);
  assertEquals(ro.offsetsMinutes, [15]);
});

Deno.test("bare-array mode: reminderOverride.anchor is never emitted, even if the model sent it", () => {
  const result = validateParsedTaskArray([
    {
      title: { value: "Task", confidence: 0.9 },
      reminderOverride: {
        value: { offsetsMinutes: [15], anchor: { refIndex: 1, event: "done" } },
        confidence: 0.7,
      },
    },
  ]);
  assertExists(result);
  assertEquals(result!.tasks[0].reminderOverride!.value.anchor, undefined);
  assertEquals(result!.tasks[0].reminderOverride!.value.offsetsMinutes, [15]);
});

// ---------------------------------------------------------------------------------------------
// `indexTerms` (anh Khôi, 2026-08-21). Everything below is about the NORMALIZE-then-TRUNCATE
// contract in `validateParsedTask`: this list feeds a lookup index where "Solr" and "solr" have to
// be the same key, so the server normalizes rather than trusting the model, and — like every other
// model-output cap in schema.ts — an over-eager list is TRUNCATED, never a reason to drop the task.
// ---------------------------------------------------------------------------------------------

function taskWithIndexTerms(indexTerms: unknown) {
  return [{ title: { value: "Fix Solr query", confidence: 0.9 }, indexTerms }];
}

Deno.test("indexTerms: well-formed list survives, lowercased and trimmed", () => {
  const result = validateParsedTaskArray(taskWithIndexTerms(["  Solr ", "DEM Search", "tokenize"]));
  assertExists(result);
  assertEquals(result!.tasks[0].indexTerms, ["solr", "dem search", "tokenize"]);
});

Deno.test("indexTerms: duplicates that differ only by case/whitespace collapse to one key", () => {
  const result = validateParsedTaskArray(taskWithIndexTerms(["Solr", "solr", " SOLR "]));
  assertExists(result);
  assertEquals(result!.tasks[0].indexTerms, ["solr"]);
});

Deno.test("indexTerms: over-cap list is TRUNCATED to MAX_INDEX_TERMS, task survives", () => {
  const many = Array.from({ length: MAX_INDEX_TERMS + 5 }, (_, i) => `term${i}`);
  const result = validateParsedTaskArray(taskWithIndexTerms(many));
  assertExists(result);
  assertEquals(result!.tasks[0].indexTerms!.length, MAX_INDEX_TERMS);
  assertEquals(result!.tasks[0].title.value, "Fix Solr query");
});

Deno.test("indexTerms: per-element fail-open — one bad term never costs the good ones", () => {
  const result = validateParsedTaskArray(taskWithIndexTerms([
    "solr",
    42,
    null,
    { nope: true },
    "",
    "   ",
    "x".repeat(MAX_INDEX_TERM_CHARS + 1),
    "tokenize",
  ]));
  assertExists(result);
  assertEquals(result!.tasks[0].indexTerms, ["solr", "tokenize"]);
});

Deno.test("indexTerms: a term of exactly MAX_INDEX_TERM_CHARS is kept", () => {
  const result = validateParsedTaskArray(taskWithIndexTerms(["y".repeat(MAX_INDEX_TERM_CHARS)]));
  assertExists(result);
  assertEquals(result!.tasks[0].indexTerms, ["y".repeat(MAX_INDEX_TERM_CHARS)]);
});

Deno.test("indexTerms: absent, empty, or all-garbage lists leave the field off entirely", () => {
  // Absent and empty must be the SAME state downstream — the local tokenizer supplies terms either
  // way, so `[]` on the wire carries no information worth a key on the task.
  for (const input of [undefined, [], ["", "  ", 7], "not an array", null]) {
    const result = validateParsedTaskArray(taskWithIndexTerms(input));
    assertExists(result);
    assertEquals(result!.tasks[0].indexTerms, undefined);
    assertEquals(result!.tasks[0].title.value, "Fix Solr query");
  }
});
