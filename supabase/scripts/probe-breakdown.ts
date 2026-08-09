// supabase/scripts/probe-breakdown.ts
//
// 🔴 AGENT: KHÔNG TỰ CHẠY FILE NÀY (anh Khôi chốt 2026-08-09 — xem CLAUDE.md ở gốc repo).
// Mỗi case ≈ 47đ vì prompt cố định chiếm 98,8% input token; chạy hết bảng ≈ 12 call.
// Sửa prompt xong thì DỪNG và hỏi anh Khôi, đừng "chạy thử cho chắc". `--dry-run` thì thoải mái.
//
// Live probe for the `breakdown` route's TWO layers, modeled directly on
// `probe-time-parsing.ts` (same env handling, same "known-answer" philosophy, same output style):
//
//   (1) the pre-existing "concrete physical first step" rule (never actually probed before this
//       file existed — `deno check` proves the prompt/schema TYPE-CHECK, not that the model
//       actually obeys "start with a concrete action verb" or "never a bare abstract verb").
//   (2) the NEW implementation-intention cue rule (Opus design 2026-08-08,
//       `specs/006-cues-and-waiting/design.md` §2 Việc A, d=0.65 evidence in
//       `docs/adhd-research-v1.md` §9): when `sourceTranscript`/`notes` name a real EVENT anchor
//       for this specific task, the FIRST step (and ONLY the first) should read
//       "<cue> → <action>" -- and, symmetrically and just as important, when NO real anchor is
//       named, the first step must stay a bare action with NO invented cue. That second half is
//       the single most important case this probe checks: a model that "helpfully" invents a
//       morning routine the user never mentioned is worse than one that says nothing.
//
// WHY THIS EXISTS: both rules live in a PROMPT (`buildBreakdownContents` in gemini.ts), and a
// prompt is not a function. This repo had ZERO live probes for `breakdown` before this file —
// `design.md` §0.1 flags this explicitly as "the real remaining work" of this task.
//
// NOT deployed: `supabase functions deploy` only ships `functions/`, never `scripts/`.
// NOT run in CI: costs real tokens (~9 tiny calls) and calls a live third-party API. Run it by
// hand after touching `buildBreakdownContents`.
//
// RUN (needs a Gemini API key — the same one set as the `GEMINI_API_KEY` secret on the Supabase
// project; anh Khôi already has one in `supabase/.env`, gitignored):
//
//   deno run --env-file=supabase/.env --allow-net --allow-env supabase/scripts/probe-breakdown.ts
//
// Dry run (no key, no network — prints the fully-built prompt for case 1):
//
//   deno run --allow-env supabase/scripts/probe-breakdown.ts --dry-run
//
// Override the model with PARSE_MODEL, same env var the real function reads.
//
// ⚠️ CONTAMINATION GUARD (the 2026-08-07 lesson, see gemini.ts's `SYSTEM_PREAMBLE_FEWSHOT_EXAMPLES`
// doc comment): NONE of this file's transcripts, anchor phrases, or task titles are copy-pasted
// from `buildBreakdownContents`'s own illustrative examples in gemini.ts ("Plan the presentation
// outline"/"Prepare project materials", or the cue anchor examples "sau khi ăn trưa"/"after lunch",
// "khi mở laptop"/"when I open my laptop", "sau khi họp xong"/"right after the meeting"). Every
// case below uses a DIFFERENT anchor phrase and a DIFFERENT task than anything written into the
// prompt itself, so a PASS here demonstrates the model generalizing the RULE, not echoing an
// example it was shown verbatim. If a future edit to `buildBreakdownContents` adds new illustrative
// examples, re-check this file's cases against them before trusting a run.

import {
  DEFAULT_PARSE_MODEL,
  SYSTEM_PREAMBLE,
  buildBreakdownContents,
  buildBreakdownResponseSchema,
  callGemini,
} from "../functions/_shared/gemini.ts";
import { validateBreakdownSteps } from "../functions/_shared/schema.ts";

// Concrete action verbs. The 7 VN / 7 EN verbs on the first line are copied VERBATIM from
// `buildBreakdownContents`'s own instruction text (mở/bật/lấy/đặt/gõ/viết/gọi;
// open/turn on/pick up/put/type/write/call) — those are the prompt's own ILLUSTRATIVE examples,
// not an exhaustive enum ("start with a concrete action verb acting on a specific object" is the
// actual rule). The second line adds a few more unambiguous physical verbs found DURING live
// probing (2026-08-08) that a correctly-behaving model legitimately reached for and this probe's
// original narrower list wrongly flagged as failures — e.g. "Nhặt các vỏ chai nước rỗng trên bàn
// trà và bỏ vào thùng rác" ("pick up the empty bottles on the coffee table and put them in the
// trash") is a perfectly good concrete first step; "nhặt" (pick up/collect) just wasn't in the
// original list. This is a PROBE assertion fix, not a prompt change — `buildBreakdownContents`
// itself is untouched. Checked against the ACTION half of the step (after the "→" cue separator,
// if any), never the cue half — the cue itself is an event clause, not an action, and is not
// expected to start with one of these verbs.
const ACTION_VERBS = [
  "mở", "bật", "lấy", "đặt", "gõ", "viết", "gọi",
  "open", "turn on", "pick up", "put", "type", "write", "call",
  "nhặt", "dọn", "cầm", "xách", "kéo", "đẩy", "nhấc",
];

