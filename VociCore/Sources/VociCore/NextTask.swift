import Foundation

/// Returns the single task the menu bar should display right now, or `nil` when no task is
/// eligible.
///
/// This is the core of Constitution Principle III (Deterministic, Pure, Test-Gated Core): the
/// function performs no I/O, reads no global clock, and depends only on its two arguments. For
/// identical `(snapshot, now)` it always returns the same result, regardless of the order of
/// `snapshot` (see `Task.orderedBefore(_:now:)` for the total-order guarantee that makes this
/// true).
///
/// Eligibility (v2 — see `Condition.swift` and `specs/002-workflow-command-center/data-model.md`
/// "Engine layer"):
/// - Only tasks with `status ∈ {.todo, .inProgress}` are considered.
/// - A task is excluded while any of its `conditions` is unsatisfied (AND semantics).
/// - A task that is the parent (via another task's `parentId`) of any `.todo`/`.inProgress`
///   child is excluded, even if that child is itself ineligible for other reasons.
///
/// Ordering (unchanged from 001): among eligible tasks, the minimum under
/// `Task.orderedBefore(_:now:)` is returned.
public func nextTask(from snapshot: [Task], now: Date) -> Task? {
    eligibleTasks(in: snapshot, now: now).min { $0.orderedBefore($1, now: now) }
}

/// All eligible tasks in `snapshot` at `now`, in the original (unordered) array order. Shared by
/// `nextTask` and `eligibilityDiff` (`Snapshots.swift`) so the eligibility rule lives in exactly
/// one place.
///
/// O(n) precomputation (an `id -> status` lookup and an `id -> hasOpenChild` set, each built with
/// a single pass) followed by an O(n) filter — no per-task or per-comparison rescans of the
/// snapshot, so this stays linear even at large n.
func eligibleTasks(in snapshot: [Task], now: Date) -> [Task] {
    // Built with an explicit loop (rather than `Dictionary(uniqueKeysWithValues:)`) so a
    // malformed snapshot with duplicate ids cannot crash the engine; the last occurrence for a
    // given id wins.
    var statusByID: [UUID: TaskStatus] = [:]
    statusByID.reserveCapacity(snapshot.count)
    for task in snapshot {
        statusByID[task.id] = task.status
    }

    // Ids that are the `parentId` of at least one currently-open (todo/inProgress) task. This is
    // a single O(n) pass over direct parent-child edges only — it does not walk parent chains,
    // so a `parentId` cycle in adversarial data cannot cause unbounded recursion here.
    var parentsWithOpenChild: Set<UUID> = []
    parentsWithOpenChild.reserveCapacity(snapshot.count)
    for task in snapshot {
        guard let parentId = task.parentId,
              task.status == .todo || task.status == .inProgress
        else { continue }
        parentsWithOpenChild.insert(parentId)
    }

    return snapshot.filter { task in
        guard task.status == .todo || task.status == .inProgress else { return false }
        guard !parentsWithOpenChild.contains(task.id) else { return false }
        return task.conditions.allSatisfy { $0.isSatisfied(statusByID: statusByID, now: now) }
    }
}

extension Task {
    /// A strict total order over tasks for a given reference time: returns `true` iff `self`
    /// should be selected before `other`.
    ///
    /// Comparison is first-difference-wins across five tiers (data-model.md; unchanged from
    /// 001):
    /// 1. Status class — `.inProgress` before `.todo` (and, defensively, before `.done`/
    ///    `.archived` should this comparator ever be invoked on ineligible tasks).
    /// 2. Deadline urgency relative to `now` — a today-or-overdue deadline ranks before no such
    ///    deadline; among today/overdue tasks, the earlier deadline instant ranks first. A
    ///    deadline strictly in the future beyond today does NOT participate in this tier.
    /// 3. Explicit priority ascending (1 highest); `nil` (unset) ranks after every explicit
    ///    1...4 value.
    /// 4. Earlier `createdAt` first.
    /// 5. Lexical order of `id.uuidString` — this final tier is total over distinct `UUID`s,
    ///    which is what makes the overall relation a strict total order (irreflexive,
    ///    asymmetric, transitive) and therefore safe to pass to `Array.min(by:)`.
    public func orderedBefore(_ other: Task, now: Date) -> Bool {
        // Tier 1: status class.
        let selfStatusRank = statusRank(status)
        let otherStatusRank = statusRank(other.status)
        if selfStatusRank != otherStatusRank {
            return selfStatusRank < otherStatusRank
        }

        // Tier 2: deadline urgency (today/overdue) relative to `now`.
        let selfIsNearTerm = isNearTermDeadline(deadline, now: now)
        let otherIsNearTerm = isNearTermDeadline(other.deadline, now: now)
        if selfIsNearTerm != otherIsNearTerm {
            return selfIsNearTerm
        }
        if selfIsNearTerm, otherIsNearTerm,
           let selfDeadline = deadline, let otherDeadline = other.deadline,
           selfDeadline != otherDeadline {
            return selfDeadline < otherDeadline
        }

        // Tier 3: explicit priority ascending; nil sorts after every explicit value.
        let selfPriorityRank = priorityRank(priority)
        let otherPriorityRank = priorityRank(other.priority)
        if selfPriorityRank != otherPriorityRank {
            return selfPriorityRank < otherPriorityRank
        }

        // Tier 4: earlier creation time first.
        if createdAt != other.createdAt {
            return createdAt < other.createdAt
        }

        // Tier 5: stable total-order tiebreak.
        return id.uuidString < other.id.uuidString
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

/// The fixed calendar the engine uses for "same calendar day" classification (tier 2). The v2
/// public API dropped the `calendar` parameter that 001 exposed (`nextTask(from:now:calendar:)`)
/// to keep the engine fully deterministic regardless of the host device's locale/time zone
/// settings — see `specs/002-workflow-command-center/contracts/vocicore-api.md`. Gregorian/UTC
/// matches the fixed calendar the test suite already anchors on (`Fixtures.swift`).
// UNVERIFIED: confirm on Mac (and with product) that pinning "today" classification to UTC
// (rather than the device's local calendar, as 001's `calendar: Calendar = .current` default
// did) is the intended v2 behavior. The public API contract removed the `calendar` parameter
// entirely, and purity (no locale/timezone reads) requires a fixed calendar here — UTC is the
// only calendar the engine can canonically agree on with the test suite (`Fixtures.swift`'s
// `testCalendar`). If deadlines are stored/compared in the user's local time near a day
// boundary, this can classify "today" differently than local-calendar 001 did.
private let engineCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

/// A deadline is "near-term" (today or overdue) relative to `now` iff it is strictly before
/// `now` (overdue) or falls on the same UTC calendar day as `now` (today). A `nil` deadline, or
/// one strictly in the future beyond today, is not near-term.
private func isNearTermDeadline(_ deadline: Date?, now: Date) -> Bool {
    guard let deadline else { return false }
    if deadline < now { return true }
    return engineCalendar.isDate(deadline, inSameDayAs: now)
}

/// Maps an optional priority to a rank where lower sorts first; `nil` (unset) maps to a value
/// greater than any valid explicit priority (1...4) so it always sorts last.
private func priorityRank(_ priority: Int?) -> Int {
    priority ?? Int.max
}
