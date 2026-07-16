import Foundation
import Testing
@testable import VolarCore

// UNVERIFIED: authored on Windows, no Swift toolchain available in this environment. Needs a
// `swift test` pass on macOS before merge.

/// Coverage for `conflicts(forAdding:into:now:calendar:busyIntervals:frogId:)` (phase4-contract.md
/// §C, spec.md FR-011c): one positive + one low-noise near-miss negative per conflict kind, plus
/// the structural guarantees (empty snapshot, no-deadline candidate, busy-interval contribution to
/// capacity, the duplicate-score boundary, and determinism under snapshot shuffle).
@Suite("conflicts capture-time advisory")
struct ConflictCheckTests {

    // MARK: - Structural

    @Test("empty snapshot never conflicts")
    func emptySnapshotReturnsNoConflicts() {
        let candidate = makeTask(
            id: fixedUUID(1), title: "Ship the release", priority: 1, deadline: tomorrow(),
            estimateMinutes: 60
        )

        let result = conflicts(
            forAdding: candidate, into: [], now: referenceNow, calendar: testCalendar,
            busyIntervals: [], frogId: nil
        )

        #expect(result.isEmpty)
    }

    @Test("no-deadline, no-priority candidate against an unrelated snapshot stays clean")
    func noDeadlineCandidateIsSafe() {
        let candidate = makeTask(id: fixedUUID(1), title: "Water the plants", priority: nil, deadline: nil)
        let unrelated = makeTask(id: fixedUUID(2), title: "Finish the quarterly report", deadline: tomorrow())
        let frog = makeTask(id: fixedUUID(3), title: "Ship the release", priority: 1, deadline: todayLater())

        let result = conflicts(
            forAdding: candidate, into: [unrelated, frog], now: referenceNow, calendar: testCalendar,
            busyIntervals: [], frogId: frog.id
        )

        #expect(result.isEmpty)
    }

    // MARK: - deadlineCapacity

    @Test("deadlineCapacity fires when the deadline day is already ~80%+ committed")
    func deadlineCapacityFiresWhenDayIsOvercommitted() {
        let day = tomorrow()
        let existing = [
            makeTask(id: fixedUUID(1), title: "A", deadline: day, estimateMinutes: 100),
            makeTask(id: fixedUUID(2), title: "B", deadline: day, estimateMinutes: 100),
            makeTask(id: fixedUUID(3), title: "C", deadline: day, estimateMinutes: 100),
        ]
        let candidate = makeTask(id: fixedUUID(4), title: "D", deadline: day, estimateMinutes: 100)

        let result = conflicts(
            forAdding: candidate, into: existing, now: referenceNow, calendar: testCalendar,
            busyIntervals: [], frogId: nil
        )

        let dayEnd = testCalendar.date(byAdding: .day, value: 1, to: testCalendar.startOfDay(for: day))!
        #expect(result.contains(.deadlineCapacity(existingCount: 3, estimatedMinutes: 400, windowEnd: dayEnd)))
    }

    @Test("deadlineCapacity does NOT fire when the deadline day is well under capacity (near-miss)")
    func deadlineCapacityNearMissDoesNotFire() {
        let day = tomorrow()
        let existing = [
            makeTask(id: fixedUUID(1), title: "A", deadline: day, estimateMinutes: 50),
            makeTask(id: fixedUUID(2), title: "B", deadline: day, estimateMinutes: 50),
        ]
        let candidate = makeTask(id: fixedUUID(3), title: "C", deadline: day, estimateMinutes: 50)

        let result = conflicts(
            forAdding: candidate, into: existing, now: referenceNow, calendar: testCalendar,
            busyIntervals: [], frogId: nil
        )

        #expect(!result.contains { if case .deadlineCapacity = $0 { return true }; return false })
    }

    @Test("deadlineCapacity counts calendar-busy minutes toward the day's total")
    func deadlineCapacityIncludesBusyIntervals() {
        let day = tomorrow()
        let dayStart = testCalendar.startOfDay(for: day)
        let existing = [makeTask(id: fixedUUID(1), title: "A", deadline: day, estimateMinutes: 100)]
        let candidate = makeTask(id: fixedUUID(2), title: "B", deadline: day, estimateMinutes: 110)

        // 3 busy hours (180 min) fully inside the deadline day: 100 + 180 + 110 = 390 >= 384.
        let busy = DateInterval(
            start: testCalendar.date(byAdding: .hour, value: 2, to: dayStart)!,
            end: testCalendar.date(byAdding: .hour, value: 5, to: dayStart)!
        )

        let result = conflicts(
            forAdding: candidate, into: existing, now: referenceNow, calendar: testCalendar,
            busyIntervals: [busy], frogId: nil
        )

        let dayEnd = testCalendar.date(byAdding: .day, value: 1, to: dayStart)!
        #expect(result.contains(.deadlineCapacity(existingCount: 1, estimatedMinutes: 390, windowEnd: dayEnd)))
    }

