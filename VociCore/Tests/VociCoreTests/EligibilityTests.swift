import Foundation
import Testing
@testable import VociCore

/// User Story 3 (dependency-aware eligibility): §6.2 #3, #6, #8, clarify #9, and the
/// deleted-prerequisite case.
@Suite("Dependency-aware eligibility")
struct EligibilityTests {

    // §6.2 #3: a priority-1 task blocked by an unfinished prerequisite is skipped in favor of an
    // eligible task, and becomes selectable once the prerequisite is marked `.done`.
    @Test("priority-1 task blocked by an unfinished dependency is skipped, then unblocks on completion")
    func blockedPriorityOneTaskIsSkippedThenUnblocks() {
        let prerequisite = makeTask(id: fixedUUID(1), status: .todo, priority: 3)
        let blockedTask = makeTask(id: fixedUUID(2), status: .todo, priority: 1, dependsOn: [prerequisite.id])
        let fallbackTask = makeTask(id: fixedUUID(3), status: .todo, priority: 4)

        let beforeCompletion = nextTask(
            from: [prerequisite, blockedTask, fallbackTask],
            now: referenceNow,
            calendar: testCalendar
        )
        // blockedTask (priority 1) is not eligible yet, so the fallback (priority 4) wins over
        // the unrelated prerequisite (priority 3) — the blocked task must never be chosen.
        #expect(beforeCompletion?.id != blockedTask.id)

        var completedPrerequisite = prerequisite
        completedPrerequisite.status = .done

        let afterCompletion = nextTask(
            from: [completedPrerequisite, blockedTask, fallbackTask],
            now: referenceNow,
            calendar: testCalendar
        )

        #expect(afterCompletion?.id == blockedTask.id)
    }

    // §6.2 #3 (multi-prerequisite variant): a task remains blocked until ALL prerequisites are
    // resolved, not just some of them.
    @Test("task with multiple prerequisites stays blocked until all are resolved")
    func taskWithMultiplePrerequisitesStaysBlockedUntilAllResolved() {
        let firstPrerequisite = makeTask(id: fixedUUID(1), status: .done)
        let secondPrerequisite = makeTask(id: fixedUUID(2), status: .todo)
        let dependent = makeTask(
            id: fixedUUID(3),
            status: .todo,
            priority: 1,
            dependsOn: [firstPrerequisite.id, secondPrerequisite.id]
        )

        let stillBlocked = nextTask(
            from: [firstPrerequisite, secondPrerequisite, dependent],
            now: referenceNow,
            calendar: testCalendar
        )
        #expect(stillBlocked?.id != dependent.id)

        var completedSecondPrerequisite = secondPrerequisite
        completedSecondPrerequisite.status = .done

        let nowUnblocked = nextTask(
            from: [firstPrerequisite, completedSecondPrerequisite, dependent],
            now: referenceNow,
            calendar: testCalendar
        )
        #expect(nowUnblocked?.id == dependent.id)
    }

    // §6.2 #6: completing a task cascades — its dependent, previously blocked, becomes the new
    // `nextTask()` result.
    @Test("completing a task cascades: its dependent becomes the new next task")
    func completingTaskCascadesToDependent() {
        let prerequisite = makeTask(id: fixedUUID(1), status: .todo, priority: 1)
        let dependent = makeTask(id: fixedUUID(2), status: .todo, priority: 1, dependsOn: [prerequisite.id])

        let before = nextTask(from: [prerequisite, dependent], now: referenceNow, calendar: testCalendar)
        #expect(before?.id == prerequisite.id)

        var completedPrerequisite = prerequisite
        completedPrerequisite.status = .done

        let after = nextTask(from: [completedPrerequisite, dependent], now: referenceNow, calendar: testCalendar)

        #expect(after?.id == dependent.id)
    }

    // §6.2 #8: when every task in the set is blocked by an unresolved prerequisite, nothing is
    // selected. (Fixture uses a mutual cycle purely to construct "every candidate blocked" —
    // `nextTask` itself does not assume or enforce acyclicity; that invariant is enforced
    // separately by `validateDependency`/`wouldCreateCycle` at edge-creation time.)
    @Test("all tasks blocked returns nil")
    func allTasksBlockedReturnsNil() {
        let taskA = makeTask(id: fixedUUID(1), status: .todo, dependsOn: [fixedUUID(2)])
        let taskB = makeTask(id: fixedUUID(2), status: .todo, dependsOn: [fixedUUID(3)])
        let taskC = makeTask(id: fixedUUID(3), status: .todo, dependsOn: [fixedUUID(1)])

        let result = nextTask(from: [taskA, taskB, taskC], now: referenceNow, calendar: testCalendar)

        #expect(result == nil)
    }

    // Clarify #9: an archived (not completed) prerequisite still counts as resolved and no
    // longer blocks its dependent.
    @Test("archived prerequisite unblocks its dependent")
    func archivedPrerequisiteUnblocksDependent() {
        let archivedPrerequisite = makeTask(id: fixedUUID(1), status: .archived)
        let dependent = makeTask(id: fixedUUID(2), status: .todo, priority: 1, dependsOn: [archivedPrerequisite.id])

        let result = nextTask(from: [archivedPrerequisite, dependent], now: referenceNow, calendar: testCalendar)

        #expect(result?.id == dependent.id)
    }

    // A deleted prerequisite (its id is simply absent from the snapshot) also counts as resolved
    // and no longer blocks its dependent.
    @Test("deleted prerequisite unblocks its dependent")
    func deletedPrerequisiteUnblocksDependent() {
        let deletedPrerequisiteID = fixedUUID(99) // never appears in `tasks`
        let dependent = makeTask(id: fixedUUID(2), status: .todo, priority: 1, dependsOn: [deletedPrerequisiteID])

        let result = nextTask(from: [dependent], now: referenceNow, calendar: testCalendar)

        #expect(result?.id == dependent.id)
    }
}
