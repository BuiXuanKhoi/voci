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
  why: string;
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
