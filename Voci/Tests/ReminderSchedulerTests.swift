// Tests/ReminderSchedulerTests.swift — XCTest coverage for the reminder subsystem
// (specs/002-workflow-command-center/contracts/phase4-contract.md §A/§B, T027).
//
// UNVERIFIED (written entirely on Windows — no Xcode/xcodegen/simulator available here):
//   1. This is a NEW test target (`VociTests` in `Voci/project.yml`) — confirm on Mac that
//      `xcodegen generate` followed by `xcodebuild test` actually builds and runs it.
//   2. `TaskStore()` (Sources/Model/TaskStore.swift, not owned by this task) always opens its
//      REAL default on-disk SwiftData store — there's no in-memory constructor to inject here.
//      Every test below uses a freshly-`UUID()`-suffixed task title/id to avoid cross-test
//      collisions, but repeated local test runs will accumulate rows in that store rather than
//      starting clean. A `TaskStore.init(inMemory:)` parameter would fix this properly — flagged
//      in this task's final report as a backlog candidate for whoever owns TaskStore.swift,
//      rather than added here (out of this task's file ownership).
//   3. `ReminderScheduler.rebuildFromStorage()`/`scheduleReminders`/etc. each spawn a
//      fire-and-forget `Task { ... await UNUserNotificationCenter... }` for system-request
//      registration. None of it is awaited by these tests (every assertion below only reads
//      synchronously-set `ReminderRecord` fields), but confirm on Mac this doesn't hang or crash
//      the `VociTests` bundle when run unsigned / without notification authorization.
import XCTest
@testable import Voci

@MainActor
final class ReminderSchedulerTests: XCTestCase {

    // MARK: - Fixtures

    private func makeScheduler() throws -> (ReminderScheduler, TaskStore) {
        let store = try TaskStore()
        let voice = VoiceReminderChannel(playback: VoicePlayback())
        let gate = ReminderContextGate()
        let scheduler = ReminderScheduler(store: store, voice: voice, gate: gate)
        return (scheduler, store)
    }

    // MARK: - rebuild-from-storage on launch

    func testRebuildFromStorageDerivesRemindersForOpenDatedTasks() throws {
        let (scheduler, store) = try makeScheduler()
        let deadline = Date().addingTimeInterval(3 * 86_400) // 3 days out — every offset is future
        let item = TaskItem(
            title: "Rebuild test \(UUID())", priority: .medium, deadline: deadline, when: .later
        )
        store.add(item)

        scheduler.rebuildFromStorage()

        let records = scheduler.recordsForTask(item.id)
        XCTAssertEqual(records.count, 3, "global default policy has 3 offsets (-1d/-1h/at)")
        XCTAssertEqual(Set(records.map(\.offsetKind)), Set(["-1d", "-1h", "at"]))
        XCTAssertTrue(records.allSatisfy { $0.state == "scheduled" }, "nothing is due yet")
    }

    // MARK: - overdue-while-closed fires once

    func testOverdueReminderFiresOnceOnRecovery() throws {
        let (scheduler, store) = try makeScheduler()
        // Deadline 2 hours in the past: -1d/-1h/at are ALL already due at derivation time.
        let deadline = Date().addingTimeInterval(-2 * 3600)
        let item = TaskItem(
            title: "Overdue test \(UUID())", priority: .medium, deadline: deadline, when: .later
        )
        store.add(item)

        scheduler.rebuildFromStorage()
        let afterFirst = scheduler.recordsForTask(item.id)
        XCTAssertFalse(afterFirst.isEmpty)
        XCTAssertTrue(
            afterFirst.allSatisfy { $0.state == "delivered" },
            "an open task's due-but-missed reminders must fire on recovery"
        )

        // A second rebuild (e.g. a second wake) must NOT re-fire already-delivered records.
        scheduler.rebuildFromStorage()
        let afterSecond = scheduler.recordsForTask(item.id)
        XCTAssertEqual(
            afterFirst.map(\.state).sorted(), afterSecond.map(\.state).sorted(),
            "recovery must be idempotent — a due-but-missed reminder fires once"
        )
    }

    // MARK: - done-task suppression

    func testDoneTaskSuppressesFire() throws {
        let (scheduler, store) = try makeScheduler()
        let deadline = Date().addingTimeInterval(-3600) // already due
        var item = TaskItem(
            title: "Done test \(UUID())", priority: .medium, deadline: deadline, when: .later
        )
        item.status = .done
        store.add(item)

        scheduler.rebuildFromStorage()

        let records = scheduler.recordsForTask(item.id)
        XCTAssertFalse(records.isEmpty)
        XCTAssertTrue(
            records.allSatisfy { $0.state == "satisfied" },
            "a done task's fresh-reloaded reminder must resolve to satisfied with no delivery"
        )
    }

    // MARK: - policy escalation offsets

    func testDeriveUsesGlobalPolicyOffsetsAndHighUrgencyFlag() {
        let deadline = Date()
        let records = ReminderRecord.derive(taskId: UUID(), deadline: deadline, reminderOverride: nil)

        XCTAssertEqual(records.count, 3)
        let byKind = Dictionary(uniqueKeysWithValues: records.map { ($0.offsetKind, $0) })

        XCTAssertEqual(byKind["-1d"]?.fireAt, deadline.addingTimeInterval(-86_400))
        XCTAssertEqual(byKind["-1h"]?.fireAt, deadline.addingTimeInterval(-3600))
        XCTAssertEqual(byKind["at"]?.fireAt, deadline)

        XCTAssertEqual(byKind["-1d"]?.isHighUrgency, false)
        XCTAssertEqual(byKind["-1h"]?.isHighUrgency, false)
        XCTAssertEqual(byKind["at"]?.isHighUrgency, true, "at-or-after-deadline offsets drive the voice escalation rung")
    }

