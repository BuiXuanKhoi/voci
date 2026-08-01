// supabase/scripts/probe-time-parsing.ts
//
// Live probe for the /parse route's DATE/TIME resolution only — calls Gemini directly with the
// EXACT prompt `parse/index.ts` would build (same `SYSTEM_PREAMBLE`, same `buildParseContents`,
// same `responseSchema`, same `callGemini`), for a table of Vietnamese/English utterances whose
// correct deadline is known, and diffs what comes back against the expected ISO string.
//
// WHY THIS EXISTS: the time rules live in a PROMPT, and a prompt is not a function — `deno check`
// passing proves nothing about whether the model actually obeys "chiều nay = 18:00" or whether it
// silently rewrites the UTC offset. The only way to know is to ask the real model. This file makes
// that a one-liner instead of a manual afternoon.
//
// NOT deployed: `supabase functions deploy` only ships `functions/`, never `scripts/`.
//
// RUN (needs a Gemini API key — the same one set as the `GEMINI_API_KEY` secret on the Supabase
// project; get it from Google AI Studio, and note this script bills real tokens, ~20 tiny calls):
//
//   GEMINI_API_KEY=... deno run --allow-net --allow-env supabase/scripts/probe-time-parsing.ts
//
// Dry run (no key, no network — prints the fully-built prompt so you can read exactly what the
// model is being told, which is also the fastest way to spot two rules contradicting each other):
//
//   deno run --allow-env supabase/scripts/probe-time-parsing.ts --dry-run
//
// Override the model with PARSE_MODEL, same env var the real function reads.

import {
  DEFAULT_PARSE_MODEL,
  SYSTEM_PREAMBLE,
  buildParseContents,
  buildParseResponseSchema,
  callGemini,
} from "../functions/_shared/gemini.ts";
import { validateParsedTaskArray } from "../functions/_shared/schema.ts";

// 2026-07-28 is a TUESDAY (2026-07-27, the Monday, is the anchor date already used in
// `gemini.ts`'s own worked examples — keep these in sync if that anchor ever changes).
const NOW_VN = "2026-07-28T15:00:00+07:00";
const TZ_VN = "Asia/Ho_Chi_Minh";

// A second timezone with a NEGATIVE offset, deliberately: the single most likely regression is the
// model "helpfully" normalizing every deadline to UTC/`Z`. A `+07:00` case alone can hide that if
// the model happens to echo the offset; a `-04:00` case makes any normalization glaringly wrong.
const NOW_NY = "2026-07-28T15:00:00-04:00";
const TZ_NY = "America/New_York";

interface Case {
  transcript: string;
  now: string;
  timezone: string;
  /** Exact ISO string the deadline MUST equal — offset included, deliberately. Omit only when
   *  the case sets `expectDeadlineAbsent` instead (mutually exclusive with this field's normal use
   *  in the pre-existing 12 cases, which always set it). */
  expected?: string;
  /** Urgency-rule cases only: when set, asserts NO `deadline` is returned at all (the task brief's
   *  "khẩn cấp KHÔNG có nghĩa là hạn chót ngay lập tức" rule) rather than comparing against
   *  `expected`. Mutually exclusive with `expected`. */
  expectDeadlineAbsent?: boolean;
  /** Urgency-rule cases only: exact ISO string `startTime` MUST equal (same written-form
   *  comparison as `expected`/`deadline` — see `normalizeIso`). Absent on every pre-existing case,
   *  which never expect a `startTime` at all. */
  expectedStartTime?: string;
  /** Regression-guard case only: asserts NO `startTime` is returned (proves rule 2a does not turn
   *  an ordinary clock-time deadline into a startTime). */
  expectStartTimeAbsent?: boolean;
  /** Urgency-rule cases only: `priority` MUST equal this value (1-4 scale, 1 = most urgent). */
  expectedPriority?: number;
  /** remindPeriodMinutes-rule case only: `reminderOverride.remindPeriodMinutes` MUST equal this
   *  exact value (minutes, positive integer) — proves the model extracts a repeating pre-deadline
   *  reminder cadence when the transcript states one explicitly. */
  expectedRemindPeriodMinutes?: number;
  /** Regression-guard cases: asserts NO `remindPeriodMinutes` is returned at all — either because
   *  the transcript names a single one-off offset (not a repeating cadence, so `offsetsMinutes`
   *  should be used instead), or because the transcript says nothing about reminders at all (in
   *  which case `reminderOverride` itself should be entirely absent, letting the client's own
   *  default reminder schedule apply). */
  expectRemindPeriodAbsent?: boolean;
  /** Regression-guard case only: asserts `reminderOverride.offsetsMinutes` contains this exact
   *  offset (minutes, negative = before deadline) — paired with `expectRemindPeriodAbsent` to prove
   *  a single stated offset ("nhắc tôi trước 1 tiếng") does NOT get misread as a repeating cadence. */
  expectedOffsetMinutes?: number;
  /** Splitting-rule cases only (2026-08-02): exact number of tasks the utterance must produce.
   *  Every pre-existing case implicitly expects 1 and asserts only on `tasks[0]`; these cases are
   *  the first that care how many came back at all. */
  expectedTaskCount?: number;
  /** Dependency-rule cases only: asserts the LAST task carries a `taskDone` condition, and that
   *  its `referenceTitle` would ACTUALLY link to the first task on the client. That second half is
   *  the point — a model can obey "emit a taskDone condition" while writing a reference too short
   *  to match, which loses the ordering with no error anywhere. See `wouldClientLink` below. */
  expectDependencyOnFirstTask?: boolean;
  /** Regression guard for the splitting rule: asserts NO task carries any condition at all — a
   *  compound-object utterance ("mua sữa và bánh mì") must neither split nor invent an ordering. */
  expectNoConditions?: boolean;
  why: string;
}