    // MARK: - deadlineCollision

    @Test("deadlineCollision fires against an in-progress task's deadline within the small window")
    func deadlineCollisionFiresAgainstInProgressTask() {
        let existingDeadline = todayLater(hour: 14)
        let existing = makeTask(id: fixedUUID(1), title: "Prep the demo", status: .inProgress, deadline: existingDeadline)
        let candidate = makeTask(
            id: fixedUUID(2), title: "Send the follow-up",
            deadline: testCalendar.date(byAdding: .minute, value: 30, to: existingDeadline)!
        )

        let result = conflicts(
            forAdding: candidate, into: [existing], now: referenceNow, calendar: testCalendar,
            busyIntervals: [], frogId: nil
        )

        #expect(result.contains(.deadlineCollision(withTaskId: existing.id, title: existing.title)))
    }

    @Test("deadlineCollision does NOT fire against a plain to-do task's nearby deadline (near-miss)")
    func deadlineCollisionNearMissAgainstPlainTodoDoesNotFire() {
        let existingDeadline = todayLater(hour: 14)
        // Ordinary to-do, no priority, not the frog: not "urgent" per the contract, so no signal
        // even though the deadlines are close.
        let existing = makeTask(id: fixedUUID(1), title: "Read an article", status: .todo, priority: nil, deadline: existingDeadline)
        let candidate = makeTask(
            id: fixedUUID(2), title: "Send the follow-up",
            deadline: testCalendar.date(byAdding: .minute, value: 30, to: existingDeadline)!
        )

        let result = conflicts(
            forAdding: candidate, into: [existing], now: referenceNow, calendar: testCalendar,
            busyIntervals: [], frogId: nil
        )

        #expect(!result.contains { if case .deadlineCollision = $0 { return true }; return false })
    }

    @Test("deadlineCollision does NOT fire when an urgent task's deadline is outside the small window (near-miss)")
    func deadlineCollisionOutsideWindowDoesNotFire() {
        let existingDeadline = todayLater(hour: 9)
        let existing = makeTask(id: fixedUUID(1), title: "Prep the demo", status: .inProgress, deadline: existingDeadline)
        // 3 hours away: outside the 2-hour collision window.
        let candidate = makeTask(
            id: fixedUUID(2), title: "Send the follow-up",
            deadline: testCalendar.date(byAdding: .hour, value: 3, to: existingDeadline)!
        )

        let result = conflicts(
            forAdding: candidate, into: [existing], now: referenceNow, calendar: testCalendar,
            busyIntervals: [], frogId: nil
        )

        #expect(!result.contains { if case .deadlineCollision = $0 { return true }; return false })
    }

    // MARK: - dependsOnBlocked

    @Test("dependsOnBlocked fires when the referenced task is overdue and still open")
    func dependsOnBlockedFiresForOverdueReference() {
        let blocker = makeTask(id: fixedUUID(1), title: "Get sign-off", status: .todo, deadline: yesterday())
        let candidate = makeTask(id: fixedUUID(2), title: "Ship the feature", conditions: [.taskDone(blocker.id)])

        let result = conflicts(
            forAdding: candidate, into: [blocker], now: referenceNow, calendar: testCalendar,
            busyIntervals: [], frogId: nil
        )

        #expect(result.contains(.dependsOnBlocked(taskId: blocker.id, title: blocker.title)))
    }

    @Test("dependsOnBlocked fires when the referenced task is itself stuck on an unsatisfied condition")
    func dependsOnBlockedFiresForStuckReference() {
        let blocker = makeTask(
            id: fixedUUID(1), title: "Get sign-off", status: .todo, deadline: nil,
            conditions: [.external(description: "waiting on legal", satisfied: false)]
        )
        let candidate = makeTask(id: fixedUUID(2), title: "Ship the feature", conditions: [.taskDone(blocker.id)])

        let result = conflicts(
            forAdding: candidate, into: [blocker], now: referenceNow, calendar: testCalendar,
            busyIntervals: [], frogId: nil
        )

        #expect(result.contains(.dependsOnBlocked(taskId: blocker.id, title: blocker.title)))
    }

