# Phase 0 Research: Voci v2 — Workflow Command Center

All Technical Context unknowns resolved. Format: Decision / Rationale / Alternatives considered.
Source decision record: `docs/task-model-v1.md`, `docs/adhd-automation-v1.md`,
`docs/product-vision-v2.md`, spec Clarifications (Session 2026-07-15).

## R1. Unified blocking model: `conditions: [Condition]` replaces `dependsOn`

- **Decision**: One enum `Condition { taskDone(UUID), afterDate(Date), external(description:satisfied:) }`
  on the engine's `Task`; eligibility = status ∈ {todo, inProgress} AND all conditions satisfied.
  Cycle detection runs only over `taskDone` edges (DFS, unchanged algorithm).
- **Rationale**: `deadline`-vs-`conditions` separation keeps ordering (urgency) and eligibility
  (gating) orthogonal; `afterDate` gives defer/snooze; `external` covers human waits AND AI
  delegation with zero extra engine surface.
- **Alternatives**: keep `dependsOn` + parallel condition list (two ways to say one thing —
  rejected); free-text `waitingOn` only (rejected by user, option 3 chosen 2026-07-15).

## R2. Reminder engine: UNUserNotificationCenter + storage-rebuilt scheduler

- **Decision**: Persist reminder intents in SwiftData; on every launch (and wake, via
  `NSWorkspace.didWakeNotification`) rebuild pending `UNNotificationRequest`s from storage;
  fire-time re-check loads the task fresh and suppresses if done/archived. Notification
  category with actions: Done / Snooze(10m) / Tomorrow. Escalation default −1d/−1h/0 from
  a global `ReminderPolicy`, per-task override field.
- **Rationale**: Constitution IV requires durable persistence + rebuild-from-storage + recovery
  tests. UNUserNotificationCenter limits pending requests (64/app) → schedule only the nearest
  N per task and re-fill on delivery/launch.
- **Alternatives**: NSBackgroundActivityScheduler polling (imprecise, battery); in-memory timers
  (violates constitution IV).

## R3. Sandbox-safe global hotkey

- **Decision**: Replace `NSEvent.addGlobalMonitorForEvents` (needs Accessibility — MAS-hostile)
  with Carbon `RegisterEventHotKey` for the capture hotkey. No Accessibility dependency remains
  in any shipped path.
- **Rationale**: Clarification #3 mandates Mac App Store first; MAS review + sandbox make
  Accessibility-dependent core paths unacceptable. `RegisterEventHotKey` is sandbox-legal and
  needs no permission prompt.
- **Alternatives**: keep NSEvent monitor (rejected: permission + review risk); MenuBarExtra-only
  activation (rejected: kills the one-breath capture promise).

## R4. Agent-completion signal: `voci://` URL scheme + Claude Code Stop-hook

- **Decision**: Register `CFBundleURLTypes` scheme `voci`; endpoint `voci://ai-done?cwd=<path>`
  (tty param reserved for the deferred typing feature). One-button connect: detect `~/.claude/`,
  NSOpenPanel pre-targeted at it (security-scoped bookmark, 2 clicks total), preview the exact
  JSON hook entry, backup `settings.json`, additive merge into `hooks.Stop`, test-signal
  round-trip, disconnect removes only the `voci://`-marked entry. Signals are idempotent, can
  only move a waiting task to needs-review, never complete anything.
- **Rationale**: Cooperative push is the only privacy-acceptable detection (no notification-DB /
  AX / screen reading — constitution I); URL scheme has no listening port (unlike localhost HTTP).
- **Alternatives**: local HTTP server (browser-reachable, rejected); process watching (can't
  identify the task); reading notification DB / ScreenCaptureKit (rejected outright).

## R5. Intent parsing router (3 tiers)

