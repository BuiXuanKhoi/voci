import Foundation
import Testing
@testable import VolarCore

/// User Story 3 (condition-aware eligibility). Covers the 001 §6.2 #3/#6/#8/#9 scenarios
/// re-expressed with `.taskDone` conditions (dependsOn -> conditions: [.taskDone(id)], migrated
/// 1:1 with the same intent and assertions), plus the v2 eligibility surface: `.afterDate`,
/// `.external`, mixed-condition AND semantics, parent-of-open-child exclusion, and determinism
/// under shuffle at n=500.
@Suite("Condition-aware eligibility")
struct EligibilityTests {

    // MARK: - §6.2 cases migrated from `dependsOn` to `conditions: [.taskDone(id)]`

    // §6.2 #3: a priority-1 task blocked by an unfinished prerequisite is skipped in favor of an
    // eligible task, and becomes selectable once the prerequisite is marked `.done`.
    @Test("priority-1 task blocked by an unfinished .taskDone condition is skipped, then unblocks on completion")
    func blockedPriorityOneTaskIsSkippedThenUnblocks() {
        let prerequisite = makeTask(id: fixedUUID(1), status: .todo, priority: 3)
        let blockedTask = makeTask(
            id: fixedUUID(2), status: .todo, priority: 1,
            conditions: [.taskDone(prerequisite.id)]
        )
        let fallbackTask = makeTask(id: fixedUUID(3), status: .todo, priority: 4)

        let beforeCompletion = nextTask(from: [prerequisite, blockedTask, fallbackTask], now: referenceNow, calendar: testCalendar)
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

    // §6.2 #3 (multi-prerequisite variant): a task remains blocked until ALL its `.taskDone`
    // conditions are resolved, not just some of them.
    @Test("task with multiple .taskDone conditions stays blocked until all are resolved")
    func taskWithMultiplePrerequisitesStaysBlockedUntilAllResolved() {
        let firstPrerequisite = makeTask(id: fixedUUID(1), status: .done)
        let secondPrerequisite = makeTask(id: fixedUUID(2), status: .todo)
        let dependent = makeTask(
            id: fixedUUID(3),
            status: .todo,
            priority: 1,
            conditions: [.taskDone(firstPrerequisite.id), .taskDone(secondPrerequisite.id)]
        )

        let stillBlocked = nextTask(from: [firstPrerequisite, secondPrerequisite, dependent], now: referenceNow, calendar: testCalendar)
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
    // `nextTask(from:now:calendar:)` result.
    @Test("completing a task cascades: its dependent becomes the new next task")
    func completingTaskCascadesToDependent() {
        let prerequisite = makeTask(id: fixedUUID(1), status: .todo, priority: 1)
        let dependent = makeTask(
            id: fixedUUID(2), status: .todo, priority: 1,
            conditions: [.taskDone(prerequisite.id)]
        )

        let before = nextTask(from: [prerequisite, dependent], now: referenceNow, calendar: testCalendar)
        #expect(before?.id == prerequisite.id)

        var completedPrerequisite = prerequisite
        completedPrerequisite.status = .done

        let after = nextTask(from: [completedPrerequisite, dependent], now: referenceNow, calendar: testCalendar)

        #expect(after?.id == dependent.id)
    }

    // §6.2 #8: when every task in the set is blocked by an unresolved `.taskDone` condition,
    // nothing is selected. (Fixture uses a mutual cycle purely to construct "every candidate
    // blocked" — `nextTask` itself does not assume or enforce acyclicity; that invariant is
    // enforced separately by `validateCondition`/`wouldCreateCycle` at edge-creation time.)
    @Test("all tasks blocked returns nil")
    func allTasksBlockedReturnsNil() {
        let taskA = makeTask(id: fixedUUID(1), status: .todo, conditions: [.taskDone(fixedUUID(2))])
        let taskB = makeTask(id: fixedUUID(2), status: .todo, conditions: [.taskDone(fixedUUID(3))])
        let taskC = makeTask(id: fixedUUID(3), status: .todo, conditions: [.taskDone(fixedUUID(1))])

        let result = nextTask(from: [taskA, taskB, taskC], now: referenceNow, calendar: testCalendar)

        #expect(result == nil)
    }

    // Clarify #9: an archived (not completed) prerequisite still counts as resolved and no
    // longer blocks its dependent.
    @Test("archived prerequisite unblocks its dependent")
    func archivedPrerequisiteUnblocksDependent() {
        let archivedPrerequisite = makeTask(id: fixedUUID(1), status: .archived)
        let dependent = makeTask(
            id: fixedUUID(2), status: .todo, priority: 1,
            conditions: [.taskDone(archivedPrerequisite.id)]
        )

        let result = nextTask(from: [archivedPrerequisite, dependent], now: referenceNow, calendar: testCalendar)

        #expect(result?.id == dependent.id)
    }

    // A deleted prerequisite (its id is simply absent from the snapshot) also counts as resolved
    // and no longer blocks its dependent.
    @Test("deleted prerequisite unblocks its dependent")
    func deletedPrerequisiteUnblocksDependent() {
        let deletedPrerequisiteID = fixedUUID(99) // never appears in `tasks`
        let dependent = makeTask(
            id: fixedUUID(2), status: .todo, priority: 1,
            conditions: [.taskDone(deletedPrerequisiteID)]
        )

        let result = nextTask(from: [dependent], now: referenceNow, calendar: testCalendar)

        #expect(result?.id == dependent.id)
    }

    // MARK: - v2: `.afterDate`

    // `now == date` counts as satisfied (`now >= date`), not merely `now > date`.
    @Test(".afterDate is satisfied exactly at the boundary instant")
    func afterDateSatisfiedAtExactBoundary() {
        let task = makeTask(id: fixedUUID(1), status: .todo, conditions: [.afterDate(referenceNow)])

        let result = nextTask(from: [task], now: referenceNow, calendar: testCalendar)

        #expect(result?.id == task.id)
    }

    @Test(".afterDate strictly in the future blocks eligibility")
    func afterDateInFutureBlocks() {
        let task = makeTask(id: fixedUUID(1), status: .todo, conditions: [.afterDate(tomorrow())])

        let result = nextTask(from: [task], now: referenceNow, calendar: testCalendar)

        #expect(result?.id != task.id)
    }

    @Test(".afterDate strictly in the past is satisfied")
    func afterDateInPastSatisfied() {
        let task = makeTask(id: fixedUUID(1), status: .todo, conditions: [.afterDate(yesterday())])

        let result = nextTask(from: [task], now: referenceNow, calendar: testCalendar)

        #expect(result?.id == task.id)
    }

    // MARK: - v2: `.external`

    @Test(".external satisfied: true is eligible")
    func externalSatisfiedTrueIsEligible() {
        let task = makeTask(
            id: fixedUUID(1), status: .todo,
            conditions: [.external(description: "waiting on reply", satisfied: true)]
        )

        let result = nextTask(from: [task], now: referenceNow, calendar: testCalendar)

        #expect(result?.id == task.id)
    }

    @Test(".external satisfied: false blocks eligibility")
    func externalSatisfiedFalseBlocks() {
        let task = makeTask(
            id: fixedUUID(1), status: .todo,
            conditions: [.external(description: "waiting on reply", satisfied: false)]
        )

        let result = nextTask(from: [task], now: referenceNow, calendar: testCalendar)

        #expect(result?.id != task.id)
    }

    // MARK: - v2: mixed-condition AND semantics

    // One unsatisfied condition blocks even when every other condition on the same task is
    // satisfied.
    @Test("mixed conditions use AND semantics: one unsatisfied condition blocks")
    func mixedConditionsUseANDSemantics() {
        let doneePrerequisite = makeTask(id: fixedUUID(1), status: .done)
        let blocked = makeTask(
            id: fixedUUID(2), status: .todo,
            conditions: [
                .taskDone(doneePrerequisite.id),           // satisfied
                .afterDate(referenceNow),                  // satisfied (boundary)
                .external(description: "sign-off", satisfied: false), // unsatisfied
            ]
        )
        let fallback = makeTask(id: fixedUUID(3), status: .todo)

        let result = nextTask(from: [doneePrerequisite, blocked, fallback], now: referenceNow, calendar: testCalendar)

        #expect(result?.id == fallback.id)

        // Flipping the last unsatisfied condition makes the task eligible.
        var unblocked = blocked
        unblocked.conditions = [
            .taskDone(doneePrerequisite.id),
            .afterDate(referenceNow),
            .external(description: "sign-off", satisfied: true),
        ]
        unblocked.priority = 1
        var lowerPriorityFallback = fallback
        lowerPriorityFallback.priority = 4

        let afterFlip = nextTask(from: [doneePrerequisite, unblocked, lowerPriorityFallback], now: referenceNow, calendar: testCalendar)
        #expect(afterFlip?.id == unblocked.id)
    }

    // MARK: - v2: parent-of-open-child exclusion

    // A parent with >=1 open (todo/inProgress) child is never returned by `nextTask`, even when
    // that child is itself ineligible (its own conditions block it) — the parent must still be
    // excluded, and neither parent nor blocked child may win over an unrelated eligible task.
    @Test("parent of an open child is excluded even when the child itself is ineligible")
    func parentOfOpenChildExcludedEvenWhenChildIneligible() {
        let parent = makeTask(id: fixedUUID(1), title: "Parent", status: .todo, priority: 1)
        let ineligibleChild = makeTask(
            id: fixedUUID(2), title: "Child", status: .todo, priority: 1,
            conditions: [.external(description: "blocked", satisfied: false)],
            parentId: parent.id
        )
        let unrelated = makeTask(id: fixedUUID(3), title: "Unrelated", status: .todo, priority: 4)

        let result = nextTask(from: [parent, ineligibleChild, unrelated], now: referenceNow, calendar: testCalendar)

        #expect(result?.id != parent.id)
        #expect(result?.id != ineligibleChild.id)
        #expect(result?.id == unrelated.id)
    }

    // A parent becomes selectable once its last open child is no longer open (done/archived),
    // and an eligible child (no open siblings) can itself be selected while the parent is
    // excluded.
    @Test("parent becomes eligible once its only child is done; eligible child can win while parent is excluded")
    func parentEligibleOnceChildDone() {
        let parent = makeTask(id: fixedUUID(1), status: .todo, priority: 1)
        let openChild = makeTask(id: fixedUUID(2), status: .todo, priority: 1, parentId: parent.id)

        let whileChildOpen = nextTask(from: [parent, openChild], now: referenceNow, calendar: testCalendar)
        // The parent is excluded; the open, unconditioned child is eligible and wins.
        #expect(whileChildOpen?.id == openChild.id)

        var doneChild = openChild
        doneChild.status = .done

        let afterChildDone = nextTask(from: [parent, doneChild], now: referenceNow, calendar: testCalendar)
        #expect(afterChildDone?.id == parent.id)
    }

    // MARK: - v2: determinism under shuffle at n=500

    // A synthetic snapshot of 500 tasks with a mix of statuses, conditions, deadlines,
    // priorities, and parent/child relationships must resolve to the exact same `nextTask`
    // result regardless of the snapshot's array order.
    @Test("nextTask is deterministic under shuffle at n=500")
    func nextTaskDeterministicUnderShuffleAtN500() {
        var generator = SeededGenerator(seed: 42)
        let snapshot = synthesizeSnapshot(count: 500, using: &generator)

        let resultInOrder = nextTask(from: snapshot, now: referenceNow, calendar: testCalendar)

        // Run several independent shuffles; every one must agree with the original order.
        for trial in 0..<5 {
            var shuffleGenerator = SeededGenerator(seed: UInt64(1000 + trial))
            let shuffled = snapshot.shuffled(using: &shuffleGenerator)
            let resultShuffled = nextTask(from: shuffled, now: referenceNow, calendar: testCalendar)
            #expect(resultShuffled?.id == resultInOrder?.id)
        }
    }
}

// MARK: - Deterministic synthetic snapshot generation (n=500 determinism test)

/// A trivial deterministic pseudo-random generator (linear congruential) so the n=500
/// determinism test is fully reproducible without relying on `SystemRandomNumberGenerator`
/// (which would make the test itself nondeterministic, defeating its purpose).
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed &+ 0x9E3779B97F4A7C15
    }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

/// Builds a deterministic 500-task synthetic snapshot mixing every eligibility/ordering
/// dimension: statuses, `.taskDone`/`.afterDate`/`.external` conditions, deadlines, priorities,
/// and parent/child relationships. Fully determined by `generator`'s seed.
func synthesizeSnapshot(count: Int, using generator: inout SeededGenerator) -> [Task] {
    var tasks: [Task] = []
    tasks.reserveCapacity(count)

    for index in 0..<count {
        let id = fixedUUID(index)
        let statusRoll = generator.next() % 4
        let status: TaskStatus
        switch statusRoll {
        case 0: status = .todo
        case 1: status = .inProgress
        case 2: status = .done
        default: status = .archived
        }

        var conditions: [Condition] = []
        if generator.next() % 3 == 0, index > 0 {
            // Reference an earlier task by index so `.taskDone` conditions never form a cycle.
            let referenced = Int(generator.next() % UInt64(index))
            conditions.append(.taskDone(fixedUUID(referenced)))
        }
        if generator.next() % 5 == 0 {
            let offsetDays = Int(generator.next() % 10) - 5
            conditions.append(.afterDate(daysFromReferenceNow(offsetDays)))
        }
        if generator.next() % 7 == 0 {
            conditions.append(.external(description: "ext-\(index)", satisfied: generator.next() % 2 == 0))
        }

        let priority: Int? = generator.next() % 4 == 0 ? nil : Int(generator.next() % 4) + 1

        let deadline: Date?
        switch generator.next() % 3 {
        case 0: deadline = nil
        case 1: deadline = daysFromReferenceNow(Int(generator.next() % 6) - 3)
        default: deadline = tomorrow()
        }

        // Occasionally attach a parent pointing at an earlier task (never a forward or
        // self-reference, so this never forms a parentId cycle).
        let parentId: UUID? = (index > 0 && generator.next() % 6 == 0)
            ? fixedUUID(Int(generator.next() % UInt64(index)))
            : nil

        let createdAt = daysFromReferenceNow(-Int(generator.next() % 30))

        tasks.append(
            makeTask(
                id: id,
                title: "Synthetic \(index)",
                status: status,
                priority: priority,
                deadline: deadline,
                conditions: conditions,
                parentId: parentId,
                createdAt: createdAt
            )
        )
    }

    return tasks
}
