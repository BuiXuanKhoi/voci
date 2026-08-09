// supabase/scripts/probe-cues.ts
//
// 🔴 AGENT: KHÔNG TỰ CHẠY FILE NÀY (anh Khôi chốt 2026-08-09 — xem CLAUDE.md ở gốc repo).
// Mỗi case ≈ 47đ vì prompt cố định chiếm 98,8% input token; file này còn có COMBO_CASES nên
// một lượt chạy đắt hơn các probe khác. Sửa prompt xong thì DỪNG và hỏi anh Khôi. `--dry-run` OK.
//
// Live probe for the `task_cues_v1` capability — modeled directly on `probe-time-parsing.ts` /
// `probe-task-refs.ts` (same env handling, same "known-answer" philosophy, same output style) but
// exercising the CUE half of `parse` mode: calls Gemini with the EXACT prompt/schema a request
// declaring ONLY `client_caps: ["task_cues_v1"]` would get — `SYSTEM_PREAMBLE_TASK_CUES`,
// `buildParseResponseSchemaWithCues()`, the SAME `buildParseContents` every mode already uses, and
// the SAME `callGemini` — for a table of utterances whose correct `cue` (or absence of one) is
// known, and diffs what comes back (after running it through the SAME server-side validator the
// real route would use, `validateParsedTaskArrayWithCues`) against that expectation.
//
// WHY THIS EXISTS (Opus design 2026-08-08, `specs/006-cues-and-waiting/design.md` §2 Việc B): the
// core case anh Khôi named directly — "ngủ dậy thì test feature này" ("when I wake up, test this
// feature") — has exactly two paths TODAY, and both are wrong: forced into `afterDate` with a
// fabricated clock hour, or `external` (which makes the user manually clear it themselves). This
// capability's entire value is in the model correctly (a) recognizing an EVENT anchor instead of a
// clock time, (b) copying the user's own words verbatim, and (c) NEVER letting that anchor leak
// into `deadline`/`startTime` — none of which `deno check` or a schema-shape check can verify; only
// a live model call can, the same reason every other `probe-*.ts` in this directory exists.
//
// NOT deployed: `supabase functions deploy` only ships `functions/`, never `scripts/`.
// NOT run in CI: costs real tokens (~8 tiny calls) and calls a live third-party API.
//
// RUN (needs a Gemini API key — the same one set as the `GEMINI_API_KEY` secret on the Supabase
// project; anh Khôi already has one in `supabase/.env`, gitignored):
//
//   deno run --env-file=supabase/.env --allow-net --allow-env supabase/scripts/probe-cues.ts
//
// Dry run (no key, no network — prints the fully-built prompt for case 1):
//
//   deno run --allow-env supabase/scripts/probe-cues.ts --dry-run
//
// Override the model with PARSE_MODEL, same env var the real function reads.
//
// ⚠️ CONTAMINATION GUARD (the 2026-08-07 lesson, see gemini.ts's `SYSTEM_PREAMBLE_FEWSHOT_EXAMPLES`
// doc comment): `TASK_CUES_SECTION` (gemini.ts) illustrates the "wake"/"dayEnd"/"office" CATEGORY
// with short phrase fragments ("ngủ dậy thì...", "tới văn phòng thì...", "sau khi ăn trưa thì...")
// — it never pairs a FULL transcript with a FULL worked JSON answer the way
// `SYSTEM_PREAMBLE_FEWSHOT_EXAMPLES` does for `parse`'s splitting/dependency rules. `tasks.md` T1.3
// itself mandates the two case transcripts below that share that category vocabulary ("ngủ dậy
// thì...", "tới văn phòng thì...") — that overlap is expected and intentional: the rule's own
// vocabulary is what the probe is proving the model can GENERALIZE past a single worked example,
// not something being echoed back. What this file does NOT do is invent a NEW full transcript that
// happens to be copy-pasted into the prompt text itself — none of the case transcripts below appear
// verbatim in `TASK_CUES_SECTION`.
//
// COMBO SECTION (Opus review of T1, 2026-08-08): the bare-array cases above exercise `task_cues_v1`
// ALONE, but that request shape never actually happens in production — `CloudParser.swift` always
// sends `client_caps: ["task_refs_v1", "task_cues_v1"]` together, so the model always sees
// `SYSTEM_PREAMBLE_TASK_REFS_CUES` (both rule sections) and must return the ENVELOPE shape with
// `cue` on top. `COMBO_CASES`/the second loop below exercise exactly that combined path — no static
// test can substitute for this, because the failure mode being checked is a model that follows ONE
// section's rules while regressing the other (e.g. correctly extracting `cue` but forgetting
// `taskRefs`, or vice versa) now that BOTH sections are in the same prompt.

