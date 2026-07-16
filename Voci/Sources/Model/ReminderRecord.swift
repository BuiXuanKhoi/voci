// Sources/Model/ReminderRecord.swift — one persisted reminder intent for a task
// (specs/002-workflow-command-center/contracts/phase4-contract.md §A). `ReminderScheduler`
// (Sources/Reminders/ReminderScheduler.swift) is the only reader/writer of this model; this file
// defines just the persisted shape plus the pure derivation math, so both the shape and the
// escalation/offset logic stay unit-testable without a live `ModelContext`
// (Tests/ReminderSchedulerTests.swift exercises `derive` directly).
import Foundation
import SwiftData

/// Durable record of one reminder fire-time for one task. Constitution IV: the scheduler's entire
/// heap is rebuilt from rows of this type on every launch/wake — nothing about "what should fire
/// when" is allowed to live only in memory.
@Model
final class ReminderRecord {
    @Attribute(.unique) var id: UUID
    var taskId: UUID
    var fireAt: Date
    /// One of the contract's frozen kinds: "-1d" / "-1h" / "at" / "override" / "resurface" /
    /// "unblocked". "-1d"/"-1h"/"at" come from the global `ReminderPolicy.defaultPolicy`;
    /// "override" is any per-task `reminderOverride` offset that doesn't match one of those three
    /// standard values; "resurface" covers both `scheduleResurface` (FR-017) and
    /// `offerReschedule` (FR-016) — see `NotificationActions.category(forOffsetKind:)` for how
    /// the two are told apart at delivery time; "unblocked" is `notifyUnblocked` (FR-015).
    var offsetKind: String
    /// "scheduled" (durable, not yet fired) / "delivered" (visual shown, awaiting acknowledgment)
    /// / "satisfied" (suppressed-as-done, or resolved by a user action).
    var state: String
    /// Drives the voice escalation rung (contract §A): true for at-or-after-deadline offsets, so
    /// a plain "-1d"/"-1h" heads-up stays visual-only unless a PRIOR visual for the same task went
    /// unacknowledged (see `ReminderScheduler.evaluate`).
    var isHighUrgency: Bool

    init(
        id: UUID = UUID(),
        taskId: UUID,
        fireAt: Date,
        offsetKind: String,
        state: String = "scheduled",
        isHighUrgency: Bool = false
    ) {
        self.id = id
        self.taskId = taskId
        self.fireAt = fireAt
        self.offsetKind = offsetKind
        self.state = state
        self.isHighUrgency = isHighUrgency
    }
}

// MARK: - Derivation (pure — no I/O, no `ModelContext`, no clock reads)

extension ReminderRecord {
    /// Labels a raw policy offset with its contract-frozen kind string. Any offset that isn't one
    /// of the three global-policy standard values is necessarily a custom per-task override.
    private static func offsetKind(for offset: TimeInterval) -> String {
        switch offset {
        case -86400: return "-1d"
        case -3600: return "-1h"
        case 0: return "at"
        default: return "override"
        }
    }

    /// One `ReminderRecord` per offset in `reminderOverride ?? globalPolicy`, anchored to
    /// `deadline`. Returns `[]` when there's no deadline — per `VociCore.Task`'s own contract,
    /// deadlines never gate eligibility, and a reminder has nothing to count down to without one.
    /// Pure: deterministic for identical inputs, no dependency on the current wall clock (fire
    /// times land in the past for an already-overdue deadline; the scheduler's recovery path,
    /// not this function, decides what to do about that — see `ReminderScheduler.rebuildFromStorage`).
    static func derive(
        taskId: UUID,
        deadline: Date?,
        reminderOverride: ReminderPolicy?,
        globalPolicy: ReminderPolicy = .defaultPolicy
    ) -> [ReminderRecord] {
        guard let deadline else { return [] }
        let policy = reminderOverride ?? globalPolicy
        return policy.offsets.map { offset in
            ReminderRecord(
                taskId: taskId,
                fireAt: deadline.addingTimeInterval(offset),
                offsetKind: offsetKind(for: offset),
                isHighUrgency: offset >= 0
            )
        }
    }
}
