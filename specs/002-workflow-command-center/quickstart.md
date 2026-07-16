# Quickstart Validation: Volar v2 — Workflow Command Center

Validation guide for the P1+P2 release boundary. Environment note: code is authored on
Windows; **every step below runs on the Mac** (build/test split per project convention).

## Prerequisites

- Mac (Apple Silicon for WhisperKit paths; any Mac for the rest), Xcode 15+ (macOS 14 SDK).
- `xcodegen` installed. Optional for cloud-parse checks: Supabase project with `/parse`
  deployed and env configured.
- Optional for orchestrator checks: Claude Code installed (`~/.claude/` exists).

## 1. Engine gate (fastest signal — pure Swift, no app)

```bash
cd VolarCore && swift build && swift test
```

**Expected**: all tests green, including migrated §6.2 cases (now condition-based) and the new
suites — afterDate boundary, external toggling, mixed-condition AND, parent exclusion,
eligibilityDiff, nextResurfaceDate, determinism-under-shuffle. Any red here blocks everything
(constitution III release gate). Contract: `contracts/volarcore-api.md`.

## 2. App build + model migration

```bash
cd Volar && xcodegen generate && open Volar.xcodeproj   # build & run target "Volar"
```

**Expected**: existing 001-era tasks load with `dependsOn` migrated into `.taskDone`
conditions; no data loss; board renders.

## 3. Structured capture (US1)

Speak: *"gửi hợp đồng sau khi xong bản nháp, chờ client ký NDA, nhắc mỗi 30 phút, chắc mất
một tiếng"*.
**Expected**: confirm card shows chips — taskDone(bản nháp) [picker if uncertain],
external("client ký NDA"), reminder override 30′, estimate 60′; unspoken fields empty;
Enter saves; task blocked (not on menu bar). Complete the draft task → US1 scenario 2:
contract task becomes eligible; a "ready" notification arrives (FR-015).

## 4. Reminders survive restarts (US2)

Create a task due in ~3 minutes with a test policy → quit the app entirely → relaunch after
the fire time.
**Expected**: notification fired (or fires immediately on recovery), with Done/Snooze/Tomorrow
buttons; tapping Done completes the task, logs a CompletionEvent, menu bar advances — app
window never opened. Completing a task before its reminder → silence.

## 5. Voice done + evening sweep (US3)

Say *"xong cái hợp đồng rồi"* with 2 similar contract tasks open.
**Expected**: disambiguation card (never a silent pick); confirm → done + instant auto-advance.
Trigger evening sweep with ≥2 open tasks → answer by voice → batch completion, all in today's
accomplishments.

## 6. Orchestrator loop (US4)

1. Settings → "Connect Claude Code" → grant `~/.claude` folder (2 clicks) → preview → confirm
   → **Expected**: hook appended (verify `settings.json` — existing hooks untouched, backup
   file present), test signal round-trips ("✓ received").
2. Delegate an active task by voice ("giao cho Claude rồi") → **Expected**: task leaves menu
   bar, next task appears, WIP counter "⏳ 1".
3. In a terminal in the project folder run any Claude Code session to completion (or simulate:
   `open "volar://ai-done?cwd=$PWD"`) → **Expected**: task flips to needs-review ambient card;
   counter decrements; duplicate signal = no-op.
4. Let a second delegated task's 10′ timer elapse instead → **Expected**: ambient resurface
   (menu bar only — no system notification), [Done][Still waiting][Check later]; ignore twice
   → folds into batch reconciliation at next popover open.

## 7. Breakdown / đổi gió / panic (US6)

Break a large task → **Expected**: 5–15′ steps chained under parent, first step trivial;
finishing last step auto-completes parent (one accomplishment line, not eight). Say "đổi gió"
mid-task → exactly one alternative offered; switch 3× on the same task → one-time breakdown
suggestion. Panic command → single ≤5′ task fills the view.

## 8. Parse routing + quota (FR-012)

On macOS 26 machine: airplane-mode OFF network, capture → **Expected**: FM parses (no network
egress — verify with a proxy/Little Snitch: zero calls). On macOS 14 machine with opt-in:
capture → one `/parse` call (text only — inspect payload); decline opt-in or go offline →
heuristic silently. Exceed the daily quota (server env set low for testing) → typed 429 →
heuristic + one gentle note; task still created. Any utterance producing >10 tasks is
truncated at 10 with a note.

## 9. Privacy audit (SC-009, release checklist)

Network-inspect a full free-tier session (capture, reminders, delegation, accomplishments):
**Expected**: zero audio bytes egress anywhere; zero transcript egress unless cloud-parse
opt-in is on; `/parse` payloads contain text only.

## Cross-references

- Data shapes: `data-model.md` · Engine API: `contracts/volarcore-api.md`
- Signals & hook install: `contracts/app-links.md` · Cloud route: `contracts/parse-proxy.md`
- Acceptance criteria per story: `spec.md` (§User Scenarios)