/** Mirrors `AppState.tokenize` (`Volar/Sources/App/AppState.swift`): lowercase, strip diacritics,
 *  split on whitespace, dedupe. `đ`/`Đ` are mapped explicitly because Swift's
 *  `.folding(options: .diacriticInsensitive)` folds them to `d`, while Unicode NFD does NOT
 *  decompose U+0111 (it is its own letter, not `d` + a combining mark) — without this line the two
 *  sides would tokenize "đã"/"đơn" differently and this probe would disagree with the real client.
 *  Punctuation is deliberately NOT stripped, matching the Swift side exactly: "Sugashack." and
 *  "Sugashack" really are different tokens there. */
function tokenize(text: string): Set<string> {
  const folded = text
    .toLowerCase()
    .replace(/đ/g, "d")
    .normalize("NFD")
    .replace(/\p{M}/gu, "");
  return new Set(folded.split(/\s+/).filter((t) => t.length > 0));
}

/** Replays the client's dependency-matching decision (`AppState.preResolveConditions` ->
 *  `scoredMatches(similarity: .strict)`): Jaccard over the token sets, linked only at >= 0.7. This
 *  is why the prompt insists `referenceTitle` repeat the earlier title word for word — "landing
 *  page" against "Làm landing page cho Sugashack" is 2/6 = 0.33 and would be dropped in silence. */
function wouldClientLink(referenceTitle: string, taskTitle: string): { linked: boolean; score: number } {
  const a = tokenize(referenceTitle);
  const b = tokenize(taskTitle);
  if (a.size === 0 || b.size === 0) return { linked: false, score: 0 };
  let shared = 0;
  for (const t of a) if (b.has(t)) shared++;
  const union = new Set([...a, ...b]).size;
  const score = union === 0 ? 0 : shared / union;
  return { linked: score >= 0.7, score };
}