import {
  DEFAULT_PARSE_MODEL,
  SYSTEM_PREAMBLE_TASK_CUES,
  SYSTEM_PREAMBLE_TASK_REFS_CUES,
  buildParseContents,
  buildParseEnvelopeResponseSchemaWithCues,
  buildParseResponseSchemaWithCues,
  callGemini,
} from "../functions/_shared/gemini.ts";
import { validateParseEnvelope, validateParsedTaskArrayWithCues } from "../functions/_shared/schema.ts";

// Same anchor date `probe-time-parsing.ts`/`probe-task-refs.ts` use (2026-07-28 is a Tuesday) —
// kept in sync deliberately so a probe run comparing multiple scripts isn't also debugging two
// different "now"s.
const NOW_VN = "2026-07-28T15:00:00+07:00";
const TZ_VN = "Asia/Ho_Chi_Minh";

interface Case {
  transcript: string;
  now: string;
  timezone: string;
  /** Substring (case-insensitive) that must appear somewhere in the matched task's title — used
   *  to find the right task in a multi-task response without depending on exact wording, since the
   *  model is free to phrase the title itself however it likes. */
  titleContains: string;
  expectCueKind?: "wake" | "dayEnd" | "unknown";
  /** Substring (case-insensitive) `cue.verbatim` must contain — never an exact match, since the
   *  model may include/omit a trailing "thì"/comma and that is not the thing being tested here. */
  expectCueVerbatimContains?: string;
  /** Regression cases only: this task must carry NO `cue` field at all. */
  expectNoCue?: boolean;
  /** Regression cases only: this task must carry NO `deadline` at all — proves the cue anchor was
   *  not smuggled into deadline via a fabricated clock hour. */
  expectDeadlineAbsent?: boolean;
  /** Regression case only: this task MUST carry a `deadline` — proves a genuine clock-time
   *  utterance still parses normally and does NOT get miscategorized as a cue instead. */
  expectDeadlinePresent?: boolean;
  expectedTaskCount?: number;
  /** Compound-utterance case only: a SECOND task (found the same way as the primary one, via a
   *  title substring) that must carry NO `cue` at all — proves the cue attached to the clause it
   *  actually modifies and did not spread to a sibling task from the same utterance
   *  (design.md §2 Việc B: "cue gắn đúng mệnh đề nó bổ nghĩa ... Không phân phối sang B"). */
  expectNoCueOnSecondTaskContaining?: string;
  why: string;
}