- **Decision**: `IntentParsing` protocol with implementations:
  `FoundationModelParser` (macOS 26+/Apple Silicon, `#available` + capability check, @Generable
  guided generation), `CloudParser` (ALL tiers, one-time explicit privacy opt-in; POST
  transcript text to Supabase Edge route `/functions/v1/parse`; provider behind the proxy —
  initial candidate Gemini Flash with JSON-schema structured output; key server-side only),
  `HeuristicNLParser` (existing, always available). Router order: FM → Cloud (if opted-in +
  online + within quota) → Heuristic. Free-tier cloud quota: default 50 parses/device/day,
  enforced server-side via **DeviceCheck** attestation (no accounts — per freemium decision);
  paid tier (StoreKit JWS) unmetered. Hard cap 10 tasks per utterance, all parsers. Over-quota
  → heuristic + gentle note, never a block. All outputs decode into validated `ParsedTask`;
  decode failure → title-only task with transcript (constitution II). AI breakdown uses the
  same router and metering.
- **Rationale**: Clarification #5 + user direction (2026-07-15): hardware-based paywall for AI
  parsing is discriminatory — cloud parse is free-with-limits. Opt-in stays regardless of price
  (text egress requires consent — constitution I amendment keeps the consent clause, drops the
  paid-only clause). Cost envelope: ~500 tokens/parse on Gemini Flash ≈ fractions of a cent;
  50/day/device is dollars/day even at thousands of free users; DeviceCheck prevents
  reinstall-farming.
- **Alternatives**: paid-only cloud parse (rejected — discriminatory); silent cloud fallback
  without opt-in (violates constitution I); per-IP limits (coarse, NAT-unfair); bundling an
  MLX model in v2 (~2GB download, deferred).

## R6. Voice-done fuzzy matching

- **Decision**: On-device matching: normalize (case/diacritics-preserving Vietnamese-aware
  lowercasing), score open tasks with token-set ratio + prefix bonus (simple Swift
  implementation, no dependency); single candidate ≥ high threshold → one-tap/one-word confirm;
  multiple above floor → disambiguation card; none → offer capture. The same intent path
  clears `.external` conditions.
- **Rationale**: Constitution II forbids silent guessing; matching is assistive with mandatory
  confirm. No network needed.
- **Alternatives**: embedding similarity via FM (overkill, macOS 26-only); exact title match
  (useless for speech).

## R7. Completion log & accomplishment rollup

- **Decision**: New SwiftData model `CompletionEvent { taskId, titleSnapshot, parentIdSnapshot,
  completedAt, estimateMinutes? }` appended on every completion (steps, tasks, recurring
  resets). Accomplishment views aggregate events; day scale groups by `parentIdSnapshot`
  with partial progress from live tasks; week/month roll up to parents/standalone; counts
  reported as separate units (việc/bước). Streaks derive from event days, upward-only.
- **Rationale**: Recurring reset-in-place erases per-task history — an immutable event log is
  the only truthful source; also the future-proof shape for v3 sync (user direction).
- **Alternatives**: `completedAt` on task only (loses recurrence history); analytics via
  SQLite views (premature).

## R8. Recurrence semantics