    @Test("dependsOnBlocked does NOT fire against an open, non-overdue, unblocked reference (near-miss)")
    func dependsOnBlockedNearMissDoesNotFire() {
        let blocker = makeTask(id: fixedUUID(1), title: "Get sign-off", status: .todo, deadline: tomorrow())
        let candidate = makeTask(id: fixedUUID(2), title: "Ship the feature", conditions: [.taskDone(blocker.id)])

        let result = conflicts(
            forAdding: candidate, into: [blocker], now: referenceNow, calendar: testCalendar,
            busyIntervals: [], frogId: nil
        )

        #expect(!result.contains { if case .dependsOnBlocked = $0 { return true }; return false })
    }

    @Test("dependsOnBlocked does NOT fire when the referenced task is already done, even if overdue (near-miss)")
    func dependsOnBlockedDoneReferenceDoesNotFire() {
        let blocker = makeTask(id: fixedUUID(1), title: "Get sign-off", status: .done, deadline: yesterday())
        let candidate = makeTask(id: fixedUUID(2), title: "Ship the feature", conditions: [.taskDone(blocker.id)])

        let result = conflicts(
            forAdding: candidate, into: [blocker], now: referenceNow, calendar: testCalendar,
            busyIntervals: [], frogId: nil
        )

        #expect(!result.contains { if case .dependsOnBlocked = $0 { return true }; return false })
    }

    // MARK: - competesWithFrog

    @Test("competesWithFrog fires when a priority-1 candidate rivals a different open frog task")
    func competesWithFrogFiresForPriorityOneCandidate() {
        let frog = makeTask(id: fixedUUID(1), title: "Today's most important thing", status: .inProgress)
        let candidate = makeTask(id: fixedUUID(2), title: "A different urgent thing", priority: 1)

        let result = conflicts(
            forAdding: candidate, into: [frog], now: referenceNow, calendar: testCalendar,
            busyIntervals: [], frogId: frog.id
        )

        #expect(result.contains(.competesWithFrog(taskId: frog.id, title: frog.title)))
    }

    @Test("competesWithFrog does NOT fire for a low-priority, non-urgent candidate (near-miss)")
    func competesWithFrogNearMissDoesNotFire() {
        let frog = makeTask(id: fixedUUID(1), title: "Today's most important thing", status: .inProgress)
        let candidate = makeTask(id: fixedUUID(2), title: "Something for later", priority: 3, deadline: tomorrow())

        let result = conflicts(
            forAdding: candidate, into: [frog], now: referenceNow, calendar: testCalendar,
            busyIntervals: [], frogId: frog.id
        )

        #expect(!result.contains { if case .competesWithFrog = $0 { return true }; return false })
    }

    @Test("competesWithFrog does NOT fire when the candidate itself is the frog")
    func competesWithFrogSelfDoesNotFire() {
        let candidate = makeTask(id: fixedUUID(1), title: "Today's most important thing", priority: 1)

        let result = conflicts(
            forAdding: candidate, into: [], now: referenceNow, calendar: testCalendar,
            busyIntervals: [], frogId: candidate.id
        )

        #expect(!result.contains { if case .competesWithFrog = $0 { return true }; return false })
    }

    // MARK: - possibleDuplicate

    @Test("possibleDuplicate fires on a near-identical, diacritic-folded, case-different title")
    func possibleDuplicateFiresForDiacriticAndCaseVariant() {
        let existing = makeTask(id: fixedUUID(1), title: "Đọc sách buổi tối", status: .todo)
        let candidate = makeTask(id: fixedUUID(2), title: "doc sach buoi toi")

        let result = conflicts(
            forAdding: candidate, into: [existing], now: referenceNow, calendar: testCalendar,
            busyIntervals: [], frogId: nil
        )

        guard case .possibleDuplicate(let taskId, let title, let score) = result.first(where: {
            if case .possibleDuplicate = $0 { return true }; return false
        }) else {
            Issue.record("expected a possibleDuplicate conflict")
            return
        }
        #expect(taskId == existing.id)
        #expect(title == existing.title)
        #expect(score == 1.0)
    }

    @Test("possibleDuplicate does NOT fire for an unrelated title (near-miss)")
    func possibleDuplicateNearMissDoesNotFire() {
        let existing = makeTask(id: fixedUUID(1), title: "Buy groceries for the week", status: .todo)
        let candidate = makeTask(id: fixedUUID(2), title: "File the quarterly tax return")

        let result = conflicts(
            forAdding: candidate, into: [existing], now: referenceNow, calendar: testCalendar,
            busyIntervals: [], frogId: nil
        )

        #expect(!result.contains { if case .possibleDuplicate = $0 { return true }; return false })
    }