const CASES: Case[] = [
  // --- The core case anh Khôi named directly (design.md §2 Việc B). Mandated by tasks.md T1.3. ---
  {
    transcript: "ngủ dậy thì test feature này",
    now: NOW_VN,
    timezone: TZ_VN,
    titleContains: "test",
    expectCueKind: "wake",
    expectCueVerbatimContains: "ngủ dậy",
    expectDeadlineAbsent: true,
    why: "THE case that motivated this whole capability -- must classify as wake, keep the user's "
      + "own words, and critically must NOT fabricate a deadline out of \"ngủ dậy\"",
  },
  {
    transcript: "tối trước khi ngủ thì đọc sách chương tiếp theo",
    now: NOW_VN,
    timezone: TZ_VN,
    titleContains: "sách",
    expectCueKind: "dayEnd",
    expectCueVerbatimContains: "ngủ",
    expectDeadlineAbsent: true,
    why: "end-of-day anchor -> dayEnd, no fabricated deadline either",
  },
  {
    transcript: "tới văn phòng thì hỏi Nam về hợp đồng",
    now: NOW_VN,
    timezone: TZ_VN,
    titleContains: "nam",
    expectCueKind: "unknown",
    expectCueVerbatimContains: "văn phòng",
    expectDeadlineAbsent: true,
    why: "machine-unresolvable anchor (arriving somewhere) -> unknown, but verbatim must still be "
      + "kept -- the value is in the words, not the classification",
  },

  // --- MOST IMPORTANT regression: a genuine clock time must NOT become a cue. ---------------------
  {
    transcript: "3 giờ chiều họp với khách hàng",
    now: NOW_VN,
    timezone: TZ_VN,
    titleContains: "họp",
    expectNoCue: true,
    expectDeadlinePresent: true,
    why: "a stated CLOCK TIME (3 giờ chiều) is an ordinary deadline, exactly as before this "
      + "capability existed -- must never also grow a cue field for the same clause",
  },

  // --- Compound utterance: cue attaches to the clause it modifies, never distributes. -------------
  {
    transcript: "ngủ dậy thì kiểm tra email công ty rồi đi tập gym luôn",
    now: NOW_VN,
    timezone: TZ_VN,
    titleContains: "email",
    expectCueKind: "wake",
    expectCueVerbatimContains: "ngủ dậy",
    expectNoCueOnSecondTaskContaining: "gym",
    why: "compound utterance, task A (email) is anchored to waking up; task B (gym) must NOT also "
      + "inherit that cue -- design.md §2 Việc B's explicit \"không phân phối sang B\" rule",
  },

  // --- Plain utterance with no anchor at all -- no cue invented. ----------------------------------
  {
    transcript: "mua sữa và bánh mì",
    now: NOW_VN,
    timezone: TZ_VN,
    titleContains: "sữa",
    expectNoCue: true,
    why: "no event anchor, no clock time -- nothing to attach a cue to, must stay absent",
  },

  // --- English case: the capability must not be VN-only. ------------------------------------------
  {
    transcript: "when I get to the office, print the signed contract",
    now: NOW_VN,
    timezone: TZ_VN,
    titleContains: "contract",
    expectCueKind: "unknown",
    expectCueVerbatimContains: "office",
    expectDeadlineAbsent: true,
    why: "English event anchor (arriving at the office) -- same unknown classification, verbatim kept",
  },
];

function findTask(
  tasks: { title: { value: string } }[],
  titleContains: string,
): { title: { value: string } } | undefined {
  const needle = titleContains.toLowerCase();
  return tasks.find((t) => t.title.value.toLowerCase().includes(needle));
}

// -------------------------------------------------------------------------------------------------
// COMBO CASES: task_refs_v1 + task_cues_v1 together — the ONLY request shape a real client ever
// sends. Each case names a NEW task that is BOTH (a) anchored to an event cue and (b) dependent on
// an EXISTING task named in `openTaskTitles` ("làm task này khi xong task kia", the same dependency
// rule `TASK_REFS_SECTION` already teaches for task_refs_v1 alone) — proving the two capabilities'
// rules survive being read from the SAME prompt at once, which no single-capability probe/test can
// demonstrate.
// -------------------------------------------------------------------------------------------------
interface ComboCase {
  transcript: string;
  now: string;
  timezone: string;
  openTaskTitles: string[];
  /** Finds the NEW task this case is actually about (the one carrying both the cue and the
   *  dependency), among possibly several tasks in the response. */
  titleContains: string;
  expectCueKind: "wake" | "dayEnd" | "unknown";
  expectCueVerbatimContains: string;
  /** The `openTaskTitles` entry the model must copy EXACTLY into `taskRefs[].titleQuery.value` —
   *  same word-for-word requirement `TASK_REFS_SECTION` already states, because the client links a
   *  reference by Jaccard token overlap at a 0.7 bar (see `probe-task-refs.ts`'s own
   *  `wouldClientLink` for the same check performed there). */
  expectedTaskRefTitle: string;
  why: string;
}

