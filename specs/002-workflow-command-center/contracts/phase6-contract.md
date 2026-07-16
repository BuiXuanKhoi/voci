# Contract: Phase 6 (US4 — AI-delegation orchestrator) — frozen seams

Project is **Volar** (paths `Volar/`, engine `VolarCore`, tokens `Volar*`). Parallel agents code
against THIS. **URL scheme**: verify the ACTUAL registered scheme in `Volar/Resources/Info.plist`
(the app was renamed Voci→Volar; the scheme is likely `volar` now, not `voci`). Use whatever is
registered, consistently. The behavioral spec is `contracts/app-links.md` (read it — the
`ai-done` matching ladder + one-button hook install contract are authoritative).

## A. Delegation subsystem — OWNED BY the Orchestrator agent (`Volar/Sources/Orchestrator/DelegationTracker.swift`, `AppLinkHandler.swift`)

`DelegationMeta` already exists (`Volar/Sources/Model/Recurrence.swift` per data-model: label,
checkBackAt, backoffStage, cwdHint, delegatedAt). A task is "delegated" when it carries an
`.external("waiting on AI: <label>", satisfied:false)` condition + `DelegationMeta`.

```swift
@MainActor final class DelegationTracker {
    init(store: TaskStore)
    /// Mark a task delegated: add the external waiting-condition + DelegationMeta, schedule the
    /// first minute-scale check-back (default 10'). Returns nothing; caller advances the menu bar.
    func delegate(taskId: UUID, label: String, checkBackMinutes: Int = 10, cwdHint: String?)
    /// Count of in-flight delegations (unsatisfied waiting-on-AI conditions) — drives the WIP badge.
    func wipCount() -> Int
    /// Tasks whose check-back is due now → resurface AMBIENTLY (menu-bar queue, NOT a notification).
    /// Backoff: 10' → 30' → batch-only (backoffStage). Called by a timer + on app foreground.
    func dueForRecheck(now: Date) -> [UUID]
    func bumpBackoff(taskId: UUID)            // user ignored a recheck → next stage
    /// Signal arrived (from AppLinkHandler): move the matched task to needs-review (clear
    /// DelegationMeta, keep the task eligible). NEVER auto-completes.
    func markNeedsReview(taskId: UUID)
    /// Batch reconcile card content at natural touchpoints (popover open / evening): the waiting
    /// tasks the user should confirm are done/not.
    func reconcileBatch() -> [UUID]
}
```

```swift
@MainActor final class AppLinkHandler {
    init(store: TaskStore, delegation: DelegationTracker)
    /// SwiftUI .onOpenURL entry. Routes `<scheme>://ai-done?cwd=...&tty=...` per app-links.md's
    /// matching ladder (exactly-one-waiting → cwd prefix-match → ambient disambiguation card;
    /// unknown/none → log+ignore). Idempotent; NEVER completes a task. Also `<scheme>://capture?text=`
    /// → feeds the existing capture/parse pipeline (never bypasses the confirm card).
    func handle(_ url: URL)
    /// For the ambiguous case, expose the candidate waiting tasks so the UI can show a one-tap card.
    var pendingDisambiguation: [UUID] { get }
}
```

## B. Claude Code connector — OWNED BY the Connector agent (`Volar/Sources/Orchestrator/ClaudeCodeConnector.swift`)

Per `contracts/app-links.md` "Claude Code hook" section. Self-contained (file I/O, no app-state).

```swift
@MainActor final class ClaudeCodeConnector {
    struct State { var installed: Bool; var claudeDetected: Bool }
    func detect() -> Bool                     // ~/.claude/ exists?
    /// The exact JSON hook entry that will be appended (for the preview UI):
    /// {"type":"command","command":"open \"<scheme>://ai-done?cwd=$PWD\""}
    func previewHookEntry() -> String
    /// Requires a user-granted security-scoped bookmark to ~/.claude (App Sandbox). Backup
    /// settings.json → parse → ADDITIVE merge into hooks.Stop (never overwrite existing hooks) →
    /// write. Returns success/failure with a human message. Marker = command contains the scheme.
    func connect(bookmarkedClaudeDir: URL) throws
    func sendTestSignal()                     // open <scheme>://ai-done?... → user sees "received"
    func disconnect(bookmarkedClaudeDir: URL) throws   // remove ONLY marker-matching entries
}
```

## C. App wiring — OWNED BY the App-wiring agent (`AppState.swift`, `MenuBarLabel.swift`, `TodayView.swift`, `PopoverView.swift`, `SettingsView.swift`)
- **T042** Delegation voice intents ("giao cho Claude rồi", "check sau 10 phút") in the capture
  pipeline + a delegate button on the current task in `TodayView`. Delegating → `DelegationTracker.delegate(...)`
  → task leaves the active slot → auto-advance (reuse the Phase-5 `toggleDone`/refresh funnel pattern).
- **T043** WIP counter "⏳ N" on `MenuBarLabel` (from `DelegationTracker.wipCount()`), soft-limit
  (>4) dismissible hint, and the ambient needs-review card ([Done][Still waiting][Check later]) in
  `PopoverView`/`TodayView` — RESURFACE is menu-bar-ambient, NEVER a system notification (constitution
  I / anti-drift-nagging). Preserve Studio Dark styling (WIP uses `Font.volarMono` + `.instrument`).
- **T044** "Connect Claude Code" section in `SettingsView`: detect → preview (show `previewHookEntry()`)
  → NSOpenPanel pre-targeted at ~/.claude (security-scoped bookmark) → connect → test-signal → disconnect.
- Construct `DelegationTracker`/`AppLinkHandler`/`ClaudeCodeConnector` in AppState; wire `.onOpenURL`
  in `VolarApp.swift` → `AppLinkHandler.handle`. A minute-scale timer (or the existing tick) calls
  `dueForRecheck` and updates the ambient queue.

## Non-negotiables (all agents)
Constitution I (signals are inbound-only, NEVER read other apps' notifications/screens; rechecks are
ambient not notifications; connector only WRITES the one marker hook, backs up first, never overwrites),
II (a signal never completes a task — only → needs-review; ambiguous → user disambiguates), V
(glance-and-dismiss, single-task menu bar preserved, no shame). Sandbox-compatible (bookmark for
~/.claude; no Accessibility). Swift 6, macOS 14 floor. Windows: cannot build — `// UNVERIFIED`. Do
not commit/branch/edit backlog/tasks/other specs.
