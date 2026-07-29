// Tests/TaskDependencyStoreTests.swift — XCTest coverage for
// `TaskStore.removeCondition(at:from:)` (cycle-detection-contract.md §1.4/§4) plus a regression
// check that `addCondition`'s existing cycle rejection is unchanged.
//
// UNVERIFIED (written entirely on Windows — no Xcode/xcodegen/simulator available here): confirm
// on Mac that `xcodegen generate` + `xcodebuild test` discovers and runs this file under the
// `VolarTests` target, same as every other file already in this directory (matches
// `StartTimePersistenceTests.swift`'s own note).
import Foundation
import XCTest
import VolarCore
@testable import Volar

@MainActor
final class TaskDependencyStoreTests: XCTestCase {

    private func makeStore() throws -> TaskStore {
        try TaskStore(inMemory: true)
    }

    /// 1. `removeCondition` removes exactly the element at `index`, leaving the rest of the array
    /// (and its order) untouched.
    func testRemoveConditionRemovesExactElement() throws {
        let store = try makeStore()
        let waitsOn1 = TaskItem(title: "Dependency 1", priority: .medium, when: .later)
        let waitsOn2 = TaskItem(title: "Dependency 2", priority: .medium, when: .later)
        try store.addBatch([waitsOn1, waitsOn2])

        var main = TaskItem(title: "Main task \(UUID())", priority: .high, when: .now)
        main.conditions = [
            .taskDone(waitsOn1.id),
            .external(description: "waiting on legal", satisfied: false),
            .taskDone(waitsOn2.id),
        ]
        store.add(main)

        let removed = store.removeCondition(at: 1, from: main.id)
        XCTAssertTrue(removed)

        let reloaded = try XCTUnwrap(store.fetchAll().first { $0.id == main.id })
        XCTAssertEqual(reloaded.conditions.count, 2)
        XCTAssertEqual(reloaded.conditions[0], .taskDone(waitsOn1.id))
        XCTAssertEqual(reloaded.conditions[1], .taskDone(waitsOn2.id))
    }

    /// 2. An out-of-bounds index is a safe no-op: `false`, and the task's conditions are left
    /// exactly as they were (not truncated, not crashed).
    func testRemoveConditionOutOfBoundsIsNoOp() throws {
        let store = try makeStore()
        let waitsOn = TaskItem(title: "Dependency", priority: .medium, when: .later)
        store.add(waitsOn)

        var main = TaskItem(title: "Main task \(UUID())", priority: .high, when: .now)
        main.conditions = [.taskDone(waitsOn.id)]
        store.add(main)

        XCTAssertFalse(store.removeCondition(at: 5, from: main.id))
        XCTAssertFalse(store.removeCondition(at: -1, from: main.id))

        let reloaded = try XCTUnwrap(store.fetchAll().first { $0.id == main.id })
        XCTAssertEqual(reloaded.conditions, [.taskDone(waitsOn.id)])
    }

    /// 3. An unknown task id is also a safe no-op: `false`, nothing thrown, nothing else in the
    /// store touched.
    func testRemoveConditionUnknownIdIsNoOp() throws {
        let store = try makeStore()
        let existing = TaskItem(title: "Untouched", priority: .medium, when: .later)
        var withCondition = existing
        withCondition.conditions = [.afterDate(Date().addingTimeInterval(3600))]
        store.add(withCondition)

        XCTAssertFalse(store.removeCondition(at: 0, from: UUID()))

        let reloaded = try XCTUnwrap(store.fetchAll().first { $0.id == existing.id })
        XCTAssertEqual(reloaded.conditions.count, 1)
    }

    /// 4. Regression: `addCondition` must still reject a `.taskDone` edge that would close a
    /// cycle, throwing `TaskStoreError.invalidCondition` with the existing human-readable message
    /// (`TaskStore.describe(_:)`) — this contract only adds removal, it doesn't touch that path.
    func testAddConditionStillRejectsCycle() throws {
        let store = try makeStore()
        let taskA = TaskItem(title: "Task A", priority: .medium, when: .later)
        var taskB = TaskItem(title: "Task B", priority: .medium, when: .later)
        // B already waits on A.
        taskB.conditions = [.taskDone(taskA.id)]
        try store.addBatch([taskA, taskB])

        // Now try to make A wait on B too — closes the A -> B -> A loop.
        XCTAssertThrowsError(try store.addCondition(.taskDone(taskB.id), to: taskA.id)) { error in
            guard case TaskStoreError.invalidCondition(let message) = error else {
                XCTFail("expected .invalidCondition, got \(error)")
                return
            }
            XCTAssertFalse(message.isEmpty)
        }

        // The rejected edge must not have been attached.
        let reloadedA = try XCTUnwrap(store.fetchAll().first { $0.id == taskA.id })
        XCTAssertTrue(reloadedA.conditions.isEmpty)
    }

    /// 5. Self-dependency is rejected the same way (`DependencyError.selfDependency`, via
    /// `addCondition`) — a quick sanity check that `removeCondition` living alongside it didn't
    /// change that behavior.
    func testAddConditionStillRejectsSelfDependency() throws {
        let store = try makeStore()
        let task = TaskItem(title: "Solo task", priority: .medium, when: .later)
        store.add(task)

        XCTAssertThrowsError(try store.addCondition(.taskDone(task.id), to: task.id))

        let reloaded = try XCTUnwrap(store.fetchAll().first { $0.id == task.id })
        XCTAssertTrue(reloaded.conditions.isEmpty)
    }
}
