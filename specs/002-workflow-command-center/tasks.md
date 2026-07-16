# Tasks: Voci v2 — Voice-first Workflow Command Center

**Input**: Design documents from `/specs/002-workflow-command-center/`

**Prerequisites**: plan.md, spec.md (clarified), research.md (R1–R13), data-model.md, contracts/

**Tests**: Included ONLY where the constitution mandates them as release gates:
VociCore engine suite (Principle III) and reminder recovery paths (Principle IV).
Written FIRST and failing before implementation.

**Organization**: Release A = Phases 1–8 (ship gate: US1+US2+US3+US4+US6 per Clarification #1).
Release B/C = Phases 9–12. US5 is DEFERRED — no tasks. All work on branch `macos`.
Convention reminder: code is authored on Windows; every build/test checkpoint runs on the Mac
(quickstart.md) — mark risky API assumptions with `// UNVERIFIED` comments.

## Format: `[ID] [P?] [Story] Description`

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project-level plumbing every story needs

- [x] T001 Update `Voci/project.yml`: register `voci` URL scheme (CFBundleURLTypes), notification categories capability notes, add `Sources/Parsing`, `Sources/Reminders`, `Sources/Orchestrator` folders to sources
- [x] T002 Update `Voci/Resources/Voci.entitlements`: App Sandbox ON, `com.apple.security.network.client`, user-selected file read-write (security-scoped bookmarks); audit `Sources/` for sandbox breakage (custom background image path in `AmbientBackground.swift`/`SettingsView.swift` needs bookmark instead of raw path — per backlog 2026-07-13)
- [x] T003 [P] Replace `NSEvent.addGlobalMonitorForEvents` hotkey with Carbon `RegisterEventHotKey` in `Voci/Sources/Speech/HotkeyManager.swift` (sandbox-safe, no Accessibility — research R3); keep toggle semantics from commit ee75841
- [x] T004 [P] Scaffold `supabase/functions/` in-repo: `parse/index.ts` stub + shared auth util placeholder + README linking `contracts/parse-proxy.md`

**Checkpoint**: project generates (`xcodegen generate`) and builds on Mac with sandbox ON

---

## Phase 2: Foundational (Blocking Prerequisites — engine v2 + persistence v2)

**⚠️ CRITICAL**: Blocks ALL user stories. Test-first is constitutionally required here.

### Engine tests first (must fail before T009–T012)

- [x] T005 [P] Migrate §6.2 suite to conditions in `VociCore/Tests/VociCoreTests/NextTaskTests.swift` (dependsOn → `.taskDone`; all 001 cases preserved 1:1)
- [x] T006 [P] New eligibility tests in `VociCore/Tests/VociCoreTests/EligibilityTests.swift`: afterDate boundary (now == date ⇒ satisfied), external satisfied/unsatisfied, mixed-condition AND, parent-of-open-child exclusion, determinism-under-shuffle n=500
- [x] T007 [P] Condition-validation tests in `VociCore/Tests/VociCoreTests/DependencyGraphTests.swift`: cycle via `.taskDone` (direct/transitive/self), afterDate/external never throw
- [x] T008 [P] Snapshot-helper tests in `VociCore/Tests/VociCoreTests/SnapshotTests.swift`: `eligibilityDiff` (complete/uncomplete/external-flip), `nextResurfaceDate` (none/several/past-only)

### Engine implementation (contract: contracts/vocicore-api.md)

- [x] T009 Create `VociCore/Sources/VociCore/Condition.swift`: `Condition` enum + satisfaction rules (data-model.md engine layer)
- [x] T010 Rework `VociCore/Sources/VociCore/Task.swift`: drop `dependsOn`, add `conditions`, `estimateMinutes`, `parentId`
- [x] T011 Rework `VociCore/Sources/VociCore/NextTask.swift` (eligibility v2 incl. parent exclusion) and `DependencyGraph.swift` (`validateCondition` DFS over `.taskDone` edges only, same `DependencyError` messages)
- [x] T012 Create `VociCore/Sources/VociCore/Snapshots.swift`: pure `eligibilityDiff(before:after:now:)` + `nextResurfaceDate(in:after:)`

### Persistence v2

- [x] T013 Rework `Voci/Sources/Model/TaskItem.swift`: VociTask @Model v2 fields (notes, sourceTranscript, kind, recurrence, reminderOverride, resumeNote, switchAwayCount, completedAt, delegation, conditions storage, parentId) + snapshot mapping to `VociCore.Task` + SwiftData migration mapping legacy `dependsOn` → `.taskDone` conditions
- [x] T014 [P] Create `Voci/Sources/Model/CompletionLog.swift`: `CompletionEvent` @Model (immutable append), append-on-complete API, day/week/month rollup queries per FR-035
- [x] T015 [P] Create `Voci/Sources/Model/Recurrence.swift`: `Recurrence` enum + reset-in-place engine (schedule-anchored, completion-moment re-anchor override — R8) + leaf-only validation
- [x] T016 Enforce persistence validation rules 1–6 of data-model.md in `Voci/Sources/Model/TaskStore.swift` (cycle check via engine, recurrence-leaf rule, parentId integrity, delete-cascade stripping `.taskDone` refs + one-time unblock notify flag, parent auto-complete, 10-task batch cap)

**Checkpoint**: `swift build && swift test` green in VociCore on Mac; app builds; legacy data migrates
> STATUS 2026-07-16: T001–T016 code-complete (4 parallel Sonnet agents) + Opus full-diff review (0 ship-blocker) + fixes applied (calendar injection, AppState↔store sync, lenient decode, quota 50). Commits after `b0e90ed`. **Mac build/test NOT yet run** — this checkpoint is the immediate next action (highest compile risk: Carbon hotkey, SwiftData migration). `[~]` = partially done.

---

## Phase 3: User Story 1 — Structured voice capture on the unified model (P1) 🎯 MVP

**Goal**: One utterance → fully structured task(s) via confirm chips; nothing guessed.

**Independent Test**: quickstart §3 — spoken utterance produces exactly the spoken attributes; dependency/defer/external/review/recurrence phrasings all land; cycle rejected with readable message.

- [x] T017 [US1] Extend `ParsedTask` in `Voci/Sources/Model/NLParser.swift`: v2 shape per data-model.md (conditions with confidence, estimateMinutes, recurrence, reminderOverride, kind, subtasks, followUpReview; max 10 tasks)
- [x] T018 [US1] Extend `HeuristicNLParser` in `Voci/Sources/Model/NLParser.swift`: resolve real `Date` deadlines (closes backlog "deadline: nil" item), defer phrases → `.afterDate`, "sau khi/xong A thì" → `.taskDone` candidate by fuzzy title, "chờ/đợi X" → `.external`, estimate phrases, recurrence phrases, reminder-override phrases
- [x] T019 [P] [US1] Create `Voci/Sources/Parsing/IntentParsing.swift`: protocol + router FM → Cloud (opt-in + online + quota) → Heuristic (R5); shared `ParsedTask` validation + title-only fallback (constitution II)
- [x] T020 [P] [US1] Create `Voci/Sources/Parsing/FoundationModelParser.swift`: `#available(macOS 26)` @Generable guided generation, capability probe, `// UNVERIFIED` markers for FM API surface
- [x] T021 [P] [US1] Create `Voci/Sources/Parsing/CloudParser.swift`: `/functions/v1/parse` client per contracts/parse-proxy.md — JWS or DeviceCheck auth headers, 429→typed quota fallback, text-only payload, ≤100 open-task titles only when dependency phrasing detected
- [~] T022 [US1] Implement `supabase/functions/parse/index.ts`: JWS/DeviceCheck verification, per-device daily counter (Postgres), Gemini Flash call with JSON-schema output, 10-task cap, no transcript logging (contract obligations 1–5) — PARTIAL: code + migration + README done and Opus-reviewed (paid JWS path + quota + Gemini + hardening all present); free-tier App Attest key store is stubbed (fails closed 503) → completing it needs an `/attest/register` endpoint + key table (backlog, not blocking since client T021 not built yet)
- [x] T023 [US1] Add DeviceCheck token generation in `Voci/Sources/Parsing/DeviceCheckProvider.swift` (DCDevice; graceful nil on unsupported/simulator → heuristic)
- [x] T024 [US1] Rework confirm card in `Voci/Sources/Views/PopoverView.swift`: chips v2 for all attributes, uncertain (<0.7) dashed chips, dependency picker instead of auto-attach, multi-task confirm (≤10), one-time cloud-parse opt-in sheet
- [x] T025 [US1] Wire `AppState.confirmSave()` in `Voci/Sources/App/AppState.swift`: materialize tasks + conditions + review follow-ups through TaskStore validation; persist `sourceTranscript` always
- [x] T026 [P] [US1] Create `Voci/Sources/Model/ParseCorrection.swift`: @Model correction log (attribute, parsed, corrected, transcript) + hook into chip edits (FR-044, local-only)

**Checkpoint**: US1 fully functional — capture by voice/type works on all three parser routes

---

## Phase 4: User Story 2 — Never miss: reliable actionable reminders (P1)

**Goal**: Constitution-IV reminder engine with escalation, actions, recovery, unblock/resurface/overdue flows.

**Independent Test**: quickstart §4 — reminders fire across restart/sleep exactly once with working action buttons; completed tasks stay silent.

### Recovery tests first (constitution IV)

- [ ] T027 [P] [US2] Reminder recovery tests in `Voci/Tests/ReminderSchedulerTests.swift` (new XCTest target in `Voci/project.yml`): rebuild-from-storage on launch, overdue-while-closed fires once, done-task suppression, policy escalation offsets, nearest-N refill under the 64-request cap

### Implementation

- [ ] T028 [US2] Create `Voci/Sources/Model/ReminderRecord.swift`: @Model per data-model.md + derivation from task deadline × (global policy | reminderOverride)
- [ ] T029 [US2] Create `Voci/Sources/Reminders/ReminderScheduler.swift`: storage-rebuilt scheduler, launch + `NSWorkspace.didWakeNotification` recovery, fire-time fresh reload & suppression, nearest-N windowing (R2)
- [ ] T030 [US2] Create `Voci/Sources/Reminders/NotificationActions.swift`: UNNotificationCategory set — deadline (Done/Snooze 10m/Tomorrow), unblocked-ready, overdue-reschedule (tonight/tomorrow/weekend); delegate routes actions to TaskStore mutations without opening the window (FR-014/015/016)
- [ ] T031 [US2] Wire auto-unblock notifications in `Voci/Sources/App/AppState.swift`: run `eligibilityDiff` after every mutation → "X is now ready" notification per newly eligible task
- [ ] T032 [US2] Wire afterDate resurfacing: schedule a timer/notification at `nextResurfaceDate` (no polling), refresh menu bar on fire (FR-017)
- [ ] T033 [US2] Add global `ReminderPolicy` defaults + editor row in `Voci/Sources/Views/SettingsView.swift`; replace `AppDelegate` "auth-only" notification setup with category registration in `Voci/Sources/App/VociApp.swift`
- [ ] T034 [US2] Implement stale-task weekly triage batch card (keep/break down/defer/drop, no badges) in `Voci/Sources/Views/TriageView.swift` + scheduling in AppState (FR-018)

**Checkpoint**: US2 independently testable — the app's reminder promise is real

---

## Phase 5: User Story 3 — Complete and advance by voice (P1)

**Goal**: Speak to finish; instant auto-advance; evening sweep harvest.

**Independent Test**: quickstart §5 — fuzzy match with disambiguation, never silent; sweep batch-completes by voice.

- [ ] T035 [P] [US3] Create `Voci/Sources/Speech/VoiceDone.swift`: Vietnamese-aware normalization + token-set fuzzy scorer over open tasks + thresholds (single-confirm / disambiguate / none) — R6; same path clears `.external` descriptions
- [ ] T036 [US3] Route completion/clear intents in `AppState` capture pipeline (detect done-phrasing before treating an utterance as new-task capture); one-word/one-tap confirm UI in `PopoverView.swift`
- [ ] T037 [US3] Harden auto-advance in `Voci/Sources/App/AppState.swift` + `Voci/Sources/Views/MenuBarLabel.swift`: completion (any source — voice, notification action, UI) recomputes `nextTask` and updates menu bar with no intermediate empty/list state (FR-020)
- [ ] T038 [US3] Create evening sweep flow in `Voci/Sources/Views/SweepView.swift` + AppState scheduling (once daily, skip-if-empty): today's open tasks read back, voice/one-tap batch completion → CompletionEvents (FR-021)

**Checkpoint**: speak-to-create AND speak-to-finish both work — the core loop closes

---

## Phase 6: User Story 4 — Delegate to AI without losing loops (P2)

**Goal**: Orchestrator layer — delegation state, ambient check-backs, WIP counter, one-button Claude Code connect.

**Independent Test**: quickstart §6 — full delegate → signal/timer → needs-review → done cycle including hook install/uninstall and idempotent signals.

- [ ] T039 [P] [US4] Create `Voci/Sources/Orchestrator/DelegationTracker.swift`: `DelegationMeta` lifecycle, delegate action (external condition + meta + advance), minute-scale check-back scheduling, backoff 10′→30′→batch, batch-reconcile card assembly, WIP count (R9)
- [ ] T040 [P] [US4] Create `Voci/Sources/Orchestrator/AppLinkHandler.swift`: `onOpenURL` routing per contracts/app-links.md — `ai-done` matching ladder (single-waiting → cwd hint → disambiguation card; idempotent; never completes) + `capture` path into the parser pipeline
- [ ] T041 [US4] Create `Voci/Sources/Orchestrator/ClaudeCodeConnector.swift`: detect `~/.claude`, security-scoped bookmark grant, preview sheet, timestamped backup, additive JSON merge into `hooks.Stop` (marker `voci://`), test-signal round-trip, disconnect removing only marker entries (contract in app-links.md)
- [ ] T042 [US4] Delegation voice intents ("giao cho Claude rồi", "check sau 10 phút") in the capture pipeline + delegate button on current task in `Voci/Sources/Views/TodayView.swift`
- [ ] T043 [US4] WIP counter on `MenuBarLabel.swift` ("⏳ N") + soft-limit dismissible hint (>4) + needs-review ambient section and [Done][Still waiting][Check later] card in `PopoverView.swift`/`TodayView.swift`
- [ ] T044 [US4] "Connect Claude Code" section in `SettingsView.swift` (detect/connect/test/disconnect states) + copy-config fallback

**Checkpoint**: orchestrator loop closes minus typing-back (deferred US5)

---

## Phase 7: User Story 6 — Breakdown, đổi gió, adapted focus, panic (P2)

**Goal**: Survive long/boring tasks; protect flow; escape overwhelm.

**Independent Test**: quickstart §7.

- [ ] T045 [P] [US6] Rework `Voci/Sources/Views/TaskBreakdownView.swift`: real breakdown of the invoked task (replace hardcoded sample — closes backlog item), steps editable, save → chained children via `.taskDone` + `parentId` through TaskStore; AI draft via `IntentParsing` breakdown mode with template fallback (FR-029)
- [ ] T046 [P] [US6] Đổi gió: "switch" voice intent + button → offer exactly one alternative (`nextTask` on snapshot minus current), preserve context, `switchAwayCount` increment, ≥3 → one-time breakdown suggestion (FR-030) — in `AppState.swift` + `TodayView.swift`
- [ ] T047 [US6] Focus session v2 in `Voci/Sources/Views/FocusOverlay.swift` + AppState: default 25′ configurable, non-blocking end prompt defaulting to continue, 90′ firm nudge, estimate-vs-elapsed line + gentle over-estimate prompt (FR-031)
- [ ] T048 [P] [US6] Panic mode: voice/click entry → single ≤5′ task view hiding all counters, explicit exit — `Voci/Sources/Views/PanicView.swift` + AppState flag (FR-032)
- [ ] T049 [US6] Quick-win prompt: "what now in N minutes" intent surfaces smallest-estimate eligible task (FR-033) in AppState + PopoverView
- [ ] T050 [US6] Re-entry context: resume-note prompt on switch/day-end (never forced) + display on task surface (FR-042 subset needed by US6; full story in Phase 11)

**Checkpoint**: 🚢 **RELEASE A GATE** — quickstart §1–§8 all pass on Mac + SC-009 privacy audit

---

## Phase 8: Release A hardening & monetization plumbing

**Purpose**: Ship-blockers for the P1+P2 release that cross stories

- [ ] T051 StoreKit 2 purchase/restore flow + entitlement cache in `Voci/Sources/Model/Entitlements.swift` + Settings purchase section — per docs/product-vision-v2.md Freemium v2 (đã duyệt 2026-07-15): intro offer trial 14 ngày full Pro (chốt); gates: Groq speech, unmetered cloud parse, meeting ingestion (Pro-only), AI weekly narrative, accomplishment history >30 ngày + view tháng, theme/soundscape pack; free giữ: vòng lõi + orchestrator + juice + export; quota free ~20–25/ngày hiện đếm ("còn N lượt AI hôm nay") — giá trị server-tunable; đề xuất giá $4.99/mo · $39.99/yr (VN 99k/799k), không lifetime lúc launch
- [ ] T052 [P] Deploy + configure `supabase/functions/parse` (secrets: provider key; env: quota) and verify 429 fallback end-to-end per quickstart §8
- [ ] T053 [P] App Store privacy label worksheet in `docs/app-store-privacy.md`: Audio Data (Groq path), transcript egress (cloud parse opt-in), DeviceCheck usage — consolidates backlog privacy-label items
- [ ] T054 Run `/speckit-constitution` amendment per plan Complexity Tracking (Principle I gate wording; Technology Constraints platform/ASR/hotkey; recurrence scope note)
- [ ] T055 Mac verification pass: full quickstart.md §1–§9 on Apple Silicon + one Intel/macOS 14 machine; file follow-ups to backlog.md

---

## Phase 9: User Story 7 — Rituals & accomplishment view (P3, Release B)

**Independent Test**: spec US7 scenarios (rollup rules, positive-only audit).

- [ ] T056 [P] [US7] Accomplishment view (session/day/week/month, việc·bước units, rollup per FR-035) in `Voci/Sources/Views/AccomplishmentsView.swift` over CompletionLog queries
- [ ] T057 [US7] Morning-frog wiring to engine favoring + evening sweep bookend polish (skip-if-empty) in AppState/`MorningFrogView.swift` (FR-034)
- [ ] T058 [P] [US7] Restrained micro-reward + variable-subtlety effect + milestone theme/soundscape unlocks (flat value) in `Voci/Sources/Views/Components.swift`/Theme (FR-036, professional skin)
- [ ] T059 [P] [US7] Weekly narrative (FM route / template fallback) in `Voci/Sources/Model/WeeklyNarrative.swift` (FR-037)

## Phase 10: User Story 8 — Calendar awareness (P3, Release B)

- [ ] T060 [US8] EventKit read-only service (`Voci/Sources/Model/CalendarService.swift`): busy blocks, effective-deadline shift, gap sizing, graceful denial (FR-038, R11)
- [ ] T061 [US8] Transition warning notification (10′ pre-event, once) via ReminderScheduler + surfacing effective deadline reason in TodayView

## Phase 11: User Story 9 — Capture at scale, voice query, resume notes (P3, Release B)

- [ ] T062 [P] [US9] Meeting/voice-memo ingestion: file drop → speech engine (on-device free / Groq paid) → action-item extraction via parser router → bulk confirm cards (FR-039) in `Voci/Sources/Views/IngestView.swift`
- [ ] T063 [P] [US9] System-wide capture: macOS Services entry + `voci://capture` handling with source reference (FR-040)
- [ ] T064 [US9] Voice query intents (today/week, waiting-on-AI, stuck-longest, waiting-on-whom) answered from snapshot + spoken/visual reply (FR-041) in AppState + PopoverView
- [ ] T065 [US9] Resume notes full story: exit prompts + next-surface display + morning continuity line (FR-042)

## Phase 12: User Story 10 — Own the data (P4, Release C)

- [ ] T066 [P] [US10] Export/backup to open JSON (+Markdown digest) incl. transcripts + completion history in `Voci/Sources/Model/Exporter.swift` (FR-043)
- [ ] T067 [US10] Full-text search across titles/notes/transcripts in TodayView search field (FR-043)

---

## Phase 13: Polish & Cross-Cutting

- [ ] T068 [P] Update `VociCore/README.md` + `Voci/README.md` for v2 API/architecture (also closes backlog T018-001 item)
- [ ] T069 [P] Positive-only audit sweep: every surface checked against FR-016/FR-036 (no red badges, no negative comparisons)
- [ ] T070 Performance check: engine at n=500 and CompletionLog rollups at 10⁴ events; fix hot spots
- [ ] T071 Mark absorbed backlog items done in `backlog.md` (FR-013 delete-cascade, NLParser real dates, breakdown stub, model-v1 refactor umbrella) and file new follow-ups discovered during Mac verification

---

## Dependencies & Execution Order

- **Phase 1 → 2**: Setup precedes foundation. **Phase 2 blocks everything** (engine + persistence v2).
- **Release A stories after Phase 2**: US1 (Phase 3) unblocks the richest flows but US2 (Phase 4) and US6-đổi-gió parts depend only on Phase 2 — US2, US3, US4, US6 can proceed in parallel once Phase 2 lands; US3's voice-done needs US1's intent routing hooks (T036 after T019); US4's capture-intents (T042) after T019; T045 AI-draft needs T019 (template fallback allows earlier landing).
- **Phase 8 gate** requires Phases 3–7 complete; T054 (constitution) can run any time after plan approval; T051/T052 can start once T021/T022 exist.
- **Release B/C phases** independent of each other; all require Phase 2; US7 requires CompletionLog (T014).

### Parallel opportunities

- T005–T008 (four test files) together; T009–T012 sequential-ish (same package, small); T013–T015 in parallel after T009–T012.
- After Phase 2: one agent per story-phase (3,4,5,6,7) is the natural fan-out; within phases, [P]-marked tasks are file-disjoint.

## Implementation Strategy

MVP = Phase 1+2+3 (US1): capture on the new model proves the architecture end-to-end
(engine, migration, parser router, chips). Then US2 (the product promise), US3 (closes the
loop), US4+US6, then the Phase 8 gate. Per project convention every phase ends with a Mac
build/test checkpoint before the next begins; each checkpoint's failures go to backlog.md
in-session. Suggested execution: Fable writes per-phase instructions; Sonnet 5 executes
(global brain/hands rule); commit after each phase checkpoint.
