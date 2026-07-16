// Sources/Model/Recurrence.swift — recurrence rule + reset-in-place engine (research.md R8),
// reminder policy, delegation metadata, and task kind. All four are persisted as JSON blobs on
// `VolarTask` (see VolarTask.swift) — this file only defines the pure value types + pure math.
import Foundation
import VolarCore

// MARK: - TaskKind

/// UI treatment only (data-model.md) — the engine has no notion of this.
enum TaskKind: String, Sendable, Equatable, Codable, CaseIterable {
    case task
    case review
}

// MARK: - Recurrence

/// Leaf-task-only schedule. `TaskStore.setRecurrence`/`add`/`addBatch` enforce "no children"
/// (validation rule 2) at the persistence boundary — this type itself is a pure value with no
/// awareness of the task graph.
enum Recurrence: Sendable, Equatable {
    case daily
    case weekly
    case monthly
    case every(days: Int)
}

extension Recurrence: Codable {
    /// Hand-rolled (rather than relying on compiler-synthesized `Codable` for an enum with
    /// associated values) so the on-disk shape is explicit, stable across app versions, and
    /// independent of any toolchain synthesis behavior — this JSON blob is what a future
    /// migration/export tool needs to read reliably.
    private enum Kind: String, Codable { case daily, weekly, monthly, every }
    private struct Wire: Codable { var kind: Kind; var days: Int? }

    init(from decoder: Decoder) throws {
        let wire = try Wire(from: decoder)
        switch wire.kind {
        case .daily: self = .daily
        case .weekly: self = .weekly
        case .monthly: self = .monthly
        case .every:
            guard let days = wire.days else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "Recurrence.every is missing its `days` payload"
                )
            }
            self = .every(days: days)
        }
    }

    func encode(to encoder: Encoder) throws {
        let wire: Wire
        switch self {
        case .daily: wire = Wire(kind: .daily, days: nil)
        case .weekly: wire = Wire(kind: .weekly, days: nil)
        case .monthly: wire = Wire(kind: .monthly, days: nil)
        case .every(let days): wire = Wire(kind: .every, days: days)
        }
        try wire.encode(to: encoder)
    }
}

// MARK: - ReminderPolicy

struct ReminderPolicy: Sendable, Equatable, Codable {
    /// Offsets relative to the task's deadline (seconds; negative = before). Default global
    /// policy per data-model.md: -1 day, -1 hour, at-deadline.
    var offsets: [TimeInterval]
    /// "Every 30 minutes" style repeat after the deadline; `nil` = fire once per offset only.
    var repeatEvery: TimeInterval?

    static let defaultPolicy = ReminderPolicy(offsets: [-86400, -3600, 0], repeatEvery: nil)
}

// MARK: - DelegationMeta

/// Present on a task while delegated-to-AI (US4). Lifecycle owned by the (later) orchestrator
/// layer — this file only defines the persisted shape.
struct DelegationMeta: Sendable, Equatable, Codable {
    var label: String
    var checkBackAt: Date
    /// 0 -> 10', 1 -> 30', >=2 -> batch-only (research.md R9).
    var backoffStage: Int
    var cwdHint: String?
    var delegatedAt: Date
}

// MARK: - Recurrence reset-in-place engine (research.md R8)

/// Pure recurrence math: every function takes an explicit `Calendar` and does all date math via
/// `Calendar` components (never bare `Date`/`TimeInterval` arithmetic), so DST transitions and
/// variable month lengths are resolved by the OS calendar rather than assumed by this code.
enum RecurrenceEngine {
    /// The date one occurrence of `rule` after `anchor`.
    ///
    /// // UNVERIFIED: confirm on Mac that `Calendar.date(byAdding: .month, ...)` CLAMPS an
    /// invalid day-of-month to the last valid day (Jan 31 + 1 month -> Feb 28, and Feb 29 in a
    /// leap year + 1 month -> Mar 29) rather than rolling over into the following month, and that
    /// `.day`/`.weekOfYear` addition across a DST spring-forward gap resolves to a valid
    /// wall-clock instant instead of producing `nil` or an off-by-one-hour result.
    static func advance(_ anchor: Date, by rule: Recurrence, calendar: Calendar) -> Date? {
        switch rule {
        case .daily:
            return calendar.date(byAdding: .day, value: 1, to: anchor)
        case .weekly:
            return calendar.date(byAdding: .weekOfYear, value: 1, to: anchor)
        case .monthly:
            return calendar.date(byAdding: .month, value: 1, to: anchor)
        case .every(let days):
            // Malformed rule guard: never produced by a valid parse/UI path, but a corrupted
            // store could contain `every(days: 0)` or negative — treat as "can't advance" rather
            // than silently looping the caller or producing a date in the past.
            guard days > 0 else { return nil }
            return calendar.date(byAdding: .day, value: days, to: anchor)
        }
    }

    /// The persisted fields a reset touches — deliberately narrow (not the whole `VolarTask`) so
    /// this stays a pure function that's trivially unit-testable without SwiftData.
    struct Reset: Sendable, Equatable {
        var deadline: Date?
        var conditions: [VolarCore.Condition]
    }

    /// Completion -> reset-in-place: reopen at the next occurrence. Schedule-anchored by default
    /// (weekly-Monday stays Monday no matter which weekday it was actually completed);
    /// `anchorToCompletion` re-anchors this ONE cycle to `completedAt` instead (the capture-time
    /// "starting from today" override, FR-006). `.afterDate` conditions shift by the same rule,
    /// each from its own prior date; `.external` conditions reset to unsatisfied (a fresh cycle
    /// re-waits on whatever it was waiting on); `.taskDone` conditions are left untouched — a
    /// recurring task's cross-task prerequisites don't reset with its own schedule.
    static func reset(
        recurrence: Recurrence,
        deadline: Date?,
        conditions: [VolarCore.Condition],
        completedAt: Date,
        anchorToCompletion: Bool,
        calendar: Calendar
    ) -> Reset {
        func nextOccurrence(from original: Date) -> Date {
            let anchor = anchorToCompletion ? completedAt : original
            // If advancing ever fails (defensive — see `advance`'s doc comment), fall back to the
            // anchor unshifted rather than producing `nil`/crashing; a stuck-in-place recurring
            // task is a visible, recoverable bug, not a crash.
            return advance(anchor, by: recurrence, calendar: calendar) ?? anchor
        }

        let nextDeadline: Date?
        if let deadline {
            nextDeadline = nextOccurrence(from: deadline)
        } else if anchorToCompletion {
            nextDeadline = advance(completedAt, by: recurrence, calendar: calendar)
        } else {
            // No prior schedule to anchor to and no override — stays undated; only its
            // `.afterDate`/`.external` conditions (if any) gate the next cycle.
            nextDeadline = nil
        }

        let nextConditions = conditions.map { condition -> VolarCore.Condition in
            switch condition {
            case .afterDate(let date):
                return .afterDate(nextOccurrence(from: date))
            case .external(let description, _):
                return .external(description: description, satisfied: false)
            case .taskDone:
                return condition
            }
        }

        return Reset(deadline: nextDeadline, conditions: nextConditions)
    }
}
