import Foundation

/// Returns the single task the menu bar should display right now, or `nil` when no task is
/// eligible.
///
/// This is the core of Constitution Principle III (Deterministic, Pure, Test-Gated Core): the
/// function performs no I/O, reads no global clock, and depends only on its three arguments.
/// For identical `(tasks, now, calendar)` it always returns the same result, regardless of the
/// order of `tasks` in the array (see `orderedBefore(now:calendar:)` for the total-order
/// guarantee that makes this true).
///
/// Eligibility (contract C-S1/C-S2):
/// - Only tasks with `status ∈ {.todo, .inProgress}` are considered.
/// - A task is excluded while any `dependsOn` id is unresolved. An id is *resolved* when the
///   task it refers to is `.done`, `.archived`, or absent from `tasks` (deleted).
///
/// Ordering (contract C-S3): among eligible tasks, the minimum under
/// `orderedBefore(now:calendar:)` is returned.
///
/// Auto-advance (User Story 2): this function has no notion of an "active" task or history —
/// completing a task and re-invoking `nextTask(from:now:calendar:)` with the updated snapshot
/// (the completed task now has `status == .done`) is sufficient to advance to the next correct
/// task, because `.done` tasks are never eligible. Recomputing after every status change, and
/// any "Next: …" transition, is the caller's (app's) responsibility — this module only ever
/// answers "what is next task right now for this snapshot".
public func nextTask(
    from tasks: [Task],
    now: Date,
    calendar: Calendar = .current
) -> Task? {
    // Build an id -> status lookup once per call so dependency resolution is O(1) per edge
    // instead of an O(n) scan per prerequisite. Built with an explicit loop (rather than
    // `Dictionary(uniqueKeysWithValues:)`) so a malformed snapshot with duplicate ids cannot
    // crash the engine; the last occurrence for a given id wins.
    var statusByID: [UUID: TaskStatus] = [:]
    statusByID.reserveCapacity(tasks.count)
    for task in tasks {
        statusByID[task.id] = task.status
    }

    let eligible = tasks.filter { task in
        guard task.status == .todo || task.status == .inProgress else { return false }
        return task.dependsOn.allSatisfy { prerequisiteID in
            guard let prerequisiteStatus = statusByID[prerequisiteID] else {
                // Absent from the snapshot: deleted, therefore resolved.
                return true
            }
            return prerequisiteStatus == .done || prerequisiteStatus == .archived
        }
    }

    return eligible.min(by: orderedBefore(now: now, calendar: calendar))
}

/// A strict total order over tasks for a given reference time: returns `true` iff `a` should be
/// selected before `b`.
///
/// Comparison is first-difference-wins across five tiers (data-model.md):
/// 1. Status class — `.inProgress` before `.todo` (and, defensively, before `.done`/`.archived`
///    should this comparator ever be invoked on ineligible tasks).
/// 2. Deadline urgency relative to `now` (using the injected `calendar` for day-boundary
///    classification) — a today-or-overdue deadline ranks before no such deadline; among
///    today/overdue tasks, the earlier deadline instant ranks first. A deadline strictly in the
///    future beyond today does NOT participate in this tier (contract C-O3).
/// 3. Explicit priority ascending (1 highest); `nil` (unset) ranks after every explicit 1...4
///    value (contract C-O4).
/// 4. Earlier `createdAt` first.
/// 5. Lexical order of `id.uuidString` — this final tier is total over distinct `UUID`s, which
///    is what makes the overall relation a strict total order (irreflexive, asymmetric,
///    transitive) and therefore safe to pass to `Array.min(by:)` (contract C-O2).
public func orderedBefore(
    now: Date,
    calendar: Calendar = .current
) -> (_ a: Task, _ b: Task) -> Bool {
    return { a, b in
        // Tier 1: status class.
        let aStatusRank = statusRank(a.status)
        let bStatusRank = statusRank(b.status)
        if aStatusRank != bStatusRank {
            return aStatusRank < bStatusRank
        }

        // Tier 2: deadline urgency (today/overdue) relative to `now`.
        let aIsNearTerm = isNearTermDeadline(a.deadline, now: now, calendar: calendar)
        let bIsNearTerm = isNearTermDeadline(b.deadline, now: now, calendar: calendar)
        if aIsNearTerm != bIsNearTerm {
            return aIsNearTerm
        }
        if aIsNearTerm, bIsNearTerm, let aDeadline = a.deadline, let bDeadline = b.deadline, aDeadline != bDeadline {
            return aDeadline < bDeadline
        }

        // Tier 3: explicit priority ascending; nil sorts after every explicit value.
        let aPriorityRank = priorityRank(a.priority)
        let bPriorityRank = priorityRank(b.priority)
        if aPriorityRank != bPriorityRank {
            return aPriorityRank < bPriorityRank
        }

        // Tier 4: earlier creation time first.
        if a.createdAt != b.createdAt {
            return a.createdAt < b.createdAt
        }

        // Tier 5: stable total-order tiebreak.
        return a.id.uuidString < b.id.uuidString
    }
}

/// Ordinal used purely for tier-1 comparison; lower ranks are selected first.
/// `.done`/`.archived` are never eligible for selection, but are given a defined (and higher)
/// rank so `orderedBefore` remains a valid total order even if ever invoked outside the
/// eligible-only code path in `nextTask`.
private func statusRank(_ status: TaskStatus) -> Int {
    switch status {
    case .inProgress: return 0
    case .todo: return 1
    case .done: return 2
    case .archived: return 3
    }
}

/// A deadline is "near-term" (today or overdue) relative to `now` iff it is strictly before
/// `now` (overdue) or falls on the same local calendar day as `now` (today), per the injected
/// `calendar`. A `nil` deadline, or one strictly in the future beyond today, is not near-term.
private func isNearTermDeadline(_ deadline: Date?, now: Date, calendar: Calendar) -> Bool {
    guard let deadline else { return false }
    if deadline < now { return true }
    return calendar.isDate(deadline, inSameDayAs: now)
}

/// Maps an optional priority to a rank where lower sorts first; `nil` (unset) maps to a value
/// greater than any valid explicit priority (1...4) so it always sorts last.
private func priorityRank(_ priority: Int?) -> Int {
    priority ?? Int.max
}
