// Sources/Model/TaskItem.swift — UI/domain task model + mapping into VociCore.Task (frozen §4)
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
    var priority: Priority
    var status: TaskStatus
    var deadline: Date?
    var dependsOn: [UUID]
    var createdAt: Date
    var when: When
    var durationMinutes: Int?
    var frog: Bool

    init(
        id: UUID = UUID(),
        title: String,
        priority: Priority,
        status: TaskStatus = .todo,
        deadline: Date? = nil,
        dependsOn: [UUID] = [],
        createdAt: Date = Date(),
        when: When,
        durationMinutes: Int? = nil,
        frog: Bool = false
    ) {
        self.id = id
        self.title = title
        self.priority = priority
        self.status = status
        self.deadline = deadline
        self.dependsOn = dependsOn
        self.createdAt = createdAt
        self.when = when
        self.durationMinutes = durationMinutes
        self.frog = frog
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

    /// The only bridge into the pure selection engine (feature 001): maps this UI struct into
    /// the small value type `nextTask(from:now:calendar:)` actually consumes. No selection logic
    /// is duplicated here.
    func toEngineTask() -> VociCore.Task {
        VociCore.Task(
            id: id,
            title: title,
            status: status,
            priority: priority.rawValue,
            deadline: deadline,
            dependsOn: dependsOn,
            createdAt: createdAt
        )
    }
}
