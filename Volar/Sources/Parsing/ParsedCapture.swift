// Sources/Parsing/ParsedCapture.swift — `task_refs_v1` (anh Khôi, 2026-08-02 task-refs design):
// the validated result of a Cloud parse that also references/updates EXISTING tasks, on top of the
// `[ParsedTask]` (brand-new tasks) the app already handles. "làm task này khi xong task kia", "task
// kia phải xong hôm nay" — the model can now point at a task that isn't in this response's own
// `tasks[]` (`ParsedTaskRef`) and propose an edit to it (`ParsedTaskUpdate`), instead of only ever
// extracting fresh tasks.
//
// PINNED PUBLIC SURFACE — implemented verbatim against the sibling agent's frozen consumption
// contract (`Sources/App/AppState.swift`, `Sources/Views/PopoverView.swift`); do not rename fields
// or reorder them without re-checking that contract, since neither side of this split can compile
// to catch drift.
//
// Access level matches `ParsedTask`/`ParsedValue`/`ParsedCondition` in `Sources/Model/NLParser.swift`
// (READ-ONLY reference for this file, not edited here): no explicit `public`/`internal` keyword —
// this codebase's parsing layer stays at the default `internal` level throughout.
//
// CLIENT SCOPE DECISIONS (anh Khôi, 2026-08-02 — see call sites below for where each applies):
//   (b) `ParsedTaskUpdate` is INERT data. Nothing in this file (or `CloudParser.swift`/
//       `IntentParsing.swift`) ever auto-applies an update to an existing task — the confirm-card
//       owner (AppState/PopoverView) is responsible for surfacing a confirm chip and only writing
//       the change on explicit user action. This file's job ends at "decode + validate the shape
//       safely," never "mutate a task."
//   (c) `reminderOverride`/`anchor` on the wire's `set` object is decoded tolerantly and DROPPED
//       this round — no `reminderOverride` field exists on `ParsedTaskUpdate` at all. See
//       `RawUpdateSet`'s doc comment in `IntentParsing.swift` for how "tolerant decode" is achieved
//       for free (Swift's synthesized `Decodable` simply ignores JSON keys with no matching stored
//       property) rather than requiring any special-case handling here.
import Foundation

// MARK: - ParsedTaskRef

/// One existing (or user-implied) task the model believes the utterance is pointing at — mirrors
/// `TaskRefOut` in `supabase/functions/_shared/schema.ts`. Identity resolution (fuzzy-matching
/// `titleQuery` against the local task store, or treating it as "no such task yet") is entirely the
/// CLIENT's job — this type carries no task id, only the words to search by, exactly like
/// `ParsedCondition.taskDone`'s `titleQuery` already does for the same reason.
struct ParsedTaskRef: Sendable, Equatable {
    /// The words identifying the referenced task (either an exact echo of one of this device's own
    /// `openTaskTitles`, or the user's own spoken words when the model can't find a match).
    var titleQuery: String
    /// 0...1, clamped at validation (`ParsedTaskValidation.validateTaskRefs`) — NEVER used to
    /// auto-attach a match; the confirm-card owner still requires an explicit user pick, same as
    /// every other fuzzy title reference in this codebase (`ParsedCondition.taskDone`).
    var confidence: Double
    /// The model's advisory hint that the user meant an ALREADY-EXISTING task, as opposed to one it
    /// just extracted fresh or one it couldn't place at all. `false` when absent on the wire (an
    /// absent hint carries no signal either way) — never causes an auto-commit by itself; the
    /// client's own local resolution is the source of truth.
    var assumeExisting: Bool = false
}

// MARK: - ParsedUpdateCondition

/// A NEW dependency an update proposes adding to the REFERENCED (existing) task — mirrors
/// `TaskUpdateConditionOut` in `_shared/schema.ts`. Deliberately its OWN small enum, not a reuse of
/// `ParsedCondition` (`Sources/Model/NLParser.swift`, off-limits this round): `.taskDoneNewTask`
/// points into THIS response's own freshly-extracted `tasks[]` by array position, a completely
/// different index space from `ParsedCondition.taskDone`'s fuzzy `titleQuery` string — conflating
/// the two would silently blur "wait for task #N in this very response" with "wait for some task,
/// resolved by title, anywhere in the store."
enum ParsedUpdateCondition: Sendable, Equatable {
    /// `index` is 1-based into `ParsedCapture.tasks` (this SAME response's own validated, newly
    /// extracted tasks — post-cap, post-validation) — "the referenced existing task must now wait
    /// for new task #N," e.g. "task kia phải chờ task mới này xong."
    case taskDoneNewTask(index: Int)
    case afterDate(Date)
}

// MARK: - ParsedTaskUpdate

/// One proposed edit to an EXISTING task, identified via `ParsedCapture.taskRefs[refIndex - 1]` —
/// mirrors `TaskUpdateOut` in `_shared/schema.ts`. Every field independently optional (a `set` that
/// only touches `priority`, say, leaves every other attribute of the referenced task untouched) —
/// same "assistive, never authoritative" posture `ParsedTask` itself documents, and per client scope
/// decision (b) above: NEVER auto-committed, always surfaced for confirmation first.
struct ParsedTaskUpdate: Sendable, Equatable {
    /// 1-based into `ParsedCapture.taskRefs`. Validation (`ParsedTaskValidation.validateTaskUpdates`)
    /// guarantees this is in-range against the ALREADY-VALIDATED `taskRefs` count — an update whose
    /// `refIndex` doesn't resolve is dropped whole at validation time, never constructed with a
    /// dangling index (mirrors `CloudParser.CompletionResolution.resolved`'s identical "bounds
    /// already checked before this case exists" guarantee for a different 1-based wire index).
    var refIndex: Int
    var deadline: ParsedValue<Date>? = nil
    var startTime: ParsedValue<Date>? = nil
    /// APPEND semantics, not replace — the confirm-card owner appends this to the referenced task's
    /// EXISTING notes. Named `notesAppend`, not `notes`, specifically so it is never confused with
    /// `ParsedTask.notes`'s replace-the-whole-field semantics (same naming rationale
    /// `TaskUpdateSetOut.notesAppend`'s server-side doc comment gives).
    var notesAppend: ParsedValue<String>? = nil
    /// 1...4, same range as `ParsedTask.priority`.
    var priority: ParsedValue<Int>? = nil
    var addConditions: [ParsedUpdateCondition] = []
}

// MARK: - ParsedCapture

/// The full validated result of one Cloud parse under `client_caps: ["task_refs_v1"]` — `tasks` is
/// exactly what `CloudParser.parse`/`IntentRouter.parse` already returned before this round;
/// `taskRefs`/`updates` are the new task_refs_v1 additions, always empty for every tier/path that
/// has nothing honest to contribute to them (FM, the on-device heuristic floor, the title-only
/// floor, and Cloud talking to a server that hasn't been redeployed with envelope support yet — see
/// `IntentRouter.parseCapture`'s and `CloudParser.performParse`'s own doc comments for exactly which
/// paths populate which fields).
struct ParsedCapture: Sendable, Equatable {
    var tasks: [ParsedTask] = []
    var taskRefs: [ParsedTaskRef] = []
    var updates: [ParsedTaskUpdate] = []
}
