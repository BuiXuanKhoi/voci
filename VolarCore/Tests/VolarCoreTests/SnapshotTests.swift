import Foundation
import Testing
@testable import VolarCore

/// `eligibilityDiff` (auto-unblock notifications, FR-015) and `nextResurfaceDate` (resurface
/// scheduler, FR-017) — both pure helpers layered on top of the same eligibility rule
/// `nextTask` uses.
@Suite("Snapshot helpers: eligibilityDiff and nextResurfaceDate")
struct SnapshotTests {

    // MARK: - eligibilityDiff

    // Completing a prerequisite unblocks its `.taskDone` dependent: the dependent's id appears
    // in the diff, the (already-eligible, now-done) prerequisite does not.
    @Test("task completion unblocks its dependent, appearing in the diff")
    func taskCompletionUnblocksDependent() {
        let prerequisite = makeTask(id: fixedUUID(1), status: .todo)
        let dependent = makeTask(id: fixedUUID(2), status: .todo, conditions: [.taskDone(prerequisite.id)])
        let before = [prerequisite, dependent]

        var completedPrerequisite = prerequisite
        completedPrerequisite.status = .done
        let after = [completedPrerequisite, dependent]

        let diff = eligibilityDiff(before: before, after: after, now: referenceNow)

        #expect(diff == [dependent.id])
    }

    // Flipping an `.external` condition from unsatisfied to satisfied unblocks the task; it
    // appears in the diff.
    @Test("external condition flip unblocks its task, appearing in the diff")
    func externalFlipUnblocksTask() {
        let task = makeTask(
            id: fixedUUID(1), status: .todo,
            conditions: [.external(description: "sign-off", satisfied: false)]
        )
        let before = [task]

        var flipped = task
        flipped.conditions = [.external(description: "sign-off", satisfied: true)]
        let after = [flipped]

        let diff = eligibilityDiff(before: before, after: after, now: referenceNow)

        #expect(diff == [task.id])
    }

    // Un-completing a prerequisite re-blocks its dependent (a newly-INeligible task); this is
    // never reported by eligibilityDiff, which only reports newly-eligible ids.
    @Test("un-completing a prerequisite re-blocks its dependent, which is NOT in the diff")
    func unCompletingReblocksDependentNotInDiff() {
        let prerequisite = makeTask(id: fixedUUID(1), status: .todo)
        let dependent = makeTask(id: fixedUUID(2), status: .todo, conditions: [.taskDone(prerequisite.id)])

        var completedPrerequisite = prerequisite
        completedPrerequisite.status = .done
        // Step 1: prerequisite done, dependent eligible.
        let eligibleSnapshot = [completedPrerequisite, dependent]

        // Step 2: prerequisite reopened (un-completed), dependent blocked again.
        var reopenedPrerequisite = prerequisite
        reopenedPrerequisite.status = .todo
        let reblockedSnapshot = [reopenedPrerequisite, dependent]

        let diff = eligibilityDiff(before: eligibleSnapshot, after: reblockedSnapshot, now: referenceNow)

        #expect(!diff.contains(dependent.id))
        #expect(diff.isEmpty)
    }

    // A task absent from `before` entirely but eligible in `after` counts as newly eligible.
    @Test("task absent from before but eligible in after counts as newly eligible")
    func taskAbsentFromBeforeCountsAsNewlyEligible() {
        let before: [Task] = []
        let addedTask = makeTask(id: fixedUUID(1), status: .todo)
        let after = [addedTask]

        let diff = eligibilityDiff(before: before, after: after, now: referenceNow)

        #expect(diff == [addedTask.id])
    }

    // MARK: - nextResurfaceDate

    @Test("no .afterDate conditions anywhere returns nil")
    func noAfterDateConditionsReturnsNil() {
        let task = makeTask(id: fixedUUID(1), status: .todo, conditions: [.taskDone(fixedUUID(2))])

        let result = nextResurfaceDate(in: [task], after: referenceNow)

        #expect(result == nil)
    }

    @Test("several future .afterDate conditions return the earliest strictly-future one")
    func severalFutureAfterDatesReturnsEarliest() {
        let earliest = daysFromReferenceNow(1)
        let middle = daysFromReferenceNow(3)
        let latest = daysFromReferenceNow(10)

        let taskA = makeTask(id: fixedUUID(1), status: .todo, conditions: [.afterDate(latest)])
        let taskB = makeTask(id: fixedUUID(2), status: .todo, conditions: [.afterDate(earliest)])
        let taskC = makeTask(id: fixedUUID(3), status: .done, conditions: [.afterDate(middle)])

        let result = nextResurfaceDate(in: [taskA, taskB, taskC], after: referenceNow)

        #expect(result == earliest)
    }

    // Only past (or exactly-now) `.afterDate` conditions never resurface: they are already
    // satisfied, so nextResurfaceDate must return nil.
    @Test("past-only .afterDate conditions return nil")
    func pastOnlyAfterDatesReturnsNil() {
        let taskA = makeTask(id: fixedUUID(1), status: .todo, conditions: [.afterDate(yesterday())])
        let taskB = makeTask(id: fixedUUID(2), status: .todo, conditions: [.afterDate(referenceNow)])

        let result = nextResurfaceDate(in: [taskA, taskB], after: referenceNow)

        #expect(result == nil)
    }
}
