import Foundation
import Testing
@testable import VociCore

/// §6.2 ordering & determinism scenarios, plus FR-007 and the clarified multiple-in-progress
/// case. Dependency/eligibility-focused scenarios (#3, #6, #8, #9, deleted-prerequisite) live in
/// `EligibilityTests.swift`; auto-advance scenarios live in `AutoAdvanceTests.swift`; cycle
/// scenarios live in `DependencyGraphTests.swift`.
@Suite("nextTask ordering & determinism")
struct NextTaskTests {

    // §6.2 #1: in-progress beats a higher-priority (numerically lower) to-do task.
    @Test("in-progress task is chosen over a higher-priority to-do task")
    func inProgressBeatsHigherPriorityTodo() {
        let inProgress = makeTask(id: fixedUUID(1), status: .inProgress, priority: 3)
        let higherPriorityTodo = makeTask(id: fixedUUID(2), status: .todo, priority: 1)

        let result = nextTask(from: [inProgress, higherPriorityTodo], now: referenceNow)

        #expect(result?.id == inProgress.id)
    }

    // §6.2 #2: an overdue deadline beats a priority-1 task with no deadline.
    @Test("overdue deadline beats priority-1 task with no deadline")
    func overdueBeatsPriorityOneNoDeadline() {
        let overdue = makeTask(id: fixedUUID(1), status: .todo, priority: 4, deadline: yesterday())
        let priorityOneNoDeadline = makeTask(id: fixedUUID(2), status: .todo, priority: 1, deadline: nil)

        let result = nextTask(from: [overdue, priorityOneNoDeadline], now: referenceNow)

        #expect(result?.id == overdue.id)
    }

    // §6.2 #7: a deadline of tomorrow must NOT outrank an explicit priority-1 task due today
    // (i.e. with no near-term deadline of its own). Only today/overdue deadlines get tier-2
    // precedence.
    @Test("deadline tomorrow does not outrank priority-1 with no near-term deadline")
    func deadlineTomorrowDoesNotOutrankPriorityToday() {
        let deadlineTomorrow = makeTask(id: fixedUUID(1), status: .todo, priority: 4, deadline: tomorrow())
        let priorityOneNoDeadline = makeTask(id: fixedUUID(2), status: .todo, priority: 1, deadline: nil)

        let result = nextTask(from: [deadlineTomorrow, priorityOneNoDeadline], now: referenceNow)

        #expect(result?.id == priorityOneNoDeadline.id)
    }

    // §6.2 #4: two tasks equal on every ordering dimension except id resolve via the stable
    // id-lexical tiebreak, and the result does not depend on input order (SC-001).
    @Test("identical tasks resolve via stable id tiebreak, independent of input order")
    func identicalTasksResolveViaStableIDTiebreak() {
        let taskA = makeTask(id: fixedUUID(1), status: .todo, priority: 2, deadline: nil, createdAt: referenceNow)
        let taskB = makeTask(id: fixedUUID(2), status: .todo, priority: 2, deadline: nil, createdAt: referenceNow)

        let resultInOrder = nextTask(from: [taskA, taskB], now: referenceNow)
        let resultShuffled = nextTask(from: [taskB, taskA], now: referenceNow)

        #expect(resultInOrder?.id == taskA.id)
        #expect(resultShuffled?.id == taskA.id)
        #expect(resultInOrder?.id == resultShuffled?.id)
    }

    // FR-007: a nil-priority task must sort after an explicit priority-4 task (unset priority is
    // never treated as a number, and never outranks any explicit priority).
    @Test("nil priority sorts after explicit priority 4")
    func nilPrioritySortsAfterExplicitPriorityFour() {
        let priorityFour = makeTask(id: fixedUUID(1), status: .todo, priority: 4)
        let noPriority = makeTask(id: fixedUUID(2), status: .todo, priority: nil)

        let result = nextTask(from: [priorityFour, noPriority], now: referenceNow)

        #expect(result?.id == priorityFour.id)
    }

    // Clarify #10: multiple simultaneously in-progress tasks still yield a single, stable
    // result — tier 1 groups them, and tiers 2-5 disambiguate deterministically.
    @Test("multiple in-progress tasks yield a single stable result")
    func multipleInProgressYieldsSingleStableResult() {
        let inProgressLowerPriority = makeTask(id: fixedUUID(1), status: .inProgress, priority: 2)
        let inProgressHigherPriority = makeTask(id: fixedUUID(2), status: .inProgress, priority: 1)

        let resultInOrder = nextTask(
            from: [inProgressLowerPriority, inProgressHigherPriority],
            now: referenceNow
        )
        let resultShuffled = nextTask(
            from: [inProgressHigherPriority, inProgressLowerPriority],
            now: referenceNow
        )

        #expect(resultInOrder?.id == inProgressHigherPriority.id)
        #expect(resultShuffled?.id == inProgressHigherPriority.id)
    }

    @Test("empty task set returns nil")
    func emptyTaskSetReturnsNil() {
        let result = nextTask(from: [], now: referenceNow)

        #expect(result == nil)
    }

    @Test("all done or archived tasks returns nil")
    func allDoneOrArchivedReturnsNil() {
        let doneTask = makeTask(id: fixedUUID(1), status: .done)
        let archivedTask = makeTask(id: fixedUUID(2), status: .archived)

        let result = nextTask(from: [doneTask, archivedTask], now: referenceNow)

        #expect(result == nil)
    }
}