    @Test("possibleDuplicate boundary: score exactly at threshold fires, just below does not")
    func possibleDuplicateThresholdBoundary() {
        // candidate {one, two, three, four}; at-threshold {one, two, three, four, five}:
        // intersection 4 / union 5 = 0.8 -> fires.
        let atThreshold = makeTask(id: fixedUUID(1), title: "one two three four five", status: .todo)
        let candidateAt = makeTask(id: fixedUUID(2), title: "one two three four")

        let atResult = conflicts(
            forAdding: candidateAt, into: [atThreshold], now: referenceNow, calendar: testCalendar,
            busyIntervals: [], frogId: nil
        )
        #expect(atResult.contains { if case .possibleDuplicate(let id, _, let score) = $0 {
            return id == atThreshold.id && score == 0.8
        }; return false })

        // candidate {one, two, three, four}; just-below {one, two, three}:
        // intersection 3 / union 4 = 0.75 -> does not fire.
        let belowThreshold = makeTask(id: fixedUUID(3), title: "one two three", status: .todo)
        let candidateBelow = makeTask(id: fixedUUID(4), title: "one two three four")

        let belowResult = conflicts(
            forAdding: candidateBelow, into: [belowThreshold], now: referenceNow, calendar: testCalendar,
            busyIntervals: [], frogId: nil
        )
        #expect(!belowResult.contains { if case .possibleDuplicate = $0 { return true }; return false })
    }

    // MARK: - Determinism

    @Test("result is identical regardless of snapshot array order, across multiple simultaneous kinds")
    func determinismUnderSnapshotShuffle() {
        let day = tomorrow()
        let capacityA = makeTask(id: fixedUUID(1), title: "Cap A", deadline: day, estimateMinutes: 200)
        let capacityB = makeTask(id: fixedUUID(2), title: "Cap B", deadline: day, estimateMinutes: 200)
        let collisionSource = makeTask(id: fixedUUID(3), title: "Urgent demo", status: .inProgress, deadline: todayLater(hour: 14))
        let blocker = makeTask(id: fixedUUID(4), title: "Get sign-off", status: .todo, deadline: yesterday())
        let frog = makeTask(id: fixedUUID(5), title: "Frog task", status: .inProgress)
        let duplicateSource = makeTask(id: fixedUUID(6), title: "Ship the release", status: .todo)

        let snapshot = [capacityA, capacityB, collisionSource, blocker, frog, duplicateSource]
        let shuffled = [duplicateSource, frog, blocker, collisionSource, capacityB, capacityA]

        let candidate = makeTask(
            id: fixedUUID(7), title: "Ship the release", priority: 1, deadline: day,
            conditions: [.taskDone(blocker.id)], estimateMinutes: 100
        )

        let resultInOrder = conflicts(
            forAdding: candidate, into: snapshot, now: referenceNow, calendar: testCalendar,
            busyIntervals: [], frogId: frog.id
        )
        let resultShuffled = conflicts(
            forAdding: candidate, into: shuffled, now: referenceNow, calendar: testCalendar,
            busyIntervals: [], frogId: frog.id
        )

        #expect(resultInOrder == resultShuffled)
        #expect(!resultInOrder.isEmpty)
    }

    // MARK: - Adversarial robustness

    @Test("adversarial snapshot (duplicate ids, huge estimates) does not crash and stays bounded")
    func adversarialSnapshotIsBoundedAndSafe() {
        let day = tomorrow()
        let sharedID = fixedUUID(1)
        let hugeA = makeTask(id: sharedID, title: "Huge A", deadline: day, estimateMinutes: Int.max)
        let hugeB = makeTask(id: sharedID, title: "Huge B", deadline: day, estimateMinutes: Int.max)
        let negative = makeTask(id: fixedUUID(2), title: "Negative", deadline: day, estimateMinutes: -999)
        let candidate = makeTask(id: fixedUUID(3), title: "Candidate", deadline: day, estimateMinutes: Int.max)

        let result = conflicts(
            forAdding: candidate, into: [hugeA, hugeB, negative], now: referenceNow, calendar: testCalendar,
            busyIntervals: [], frogId: nil
        )

        // The point of this test is simply that the call above returns instead of crashing or
        // hanging; a capacity conflict is expected (the day is trivially over capacity), but
        // asserting non-empty here also proves clamping didn't silently zero everything out.
        #expect(result.contains { if case .deadlineCapacity = $0 { return true }; return false })
    }
}
