# Implementation Plan: Volar v2 — Voice-first Workflow Command Center

**Branch**: `macos` (project convention — no feature branches) | **Date**: 2026-07-15 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/002-workflow-command-center/spec.md`
(clarified 2026-07-15, 5 questions + 3 mid-session user directions integrated)

## Summary

Volar v2 pivots the product from "voice to-do app" to a voice-first workflow command center:
(1) a unified task model where a single `conditions: [Condition]` list
(taskDone / afterDate / external) gates eligibility while `deadline` keeps driving urgency;
(2) an ADHD automation layer — reliable escalating reminders with actionable notifications,
voice completion with auto-advance, rituals, breakdown, structured switching; (3) an AI-agent
orchestrator — delegation tracking with ambient minute-scale check-backs, WIP awareness, and a
one-button Claude Code integration over a sandbox-safe `volar://` app link. First shippable
release = user stories P1+P2. Distribution is Mac App Store-first (sandbox + StoreKit), which
defers terminal-typing (US5) and mandates a sandbox-safe hotkey. Intent parsing routes
on-device Foundation Models → free metered cloud parse (opt-in, DeviceCheck-metered, Gemini
behind the existing Supabase proxy) → heuristic parser. The pure engine work stays in
`VolarCore` and remains the constitution-III release gate.

## Technical Context

**Language/Version**: Swift 6.x (strict concurrency), SwiftUI, targeting macOS 14 SDK floor
with `#available(macOS 26)` conditional paths (FoundationModels). Xcode 15+ builds; Xcode 26
required only to exercise FM paths.

**Primary Dependencies**: VolarCore (internal, dependency-free) · SwiftData · UserNotifications ·
EventKit (P3) · StoreKit 2 + DeviceCheck (quota/entitlement) · WhisperKit (existing, arm64-gated)
· Carbon `RegisterEventHotKey` (sandbox-safe hotkey) · Supabase Edge Functions (Deno) for
`/groq` (existing plan) + `/parse` (new) — provider keys server-side (initial parse provider:
Gemini Flash, swappable).

**Storage**: SwiftData — `VolarTask` (extended), `CompletionEvent` (append-only),
`ReminderRecord`, `ParseCorrection`; `UserDefaults` for settings/policies; security-scoped
bookmark for `~/.claude`. Postgres (Supabase) server-side for free-quota counters only.

**Testing**: Swift Testing for `VolarCore` (release gate, extended suite per
`contracts/volarcore-api.md`); XCTest for app-layer units (reminder recovery, migration,
matching, hook merge); manual validation script `quickstart.md` on the Mac (Windows/Mac
split: code authored on Windows ships unverified until Mac run).

**Target Platform**: macOS 14+ (Sonoma), Apple Silicon + Intel; AI features conditionally
enabled (FM: macOS 26 + Apple Silicon; WhisperKit: arm64). Mac App Store distribution:
App Sandbox ON, no Accessibility-dependent paths.

**Project Type**: Single desktop app (menu-bar-first) + internal Swift package + minimal
serverless backend routes.

**Performance Goals**: `nextTask()` well under 1 ms at hundreds of tasks (unchanged);
capture-to-board ≤5 s of user effort; notification actions mutate state without app launch;
zero polling loops (scheduling is event/date-driven).

**Constraints**: Pure deterministic engine (constitution III); audio never leaves device;
transcript text leaves only on opted-in cloud-parse path; sandbox-compatible everything;
notification requests ≤64 pending (schedule nearest-N, refill on launch/delivery); no accounts.

**Scale/Scope**: Single user, low hundreds of active tasks, completion log growing to ~10⁴
events/year (SwiftData fine); backend QPS negligible (personal-capture rates), quota 50/day/device.

## Constitution Check

*GATE evaluated pre-Phase-0 and re-checked post-Phase-1.*

