import Foundation
import Testing
@testable import VociCore

/// User Story 2 (auto-advance on completion). At the engine level, "auto-advance" is simply
/// re-invoking `nextTask(from:now:)` with an updated snapshot in which the previously
/// active task's `status` has been flipped to `.done` — the engine has no notion of history or
/// an "active" task, so this is exercised purely by comparing two calls against two snapshots.
@Suite("Auto-advance on completion")
struct AutoAdvanceTests {

    // US2 acceptance scenario 1: completing the active task advances selection to the next
    // correct eligible task.
    @Test("completing the active task advances to the next correct task")
    func completingActiveTaskAdvancesToNextTask() {
        let activeTask = makeTask(id: fixedUUID(1), status: .inProgress, priority: 2)
        let nextEligibleTask = makeTask(id: fixedUUID(2), status: .todo, priority: 1)

        let before = nextTask(from: [activeTask, nextEligibleTask], now: referenceNow)
        #expect(before?.id == activeTask.id)

        var completedActiveTask = activeTask
        completedActiveTask.status = .done

        let after = nextTask(from: [completedActiveTask, nextEligibleTask], now: referenceNow)

        #expect(after?.id == nextEligibleTask.id)
    }

    // US2 acceptance scenario 3: completing the only eligible task leaves nothing selected.
    @Test("completing the sole eligible task returns nil")
    func completingSoleEligibleTaskReturnsNil() {
        let onlyTask = makeTask(id: fixedUUID(1), status: .todo, priority: 1)

        let before = nextTask(from: [onlyTask], now: referenceNow)
        #expect(before?.id == onlyTask.id)

        var completedOnlyTask = onlyTask
        completedOnlyTask.status = .done

        let after = nextTask(from: [completedOnlyTask], now: referenceNow)

        #expect(after == nil)
    }
}
