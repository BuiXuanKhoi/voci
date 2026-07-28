// Tests/StartTimePersistenceTests.swift — XCTest coverage for `TaskItem.startTime` /
// `VolarTask.startTime` (urgent-task "làm ngay lập tức" start instant, kept separate from
// `deadline` — see doc comments on both types). Confirms the value round-trips through
// `TaskStore` in both directions (the "sót một chiều map" failure mode called out in this task's
// instructions) and survives an update to an already-persisted task.
//
// UNVERIFIED (written entirely on Windows — no Xcode/xcodegen/simulator available here): confirm
// on Mac that `xcodegen generate` + `xcodebuild test` discovers and runs this file under the
// `VolarTests` target, same as every other file already in this directory.
import Foundation
import XCTest
@testable import Volar

@MainActor
final class StartTimePersistenceTests: XCTestCase {

    private func makeStore() throws -> TaskStore {
        try TaskStore(inMemory: true)
    }

    /// 1. Saving a `TaskItem` with a non-nil `startTime` and reading it back through the store
    /// (`add` -> `fetchAll`, i.e. `TaskItem` -> `VolarTask` -> `TaskItem`) must preserve the exact
    /// instant.
    func testStartTimeRoundTripsThroughStore() throws {
        let store = try makeStore()
        let startTime = Date().addingTimeInterval(60) // "in a minute" — arbitrary fixed instant
        let item = TaskItem(
            title: "Urgent test \(UUID())", priority: .high, startTime: startTime, when: .now
        )
        store.add(item)

        let reloaded = try XCTUnwrap(store.fetchAll().first { $0.id == item.id })
        XCTAssertEqual(reloaded.startTime, startTime)
    }

    /// 2. A task with no `startTime` (the overwhelming majority — anything not created from an
    /// urgent utterance) must read back `nil`, not crash and not synthesize a value.
    func testNilStartTimeRoundTripsAsNil() throws {
        let store = try makeStore()
        let item = TaskItem(title: "Plain test \(UUID())", priority: .medium, when: .later)
        XCTAssertNil(item.startTime, "sanity: default init leaves startTime nil")
        store.add(item)

        let reloaded = try XCTUnwrap(store.fetchAll().first { $0.id == item.id })
        XCTAssertNil(reloaded.startTime)
    }

    /// 3. Direct `TaskItem` -> `VolarTask` -> `TaskItem` round trip via the two hand-written
    /// mapping points (`VolarTask.init`/`asTaskItem`), bypassing the store entirely. This is the
    /// most direct regression test for "a mapping site forgot to carry startTime through" — if
    /// either `asTaskItem` or the init call site drops the field, this fails independently of any
    /// store/SwiftData behavior.
    func testDirectVolarTaskRoundTripPreservesStartTime() {
        let startTime = Date().addingTimeInterval(-30) // half a minute ago — "said it, now working"
        let original = TaskItem(
            title: "Direct mapping test", priority: .high, startTime: startTime, when: .now
        )
        let model = VolarTask(
            id: original.id,
            title: original.title,
            priority: original.priority,
            status: original.status,
            deadline: original.deadline,
            startTime: original.startTime,
            when: original.when
        )
        let roundTripped = model.asTaskItem
        XCTAssertEqual(roundTripped.startTime, startTime)
    }

    /// 4. Updating an already-persisted task (via `mergeIntoExisting`, the general "edit task"
    /// path that reuses `VolarTask.apply(_:)`) must not lose a previously-set `startTime` when the
    /// edit itself doesn't touch it.
    func testStartTimeSurvivesUpdateToExistingTask() throws {
        let store = try makeStore()
        let startTime = Date().addingTimeInterval(120)
        let item = TaskItem(
            title: "Update test \(UUID())", priority: .high, startTime: startTime, when: .now
        )
        store.add(item)

        let merged = store.mergeIntoExisting(item.id) { current in
            var updated = current
            updated.title = "Update test — renamed"
            return updated
        }

        XCTAssertEqual(merged?.startTime, startTime, "unrelated edit must not drop startTime")
        let reloaded = try XCTUnwrap(store.fetchAll().first { $0.id == item.id })
        XCTAssertEqual(reloaded.startTime, startTime, "startTime must still be there after reload")
    }
}
