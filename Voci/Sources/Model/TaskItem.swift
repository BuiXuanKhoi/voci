// Sources/Model/TaskItem.swift — UI/domain task model + mapping into VociCore.Task (v2 shape,
// contracts/vocicore-api.md). See VociTask.swift for the paired SwiftData persistence model.
import Foundation
import VociCore

/// Alias so app code (and Phase-2 views) can write `TaskStatus` without importing `VociCore`
/// everywhere — the lifecycle enum itself lives in the engine package and is not redefined here.
typealias TaskStatus = VociCore.TaskStatus

/// UI-facing priority, 1 (highest) ... 3 (lowest). Maps 1:1 onto `VociCore.Task.priority`'s
/// `Int` scale via `rawValue` (the engine additionally allows 4 / `nil`; this app never produces
/// those, so the UI enum only needs high/medium/low).
enum Priority: Int, Sendable, Equatable, CaseIterable, Codable {
    case high = 1
    case medium = 2
    case low = 3
}

/// UI-only "Now" vs "Later today" bucket. The engine has no notion of this; it is purely how
/// `TodayView` (Phase 2) groups the list, mirroring the prototype's `task.when`.
enum When: Sendable, Equatable, Codable {
    case now
    case later
}

struct TaskItem: Identifiable, Sendable, Equatable {
    let id: UUID
    var title: String
    var details: String
    var priority: Priority
    var status: TaskStatus
    var deadline: Date?
    /// Gates eligibility (replaces v1's `dependsOn: [UUID]` — data-model.md "Persisted layer").
    /// AND semantics, mirrors `VociCore.Task.conditions` 1:1 (see `snapshot()`). `.taskDone`
    /// edges must be validated via `TaskStore` before being attached (validation rule 1); this
    /// struct itself carries no validation, matching `VociCore.Condition`'s own pure-value
    /// nature — see `TaskStore`'s doc comments for the trust-boundary note.
    var conditions: [VociCore.Condition]
    var createdAt: Date
    var when: When
    var durationMinutes: Int?
    var frog: Bool

    // MARK: - v2 fields (specs/002-workflow-command-center/data-model.md "Persisted layer")

    /// Free-text notes, distinct from `details` (which stays the voice-capture read-back copy
    /// spoken by `AppState.speakDetails`).
    var notes: String?
    /// Verbatim utterance for voice-created tasks — always kept (FR-001).
    var sourceTranscript: String?
    var kind: TaskKind
    /// Leaf tasks only — `TaskStore.setRecurrence`/`add`/`addBatch` reject setting this on a task
    /// that has children (validation rule 2).
    var recurrence: Recurrence?
    /// `nil` -> global default `ReminderPolicy.defaultPolicy`.
    var reminderOverride: ReminderPolicy?
    /// "Save game" note surfaced on re-entry (FR-042).
    var resumeNote: String?
    /// Đổi-gió counter; ≥3 triggers a one-time breakdown suggestion (FR-030).
    var switchAwayCount: Int
    /// Latest completion instant; full history lives in `CompletionEvent` — recurrence resets
    /// in place, so this field alone can't reconstruct history.
    var completedAt: Date?
    /// Breakdown child -> parent link. Engine rule: a task that is a parent of any open child is
    /// excluded from `nextTask`, even though it stays selectable in its own right once every
    /// child is done/archived.
    var parentId: UUID?
    /// Present while delegated-to-AI (US4); cleared once the matching `.external` condition is
    /// satisfied (signal or manual).
    var delegation: DelegationMeta?

    init(
        id: UUID = UUID(),
        title: String,
        details: String = "",
        priority: Priority,
        status: TaskStatus = .todo,
        deadline: Date? = nil,
        conditions: [VociCore.Condition] = [],
        createdAt: Date = Date(),
        when: When,
        durationMinutes: Int? = nil,
        frog: Bool = false,
        notes: String? = nil,
        sourceTranscript: String? = nil,
        kind: TaskKind = .task,
        recurrence: Recurrence? = nil,
        reminderOverride: ReminderPolicy? = nil,
        resumeNote: String? = nil,
        switchAwayCount: Int = 0,
        completedAt: Date? = nil,
        parentId: UUID? = nil,
        delegation: DelegationMeta? = nil
    ) {
        self.id = id
        self.title = title
        self.details = details
        self.priority = priority
        self.status = status
        self.deadline = deadline
        self.conditions = conditions
        self.createdAt = createdAt
        self.when = when
        self.durationMinutes = durationMinutes
        self.frog = frog
        self.notes = notes
        self.sourceTranscript = sourceTranscript
        self.kind = kind
        self.recurrence = recurrence
        self.reminderOverride = reminderOverride
        self.resumeNote = resumeNote
        self.switchAwayCount = switchAwayCount
        self.completedAt = completedAt
        self.parentId = parentId
        self.delegation = delegation
    }

    /// Derived: "done" is purely the engine status, never a separately stored bool.
    var done: Bool { status == .done }

    /// Derived: formatted deadline time ("11:30 AM"); `nil` once done or when there's no
    /// deadline at all — matches the prototype's `timeBadge` (only ever shown for open tasks).
    var timeBadge: String? {
        guard !done, let deadline else { return nil }
        return deadline.formatted(.dateTime.hour().minute())
    }

    /// Derived: "45 min" / "1 hr" / "1h 30m" — matches the prototype's `dur` label.
    var durationLabel: String? {
        guard let durationMinutes, durationMinutes > 0 else { return nil }
        if durationMinutes < 60 { return "\(durationMinutes) min" }
        let hours = durationMinutes / 60
        let minutes = durationMinutes % 60
        if minutes == 0 { return hours == 1 ? "1 hr" : "\(hours) hrs" }
        return "\(hours)h \(minutes)m"
    }

    /// The only bridge into the pure selection engine (contracts/vocicore-api.md): maps this UI
    /// struct into the small value type `nextTask(from:now:calendar:)` actually consumes. No selection
    /// logic is duplicated here. `durationMinutes` feeds the engine's `estimateMinutes` — same
    /// concept, kept under its existing UI-facing name here (see TaskStore migration notes for
    /// why the persisted attribute name wasn't renamed to match).
    func snapshot() -> VociCore.Task {
        VociCore.Task(
            id: id,
            title: title,
            status: status,
            priority: priority.rawValue,
            deadline: deadline,
            conditions: conditions,
            estimateMinutes: durationMinutes,
            parentId: parentId,
            createdAt: createdAt
        )
    }
}