const CASES: Case[] = [
  // --- Bare period-of-day, no clock hour: the end-of-period anchor table. -----------------------
  {
    transcript: "nộp báo cáo chiều nay",
    now: NOW_VN,
    timezone: TZ_VN,
    expected: "2026-07-28T18:00:00+07:00",
    expectRemindPeriodAbsent: true,
    why: "chiều (no hour) -> 18:00 end-of-period anchor, today; ALSO the remindPeriod regression "
      + "guard -- the transcript says nothing about reminders, so reminderOverride must not be "
      + "invented at all (client applies its own 1/2-1/3 default reminder schedule)",
  },
  {
    transcript: "gửi mail sáng nay",
    now: NOW_VN,
    timezone: TZ_VN,
    expected: "2026-07-28T12:00:00+07:00",
    why: "sáng -> 12:00; ALREADY PAST at now=15:00 and must STILL be returned as-is (the client, "
      + "not the model, offers to move it) — this is the case that drives the overdue advisory",
  },
  {
    transcript: "làm slide tối nay",
    now: NOW_VN,
    timezone: TZ_VN,
    expected: "2026-07-28T22:00:00+07:00",
    why: "tối -> 22:00",
  },
  {
    transcript: "deploy đêm nay",
    now: NOW_VN,
    timezone: TZ_VN,
    expected: "2026-07-28T23:59:00+07:00",
    why: "đêm -> 23:59 (must not roll into tomorrow 00:00)",
  },
  {
    transcript: "review code trưa mai",
    now: NOW_VN,
    timezone: TZ_VN,
    expected: "2026-07-29T13:00:00+07:00",
    why: "trưa -> 13:00, and the day word still shifts to tomorrow",
  },
  {
    transcript: "họp team sáng mai",
    now: NOW_VN,
    timezone: TZ_VN,
    expected: "2026-07-29T12:00:00+07:00",
    why: "sáng -> 12:00 on day+1",
  },

  // --- Explicit clock hour: the anchor table must NOT apply. ------------------------------------
  {
    transcript: "gọi khách 3 giờ chiều mai",
    now: NOW_VN,
    timezone: TZ_VN,
    expected: "2026-07-29T15:00:00+07:00",
    why: "explicit hour wins over the 18:00 anchor; `chiều` only disambiguates PM",
  },
  {
    transcript: "chạy backup 9 giờ sáng mai",
    now: NOW_VN,
    timezone: TZ_VN,
    expected: "2026-07-29T09:00:00+07:00",
    why: "explicit hour wins over the 12:00 anchor",
  },

  // --- Day/week arithmetic (pre-existing rules — regression guard, these already worked). -------
  {
    transcript: "thứ sáu tuần sau nộp thuế",
    now: NOW_VN,
    timezone: TZ_VN,
    expected: "2026-08-07T12:00:00+07:00",
    why: "Friday of the week AFTER the one containing now (not 2026-07-31). NOTE: no time-of-day "
      + "was spoken, so the hour here is genuinely open — treat an hour mismatch on THIS case as "
      + "informational, the DATE is what is being tested",
  },

  // --- English, same rules. --------------------------------------------------------------------
  {
    transcript: "send the invoice this afternoon",
    now: NOW_VN,
    timezone: TZ_VN,
    expected: "2026-07-28T18:00:00+07:00",
    why: "the anchor table is language-independent",
  },

  // --- Negative UTC offset: catches silent UTC normalization. -----------------------------------
  {
    transcript: "nộp báo cáo chiều nay",
    now: NOW_NY,
    timezone: TZ_NY,
    expected: "2026-07-28T18:00:00-04:00",
    why: "offset must be echoed VERBATIM — a `Z`/`+00:00` here means the model normalized to UTC, "
      + "which is exactly the bug class this whole change exists to kill",
  },
  {
    transcript: "call the vendor tomorrow morning",
    now: NOW_NY,
    timezone: TZ_NY,
    expected: "2026-07-29T12:00:00-04:00",
    why: "anchor + day shift + negative offset together",
  },

  // --- Urgency semantics (startTime + priority, deadline withheld unless stated explicitly). -----
  {
    transcript: "Giờ phải làm task disposition code ngay lập tức",
    now: NOW_VN,
    timezone: TZ_VN,
    expectDeadlineAbsent: true,
    expectedStartTime: "2026-07-28T15:00:00+07:00",
    expectedPriority: 1,
    why: "urgency phrasing (\"ngay lập tức\") -> startTime = now verbatim, priority 1, and NO "
      + "deadline invented — the client derives a provisional deadline from startTime + estimate",
  },
  {
    transcript: "làm ngay, 5 giờ chiều phải xong",
    now: NOW_VN,
    timezone: TZ_VN,
    expected: "2026-07-28T17:00:00+07:00",
    expectedStartTime: "2026-07-28T15:00:00+07:00",
    expectedPriority: 1,
    why: "urgency (\"làm ngay\") gives startTime = now, AND the transcript ALSO states an explicit "
      + "deadline (5pm today) -> both fields must be present together, deadline is not withheld "
      + "just because the task is urgent",
  },

  // --- Regression guard: an ordinary clock-time deadline must NOT grow a startTime. ---------------
  {
    transcript: "họp team 3 giờ chiều mai",
    now: NOW_VN,
    timezone: TZ_VN,
    expected: "2026-07-29T15:00:00+07:00",
    expectStartTimeAbsent: true,
    why: "a bare clock-time meeting is a DEADLINE by default (rule 2a) -> must NOT also produce a "
      + "startTime just because startTime now exists as a field",
  },

  // --- remindPeriodMinutes: repeating pre-deadline reminder cadence vs a single one-off offset. ---
  {
    transcript: "nhắc tôi mỗi 15 phút cho tới khi xong báo cáo chiều nay",
    now: NOW_VN,
    timezone: TZ_VN,
    expected: "2026-07-28T18:00:00+07:00",
    expectedRemindPeriodMinutes: 15,
    why: "explicit repeating cadence (\"mỗi 15 phút\") -> reminderOverride.remindPeriodMinutes = "
      + "15, alongside the ordinary chiều-nay 18:00 deadline anchor",
  },
  {
    transcript: "nhắc tôi trước 1 tiếng, họp lúc 5 giờ chiều mai",
    now: NOW_VN,
    timezone: TZ_VN,
    expected: "2026-07-29T17:00:00+07:00",
    expectedOffsetMinutes: -60,
    expectRemindPeriodAbsent: true,
    why: "MOST IMPORTANT regression guard: a single stated moment before the deadline (\"trước 1 "
      + "tiếng\") is offsetsMinutes: [-60], a ONE-OFF reminder -- NOT a repeating cadence, so "
      + "remindPeriodMinutes must be absent even though a reminderOverride IS legitimately present",
  },

  // --- Splitting + dependency (anh Khôi 2026-08-02) ---------------------------------------------
  // The rule these probe lives entirely in `SYSTEM_PREAMBLE`; before it existed the first case
  // below came back as ONE task, which is what prompted the whole rule.
  {
    transcript: "làm xong landing page và gửi cho khách hàng Sugashack",
    now: NOW_VN,
    timezone: TZ_VN,
    expectedTaskCount: 2,
    expectDependencyOnFirstTask: true,
    why: "THE case that started this rule: two different actions (làm / gửi) at two different "
      + "moments, with \"xong ... và\" stating the ordering -> 2 tasks, and the SECOND must carry "
      + "a taskDone condition whose referenceTitle actually links back to the first",
  },
  {
    transcript: "sau khi deploy xong thì nhắn cho team QA",
    now: NOW_VN,
    timezone: TZ_VN,
    expectedTaskCount: 2,
    expectDependencyOnFirstTask: true,
    why: "the explicit \"sau khi ... thì\" form -- same two-task + dependency shape, different "
      + "connective, so the rule can't be passing on the word \"xong\" alone",
  },
  {
    transcript: "mua sữa và bánh mì",
    now: NOW_VN,
    timezone: TZ_VN,
    expectedTaskCount: 1,
    expectNoConditions: true,
    why: "MOST IMPORTANT regression guard for over-splitting: ONE action (mua) with two objects "
      + "is ONE task -- a rule that splits this has misread \"và\" as a task separator",
  },
  {
    transcript: "gọi cho Nam và Hoa về hợp đồng",
    now: NOW_VN,
    timezone: TZ_VN,
    expectedTaskCount: 1,
    expectNoConditions: true,
    why: "second over-splitting guard, harder than the shopping one: same verb, two PEOPLE, and "
      + "no stated ordering between them -- one task, and no invented dependency",
  },
];

