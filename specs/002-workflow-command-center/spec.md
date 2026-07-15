# Feature Specification: Voci v2 — Voice-first Workflow Command Center

**Feature Branch**: `002-workflow-command-center` *(spec label only — all work happens on the `macos` branch; no feature branch is created)*

**Created**: 2026-07-15

**Status**: Draft

**Input**: User description: "Voci v2 — nâng cấp từ voice to-do app thành trung tâm chỉ huy công việc bằng giọng nói cho kỷ nguyên AI, theo các quyết định đã chốt trong docs/task-model-v1.md, docs/adhd-automation-v1.md, docs/product-vision-v2.md: task model thống nhất quanh conditions[], tầng automation ADHD, chế độ orchestrator AI, và các tính năng Vision Tier 1+2 đã duyệt."

**Source documents** (decision record, authoritative for design intent):
`docs/task-model-v1.md` · `docs/adhd-automation-v1.md` · `docs/product-vision-v2.md`

## Clarifications

### Session 2026-07-15

- Q: What is the first shippable release boundary of v2? → A: P1 + P2 together — the first release includes the unified task model, reliable reminders, voice completion, AI-delegation orchestrator, terminal voice-reply, and focus/breakdown/switching. P3–P4 stories follow in subsequent releases.
- Q: What is the macOS platform floor for v2? → A: Keep macOS 14+; on-device AI capabilities (smart parsing, AI breakdown, generated weekly narrative) activate conditionally on supported OS/hardware, with the heuristic parser and templates serving older systems. The constitution's platform wording is to be amended to match.
- Q: (User direction, mid-session) → A: Reserved explicitly for v3+: cloud sync with multi-device reminders, and teamwork features (collecting tasks from a team and automatically resolving them). Confirmed out of scope for v2.
- Q: Distribution channel for v2 (affects terminal voice-reply and payments)? → A: Mac App Store first — sandbox + StoreKit per the existing freemium plan. Typing-into-terminal (User Story 5) is deferred far beyond v2; only the sandbox-compatible agent-completion signal (inbound app-link + one-button hook connect) ships in v2. All v2 features must be sandbox-compatible (no Accessibility-dependent core paths).
- Q: When a recurring task is completed late, when is the next occurrence due? → A: Default anchors to the original schedule (weekly-Monday stays Monday). At completion time only, the user may say/tap to anchor this cycle from the completion date instead ("next one from today"). Never asked at capture time.
- Q: Is cloud AI parsing/breakdown in v2 scope? → A: Yes, as a routed fallback chain: (1) on-device AI where the OS/hardware supports it — all tiers; (2) otherwise cloud text-only parsing (candidate provider: Gemini Flash behind the existing server proxy — provider swappable, key never on client); (3) otherwise the heuristic parser. Audio never goes to the parsing service.
- Q: (User direction, mid-session) Should cloud parsing be paid-only? → A: No — hardware-based paywalls feel discriminatory. Cloud parse-to-task is FREE for everyone with: one-time explicit privacy opt-in (text leaves device — required regardless of price), a per-device daily quota (default 50 cloud parses/day, server-tunable, enforced via Apple device attestation since there are no accounts), and a cap of 10 tasks created per utterance (all tiers, UX sanity). Exceeding quota falls back to the heuristic parser with a gentle note — task creation is never blocked. Paid tier: premium speech accuracy + unmetered cloud parsing.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Structured voice capture on the unified task model (Priority: P1)

A professional speaks one sentence — *"Send the contract after I finish the draft, but wait until the client signs the NDA; remind me every 30 minutes, should take about an hour"* — and a single task appears on the board carrying a dependency on the draft task, an external waiting-condition ("client signs NDA"), a reminder override, and a one-hour estimate. Attributes the user did not say are simply absent; nothing is guessed. Speaking a deferral ("start Monday") hides the task until Monday. Speaking a recurring chore ("every morning") makes it repeat. Speaking a breakdown request or a review follow-up ("when it's done, review it") creates linked child/review tasks.

**Why this priority**: The unified task model (conditions, estimates, recurrence, parent/child, reminder overrides) is the foundation every other story builds on. Without it, no automation layer or orchestrator behavior can exist.

**Independent Test**: Can be fully tested by speaking (or typing) utterances that exercise each attribute and verifying the resulting task snapshot — including that unspoken attributes stay empty and that the selection engine respects the new eligibility rules deterministically.

**Acceptance Scenarios**:

1. **Given** an empty board, **When** the user speaks a task with a deadline, an estimate, and a "wait for X" condition, **Then** a confirm card shows each parsed attribute as a dismissible chip and saving produces one task with exactly those attributes and no others.
2. **Given** task B was captured as "after A is done", **When** A is completed, **Then** B becomes eligible for selection without any user action.
3. **Given** a task deferred to a future date, **When** the selection engine runs before that date, **Then** the task is never selected; **When** it runs after that date, **Then** the task is selectable.
4. **Given** a task with an unsatisfied external condition, **When** the user says the condition is met (or taps clear), **Then** the task becomes eligible.
5. **Given** an attempted "after X" edge that would close a dependency cycle, **When** the user tries to save it, **Then** the edge is rejected with a human-readable message and nothing is persisted.
6. **Given** a recurring task marked done, **Then** it resets to open with its dates shifted one period forward, and the completion is recorded in the completion history.
7. **Given** a parent task broken into steps, **When** the final step is completed, **Then** the parent completes automatically and the parent — not each step — counts as one completed "việc".

---

### User Story 2 - Never miss: reliable reminders that act, not nag (Priority: P1)

The user captures tasks with deadlines and trusts Voci to bring them back at the right time. Reminders escalate as the deadline approaches (default: one day before, one hour before, at the deadline), arrive as actionable notifications with **Done / Snooze / Tomorrow** buttons, survive app restarts and Mac sleep, and never fire for tasks already completed. When a task becomes unblocked because its prerequisite finished, the user is told. When a deadline passes, the notification offers one-tap rescheduling instead of accumulating red guilt badges.

**Why this priority**: Reliable delivery is a constitution-level requirement (Principle IV) and the single biggest gap between the current build and the product promise: today no notification is ever scheduled.

**Independent Test**: Schedule reminders against near-future deadlines; verify firing across app restart and sleep/wake; verify completed tasks suppress their reminders; verify notification actions mutate the task without opening the app.

**Acceptance Scenarios**:

1. **Given** a task due in 90 minutes with the default policy, **When** time passes, **Then** exactly the policy's remaining notifications fire (one hour before, at deadline), each with Done/Snooze/Tomorrow actions.
2. **Given** a scheduled reminder and the app is quit and relaunched, **When** the fire time arrives, **Then** the reminder still fires.
3. **Given** a reminder fires for a task completed moments earlier, **Then** no notification is shown.
4. **Given** task B waits on A and A completes, **Then** the user receives a "B is now ready" notification.
5. **Given** a deadline passes un-actioned, **Then** the next notification offers "tonight / tomorrow / this weekend" one-tap reschedule options.
6. **Given** the user taps "Done" on a notification, **Then** the task completes, the completion is logged, and the menu bar advances to the next task without the app window opening.

---

### User Story 3 - Complete and advance by voice (Priority: P1)

Finishing work is as frictionless as capturing it: the user says *"the report is done"* and Voci matches the phrase to the right task, marks it done, and the menu bar instantly shows the next thing to do. In the evening, a two-minute sweep reads back today's open tasks so the user can harvest everything they finished in real life but never ticked.

**Why this priority**: The complete-fast loop closes the task lifecycle by voice (speak to create → speak to finish) and feeds every downstream feature (accomplishment view, streaks, auto-advance). High value, small surface.

**Independent Test**: With several open tasks, speak completion phrases with inexact titles and verify correct fuzzy matching (with confirmation when ambiguous), instant auto-advance, and completion-log entries; run an evening sweep and batch-complete via voice.

**Acceptance Scenarios**:

1. **Given** an open task "Write Q3 report", **When** the user says "xong cái báo cáo rồi", **Then** Voci proposes that task for completion (one-tap/one-word confirm) and completes it on confirmation.
2. **Given** two similarly-named open tasks, **When** a spoken completion matches both, **Then** Voci asks which one — it never silently picks.
3. **Given** a task completes, **Then** the menu bar shows the next selected task with no user action in between.
4. **Given** the evening sweep runs, **When** the user answers "done" to some items by voice, **Then** all confirmed items complete in one pass and appear in today's accomplishments.

---

### User Story 4 - Delegate to AI without losing a single loop (Priority: P2)

The user prompts an AI agent (e.g., Claude Code) to do a task, tells Voci *"handed it to Claude"* (or Voci learns it automatically via the connected integration), and moves on. The task leaves the menu bar; the next task surfaces. Voci tracks every in-flight delegation: a minute-scale check-back timer quietly resurfaces the task for review, the menu bar shows how many delegations are in flight, and if too many pile up Voci gently suggests reviewing before delegating more. Signals about finished agents arrive through a one-button integration — never by Voci reading other apps' notifications or screens. If the user already handled things without telling Voci, reconciliation happens in one batch question at natural touchpoints — never by nagging notifications.