// Bare abstract verbs the prompt explicitly forbids opening the first step with, unless paired
// with a concrete object AND a physical starting motion (which in practice means: never opens
// with these words at all — see `buildBreakdownContents`'s "Bad -> good" example).
const ABSTRACT_VERBS = ["plan", "prepare", "think about", "organize", "research", "lên kế hoạch", "chuẩn bị"];

// Matches an explicit clock hour ("3 giờ", "14:00", "3pm") — deliberately narrow (requires a
// digit immediately adjacent to the marker) so it doesn't false-positive on ordinary words that
// happen to contain the letter "h" or "g".
const CLOCK_HOUR_RE = /\d{1,2}\s*giờ|\d{1,2}:\d{2}|\b\d{1,2}\s*(am|pm)\b/i;

// Rough "this text contains Vietnamese-specific diacritics" check — Latin-1 Supplement + Latin
// Extended Additional covers precomposed Vietnamese vowels (ạ, ệ, ơ, ư, etc).
const VIETNAMESE_DIACRITIC_RE = /[À-ỹ]/;

interface Case {
  taskTitle: string;
  notes?: string;
  sourceTranscript?: string;
  deadline?: string;
  lang: "vi" | "en";
  /** When true, step 1 MUST open with "<cue> → <action>" — a real anchor exists in
   *  sourceTranscript/notes. When false, step 1 must have NO "→" at all (the anti-invention
   *  regression guard — the single most important assertion in this file). */
  expectCueOnStep1: boolean;
  why: string;
}

const CASES: Case[] = [
  // --- Positive cue cases: a real event anchor IS present, step 1 must carry it. ------------------
  {
    taskTitle: "Soạn slide thuyết trình cho khách hàng ABC",
    sourceTranscript: "tối nay sau khi tắm xong thì soạn slide thuyết trình cho khách hàng ABC",
    lang: "vi",
    expectCueOnStep1: true,
    why: "sourceTranscript names a real event anchor (\"sau khi tắm xong\") -- step 1 must open with it",
  },
  {
    taskTitle: "Đọc hợp đồng thuê nhà",
    sourceTranscript: "trước khi đi ngủ thì nhớ đọc kỹ hợp đồng thuê nhà mới",
    lang: "vi",
    expectCueOnStep1: true,
    why: "a dayEnd-flavored event anchor (\"trước khi đi ngủ\"), different phrasing/task than case 1",
  },
  {
    taskTitle: "Draft the investor update email",
    sourceTranscript: "right after I walk the dog this morning I need to draft the investor update email",
    lang: "en",
    expectCueOnStep1: true,
    why: "English event anchor (\"right after I walk the dog\") -- the rule must not be VN-only",
  },
  {
    taskTitle: "Cập nhật hồ sơ nhân sự cho nhân viên mới",
    notes: "khi bật máy tính lên là làm luôn, đừng để quên",
    lang: "vi",
    expectCueOnStep1: true,
    why: "anchor comes from `notes`, not `sourceTranscript` -- the rule must read both fields",
  },

  // --- Negative cue cases: NO real anchor -- step 1 must stay a bare action, no invented cue. -----
  {
    taskTitle: "Dọn dẹp phòng khách",
    lang: "vi",
    expectCueOnStep1: false,
    why: "MOST IMPORTANT regression guard: no sourceTranscript/notes at all -- a model that invents "
      + "a routine anchor here is fabricating a habit the user never mentioned",
  },
  {
    taskTitle: "Clean out the garage",
    lang: "en",
    expectCueOnStep1: false,
    why: "same anti-invention guard in English",
  },
  {
    taskTitle: "Chuẩn bị tài liệu họp dự án Kim Cương",
    sourceTranscript: "3 giờ chiều mai họp bàn về dự án Kim Cương với sếp Hùng",
    deadline: "2026-07-29T15:00:00+07:00",
    lang: "vi",
    expectCueOnStep1: false,
    why: "sourceTranscript names ONLY a CLOCK TIME (3 giờ chiều), never an event -- a clock hour is "
      + "explicitly forbidden as a cue, so step 1 must stay bare, not adopt the meeting time as a cue",
  },
  {
    taskTitle: "Nộp tờ khai thuế thu nhập cá nhân",
    deadline: "2026-08-15T23:59:00+07:00",
    lang: "vi",
    expectCueOnStep1: false,
    why: "only a deadline field is given (no sourceTranscript/notes at all) -- deadline is a due "
      + "date, never a cue source, so step 1 must stay bare",
  },
  {
    taskTitle: "Lên kế hoạch tổ chức tiệc sinh nhật cho công ty",
    lang: "vi",
    expectCueOnStep1: false,
    why: "a deliberately abstract-sounding title (\"lên kế hoạch\") -- checks the model doesn't just "
      + "echo the abstract verb from taskTitle into step 1, on top of the no-anchor guard",
  },
];

