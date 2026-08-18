import Foundation
import Testing
@testable import VolarCore

/// specs/009-light-mode-list-v2 §6: `rankReason(for:now:calendar:)` gives the UI a reason string
/// source ("quá hạn 2h" / "hạn hôm nay 16:00" / "ưu tiên cao") instead of a bare position in the
/// list. One test per case, plus an invariant tying it back to `eligibleTasksOrdered`'s actual
/// ordering, and a purity check (Constitution Principle III).
@Suite("rankReason")
struct RankReasonTests {

    @Test("in-progress task returns .inProgress regardless of deadline or priority")
    func inProgressReturnsInProgress() {
        let task = makeTask(id: fixedUUID(1), status: .inProgress, priority: 4, deadline: yesterday())

        let result = rankReason(for: task, now: referenceNow, calendar: testCalendar)

        #expect(result == .inProgress)
    }

    @Test("todo task with a past deadline returns .overdue with the elapsed interval")
    func todoWithPastDeadlineReturnsOverdue() {
        let deadline = yesterday()
        let task = makeTask(id: fixedUUID(1), status: .todo, deadline: deadline)

        let result = rankReason(for: task, now: referenceNow, calendar: testCalendar)

        #expect(result == .overdue(by: referenceNow.timeIntervalSince(deadline)))
    }

    @Test("todo task with a later-today deadline returns .dueToday")
    func todoWithLaterTodayDeadlineReturnsDueToday() {
        let deadline = todayLater()
        let task = makeTask(id: fixedUUID(1), status: .todo, deadline: deadline)

        let result = rankReason(for: task, now: referenceNow, calendar: testCalendar)

        #expect(result == .dueToday(deadline))
    }

    @Test("todo task with no near-term deadline but an explicit priority returns .priority")
    func todoWithPriorityOnlyReturnsPriority() {
        let task = makeTask(id: fixedUUID(1), status: .todo, priority: 2, deadline: tomorrow())

        let result = rankReason(for: task, now: referenceNow, calendar: testCalendar)

        #expect(result == .priority(2))
    }

    @Test("todo task with no near-term deadline and no priority returns .none")
    func todoWithNothingReturnsNone() {
        let task = makeTask(id: fixedUUID(1), status: .todo, priority: nil, deadline: nil)

        let result = rankReason(for: task, now: referenceNow, calendar: testCalendar)

        #expect(result == .none)
    }

    // Invariant: a task that beats another task's today-deadline in `eligibleTasksOrdered` must
    // itself be in-progress or have a near-term deadline (that's the only way `orderedBefore`'s
    // tier 2 lets it win) — so its own `rankReason` can never be `.none`.
    @Test("winner of eligibleTasksOrdered is never .none when another task in the snapshot is due today")
    func winnerNeverNoneWhenAnotherTaskDueToday() {
        let dueTodayTask = makeTask(id: fixedUUID(1), status: .todo, priority: 4, deadline: todayLater())
        let priorityOnlyTask = makeTask(id: fixedUUID(2), status: .todo, priority: 1, deadline: nil)

        let ordered = eligibleTasksOrdered(from: [priorityOnlyTask, dueTodayTask], now: referenceNow, calendar: testCalendar)
        let winner = ordered.first!

        // Near-term deadline (tier 2) outranks priority alone (tier 3).
        #expect(winner.id == dueTodayTask.id)
        #expect(rankReason(for: winner, now: referenceNow, calendar: testCalendar) != .none)
    }

    @Test("rankReason is pure: repeated calls with identical inputs return identical results")
    func rankReasonIsPure() {
        let task = makeTask(id: fixedUUID(1), status: .todo, priority: 3, deadline: yesterday())

        let first = rankReason(for: task, now: referenceNow, calendar: testCalendar)
        let second = rankReason(for: task, now: referenceNow, calendar: testCalendar)

        #expect(first == second)
    }
}
