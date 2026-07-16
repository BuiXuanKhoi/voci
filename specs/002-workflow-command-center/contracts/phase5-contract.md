# Contract: Phase 5 (US3 — complete & advance by voice) — frozen seams

Parallel agents code against THIS. Owner named per symbol. Won't fully compile until all land +
Mac verify; the contract keeps them consistent.

## A. Voice-done matcher — OWNED BY the VoiceDone agent (`Volar/Sources/Speech/VoiceDone.swift`)

Classifies a spoken utterance as a COMPLETION / CLEAR-EXTERNAL / (else) new-capture, and fuzzy-
matches it against open tasks. Assistive, never authoritative (constitution II — always confirm,
never silently complete).

```swift
enum VoiceDoneIntent: Sendable, Equatable {
    case complete(candidates: [VoiceMatch])   // ≥1 open task matched a "xong/done" phrase
    case clearExternal(candidates: [VoiceMatch]) // "client đã ký", "anh Nam gửi rồi" → clear an .external
    case notACompletion                        // fall through to normal new-task capture
}
struct VoiceMatch: Sendable, Equatable { let taskId: UUID; let title: String; let score: Double }

@MainActor struct VoiceDone {
    /// Vietnamese+English aware. `openTasks` = the user's current open/in-progress tasks (id+title,
    /// plus each task's unsatisfied .external descriptions for clearExternal matching).
    func classify(_ transcript: String, openTasks: [VoiceDoneTask]) -> VoiceDoneIntent
}
struct VoiceDoneTask: Sendable, Equatable {
    let id: UUID; let title: String; let externalDescriptions: [String]
}
```

Thresholds: exactly one candidate ≥ high (~0.8) → the app offers ONE-tap/one-word confirm;
several above a floor (~0.5) → disambiguation; none → `notACompletion` (or, if a done-phrase was
clearly present but nothing matched, the app STATES "no matching task" and offers capture —
never guesses). Reuse/normalize like the Phase-3 heuristic (diacritic+case fold, "đ/Đ" special-
cased — see `NLParser`/`ConflictCheck` for the established convention). Pure of I/O.

## B. Evening sweep view — OWNED BY the Sweep agent (`Volar/Sources/Views/SweepView.swift`)

```swift
struct SweepView: View {
    let items: [TaskItem]                    // today's open/in-progress tasks
    var onComplete: (TaskItem) -> Void       // one-tap or voice-confirmed done → CompletionEvent
    var onSkip: (TaskItem) -> Void
    var onDismiss: () -> Void
}
```
Calm batch, glance-and-dismiss, anti-shame (no red/badges — FR-036). Voice answering is driven by
AppState (the view exposes per-item complete/skip); the view itself is self-contained, inputs
injected. Skipped when `items` empty (presenter guards).

## C. App wiring — OWNED BY the App-wiring agent (`AppState.swift`, `PopoverView.swift`, `MenuBarLabel.swift`)
- **T036** In the capture pipeline, BEFORE treating a finished recording as new-task capture, call
  `VoiceDone.classify(...)`. On `.complete`/`.clearExternal`: single confident candidate → one-tap/
  one-word confirm in `PopoverView`; multiple → disambiguation; none-but-done-phrase → state it +
  offer capture. Confirm → complete the task (through `TaskStore`, feeding `CompletionEvent`) or
  clear the `.external` condition. `.notACompletion` → existing new-task confirm flow (Phase 3).
- **T037** Harden auto-advance: completion from ANY source (voice, notification action, UI toggle,
  sweep) recomputes `VolarCore.nextTask(from:now:calendar:)` and updates `MenuBarLabel` with NO
  intermediate empty/list state (FR-020). Consolidate so every completion path funnels through one
  refresh+advance function (avoid divergent update paths).
- **T038** Evening sweep: once-daily schedule (ISO-day `@AppStorage` gate like morning-frog/triage),
  skip-if-empty; present `SweepView(items:onComplete:onSkip:onDismiss:)`; wire voice answering
  ("xong cái A", "cái B chưa") through `VoiceDone` to batch-complete → `CompletionEvent`s.

## Non-negotiables (all agents)
Constitution II (voice-done ALWAYS confirms, never silently completes; multiple matches always
disambiguate; zero matches stated not guessed), V (glance-and-dismiss, single-task menu bar +
auto-advance preserved, no shame styling). Reuse Phase-2/3 APIs (TaskStore completion, CompletionLog,
nextTask with injected `calendar: .current`). Swift 6, macOS 14 floor. Windows: cannot build — mark
`// UNVERIFIED`. Do not commit/branch/edit backlog/tasks/other specs.
