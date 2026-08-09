import Foundation
import Testing
@testable import VolarCore

/// Guards the invariant `NextTask.swift` was rewritten around 2026-08-09 (specs/006-cues-and-
/// waiting, Opus review of T5 "wire UI"): `nextTask(from:now:calendar:)` must always equal
/// `eligibleTasksOrdered(from:now:calendar:).first`. `nextTask` is now literally IMPLEMENTED as
/// `eligibleTasksOrdered(...).first`, so this can't actually diverge at the source level — but
/// this suite exists anyway as the regression fence: if a future edit ever "optimizes" `nextTask`
/// back into its own separate `.min(by:)` path (exactly the shape it had before this file was
/// touched), these tests catch the split immediately instead of relying on nobody ever doing that.
///
/// This is also the reason `eligibleTasksOrdered` exists at all: the app layer
/// (`Volar/Sources/App/AppState.swift`'s `WaitingMode.decide(eligibleOrder:)` caller) needs the
/// FULL eligible ranking, not just the top pick, and previously had no public way to get it
/// without hand-copying `eligibleTasks`'s filter rule — a copy with no compiler tie back to this
/// file, which is exactly the silent-drift risk this suite is meant to close off for good.
@Suite("eligibleTasksOrdered / nextTask invariant")
struct EligibleTasksOrderedTests {

    // MARK: - 1. Empty snapshot

    @Test("empty snapshot: eligibleTasksOrdered is empty, nextTask is nil, .first matches")
    func emptySnapshot() {
        let ordered = eligibleTasksOrdered(from: [], now: referenceNow, calendar: testCalendar)
        let winner = nextTask(from: [], now: referenceNow, calendar: testCalendar)

        #expect(ordered.isEmpty)
        #expect(winner == nil)
        #expect(ordered.first?.id == winner?.id)
    }

    // MARK: - 2. Single eligible task

    @Test("single eligible task: eligibleTasksOrdered has exactly it, nextTask matches")
    func singleEligibleTask() {
        let only = makeTask(id: fixedUUID(1), status: .todo, priority: 2)

        let ordered = eligibleTasksOrdered(from: [only], now: referenceNow, calendar: testCalendar)
        let winner = nextTask(from: [only], now: referenceNow, calendar: testCalendar)

        #expect(ordered.map(\.id) == [only.id])
        #expect(winner?.id == only.id)
        #expect(ordered.first?.id == winner?.id)
    }

    // MARK: - 3. Many tasks, mixed .taskDone condition + parent-of-open-child exclusion

    @Test("mixed snapshot with conditions and parent-child: full ordering, and .first matches nextTask")
    func mixedSnapshotConditionsAndParentChild() {
        // Eligible, ranked by priority (ascending, 1 highest): high, medium, low.
        let high = makeTask(id: fixedUUID(1), status: .todo, priority: 1)
        let medium = makeTask(id: fixedUUID(2), status: .todo, priority: 2)
        let low = makeTask(id: fixedUUID(3), status: .todo, priority: 3)

        // Blocked: unresolved .taskDone condition against `high` (still .todo).
        let blocked = makeTask(
            id: fixedUUID(4), status: .todo, priority: 1,
            conditions: [.taskDone(high.id)]
        )

        // Parent-of-open-child: excluded even though it's otherwise eligible on its own terms;
        // its still-open child is separately eligible.
        let parent = makeTask(id: fixedUUID(5), status: .todo, priority: 1)
        let openChild = makeTask(id: fixedUUID(6), status: .todo, priority: 4, parentId: parent.id)

        // Done/archived: never eligible regardless of condition/parent-child status.
        let done = makeTask(id: fixedUUID(7), status: .done, priority: 1)
        let archived = makeTask(id: fixedUUID(8), status: .archived, priority: 1)

        let snapshot = [low, blocked, done, high, parent, archived, openChild, medium]

        let ordered = eligibleTasksOrdered(from: snapshot, now: referenceNow, calendar: testCalendar)
        let winner = nextTask(from: snapshot, now: referenceNow, calendar: testCalendar)

        // Full ranking: eligible-only, sorted by priority tier (all .todo, no near-term deadline,
        // so priority is the deciding tier) — high, then medium, then openChild (priority 4), then
        // low. `blocked`/`parent`/`done`/`archived` are all absent.
        #expect(ordered.map(\.id) == [high.id, medium.id, openChild.id, low.id])

        // The invariant this suite exists for.
        #expect(winner?.id == ordered.first?.id)
        #expect(winner?.id == high.id)
    }

    // MARK: - 4. Determinism under input-order shuffle (mirrors NextTaskTests' own convention)

    @Test("eligibleTasksOrdered ranking is independent of snapshot array order, and still matches nextTask")
    func orderingIndependentOfInputOrderMatchesNextTask() {
        let a = makeTask(id: fixedUUID(1), status: .todo, priority: 3)
        let b = makeTask(id: fixedUUID(2), status: .todo, priority: 1)
        let c = makeTask(id: fixedUUID(3), status: .todo, priority: 2)

        let inOrder = eligibleTasksOrdered(from: [a, b, c], now: referenceNow, calendar: testCalendar)
        let shuffled = eligibleTasksOrdered(from: [c, a, b], now: referenceNow, calendar: testCalendar)

        let expectedOrder = [b.id, c.id, a.id] // priority 1, 2, 3
        #expect(inOrder.map(\.id) == expectedOrder)
        #expect(shuffled.map(\.id) == expectedOrder)

        let winnerInOrder = nextTask(from: [a, b, c], now: referenceNow, calendar: testCalendar)
        let winnerShuffled = nextTask(from: [c, a, b], now: referenceNow, calendar: testCalendar)
        #expect(winnerInOrder?.id == inOrder.first?.id)
        #expect(winnerShuffled?.id == shuffled.first?.id)
    }
}