function splitCue(title: string): { cue?: string; action: string } {
  const idx = title.indexOf("→");
  if (idx === -1) return { action: title };
  return { cue: title.slice(0, idx).trim(), action: title.slice(idx + 1).trim() };
}

function startsWithAny(text: string, options: string[]): boolean {
  const lower = text.toLowerCase().trim();
  return options.some((opt) => lower.startsWith(opt));
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
    console.log(buildBreakdownContents({
      taskTitle: c.taskTitle,
      notes: c.notes,
      sourceTranscript: c.sourceTranscript,
      deadline: c.deadline,
    }));
    console.log(`\n\n(${CASES.length} cases defined; re-run with GEMINI_API_KEY set to probe live.)`);
    return;
  }

  if (!apiKey) {
    console.error(
      "GEMINI_API_KEY is not set.\n" +
        "  Live:    deno run --env-file=supabase/.env --allow-net --allow-env " +
        "supabase/scripts/probe-breakdown.ts\n" +
        "  Dry run: deno run --allow-env supabase/scripts/probe-breakdown.ts --dry-run",
    );
    Deno.exit(2);
  }

  console.log(`model: ${model}\n`);
  let pass = 0;
  let fail = 0;

  for (const [i, c] of CASES.entries()) {
    const label = `[${String(i + 1).padStart(2, "0")}] "${c.taskTitle}"`;
    try {
      const raw = await callGemini({
        apiKey,
        model,
        systemInstruction: SYSTEM_PREAMBLE,
        contents: buildBreakdownContents({
          taskTitle: c.taskTitle,
          notes: c.notes,
          sourceTranscript: c.sourceTranscript,
          deadline: c.deadline,
        }),
        responseSchema: buildBreakdownResponseSchema(),
        timeoutMs: 30000,
      });

      // Run through the SAME server-side validator the real route uses -- this probe can never
      // pass on a response the production path would have thrown out as invalid.
      const steps = validateBreakdownSteps(raw);
      const problems: string[] = [];

      if (!steps || steps.length === 0) {
        problems.push(`no valid steps returned (raw: ${JSON.stringify(raw).slice(0, 300)})`);
      } else {
        const step1 = steps[0];
        const { cue, action } = splitCue(step1.title);
        const hasCue = cue !== undefined && cue.length > 0;

        if (c.expectCueOnStep1 && !hasCue) {
          problems.push(`step1: expected a "<cue> → <action>" cue, got no cue at all: "${step1.title}"`);
        }
        if (!c.expectCueOnStep1 && hasCue) {
          problems.push(
            `step1: expected NO cue (no real anchor was given) but the model invented one: "${step1.title}"`,
          );
        }

        // Action-verb rule (applies regardless of whether a cue is present).
        if (!startsWithAny(action, ACTION_VERBS)) {
          problems.push(`step1 action does not open with a concrete action verb: "${action}"`);
        }
        if (startsWithAny(action, ABSTRACT_VERBS)) {
          problems.push(`step1 action opens with a bare abstract verb: "${action}"`);
        }
        if (CLOCK_HOUR_RE.test(step1.title)) {
          problems.push(`step1 contains a clock hour (forbidden, cue or otherwise): "${step1.title}"`);
        }

        // Language rule: spot-checked on step 1 only (the rule applies to every step, but step 1
        // is the one this probe already inspects closely for the cue/verb rules above).
        const hasDiacritics = VIETNAMESE_DIACRITIC_RE.test(step1.title);
        if (c.lang === "vi" && !hasDiacritics) {
          problems.push(`step1 language: expected Vietnamese, got no Vietnamese diacritics at all: "${step1.title}"`);
        }
        if (c.lang === "en" && hasDiacritics) {
          problems.push(`step1 language: expected English, but found Vietnamese diacritics: "${step1.title}"`);
        }

        if (steps.length < 3 || steps.length > 9) {
          problems.push(`step count ${steps.length} outside the contracted 3-9 range`);
        }
      }

      if (problems.length === 0) {
        pass++;
        const step1Title = steps![0].title;
        console.log(`PASS ${label}  ->  step1="${step1Title}" (${steps!.length} steps total)`);
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