| Principle | Assessment |
|---|---|
| I. On-Device Privacy First (NON-NEG) | PASS with one **amendment required**: cloud-parse tier gate changes from "AI Pro AND opt-in" to "any tier AND opt-in, free tier metered" (user direction 2026-07-15). Text-only egress, audio-never, opt-in, and documented-egress clauses all preserved. Groq speech stays paid+consent. R13 tracks the amendment. |
| II. Never Silently Guess | PASS by design: confirm chips for every parsed attribute; <0.7 confidence → uncertain chip / picker (dependencies never auto-attach); voice-done and signal matching always disambiguate; raw LLM output decoded into validated `ParsedTask` with title-only fallback; agent signals can never complete tasks. |
| III. Deterministic, Pure, Test-Gated Core (NON-NEG) | PASS: engine stays pure; `dependsOn` generalizes to `.taskDone` edges with identical DAG invariant + DFS rejection; §6.2 suite migrates 1:1 and extends (afterDate/external/parent/diff cases); suite remains the release gate. New helpers (`eligibilityDiff`, `nextResurfaceDate`) are pure. |
| IV. Reliable Reminder Delivery | PASS — this feature finally implements it: durable `ReminderRecord`s, scheduler rebuilt from storage on launch/wake, fire-time fresh reload with satisfied-suppression, recovery paths covered by automated tests (quickstart §4). |
| V. ADHD-First, Glance-and-Dismiss | PASS: single-task menu bar + auto-advance untouched; chips-not-forms; rituals are batch, ambient, skippable; anti-shame rules are FRs (FR-016/018/036); corrections logged locally (FR-044/`ParseCorrection`). |

**Deviations needing governance action (not principle violations)** — see Complexity Tracking:
constitution Technology Constraints name macOS 26+/SpeechAnalyzer-first and "recurring stays
out of v1"; clarified reality is macOS 14 floor, WhisperKit/Groq ASR, recurrence in v2 scope.

**Post-Phase-1 re-check**: design artifacts introduce no new egress, no impurity, no
decision-adding UI; sandbox constraint traced through hotkey (R3), hook install (R4), and
app-link contracts. Gate remains PASS.

## Project Structure

### Documentation (this feature)

```text
specs/002-workflow-command-center/
├── plan.md              # This file
├── research.md          # Phase 0 — 13 resolved decisions (R1–R13)
├── data-model.md        # Phase 1 — engine + persisted layers, validation rules
├── quickstart.md        # Phase 1 — Mac-side validation guide (P1+P2 release)
├── contracts/
│   ├── volarcore-api.md  # Engine public API v2 + test-suite contract
│   ├── app-links.md     # volar:// inbound signals + Claude Code hook install contract
│   └── parse-proxy.md   # /functions/v1/parse request/response/metering contract
├── checklists/requirements.md
└── spec.md              # Clarified specification
```

### Source Code (repository root)

