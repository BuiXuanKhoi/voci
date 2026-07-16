# Contract: Intent Parsing v2 (Phase 3 / US1)

Frozen seam between the Phase-3 parallel agents. Everyone codes against THIS, not each other's
files (proven Phase-2 pattern). Won't fully compile until all agents land + Mac verify; the
contract guarantees consistency. Owner of each type is named; others reference by shape.

## `ParsedTask` v2 — OWNED BY the NLParser agent (in `Voci/Sources/Model/NLParser.swift`)

The validated value the confirm card renders and `confirmSave` materializes. Assistive, never
authoritative (constitution II). Codable. Replaces the v1 `ParsedTask`.

```swift
struct ParsedTask: Sendable, Equatable {
    var title: String                         // required; only guaranteed field
    var notes: String?
    var deadline: ParsedValue<Date>?          // resolved absolute instant
    var estimateMinutes: ParsedValue<Int>?
    var priority: ParsedValue<Int>?           // 1...4
    var reminderOverride: ParsedValue<ReminderPolicy>?
    var recurrence: ParsedValue<Recurrence>?
    var kind: TaskKind                         // default .task; .review when "review after…"
    var conditions: [ParsedCondition]          // taskDone(by fuzzy title ref) / afterDate / external
    var subtasks: [String]                     // breakdown step titles (may be empty)
    var followUpReview: Bool                    // "when done, review it" → a second .review task
    var sourceTranscript: String               // verbatim utterance, ALWAYS retained
}

/// Wraps a parsed attribute with its model confidence so the UI can gate it.
struct ParsedValue<T: Sendable & Equatable>: Sendable, Equatable {
    var value: T
    var confidence: Double                     // 0…1
    var isUncertain: Bool { confidence < 0.7 } // <0.7 → dashed "uncertain" chip; never auto-committed
}

/// A parsed blocking condition BEFORE resolution to VociCore.Condition.
/// taskDone references a task by fuzzy title (resolved to a UUID via picker at confirm time,
/// NEVER auto-attached below 0.7 — constitution II).
enum ParsedCondition: Sendable, Equatable {
    case taskDone(titleQuery: String, confidence: Double)
    case afterDate(Date, confidence: Double)
    case external(description: String, confidence: Double)
}
```

`Recurrence`, `ReminderPolicy`, `TaskKind` already exist (agent-B Phase-2, `Recurrence.swift`) —
reuse, do not redefine.

## `IntentParsing` — OWNED BY the Parsing agent (`Voci/Sources/Parsing/IntentParsing.swift`)

```swift
protocol IntentParser: Sendable {
    /// Parse one utterance into 1…10 tasks. Never throws for content reasons — a failure to
    /// parse an attribute degrades that attribute, never the whole result (constitution II).
    func parse(_ transcript: String, now: Date, openTaskTitles: [String]) async -> [ParsedTask]
    /// Breakdown mode: a parent title → 3…9 step titles (5–15 min each, first trivially small).
    func breakdown(title: String, notes: String?) async -> [String]
}

/// Routes FM (on-device, if available) → Cloud (opted-in + online + within quota) → Heuristic.
/// ALWAYS returns a usable result: any route failure falls through to the next; heuristic is
/// the floor and never unavailable. Enforces the 10-task cap regardless of route.
@MainActor final class IntentRouter { /* selects + falls through; see T019 */ }
```

Routing rules (R5):
- On-device FM (`FoundationModelParser`, macOS 26 + Apple Silicon via capability probe) → all tiers.
- Else Cloud (`CloudParser`, POST to `/functions/v1/parse` per `parse-proxy.md`) IF: user opted in
  (one-time privacy consent) AND online AND not over quota (429 → fall through, gentle note).
- Else Heuristic (`HeuristicNLParser`, always available).
- Cloud/FM raw output decodes into validated `ParsedTask`; any decode/schema violation →
  title-only task carrying the transcript (constitution II), NEVER a crash, NEVER discard the
  whole utterance.
- `openTaskTitles` (≤100, titles only) passed to Cloud ONLY when the transcript contains
  dependency phrasing ("sau khi", "xong … thì", "after", "when … done").

## Confirm + materialize — OWNED BY the AppState/PopoverView agent

- Confirm card renders each present attribute as a dismissible chip; `isUncertain` attributes
  render dashed with `?` and require an explicit tap to accept (constitution II). `taskDone`
  conditions below 0.7 show a task PICKER (never auto-attach).
- Saving materializes ≤10 tasks through `TaskStore` validation (existing Phase-2 API): resolve
  `ParsedCondition.taskDone(titleQuery)` → a real task UUID (picker/fuzzy), build
  `VociCore.Condition`s, create the task(s); if `followUpReview`, create a second `.review` task
  depending on the first; persist `sourceTranscript` on every voice-created task.
- Every user edit of a parsed attribute logs a `ParseCorrection` (local-only, FR-044).

## Non-negotiables (all agents)
- Constitution II (never silently guess), V (glance-and-dismiss chips, not a form).
- Audio never reaches any parser (text only in/out of the parse tier).
- Swift 6 strict concurrency; macOS 14 floor; `#available(macOS 26)` for FM.
- Windows: cannot build — mark `// UNVERIFIED`. Do not commit/branch. Do not edit backlog/tasks/other specs.