    func testDerivePrefersPerTaskOverride() {
        let deadline = Date()
        let override = ReminderPolicy(offsets: [-1800], repeatEvery: nil) // 30 min before — nonstandard
        let records = ReminderRecord.derive(taskId: UUID(), deadline: deadline, reminderOverride: override)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.offsetKind, "override")
        XCTAssertEqual(records.first?.fireAt, deadline.addingTimeInterval(-1800))
    }

    func testDeriveReturnsEmptyForUndatedTask() {
        let records = ReminderRecord.derive(taskId: UUID(), deadline: nil, reminderOverride: nil)
        XCTAssertTrue(records.isEmpty, "reminders never gate eligibility and have nothing to anchor to without a deadline")
    }

    // MARK: - nearest-N refill under the 64 cap

    func testNearestCandidatesPicksEarliestUnderCapacity() {
        let now = Date()
        let records = (0..<10).map { offset in
            ReminderRecord(taskId: UUID(), fireAt: now.addingTimeInterval(Double(offset) * 60), offsetKind: "at")
        }
        let shuffled = records.shuffled()

        let selected = ReminderScheduler.nearestCandidates(shuffled, excluding: [], capacity: 3)

        XCTAssertEqual(selected.count, 3)
        XCTAssertEqual(
            selected.map(\.fireAt), Array(records.prefix(3)).map(\.fireAt),
            "must pick the 3 EARLIEST, not just any 3"
        )
    }

    func testNearestCandidatesExcludesAlreadyRegistered() {
        let now = Date()
        let records = (0..<5).map { offset in
            ReminderRecord(taskId: UUID(), fireAt: now.addingTimeInterval(Double(offset) * 60), offsetKind: "at")
        }

        let selected = ReminderScheduler.nearestCandidates(
            records, excluding: [records[0].id, records[1].id], capacity: 10
        )

        XCTAssertEqual(selected.count, 3)
        XCTAssertFalse(selected.contains { $0.id == records[0].id || $0.id == records[1].id })
    }

    func testNearestCandidatesRespectsZeroCapacity() {
        let record = ReminderRecord(taskId: UUID(), fireAt: Date(), offsetKind: "at")
        XCTAssertTrue(ReminderScheduler.nearestCandidates([record], excluding: [], capacity: 0).isEmpty)
    }

    func testNearestCandidatesSkipsNonScheduledStates() {
        let now = Date()
        let scheduled = ReminderRecord(taskId: UUID(), fireAt: now, offsetKind: "at", state: "scheduled")
        let delivered = ReminderRecord(taskId: UUID(), fireAt: now.addingTimeInterval(-10), offsetKind: "at", state: "delivered")

        let selected = ReminderScheduler.nearestCandidates([scheduled, delivered], excluding: [], capacity: 10)

        XCTAssertEqual(selected.map(\.id), [scheduled.id], "only .scheduled records are eligible for a system slot")
    }

    // MARK: - voice-gate suppression paths

    func testGateSuppressesDuringBusyInterval() {
        let gate = ReminderContextGate()
        let now = Date()
        gate.busyIntervals = [DateInterval(start: now.addingTimeInterval(-60), end: now.addingTimeInterval(60))]
        XCTAssertTrue(gate.shouldSuppressVoice(now: now))
    }

    func testGateAllowsOutsideBusyInterval() {
        let gate = ReminderContextGate()
        let now = Date()
        gate.busyIntervals = [DateInterval(start: now.addingTimeInterval(3600), end: now.addingTimeInterval(7200))]
        XCTAssertFalse(gate.shouldSuppressVoice(now: now))
    }

    func testGateSuppressesWhenDoNotDisturbSignalFires() {
        let gate = ReminderContextGate()
        gate.isDoNotDisturbOn = { true }
        XCTAssertTrue(gate.shouldSuppressVoice(now: Date()))
    }

    func testGateSuppressesWhenLocalCaptureActive() {
        let gate = ReminderContextGate()
        gate.isLocalMicCaptureActive = { true }
        XCTAssertTrue(gate.shouldSuppressVoice(now: Date()))
    }

    func testGateSuppressesWhenScreenSharingSignalFires() {
        let gate = ReminderContextGate()
        gate.isScreenBeingShared = { true }
        XCTAssertTrue(gate.shouldSuppressVoice(now: Date()))
    }

    func testGateSuppressesWhenOtherAudioSignalFires() {
        let gate = ReminderContextGate()
        gate.isOtherAudioPlaying = { true }
        XCTAssertTrue(gate.shouldSuppressVoice(now: Date()))
    }

    func testGateDefaultsToNotSuppressedWithNoSignalsWired() {
        let gate = ReminderContextGate()
        // No busyIntervals, no injected closures wired. The only remaining concrete check
        // (AVCaptureDevice mic contention) should read `false` in a plain test-runner process with
        // no audio call in progress — fail-open by design absent any actual signal (see
        // ReminderContextGate.swift's header comment on why "unsure" vs "no signal" differ).
        XCTAssertFalse(gate.shouldSuppressVoice(now: Date()))
    }
}