```text
VolarCore/                                  # Pure engine (extend in place)
├── Sources/VolarCore/
│   ├── Task.swift                         # + conditions, estimateMinutes, parentId (drop dependsOn)
│   ├── Condition.swift                    # NEW: Condition enum + satisfaction rules
│   ├── NextTask.swift                     # eligibility v2 (conditions, parent exclusion)
│   ├── DependencyGraph.swift              # validateCondition (DFS over .taskDone edges)
│   └── Snapshots.swift                    # NEW: eligibilityDiff, nextResurfaceDate
└── Tests/VolarCoreTests/                   # migrated §6.2 + new suites (see contract)

Volar/                                      # App target (SwiftUI + SwiftData, sandboxed)
├── Sources/
│   ├── Model/
│   │   ├── TaskItem.swift                 # VolarTask @Model v2 + migration from dependsOn
│   │   ├── CompletionLog.swift            # NEW: CompletionEvent + queries/rollups
│   │   ├── Recurrence.swift               # NEW: reset-in-place engine (app layer)
│   │   └── NLParser.swift                 # ParsedTask v2; heuristic parser extensions
│   ├── Parsing/                           # NEW: IntentParsing router
│   │   ├── IntentParsing.swift            # protocol + router (FM → cloud → heuristic)
│   │   ├── FoundationModelParser.swift    # #available(macOS 26) @Generable
│   │   └── CloudParser.swift              # /parse client, DeviceCheck/JWS auth, 429→fallback
│   ├── Reminders/                         # NEW: constitution-IV engine
│   │   ├── ReminderScheduler.swift        # rebuild-from-storage, nearest-N, wake recovery
│   │   └── NotificationActions.swift      # categories: Done/Snooze/Tomorrow, ready, reschedule
│   ├── Orchestrator/                      # NEW
│   │   ├── DelegationTracker.swift        # DelegationMeta, backoff, WIP counter, batch reconcile
│   │   ├── AppLinkHandler.swift           # volar://ai-done, volar://capture (onOpenURL)
│   │   └── ClaudeCodeConnector.swift      # detect, preview, backup, merge, test, disconnect
│   ├── Speech/…                           # existing engines; VoiceDone matcher added
│   ├── Views/…                            # confirm chips v2, sweep, triage, accomplishments,
│   │                                      #   đổi gió, panic, WIP badge, Settings sections
│   └── App/AppState.swift                 # wiring: auto-advance, diff→notify, focus/session
├── Resources/Volar.entitlements            # sandbox + network client + bookmarks
└── project.yml                            # URL scheme, notification categories, capabilities

supabase/                                  # NEW (backend routes; deployed separately)
└── functions/
    ├── groq/                              # existing plan (speech proxy)
    └── parse/                             # NEW per contracts/parse-proxy.md
```

**Structure Decision**: Extend the existing two-layer layout (pure `VolarCore` + app target)
rather than adding modules — the engine delta is small and the constitution-III boundary is
already correct. New app concerns get dedicated folders (`Parsing/`, `Reminders/`,
`Orchestrator/`) to keep review surfaces separable. Backend stays a thin serverless appendix
in-repo for versioning, deployed to the already-planned Supabase project.

## Delivery phasing (release boundary from Clarification #1)

- **Release A (ship gate = P1+P2)**:
  A1 model+engine (US1) → A2 reminders (US2) → A3 voice-done/advance/sweep (US3) →
  A4 orchestrator + Claude Code connect (US4) → A5 breakdown/đổi gió/focus/panic (US6) →
  A6 parse router + proxy + quota (FR-012). Each step lands with its tests; A1 blocks all.
- **Release B (P3)**: rituals/accomplishment view/narrative (US7), calendar (US8),
  capture-at-scale + voice query + resume notes (US9).
- **Release C (P4)**: export/backup + search (US10).
- **Deferred**: US5 terminal typing (post-v2, Developer-ID-build decision); v3 items per spec.

## Complexity Tracking

| Violation / deviation | Why needed | Simpler alternative rejected because |
|---|---|---|
| Constitution amendment: Principle I cloud-parse gate wording (paid-only → any-tier metered, opt-in retained) | User direction 2026-07-15 — hardware-based paywall deemed discriminatory; free tier gets metered cloud parse | Keeping paid-only contradicts product owner's explicit decision; silent divergence from constitution is worse than a tracked amendment (R13) |
| Constitution amendment: Technology Constraints (macOS 26+/SpeechAnalyzer wording vs decided macOS 14 floor + WhisperKit/Groq + sandbox-safe hotkey; recurrence now in scope) | Clarifications #2/#3 + shipped speech-engine decisions | Raising the floor to 26 rejected in clarify; constitution must follow decided reality via formal amendment, tracked in backlog |
| DeviceCheck dependency (new Apple service + server verification) despite "Option 1 gọn — no DeviceCheck" freemium decision | Free metered cloud parse needs abuse-resistant per-device counting without accounts | Client-side counters trivially reset by reinstall; per-IP unfair behind NAT; accounts explicitly excluded by freemium decision |