const COMBO_CASES: ComboCase[] = [
  {
    // CONTAMINATION FOUND AND FIXED (2026-08-09, T1 combo hardening — re-measured against the real
    // production preamble/schema): this case used to name its client "Sugashack" and both the new
    // and referenced tasks "landing page cho Sugashack" -- copied from `probe-task-refs.ts`
    // [01]/[13]'s CONNECTIVE ("sau khi xong cái vụ X"), but not from their proper nouns. The
    // problem: "Sugashack" + "landing page" appear VERBATIM inside `SYSTEM_PREAMBLE_CORE`'s own
    // worked splitting-rule example ("làm xong landing page và gửi cho khách Sugashack" is TWO
    // tasks -- gemini.ts, sent on EVERY single call regardless of mode) -- exactly the "nhiễm đề"
    // trap this file's own module doc comment warns about, just missed because the collision was
    // with `SYSTEM_PREAMBLE_CORE` rather than with another probe file's case list. Measured effect
    // of swapping ONLY the proper noun/topic -- identical sentence structure, identical cue clause,
    // identical heavy new-task/referenced-task word overlap kept on purpose (that overlap is the
    // real thing this case is testing) -- took this case from 0-1/8 pass to 6/8: most of what
    // looked like "the model can't juggle a cue plus a self-overlapping dependency" was actually
    // "the model already saw this exact client name used in a different worked example a few
    // paragraphs earlier in the same prompt." The PRIOR version of this comment (concluding two
    // earlier phrasings' failures were "a real, narrow model limitation... unrelated to cues") was
    // WRONG -- isolating this case with cues removed entirely (SYSTEM_PREAMBLE_TASK_REFS alone, no
    // TASK_CUES_SECTION) passed 10/10 on the ORIGINAL Sugashack wording, proving the miss WAS
    // cue-related after all. The real, cue-specific bug this combo work found and fixed lives in
    // `gemini.ts`'s `TASK_CUES_SECTION` doc comment (2026-08-09 update): the model was treating cue
    // and a conditions/taskDone dependency as mutually exclusive on the same task. The residual gap
    // here (6/8, vs. combo #2 below's clean pass rate) is that case's own OWN self-overlapping
    // vocabulary genuinely making the dependency harder to resolve on top of the cue -- a smaller,
    // real difficulty, not the same bug, and not one further prompt tuning fixed without
    // destabilizing combo #2 (see gemini.ts's doc comment's "KNOWN UNFIXED LIMITATION" paragraph).
    transcript: "ngủ dậy thì gửi bản hợp đồng thuê nhà cho khách hàng Fumiko, sau khi xong cái vụ " +
      "soạn hợp đồng thuê nhà cho Fumiko",
    now: NOW_VN,
    timezone: TZ_VN,
    openTaskTitles: ["Soạn hợp đồng thuê nhà cho Fumiko"],
    titleContains: "gửi",
    expectCueKind: "wake",
    expectCueVerbatimContains: "ngủ dậy",
    expectedTaskRefTitle: "Soạn hợp đồng thuê nhà cho Fumiko",
    why: "combo #1: a NEW task anchored to waking up (wake) AND depending on an EXISTING " +
      "referenced task, where the new task's own title and the referenced task's title share heavy " +
      "vocabulary (\"hợp đồng thuê nhà cho Fumiko\") on both sides — the harder of the two combo " +
      "cases; the model must extract BOTH the cue and the dependency in the same response",
  },
  {
    transcript: "trước khi đi ngủ thì gửi báo cáo tiến độ cho khách hàng Momo, sau khi task tổng " +
      "hợp số liệu cho khách hàng Momo xong",
    now: NOW_VN,
    timezone: TZ_VN,
    openTaskTitles: ["Tổng hợp số liệu cho khách hàng Momo"],
    titleContains: "báo cáo",
    expectCueKind: "dayEnd",
    expectCueVerbatimContains: "đi ngủ",
    expectedTaskRefTitle: "Tổng hợp số liệu cho khách hàng Momo",
    why: "combo #2: different cue kind (dayEnd) + a different dependency, same combined-survival " +
      "check, different transcript so combo #1 passing alone doesn't just mean it got lucky once",
  },
];

