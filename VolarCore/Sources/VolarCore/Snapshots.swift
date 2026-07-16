import Foundation

/// Ids of tasks that are eligible (per `eligibleTasks(in:now:)`, the same rule `nextTask` uses)
/// in `after` but were not eligible in `before` — pure set logic, feeding auto-unblock
/// notifications (FR-015).
///
/// Only status/condition-driven changes are reported: a task absent from `before` entirely but
/// eligible in `after` counts as newly eligible (it was, trivially, not eligible in `before`). A
/// task that becomes ineligible (e.g. un-completing a prerequisite re-blocks a dependent) is
/// simply not in the result — this function only ever reports additions, never removals.
///
/// Deduplicates by id (an adversarial snapshot with duplicate ids never yields duplicate ids in
/// the result) and preserves the order in which each newly-eligible id first appears in `after`.
public func eligibilityDiff(before: [Task], after: [Task], now: Date) -> [UUID] {
    let eligibleBeforeIDs = Set(eligibleTasks(in: before, now: now).map(\.id))

    var seen: Set<UUID> = []
    var newlyEligible: [UUID] = []
    for task in eligibleTasks(in: after, now: now) {
        guard !eligibleBeforeIDs.contains(task.id) else { continue }
        guard seen.insert(task.id).inserted else { continue }
        newlyEligible.append(task.id)
    }
    return newlyEligible
}

/// The earliest strictly-future `.afterDate` payload anywhere in `snapshot`, or `nil` if none
/// exists — feeds the resurface scheduler (FR-017).
///
/// Scans every task's `conditions` regardless of current eligibility or status (a task that is
/// currently ineligible for other reasons may still resurface once its `.afterDate` arrives).
/// "Strictly future" means `date > now`; a date equal to or before `now` is already satisfied
/// (see `Condition.isSatisfied`) and never a candidate for resurfacing.
public func nextResurfaceDate(in snapshot: [Task], after now: Date) -> Date? {
    var earliest: Date?
    for task in snapshot {
        for condition in task.conditions {
            guard case .afterDate(let date) = condition, date > now else { continue }
            if earliest == nil || date < earliest! {
                earliest = date
            }
        }
    }
    return earliest
}
