import Foundation

/// The lifecycle status of a `Task`.
///
/// Eligibility mapping (see `nextTask(from:now:calendar:)`):
/// - Eligible for selection: `.todo`, `.inProgress`.
/// - Not eligible: `.done`, `.archived`.
///
/// Prerequisite-resolution mapping (see `DependencyGraph.swift` docs and `NextTask.swift`):
/// a prerequisite counts as *resolved* when the task it refers to is `.done` or `.archived`
/// (or is absent from the snapshot entirely, i.e. deleted). A prerequisite that is still
/// `.todo` or `.inProgress` continues to block its dependent.
public enum TaskStatus: Sendable, Equatable {
    case todo
    case inProgress
    case done
    case archived
}

/// A pure, immutable snapshot of a task, as consumed by the `VociCore` selection engine.
///
/// This is intentionally a small subset of the fully persisted task model (see
/// `specs/001-nexttask-engine/data-model.md`): only the fields relevant to eligibility and
/// ordering are represented here. The app layer is responsible for mapping its persisted
/// model (e.g. a SwiftData `@Model`) into this value type before calling into `VociCore`.
public struct Task: Sendable, Equatable, Identifiable {
    /// Stable unique identity. Used as the final tiebreak (lexical order of its string form)
    /// in `orderedBefore(now:calendar:)` to guarantee a strict total order.
    public let id: UUID

    /// Human-readable title. Not used by ordering or eligibility; carried so dependency-graph
    /// errors (`DependencyError`) can produce a readable message.
    public var title: String

    /// Drives eligibility (only `.todo`/`.inProgress` are selectable) and tier 1 of the
    /// ordering (in-progress ranks before to-do).
    public var status: TaskStatus

    /// Explicit priority on a 1 (highest) ... 4 scale. `nil` means "unset" and is a distinct
    /// state from any numeric value: unset priority always sorts after every explicit
    /// priority in tier 3 of the ordering.
    public var priority: Int?

    /// Absolute deadline instant (stored/compared in UTC; day-boundary classification uses
    /// the injected `Calendar`). `nil` means "no deadline".
    public var deadline: Date?

    /// Ids of prerequisite tasks. A task is eligible only once every id here is *resolved*
    /// (see `TaskStatus` doc comment above).
    public var dependsOn: [UUID]

    /// Creation timestamp; earlier tasks are preferred in tier 4 of the ordering when all
    /// prior tiers tie.
    public var createdAt: Date

    public init(
        id: UUID,
        title: String,
        status: TaskStatus,
        priority: Int?,
        deadline: Date?,
        dependsOn: [UUID],
        createdAt: Date
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.priority = priority
        self.deadline = deadline
        self.dependsOn = dependsOn
        self.createdAt = createdAt
    }
}