/** Compares two ISO strings as WRITTEN, not as instants: `...T18:00:00+07:00` and
 *  `...T11:00:00Z` are the same moment but only the first is acceptable here — echoing the
 *  caller's offset is itself part of the contract (a `Z` deadline is how the original bug
 *  manifested), so this deliberately does NOT go through `Date.parse`. Only normalizes the
 *  things that are genuinely free: case of the zone designator, and an omitted `:00` seconds. */
function normalizeIso(s: string): string {
  return s.trim().toUpperCase().replace(/(T\d{2}:\d{2})(?=[+\-Z])/, "$1:00");
}

function sameInstant(a: string, b: string): boolean {
  const ta = Date.parse(a);
  const tb = Date.parse(b);
  return Number.isFinite(ta) && Number.isFinite(tb) && ta === tb;
}

async function main() {
  const dryRun = Deno.args.includes("--dry-run");
  const apiKey = Deno.env.get("GEMINI_API_KEY") ?? "";
  const model = Deno.env.get("PARSE_MODEL") || DEFAULT_PARSE_MODEL;

  if (dryRun) {
    const c = CASES[0];
    console.log("=== SYSTEM INSTRUCTION ===\n");
    console.log(SYSTEM_PREAMBLE);
    console.log("\n\n=== CONTENTS (case 1) ===\n");
    console.log(buildParseContents({
      transcript: c.transcript,
      now: c.now,
      timezone: c.timezone,
      openTaskTitles: [],
    }));
    console.log(`\n\n(${CASES.length} cases defined; re-run with GEMINI_API_KEY set to probe live.)`);
    return;
  }

  if (!apiKey) {
    console.error(
      "GEMINI_API_KEY is not set.\n" +
        "  Live:    GEMINI_API_KEY=... deno run --allow-net --allow-env " +
        "supabase/scripts/probe-time-parsing.ts\n" +
        "  Dry run: deno run --allow-env supabase/scripts/probe-time-parsing.ts --dry-run",
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
        systemInstruction: SYSTEM_PREAMBLE,
        contents: buildParseContents({
          transcript: c.transcript,
          now: c.now,
          timezone: c.timezone,
          openTaskTitles: [],
        }),
        responseSchema: buildParseResponseSchema(),
        timeoutMs: 30000,
      });

      // Run the model output through the SAME validator the real route uses, so this probe can
      // never pass on a response the production path would have thrown out as invalid.
      const validated = validateParsedTaskArray(raw);
      const task = validated?.tasks?.[0];
      const gotDeadline = task?.deadline?.value;
      const gotStartTime = task?.startTime?.value;
      const gotPriority = task?.priority?.value;
      const gotRemindPeriod = task?.reminderOverride?.value?.remindPeriodMinutes;
      const gotOffsets = task?.reminderOverride?.value?.offsetsMinutes;

      // Each case asserts a subset of {deadline, startTime, priority} — collect every mismatch
      // instead of stopping at the first, so a single failing case still reports everything wrong
      // with it in one shot rather than requiring a re-run per assertion.
      const problems: string[] = [];

      if (c.expectDeadlineAbsent) {
        if (gotDeadline !== undefined) {
          problems.push(`deadline: expected ABSENT, got ${gotDeadline}`);
        }
      } else if (c.expected !== undefined) {
        if (!gotDeadline) {
          problems.push(`deadline: expected ${c.expected}, got none`);
        } else if (normalizeIso(gotDeadline) === normalizeIso(c.expected)) {
          // ok
        } else if (sameInstant(gotDeadline, c.expected)) {
          // Right moment, wrong notation: the model normalized the zone (usually to `Z`). Counted
          // as a FAILURE on purpose — echoing the caller's offset is part of the contract, and a
          // `Z` deadline is precisely how the original 7-hour bug looked on the wire.
          problems.push(
            `deadline: got ${gotDeadline} <-- correct instant, but the UTC OFFSET was rewritten ` +
              `(want ${c.expected})`,
          );
        } else {
          problems.push(`deadline: got ${gotDeadline}, want ${c.expected}`);
        }
      }

      if (c.expectStartTimeAbsent) {
        if (gotStartTime !== undefined) {
          problems.push(`startTime: expected ABSENT, got ${gotStartTime}`);
        }
      } else if (c.expectedStartTime !== undefined) {
        if (!gotStartTime) {
          problems.push(`startTime: expected ${c.expectedStartTime}, got none`);
        } else if (normalizeIso(gotStartTime) !== normalizeIso(c.expectedStartTime)) {
          problems.push(`startTime: got ${gotStartTime}, want ${c.expectedStartTime}`);
        }
      }

      if (c.expectedPriority !== undefined) {
        if (gotPriority !== c.expectedPriority) {
          problems.push(`priority: got ${gotPriority ?? "none"}, want ${c.expectedPriority}`);
        }
      }

      // --- Splitting + dependency (2026-08-02) --------------------------------------------------
      const tasks = validated?.tasks ?? [];

      if (c.expectedTaskCount !== undefined && tasks.length !== c.expectedTaskCount) {
        problems.push(
          `taskCount: got ${tasks.length}, want ${c.expectedTaskCount} ` +
            `[${tasks.map((t) => `"${t.title.value}"`).join(", ")}]`,
        );
      }

      if (c.expectNoConditions) {
        const withConditions = tasks.filter((t) => (t.conditions?.length ?? 0) > 0);
        if (withConditions.length > 0) {
          problems.push(
            `conditions: expected NONE, got ${withConditions.length} task(s) carrying one ` +
              `(an ordering was invented that the utterance never stated)`,
          );
        }
      }

      if (c.expectDependencyOnFirstTask) {
        // Deliberately checks the LAST task, not "some task": the dependency has a direction, and
        // the earlier task pointing at the later one is a real failure mode, not a near-miss.
        const first = tasks[0];
        const last = tasks[tasks.length - 1];
        const firstHasCondition = (first?.conditions?.length ?? 0) > 0;
        const dep = last?.conditions?.find((c) => c.value.kind === "taskDone");

        if (tasks.length < 2 || !first || !last) {
          // The taskCount assertion above already reported this; don't double-report.
        } else if (firstHasCondition) {
          problems.push(
            `dependency: the FIRST task carries a condition — the ordering is backwards ` +
              `("${first.title.value}" should not wait on anything here)`,
          );
        } else if (!dep) {
          problems.push(
            `dependency: last task "${last.title.value}" carries no taskDone condition ` +
              `(it must wait on "${first.title.value}")`,
          );
        } else {
          const ref = dep.value.referenceTitle ?? "";
          const { linked, score } = wouldClientLink(ref, first.title.value);
          if (!linked) {
            // The model DID follow the rule's letter and still produced a dead link. This is the
            // single most valuable line in this probe: nothing else anywhere — not `deno check`,
            // not the server validator, not a Swift unit test — can catch it, because both sides
            // are individually well-formed and the loss happens only when they meet.
            problems.push(
              `dependency: referenceTitle "${ref}" would NOT link to "${first.title.value}" on ` +
                `the client (Jaccard ${score.toFixed(2)} < 0.70) — the ordering would be dropped ` +
                `in silence`,
            );
          }
        }
      }

      if (c.expectedRemindPeriodMinutes !== undefined) {
        if (gotRemindPeriod !== c.expectedRemindPeriodMinutes) {
          problems.push(
            `remindPeriodMinutes: got ${gotRemindPeriod ?? "none"}, want ${c.expectedRemindPeriodMinutes}`,
          );
        }
      }

      if (c.expectRemindPeriodAbsent) {
        if (gotRemindPeriod !== undefined) {
          problems.push(`remindPeriodMinutes: expected ABSENT, got ${gotRemindPeriod}`);
        }
      }

      if (c.expectedOffsetMinutes !== undefined) {
        if (!gotOffsets || !gotOffsets.includes(c.expectedOffsetMinutes)) {
          problems.push(
            `offsetsMinutes: expected to contain ${c.expectedOffsetMinutes}, got ${JSON.stringify(gotOffsets ?? [])}`,
          );
        }
      }

      if (problems.length === 0) {
        pass++;
        const parts = [
          gotDeadline ? `deadline=${gotDeadline}` : undefined,
          gotStartTime ? `startTime=${gotStartTime}` : undefined,
          gotPriority !== undefined ? `priority=${gotPriority}` : undefined,
          gotRemindPeriod !== undefined ? `remindPeriodMinutes=${gotRemindPeriod}` : undefined,
          gotOffsets ? `offsetsMinutes=${JSON.stringify(gotOffsets)}` : undefined,
        ].filter(Boolean);
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

  console.log(`\n${pass} passed, ${fail} failed, ${CASES.length} total`);
  Deno.exit(fail === 0 ? 0 : 1);
}

await main();