- **Decision**: `Recurrence { daily, weekly, monthly, every(days:) }` on leaf tasks only
  (validation rejects on parents). Completion → reset in place: reopen, shift deadline and
  `afterDate` conditions to the next occurrence anchored to the original schedule; external
  conditions reset to unsatisfied; log event. At completion moment only, an optional
  "from today" affordance re-anchors that cycle to the completion date (clarification #4).
- **Rationale**: Schedule-anchoring keeps rituals stable (Monday stays Monday); completion-time
  override covers interval-style chores without a capture-time question.
- **Alternatives**: RRULE engine (v2 explicitly excludes); spawn-new-task per occurrence
  (id churn, breaks conditions pointing at it).

## R9. Delegation lifecycle & anti-drift

- **Decision**: Delegation = `.external("chờ AI: <label>", satisfied: false)` + `DelegationMeta`
  (persisted alongside the task): checkBackAt, backoffStage, cwdHint. Resurface is ambient only
  (menu-bar queue section), backoff 10'→30'→batch; batch reconciliation card at popover-open /
  evening sweep. WIP counter = count of unsatisfied delegation conditions; soft limit 4 →
  dismissible hint. Signal matching: exactly-one-waiting → that task; else cwdHint match;
  else one-tap card.
- **Rationale**: Spec US4 + anti-nagging design (never notifications for rechecks; silence
  means back off).
- **Alternatives**: system notifications for recheck (rejected — drift-nagging); auto-done on
  signal (rejected — constitution II).

## R10. Focus / switching / panic

- **Decision**: FocusSession state in AppState: default 25' (configurable), end-of-box shows
  non-blocking inline prompt defaulting to continue; continuous-focus odometer fires one firm
  nudge at 90'. estimate-vs-elapsed line when estimateMinutes present. "Đổi gió" = nextTask over
  snapshot minus current task; switch count per task persisted → ≥3 triggers one-time breakdown
  suggestion. Panic mode = filter to smallest-estimate eligible task, hide counters, explicit exit.
- **Rationale**: Spec US6; engine unchanged (filtering happens app-side on the snapshot).
- **Alternatives**: engine-level `excluding:` parameter (unnecessary API growth).

## R11. Calendar (P3) — EventKit read-only

- **Decision**: `EKEventStore` full-access read (macOS 14 API `requestFullAccessToEvents`);
  compute today's busy blocks → effective-deadline shift, gap sizing for quick-wins, one
  transition warning 10' pre-event (scheduled as local notification). Denial → feature hides,
  single explanatory row in Settings, no re-prompts. Data never persisted beyond the day cache.
- **Rationale**: Spec US8 + privacy (no egress).
- **Alternatives**: calendar write access (not needed); polling AppleScript into Calendar.app
  (fragile, rejected).

## R12. Cloud proxy extension (paid parse route)

- **Decision**: Extend the already-planned Supabase Edge Function proxy with `/parse`:
  authenticates EITHER a StoreKit JWS (paid → unmetered) OR a DeviceCheck token (free →
  50/day/device counter in Postgres, quota value in server config), rate-limits, forwards
  transcript text to the configured LLM (initial: Gemini Flash, JSON-schema response), returns
  `ParsedTask` JSON (max 10 tasks). Client never holds provider keys; provider swap is
  server-side config. Quota-exceeded returns a typed 429 the client maps to heuristic fallback.
- **Rationale**: Reuses the freemium backend decision (backlog 2026-07-15) — one proxy, two
  auth modes; provider-agnostic client honors constitution's `IntentParsing` protocol.
- **Alternatives**: Groq-hosted Llama for parsing (kept as swap option — same proxy pattern);
  direct-from-client Gemini key (rejected: key extraction, same reason as Groq proxy);
  accounts/login for quota (rejected per freemium decision — no accounts).

## R13. Constitution amendments required (governance follow-up)

- **Decision**: Amend Technology & Model Constraints to reflect reality decided in
  clarifications: platform floor macOS 14+ with conditional macOS 26 AI features; ASR default =
  WhisperKit free tier / Groq paid (SpeechAnalyzer optional future); hotkey mechanism =
  sandbox-safe; add v2 scope note (recurrence now in scope — the "v1 non-goals" list stays
  historical). Principle I amendment: cloud parse path is available to ALL tiers (was
  "AI Pro tier AND opted in") — the explicit opt-in and text-only clauses stay untouched;
  metering replaces the paid gate. Principles II–V unchanged.
- **Rationale**: Constitution currently names macOS 26+ and SpeechAnalyzer-first, contradicting
  the shipped/decided architecture; governance requires an explicit amendment rather than
  silent divergence.
- **Alternatives**: raise floor to 26 (rejected in clarification #2).