async function main() {
  const dryRun = Deno.args.includes("--dry-run");
  const apiKey = Deno.env.get("GEMINI_API_KEY") ?? "";
  const model = Deno.env.get("PARSE_MODEL") || DEFAULT_PARSE_MODEL;

  if (dryRun) {
    const c = CASES[0];
    console.log("=== SYSTEM INSTRUCTION ===\n");
    console.log(SYSTEM_PREAMBLE_TASK_CUES);
    console.log("\n\n=== CONTENTS (case 1) ===\n");
    console.log(buildParseContents({
      transcript: c.transcript,
      now: c.now,
      timezone: c.timezone,
      openTaskTitles: [],
    }));
    console.log(
      `\n\n(${CASES.length} bare cases + ${COMBO_CASES.length} combo cases defined; ` +
        "re-run with GEMINI_API_KEY set to probe live.)",
    );
    return;
  }

  if (!apiKey) {
    console.error(
      "GEMINI_API_KEY is not set.\n" +
        "  Live:    deno run --env-file=supabase/.env --allow-net --allow-env " +
        "supabase/scripts/probe-cues.ts\n" +
        "  Dry run: deno run --allow-env supabase/scripts/probe-cues.ts --dry-run",
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
        systemInstruction: SYSTEM_PREAMBLE_TASK_CUES,
        contents: buildParseContents({
          transcript: c.transcript,
          now: c.now,
          timezone: c.timezone,
          openTaskTitles: [],
        }),
        responseSchema: buildParseResponseSchemaWithCues(),
        timeoutMs: 30000,
      });

      // Run through the SAME server-side validator a real `task_cues_v1` request would use — this
      // probe can never pass on a response the production path would have rejected/stripped.
      const validated = validateParsedTaskArrayWithCues(raw);
      const problems: string[] = [];

      if (!validated || validated.tasks.length === 0) {
        problems.push(`no valid tasks returned (raw: ${JSON.stringify(raw).slice(0, 300)})`);
      } else {
        if (c.expectedTaskCount !== undefined && validated.tasks.length !== c.expectedTaskCount) {
          problems.push(`taskCount: got ${validated.tasks.length}, want ${c.expectedTaskCount}`);
        }

        const task = findTask(validated.tasks, c.titleContains);
        if (!task) {
          problems.push(
            `no task with title containing "${c.titleContains}" found among ` +
              `[${validated.tasks.map((t) => `"${t.title.value}"`).join(", ")}]`,
          );
        } else {
          const fullTask = validated.tasks.find((t) => t === task) as
            | { cue?: { kind: string; verbatim: string }; deadline?: { value: string } }
            | undefined;
          const cue = fullTask?.cue;

          if (c.expectCueKind !== undefined) {
            if (!cue) {
              problems.push(`cue: expected kind="${c.expectCueKind}", got no cue at all`);
            } else if (cue.kind !== c.expectCueKind) {
              problems.push(`cue.kind: got "${cue.kind}", want "${c.expectCueKind}"`);
            }
          }
          if (c.expectCueVerbatimContains !== undefined) {
            const verbatim = cue?.verbatim?.toLowerCase() ?? "";
            if (!verbatim.includes(c.expectCueVerbatimContains.toLowerCase())) {
              problems.push(
                `cue.verbatim: expected to contain "${c.expectCueVerbatimContains}", got ` +
                  `${cue ? `"${cue.verbatim}"` : "no cue"}`,
              );
            }
          }
          if (c.expectNoCue && cue !== undefined) {
            problems.push(`cue: expected ABSENT, got kind="${cue.kind}" verbatim="${cue.verbatim}"`);
          }
          if (c.expectDeadlineAbsent && fullTask?.deadline !== undefined) {
            problems.push(
              `deadline: expected ABSENT (the cue anchor must never leak into a fabricated ` +
                `deadline), got ${fullTask.deadline.value}`,
            );
          }
          if (c.expectDeadlinePresent && fullTask?.deadline === undefined) {
            problems.push(`deadline: expected PRESENT (a genuine clock time was stated), got none`);
          }
        }

        if (c.expectNoCueOnSecondTaskContaining !== undefined) {
          const secondTask = findTask(validated.tasks, c.expectNoCueOnSecondTaskContaining) as
            | { title: { value: string }; cue?: { kind: string; verbatim: string } }
            | undefined;
          if (!secondTask) {
            problems.push(
              `no SECOND task with title containing "${c.expectNoCueOnSecondTaskContaining}" found ` +
                `among [${validated.tasks.map((t) => `"${t.title.value}"`).join(", ")}]`,
            );
          } else if (secondTask.cue !== undefined) {
            problems.push(
              `second task "${secondTask.title.value}": expected NO cue (must not inherit the ` +
                `first task's anchor), got kind="${secondTask.cue.kind}" verbatim="${secondTask.cue.verbatim}"`,
            );
          }
        }
      }

      if (problems.length === 0) {
        pass++;
        const task = validated ? findTask(validated.tasks, c.titleContains) : undefined;
        const fullTask = task
          ? (validated!.tasks.find((t) => t === task) as
            | { cue?: { kind: string; verbatim: string }; deadline?: { value: string } }
            | undefined)
          : undefined;
        const parts = [
          fullTask?.cue ? `cue={kind:${fullTask.cue.kind}, verbatim:"${fullTask.cue.verbatim}"}` : "cue=absent",
          fullTask?.deadline ? `deadline=${fullTask.deadline.value}` : "deadline=absent",
        ];
        console.log(`PASS ${label}  ->  ${parts.join(", ")}`);
      } else {
        fail++;
        console.log(`FAIL ${label}\n${problems.map((p) => `     ${p}`).join("\n")}\n     (${c.why})\n`);
      }
    } catch (err) {
      fail++;
      console.log(`FAIL ${label}\n     threw: ${err instanceof Error ? err.message : String(err)}\n`);
    }
  }

  console.log(`\n${pass} passed, ${fail} failed, ${CASES.length} bare cases total`);

  // --- COMBO CASES: task_refs_v1 + task_cues_v1 together (see the module doc comment above). ------
  console.log("\n=== COMBO CASES (task_refs_v1 + task_cues_v1 together) ===\n");
  let comboPass = 0;
  let comboFail = 0;

  for (const [i, c] of COMBO_CASES.entries()) {
    const label = `[C${i + 1}] "${c.transcript}"`;
    try {
      const raw = await callGemini({
        apiKey,
        model,
        systemInstruction: SYSTEM_PREAMBLE_TASK_REFS_CUES,
        contents: buildParseContents({
          transcript: c.transcript,
          now: c.now,
          timezone: c.timezone,
          openTaskTitles: c.openTaskTitles,
        }),
        responseSchema: buildParseEnvelopeResponseSchemaWithCues(),
        timeoutMs: 30000,
      });

      // Run through the SAME server-side validator a real combo request would use.
      const validated = validateParseEnvelope(raw, true);
      const problems: string[] = [];

      if (!validated || validated.tasks.length === 0) {
        problems.push(`no valid tasks returned (raw: ${JSON.stringify(raw).slice(0, 300)})`);
      } else {
        const task = findTask(validated.tasks, c.titleContains) as
          | {
            title: { value: string };
            cue?: { kind: string; verbatim: string };
            conditions?: { value: { kind: string; refIndex?: number; referenceTitle?: string } }[];
          }
          | undefined;

        if (!task) {
          problems.push(
            `no task with title containing "${c.titleContains}" found among ` +
              `[${validated.tasks.map((t) => `"${t.title.value}"`).join(", ")}]`,
          );
        } else {
          // --- cue half ---
          if (!task.cue) {
            problems.push(`cue: expected kind="${c.expectCueKind}", got no cue at all`);
          } else {
            if (task.cue.kind !== c.expectCueKind) {
              problems.push(`cue.kind: got "${task.cue.kind}", want "${c.expectCueKind}"`);
            }
            if (!task.cue.verbatim.toLowerCase().includes(c.expectCueVerbatimContains.toLowerCase())) {
              problems.push(
                `cue.verbatim: expected to contain "${c.expectCueVerbatimContains}", got "${task.cue.verbatim}"`,
              );
            }
          }

          // --- taskRefs half ---
          const refIdx = validated.taskRefs.findIndex(
            (r) => r.titleQuery.value === c.expectedTaskRefTitle,
          );
          if (refIdx === -1) {
            problems.push(
              `taskRefs: expected an entry with titleQuery "${c.expectedTaskRefTitle}" (copied ` +
                `EXACTLY from openTaskTitles), got [${
                  validated.taskRefs.map((r) => `"${r.titleQuery.value}"`).join(", ")
                }]`,
            );
          } else {
            const dep = task.conditions?.find((cond) => cond.value.kind === "taskDone");
            if (!dep) {
              problems.push(
                `conditions: task "${task.title.value}" carries no taskDone condition pointing at ` +
                  `the referenced task (taskRefs entry found, but nothing depends on it)`,
              );
            } else if (dep.value.refIndex !== refIdx + 1) {
              problems.push(
                `conditions: taskDone.refIndex is ${dep.value.refIndex}, want ${
                  refIdx + 1
                } (the 1-based position of "${c.expectedTaskRefTitle}" in taskRefs)`,
              );
            }
          }
        }
      }

      if (problems.length === 0) {
        comboPass++;
        const task = validated ? findTask(validated.tasks, c.titleContains) : undefined;
        const fullTask = task
          ? (validated!.tasks.find((t) => t === task) as
            | { cue?: { kind: string; verbatim: string } }
            | undefined)
          : undefined;
        console.log(
          `PASS ${label}  ->  cue=${
            fullTask?.cue ? `{kind:${fullTask.cue.kind}, verbatim:"${fullTask.cue.verbatim}"}` : "absent"
          }, taskRefs=[${validated!.taskRefs.map((r) => `"${r.titleQuery.value}"`).join(", ")}]`,
        );
      } else {
        comboFail++;
        console.log(`FAIL ${label}\n${problems.map((p) => `     ${p}`).join("\n")}\n     (${c.why})\n`);
      }
    } catch (err) {
      comboFail++;
      console.log(`FAIL ${label}\n     threw: ${err instanceof Error ? err.message : String(err)}\n`);
    }
  }

  console.log(`\n${comboPass} passed, ${comboFail} failed, ${COMBO_CASES.length} combo cases total`);
  console.log(
    `\nGRAND TOTAL: ${pass + comboPass} passed, ${fail + comboFail} failed, ${
      CASES.length + COMBO_CASES.length
    } total`,
  );
  Deno.exit(fail === 0 && comboFail === 0 ? 0 : 1);
}

await main();