**Why this priority**: This is the positioning pivot — the orchestrator layer that makes Voci a workflow command center rather than a to-do list. It depends on the P1 model (external conditions) but is independently testable on top of it.

**Independent Test**: Delegate several tasks, verify state transitions (waiting → needs-review → done), timer-based ambient resurfacing with backoff, WIP counter accuracy, one-button Claude Code hook installation on a machine with Claude Code present, and correct behavior when the completion signal arrives via the URL callback.

**Acceptance Scenarios**:

1. **Given** an active task, **When** the user says "giao cho Claude rồi", **Then** the task enters a waiting-on-AI state, leaves the menu bar, and the next task surfaces — no separate "switch" announcement needed.
2. **Given** a task waiting on AI with a 10-minute check-back, **When** 10 minutes pass with no signal, **Then** the task reappears ambiently (menu bar queue, no notification) with one-tap options [Done] [Still waiting] [Check in 30'].
3. **Given** the user ignores a resurfaced check twice, **Then** subsequent checks back off and fold into batch reconciliation instead of repeating.
4. **Given** Claude Code is installed, **When** the user clicks "Connect Claude Code" and approves the previewed change, **Then** the integration is installed without editing any file by hand, a test signal round-trips successfully, and disconnect removes exactly what was added.
5. **Given** exactly one task is waiting on AI, **When** a completion signal arrives, **Then** that task moves to needs-review; **Given** several are waiting, **Then** the signal's project-folder hint selects the match, and if still ambiguous the user is asked with a one-tap card. A signal alone MUST never mark a task done.
6. **Given** 4+ tasks are in flight, **When** the user delegates another, **Then** a gentle, dismissible suggestion to review first appears (never a blocker).

---

### User Story 5 - Voice-reply into the agent's terminal (Priority: DEFERRED — far post-v2, clarified 2026-07-15)

> **Deferred**: requires automation entitlements incompatible with the Mac-App-Store-first
> distribution decision. Kept in the spec as design record. The inbound completion-signal
> half of the loop (Story 4) ships in v2; the outbound typing half does not.

When an agent finishes, the user presses the hotkey and speaks the next instruction — *"add tests for that and run again"*. Voci shows the transcribed text and the exact destination ("→ iTerm2, project voci"), and on confirmation types it into the precise terminal session the agent ran in, even if that window is buried. Voci only ever writes into the terminal; it never reads terminal content. On terminals that cannot be scripted, Voci activates the right window and stages the text for a one-key paste.

**Why this priority**: Closes the orchestration loop end-to-end by voice. Depends on Story 4's signal metadata but delivers distinct, independently testable value.

**Independent Test**: With a finished agent session in a supported terminal, dictate a follow-up, verify the preview shows text + destination, confirm, and verify the text lands in the correct session; verify the fallback path on an unsupported terminal; verify nothing is ever sent without explicit confirmation.

**Acceptance Scenarios**:

1. **Given** an agent finished in a known terminal session, **When** the user dictates a reply and confirms the preview, **Then** the exact text is delivered into that session and the task returns to waiting-on-AI with a fresh check-back timer.
2. **Given** the preview is shown, **When** the user cancels, **Then** nothing is typed anywhere.
3. **Given** the target session no longer exists, **Then** the user is told and offered the clipboard fallback — text is never typed into a different window.
4. **Given** an unsupported terminal, **Then** Voci activates the correct window, places the text on the clipboard, and instructs "⌘V to send".

---

### User Story 6 - Survive long tasks: breakdown, structured switching, adapted focus (Priority: P2)

Facing a long, boring task, the user breaks it into 5–15 minute steps (assisted by on-device AI suggestions where available), each step small enough to finish before boredom hits, the first step trivially easy to start. When the urge to switch strikes, saying "đổi gió" offers exactly **one** alternative — never the whole board — while the current task keeps its place and shows its in-progress context on return. Focus sessions default to 25 minutes; the end-of-session signal is gentle and defaults to continuing (never yanking the user out of flow), while sessions past ~90 minutes get one firm break nudge. A task abandoned by switching three times triggers a breakdown suggestion. When everything feels like too much, a panic command hides everything except one ≤5-minute task.

**Why this priority**: Directly addresses initiation paralysis, boredom-switching, and time blindness — the core ADHD failure modes during execution. Builds on the P1 model (parent/child, estimates).

**Independent Test**: Break a task into steps and verify chaining, progress display, parent auto-completion; exercise the switch command and verify single-alternative offers, context restoration, and the 3-switch breakdown trigger; run focus sessions across the 25-minute and 90-minute boundaries; trigger panic mode.

**Acceptance Scenarios**:

1. **Given** a large task, **When** the user requests a breakdown, **Then** proposed steps of 5–15 minutes appear for editing/confirmation (voice or click), and saving creates chained child tasks under the parent.
2. **Given** a mid-task boredom moment, **When** the user says "đổi gió", **Then** exactly one alternative task is offered; accepting swaps the menu bar task while the previous one retains its progress context for re-entry.
3. **Given** a task switched away from 3 times, **Then** Voci suggests breaking it down.
4. **Given** a 25-minute focus session ends while the user keeps working, **Then** the session extends without interruption; **Given** 90 continuous minutes, **Then** one firm break reminder appears.
5. **Given** panic mode is invoked, **Then** the interface reduces to a single ≤5-minute task and exits panic mode only on user request.

---

### User Story 7 - Rituals and visible accomplishment, professional tone (Priority: P3)

The day is book-ended by two short rituals: a morning prompt to pick the single most important task, and an evening sweep that closes the day. An accomplishment view answers "what did I get done this session / today / this week / this month" — showing partial progress on big tasks ("Báo cáo quý — 3/7 steps") so a productive day never looks empty, counting "việc" and "bước" separately, and never rendering comparison charts or red empty days. Completion moments feel satisfying but restrained (Things/Linear-grade polish, no confetti mascots); milestones quietly unlock new themes/soundscapes; occasional completions carry a subtly richer effect. A weekly narrative summarizes the week in calm, affirming language.

**Why this priority**: Motivation and anti-shame mechanics keep the ADHD user retained long-term, but they consume data produced by P1–P2 stories (completion log) and can ship after them.

**Independent Test**: Complete a mix of standalone tasks, steps, and recurring tasks across simulated days; verify rollup display rules per timeframe, unit counting, positive-only framing, milestone unlocks, and the weekly narrative content.

**Acceptance Scenarios**:

1. **Given** 3 of 7 steps of a parent task completed today (parent unfinished), **Then** today's view shows the parent with "3/7" progress — the day is visibly non-empty.
2. **Given** the final step completes the parent today, **Then** today's view shows one line for the parent (no double count of parent + steps).
3. **Given** a completed week, **Then** the weekly view lists standalone tasks and completed parents with step counts as sub-text, and displays counts as "N việc · M bước".
4. **Given** any accomplishment surface, **Then** no negative comparison ("less than last week"), no red styling of empty days, and streaks count only upward.
5. **Given** a recurring task done many times, **Then** each completion appears in history even though the task itself was reset in place.

---

### User Story 8 - Calendar-aware realism (Priority: P3)

Voci reads the user's calendar (read-only) so its advice matches reality: a 5 PM deadline with meetings from 2–5 PM is surfaced as effectively due at 2 PM; free gaps power "quick win" suggestions sized to the available minutes; and a transition warning fires 10 minutes before a meeting so the time-blind user is never ambushed by their own calendar.

**Why this priority**: Multiplies the value of estimates and deadlines from P1 but requires calendar access and is independent of the orchestrator stories.

**Independent Test**: With seeded calendar events, verify effective-deadline adjustment, gap-sized task suggestions, and transition warnings; verify all calendar data stays on device and the feature degrades gracefully when access is denied.

**Acceptance Scenarios**:

1. **Given** a task due 5 PM and meetings 2–5 PM, **Then** urgency treats the task as due 2 PM and communicates why.
2. **Given** a 20-minute free gap and an eligible ~15-minute task, **When** the user asks "what now", **Then** that task is suggested over longer ones.
3. **Given** a meeting starts in 10 minutes, **Then** a single transition warning fires.
4. **Given** calendar permission is denied, **Then** all other features work unchanged and no repeated permission prompts occur.

---

### User Story 9 - Capture at scale and interrogate the board (Priority: P3)

Beyond single utterances: the user drops in a meeting recording or long voice memo and receives proposed action items to confirm in bulk (audio processed on device); highlights text anywhere on the Mac and turns it into a task with its source; asks the board questions by voice — *"what's waiting on AI?", "what's stuck longest?", "what's on this week?"* — and gets a spoken/visual answer; and when leaving a task, records a one-line resume note that greets them on return ("yesterday you stopped at X, planned to do Y").

**Why this priority**: Extends capture and recall breadth for professionals; each capability is valuable alone but none blocks the core loops above.

**Independent Test**: Ingest a recorded meeting and verify proposed items requiring explicit confirmation; capture from a text selection; issue voice queries and verify accurate answers; verify resume notes are prompted on exit and surfaced on re-entry.

**Acceptance Scenarios**:

1. **Given** a 30-minute meeting recording, **When** ingested, **Then** proposed action items appear as confirmable cards (nothing saved without confirmation) and the audio never leaves the device on the free tier.
2. **Given** text selected in another app, **When** the capture shortcut is used, **Then** a task is created carrying the text and source reference.
3. **Given** several tasks waiting on AI, **When** the user asks "cái nào đang chờ AI?", **Then** the answer lists exactly those tasks.
4. **Given** a task left mid-way with a resume note, **When** it next surfaces, **Then** the note is shown/read back before work resumes.

---

### User Story 10 - Own the data (Priority: P4)

The user can export/back up all tasks, transcripts, and completion history to open formats, and search full-text across titles, notes, and original transcripts.

**Why this priority**: Trust prerequisite for professionals; simple, independent, and lowest urgency.

**Independent Test**: Export a populated board and verify the archive round-trips (re-import or human-readable audit); search by fragments of a spoken transcript and find the task.

**Acceptance Scenarios**:

1. **Given** a populated board, **When** the user exports, **Then** an open-format archive is produced containing tasks, attributes, transcripts, and completion history.
2. **Given** a phrase spoken weeks ago, **When** searched, **Then** the originating task is found via its stored transcript.

---

### Edge Cases

- **Dependency cycle attempts** (direct, transitive, self-reference) must be rejected at save time with a human-readable message; the board is never left in a cyclic state.
- **Prerequisite deleted or archived**: dependent tasks treat the condition as satisfied; the user is informed once when this changes a task's blocked state.
- **Recurring task with subtasks**: recurrence is not permitted on parent tasks with children (validation prevents it; see Assumptions).
- **External condition satisfied while the app was not running**: state reconciles at next launch; check-back timers that elapsed while closed fire their ambient resurfacing once, not repeatedly.
- **Completion signal for an unknown/no waiting task**: ignored silently (logged locally); signals never create tasks or mark anything done.
- **Spoofed/duplicate completion signals**: at worst a task resurfaces early for review; idempotent handling; no state loss.
- **Voice-done matches zero tasks**: Voci says so and offers capture instead — it never guesses a completion.
- **Terminal session gone before voice-reply**: user informed; clipboard fallback offered; no typing into any other window.
- **Notification permission denied**: reminders degrade to in-app/menu-bar surfacing with one explanatory prompt; no silent loss and no repeated permission nagging.
- **Clock/timezone/DST changes**: absolute-instant semantics hold; date-based conditions and reminders fire exactly once at the correct instant.
- **On-device AI unavailable** (older OS or hardware): parsing falls back to the existing heuristic parser; AI-assisted breakdown hides; all P1 flows still work.
- **Two similarly named tasks in voice-done or delegation matching**: always disambiguate via a one-tap card; never silently pick (Principle II).
- **Sweep/triage with zero candidates**: rituals skip silently rather than presenting empty ceremonies.

## Requirements *(mandatory)*

### Functional Requirements

**Unified task model & engine**

- **FR-001**: A task MUST support: title, optional notes, original transcript (always retained for voice-created tasks), kind (task | review), status, optional priority, optional deadline, optional effort estimate (minutes), zero-or-more blocking conditions, optional recurrence, optional reminder override, optional parent link, and creation/completion timestamps.
- **FR-002**: Blocking conditions MUST support exactly three kinds: *after another task completes*, *after a date/time*, and *external* (free-text description with a satisfied flag). A task is eligible for selection only when its status is open/in-progress AND every condition is satisfied.
- **FR-003**: An *after-task* condition is satisfied when the referenced task is done, archived, or absent; *after-date* when the reference time has passed; *external* when its flag is set.
- **FR-004**: The set of *after-task* edges MUST remain acyclic; any edge (including self-reference) that would violate this MUST be rejected at creation with a human-readable message and MUST NOT persist. Date and external conditions never participate in cycle checks.
- **FR-005**: Task selection MUST remain a pure, deterministic, total-order function of the task snapshot and reference time, preserving the existing ordering tiers (in-progress first, near-term deadline urgency, priority, creation time, stable id tiebreak). The existing release-gate test suite MUST be extended to cover the new eligibility rules and continue to pass.
- **FR-006**: Completing a recurring task MUST reset it in place (status reopened; deadline and date conditions shifted one period; external conditions reset to unsatisfied) and MUST record a completion event. The next occurrence MUST anchor to the original schedule by default (a weekly-Monday task stays Monday even when completed Wednesday); at completion time only, the user MAY redirect that cycle to anchor from the completion date instead — this choice is never requested at capture time.
- **FR-007**: Every completion (task or step) MUST append an immutable completion event carrying the task's identity, title snapshot, parent link snapshot, and completion instant — the source of truth for all accomplishment surfaces and streaks.
- **FR-008**: Completing the last open child of a parent MUST auto-complete the parent; a parent with open children MUST NOT be directly selectable (its next open step is selected instead).

**Capture & confirmation**

- **FR-009**: Voice/text capture MUST populate only attributes explicitly expressed in the utterance; unexpressed attributes remain unset. Every parsed attribute MUST surface as a dismissible confirmation chip before taking effect; low-confidence attributes MUST require explicit confirmation (never auto-attach a dependency below the confidence threshold).
- **FR-010**: One utterance MUST be able to produce linked structures: dependency phrasing in either direction ("B after A" / "when A is done, B"), deferrals, external waits, review follow-ups (a second task of kind review depending on the first), and reminder overrides.
- **FR-011**: Parsing failure on any attribute MUST degrade to a title-only task carrying the raw transcript with a visible "couldn't parse details" hint — never a silent drop, never a crash, never discarding successfully parsed attributes.
- **FR-012**: Intent parsing MUST route: on-device AI where available (all tiers) → cloud parsing for ALL tiers with one-time explicit opt-in (transcript text only, never audio, via the server proxy — provider swappable, keys server-side only) → heuristic parser otherwise. Free-tier cloud parsing MUST be metered per device per day (default 50, server-tunable) without requiring an account; exceeding the quota MUST degrade to the heuristic parser with a gentle note — never a hard block on task creation. Any single utterance MUST create at most 10 tasks (all tiers, all parsers). Users who decline the opt-in, or are offline, MUST always retain the heuristic path. AI-assisted breakdown (FR-029) follows the same routing and metering.

**Reminders & not-missing**

- **FR-013**: Tasks with deadlines MUST produce reminders per an escalating default policy (application-configurable; default: −1 day, −1 hour, at deadline), overridable per task by spoken instruction. Reminder state MUST persist and reschedule across app restarts and system sleep; due-but-missed reminders MUST fire on recovery.
- **FR-014**: Deadline notifications MUST carry Done / Snooze / Tomorrow actions that mutate the task without opening the app. A reminder whose task is already completed/archived MUST NOT present.
- **FR-015**: When completing a task unblocks others, the user MUST be notified once per newly-ready task.
- **FR-016**: A passed deadline MUST trigger a reschedule offer (e.g., tonight / tomorrow / weekend) rather than persistent overdue badging; overdue count displays MUST NOT accumulate shame-styling (no red badge counts).
- **FR-017**: Tasks blocked on a date MUST automatically resurface when the date passes without polling-style repeated alerts.
- **FR-018**: Open tasks untouched for a configurable staleness window MUST enter a periodic (default weekly) triage flow offering keep / break down / defer / drop per task — presented in one batch, never as individual nag notifications.

**Voice completion & advance**

- **FR-019**: A spoken completion phrase MUST fuzzy-match against open tasks; a confident single match completes on one confirmation; multiple candidates MUST be disambiguated; zero matches MUST be stated. The same phrasing path MUST also clear external conditions ("client signed the NDA").
- **FR-020**: On completion the menu bar MUST advance to the next selected task immediately with no intermediate list or empty state requiring a decision.
- **FR-021**: An end-of-day sweep MUST present today's open/in-progress tasks for rapid voice/one-tap batch completion, feeding the completion log.

**AI delegation (orchestrator)**

- **FR-022**: The user MUST be able to mark a task as delegated-to-AI in one utterance or tap, which sets an external waiting condition, removes it from the active slot, and advances to the next task — with no separate switch announcement required.
- **FR-023**: Each delegation MUST carry a minute-scale check-back timer (default configurable, spoken override) that ambiently resurfaces the task for review — via the menu bar queue only, never a system notification — with one-tap [Done] [Still waiting] [Check later] responses; unanswered checks MUST back off and fold into batch reconciliation at natural touchpoints.
- **FR-024**: The menu bar MUST display the count of in-flight delegations; exceeding a soft limit (default 4) MUST produce a gentle, dismissible review-first suggestion, never a block.
- **FR-025**: Voci MUST accept agent-completion signals only through an inbound app-link callback registered by the app. On a signal: exactly one waiting task → mark needs-review; several → match by project-folder hint; ambiguous → one-tap disambiguation card. A signal MUST NEVER mark a task done and MUST be idempotent. Voci MUST NOT read other applications' notifications, windows, or screens to detect agent state.
- **FR-026**: Where a supported agent CLI is detected, Voci MUST offer a one-button connect flow: preview of the exact configuration change, backup before write, additive merge (never overwriting existing user configuration), a test-signal round-trip, and a disconnect that removes only what Voci added. A copy-manually fallback MUST exist.

**Voice-reply to terminal — DEFERRED (far post-v2; see Clarifications 2026-07-15)**

- **FR-027 (deferred)**: For a task whose delegation signal identified its terminal session, the user MUST be able to dictate a follow-up instruction; Voci MUST show the transcript and the resolved destination and MUST NOT send without explicit confirmation.
- **FR-028 (deferred)**: On confirmation Voci MUST deliver the text into exactly the identified session on scriptable terminals; on unsupported terminals it MUST activate the correct window and stage the text on the clipboard with a paste instruction. Delivery is write-only: Voci MUST NOT read terminal contents. If the session is gone, the user is informed and offered the clipboard path; text is never delivered to any other window.

**Focus, breakdown, switching**

- **FR-029**: The user MUST be able to break a task into ordered child steps (target 5–15 minutes each); where on-device AI is available it MUST propose an editable draft; steps chain via after-task conditions under the parent.
- **FR-030**: A switch command MUST offer exactly one alternative task (next-by-ordering excluding the current); accepting preserves the abandoned task's in-progress context, which MUST be surfaced on re-entry (last step, resume note, transcript). Three or more switches away from the same task MUST trigger a one-time breakdown suggestion.
- **FR-031**: Focus sessions MUST default to 25 minutes (configurable): session end signals MUST be non-blocking and default to continuation; roughly 90 minutes of continuous focus MUST produce one firm break reminder. Elapsed time against the task's estimate MUST be visible during a session, with a gentle prompt when significantly over.
- **FR-032**: A panic command (voice or click) MUST reduce the interface to a single task with estimate ≤5 minutes (or the smallest available), hiding all other counts and queues until dismissed.
- **FR-033**: Tasks with small estimates (≤~5 minutes) MUST be offered opportunistically when the user asks what to do in a short gap.

**Rituals & accomplishment**

- **FR-034**: A once-daily morning prompt MUST ask the user to pick the day's single most important task, which the engine then favors; an evening sweep (FR-021) bookends the day. Both rituals MUST skip silently when they have no candidates.
- **FR-035**: An accomplishment view MUST present completions by session / day / week / month from the completion log with rollup rules: day-scale shows steps grouped under parents including partial progress; week/month-scale shows standalone tasks and completed parents with step counts as sub-text; parent+steps completed together render as one line; counts display "việc" (standalone + completed parents) and "bước" (steps) as separate units, never summed.
- **FR-036**: All motivational surfaces MUST be positive-only: no negative comparisons, no red/empty-day styling, upward-only streaks. Presentation MUST follow the professional restraint standard (subtle completion effects, calm copy, no cartoon mascots); milestone rewards MUST be aesthetic unlocks (themes/soundscapes) with flat per-task value so rewards never influence task choice; occasional completions MAY carry a subtly richer effect on an unpredictable schedule.
- **FR-037**: A weekly narrative summary MUST be generated from the completion log in calm, affirming language (on-device where AI is available; template-based otherwise).

**Calendar, capture-at-scale, query, data**

- **FR-038**: With user permission, Voci MUST read calendar events (read-only) to: adjust effective urgency for deadlines that collide with busy blocks, size gap suggestions to actual free minutes, and fire a single transition warning ~10 minutes before events. Denial MUST degrade gracefully with no repeated prompts. Calendar data MUST NOT leave the device.
- **FR-039**: The user MUST be able to ingest an audio recording (e.g., a meeting) and receive proposed action items as confirmable cards — nothing persists unconfirmed; free-tier processing MUST keep audio on device.
- **FR-040**: A system-wide capture path MUST turn selected text in other applications into a task carrying the text and source reference.
- **FR-041**: The user MUST be able to ask the board questions by voice (today/this week, waiting-on-AI, stuck-longest, waiting-on-whom) and receive an accurate spoken/visual answer scoped to their own data.
- **FR-042**: When leaving a task or ending the day, the user MUST be offered (never forced) a one-line resume note attached to the task, surfaced on the task's next appearance.
- **FR-043**: The user MUST be able to export all tasks, attributes, transcripts, and completion history to an open format, and search full-text across titles, notes, and transcripts.
- **FR-044**: Every user correction of a parsed attribute MUST be logged locally (attribute, parsed value, corrected value, transcript) as parser-improvement data that never leaves the device.

### Key Entities

- **Task**: The unit of work. Identity, title, notes, original transcript, kind (task/review), status, priority, deadline, effort estimate, conditions, recurrence, reminder override, parent link, timestamps. Selection-relevant subset feeds the pure engine; the full record persists.
- **Condition**: A blocking gate on a task — one of after-task (reference to another task), after-date (instant), external (description + satisfied flag, optionally carrying delegation metadata: check-back schedule, origin hints like project folder/session).
- **Reminder policy**: Escalating offsets relative to deadline plus optional repeat interval; a global default and per-task overrides.
- **Completion event**: Immutable record of one completion — task identity, title snapshot, parent snapshot, instant. Source of truth for accomplishment views, streaks, weekly narrative.
- **Recurrence rule**: Daily / weekly / monthly / every-N-days period applied by reset-in-place on completion.
- **Delegation link**: The association between a waiting task and its external agent context (folder/session hints, check-back timer state, in-flight status) enabling signal matching and terminal reply routing.
- **Resume note**: Short user-authored context attached to a task, surfaced on re-entry.
- **Calendar event (read-only)**: External busy/free information consumed for effective deadlines, gap sizing, and transition warnings; never stored beyond what the feature needs, never egressed.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Speaking a structured task (deadline + dependency + estimate) puts it on the board in under 5 seconds of user effort with zero mandatory follow-up questions; unspoken attributes are empty in 100% of cases.
- **SC-002**: In automated recovery tests (restart, sleep/wake, missed-while-closed), 100% of due reminders present exactly once — none lost, none duplicated, none for completed tasks.
- **SC-003**: Completing a task — by voice or from a notification — takes one confirmation and ≤2 seconds of interaction, and the next task is visible immediately (no empty gap requiring a decision).
- **SC-004**: Across a simulated week of AI delegations, 0 delegated tasks are permanently forgotten: every one either reaches needs-review via signal/timer or appears in batch reconciliation.
- **SC-005**: Connecting the agent integration takes ≤2 clicks and ≤60 seconds including the verified test signal; disconnecting restores the prior configuration byte-for-byte apart from Voci's removed entry.
- **SC-006**: The engine test suite (existing release gate + new eligibility/condition/hierarchy cases) passes 100%, and selection on a board of several hundred tasks completes in well under 1 second.
- **SC-007**: In accomplishment views, a day with ≥1 completed step never renders as empty, and no surface anywhere shows negative comparison or shame styling (audited against a checklist).
- **SC-008**: Voice replies reach the exact originating terminal session in 100% of supported-terminal tests, and 0 sends occur without a confirmed preview.
- **SC-009**: On the free tier, 0 bytes of audio leave the device across all capture paths (verified by network audit); transcript text egress occurs only on the paid, opted-in path.
- **SC-010**: A first-time user can complete the core loop — capture by voice, receive a reminder, complete by voice, see it in today's accomplishments — without reading documentation.

## Assumptions

- **Scope phasing**: This spec covers the approved v2 scope (model + automation + orchestrator + vision Tier 1–2). **First release boundary (clarified 2026-07-15): all P1 + P2 stories ship together**; P3–P4 stories follow in subsequent releases in dependency order. Each user story remains independently testable. Tier 3 (iPhone/Watch sync, team/share), kanban views, and general-purpose AI chat remain out of scope.
- **Platform floor (clarified 2026-07-15)**: macOS 14+ stays the floor. On-device AI parsing/breakdown/narrative activates conditionally where OS/hardware supports it; the heuristic parser and template-based summaries serve everything older. The constitution's macOS 26+ wording will be amended; the plan's constitution check records this.
- **Reserved for v3+ (user direction 2026-07-15)**: cloud sync with cross-device reminders, and teamwork — collecting tasks from a team and automatically resolving them when done. Design decisions in v2 must not preclude these (e.g., stable task identities, completion log as syncable events) but no v2 work targets them.
- **Recurrence simplicity**: Recurrence applies to leaf tasks only (no children); reset-in-place semantics; no complex RRULE editing in v2.
- **Delegation matching**: Project-folder and session hints from the integration are best-effort; ambiguity always resolves via a one-tap user card (Principle II), so imperfect hints degrade to one extra tap, not errors.
- **Distribution (clarified 2026-07-15)**: Mac App Store first — App Sandbox + StoreKit (existing freemium plan). Consequences: every v2 feature must be sandbox-compatible; the Claude Code connect flow uses user-granted folder access (2 clicks); the global hotkey must use the sandbox-safe mechanism (no Accessibility-dependent core path); terminal typing (Story 5) is deferred until/unless a Developer ID build is pursued later.
- **Single user, single Mac**: No sync or multi-device state in v2; export covers data portability.
- **Language**: Capture and voice commands must work in the user's spoken language mix (Vietnamese/English per existing speech-engine decisions); UI copy remains English with calm professional tone.
- **Existing infrastructure reused**: Speech engines (on-device Whisper / Apple speech / paid cloud path with consent), menu-bar shell, focus overlay, and morning-frog UI exist and are extended, not rebuilt.
