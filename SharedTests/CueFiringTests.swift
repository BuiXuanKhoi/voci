// Tests/CueFiringTests.swift — XCTest coverage for the pure cue decision logic
// (`Sources/Reminders/CueFiring.swift`). Every test drives `CueFiring.firing`/`CueFiring.pending`
// directly with hand-built `TaskCue` values — no `ModelContext`/`UserDefaults`/`Date()` involved,
// mirroring `FullScreenEscalationDecisionTests`'s own "drive the pure function directly" style.
//
// UNVERIFIED (written entirely on Windows — no Xcode/xcodegen/simulator available here): confirm
// on Mac that `xcodebuild test` picks this file up and every assertion below still holds once
// compiled for real.
import XCTest
@testable import Volar

final class CueFiringTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeCue(
        kind: CueKind,
        verbatim: String = "ngủ dậy thì test feature này",
        createdAt: Date? = nil,
        expiresAt: Date? = nil
    ) -> TaskCue {
        let created = createdAt ?? now.addingTimeInterval(-3600)
        return TaskCue(
            kind: kind,
            verbatim: verbatim,
            createdAt: created,
            expiresAt: expiresAt ?? TaskCue.defaultExpiry(from: created)
        )
    }

    // MARK: - firing(...)

    func testNilLastActiveNeverFires() {
        let cue = makeCue(kind: .wake)
        let taskId = UUID()
        let result = CueFiring.firing(now: now, lastActiveAt: nil, cues: [(taskId, cue)])
        XCTAssertEqual(result, [])
    }

    func testGapJustUnderSixHoursDoesNotFire() {
        let cue = makeCue(kind: .wake)
        let taskId = UUID()
        let lastActive = now.addingTimeInterval(-(6 * 3600 - 60)) // 5h59
        let result = CueFiring.firing(now: now, lastActiveAt: lastActive, cues: [(taskId, cue)])
        XCTAssertEqual(result, [])
    }

    func testGapJustOverSixHoursFires() {
        let cue = makeCue(kind: .wake)
        let taskId = UUID()
        let lastActive = now.addingTimeInterval(-(6 * 3600 + 60)) // 6h01
        let result = CueFiring.firing(now: now, lastActiveAt: lastActive, cues: [(taskId, cue)])
        XCTAssertEqual(result, [taskId])
    }

    func testGapExactlySixHoursFiresBecauseOfGreaterOrEqual() {
        // Boundary case called out explicitly in tasks.md — must fire because the comparison is
        // `>=`, not `>`.
        let cue = makeCue(kind: .wake)
        let taskId = UUID()
        let lastActive = now.addingTimeInterval(-6 * 3600) // exactly 6h
        let result = CueFiring.firing(now: now, lastActiveAt: lastActive, cues: [(taskId, cue)])
        XCTAssertEqual(result, [taskId])
    }

    func testExpiredCueNeverFiresEvenWithSufficientGap() {
        let created = now.addingTimeInterval(-72 * 3600) // 72h ago
        let cue = makeCue(kind: .wake, createdAt: created, expiresAt: created.addingTimeInterval(48 * 3600))
        let taskId = UUID()
        // Gap is huge (72h), well past the 6h floor — expiry must still win.
        let result = CueFiring.firing(now: now, lastActiveAt: created, cues: [(taskId, cue)])
        XCTAssertEqual(result, [])
    }

    func testUnknownKindNeverFiresRegardlessOfGap() {
        let cue = makeCue(kind: .unknown)
        let taskId = UUID()
        let lastActive = now.addingTimeInterval(-24 * 3600) // huge gap
        let result = CueFiring.firing(now: now, lastActiveAt: lastActive, cues: [(taskId, cue)])
        XCTAssertEqual(result, [])
    }

    func testDayEndKindNeverFiresRegardlessOfGap() {
        let cue = makeCue(kind: .dayEnd)
        let taskId = UUID()
        let lastActive = now.addingTimeInterval(-24 * 3600) // huge gap
        let result = CueFiring.firing(now: now, lastActiveAt: lastActive, cues: [(taskId, cue)])
        XCTAssertEqual(result, [])
    }

    func testMultipleFiringCuesPreserveInputOrder() {
        let cueA = makeCue(kind: .wake, verbatim: "A")
        let cueB = makeCue(kind: .wake, verbatim: "B")
        let cueC = makeCue(kind: .wake, verbatim: "C")
        let idA = UUID()
        let idB = UUID()
        let idC = UUID()
        let lastActive = now.addingTimeInterval(-7 * 3600)
        let result = CueFiring.firing(
            now: now,
            lastActiveAt: lastActive,
            cues: [(idC, cueC), (idA, cueA), (idB, cueB)]
        )
        XCTAssertEqual(result, [idC, idA, idB])
    }

    func testEmptyCuesReturnsEmpty() {
        let lastActive = now.addingTimeInterval(-7 * 3600)
        let result = CueFiring.firing(now: now, lastActiveAt: lastActive, cues: [])
        XCTAssertEqual(result, [])
    }

    func testMixedKindsOnlyWakeFires() {
        let wake = makeCue(kind: .wake, verbatim: "wake")
        let unknown = makeCue(kind: .unknown, verbatim: "unknown")
        let dayEnd = makeCue(kind: .dayEnd, verbatim: "dayEnd")
        let idWake = UUID()
        let idUnknown = UUID()
        let idDayEnd = UUID()
        let lastActive = now.addingTimeInterval(-7 * 3600)
        let result = CueFiring.firing(
            now: now,
            lastActiveAt: lastActive,
            cues: [(idWake, wake), (idUnknown, unknown), (idDayEnd, dayEnd)]
        )
        XCTAssertEqual(result, [idWake])
    }

    // MARK: - pending(...)

    func testPendingIncludesUnexpiredNonWakeKinds() {
        let unknown = makeCue(kind: .unknown)
        let dayEnd = makeCue(kind: .dayEnd)
        let idUnknown = UUID()
        let idDayEnd = UUID()
        let result = CueFiring.pending(now: now, cues: [(idUnknown, unknown), (idDayEnd, dayEnd)])
        XCTAssertEqual(result, [idUnknown, idDayEnd])
    }

    func testPendingExcludesExpiredCues() {
        let created = now.addingTimeInterval(-72 * 3600)
        let expired = makeCue(kind: .unknown, createdAt: created, expiresAt: created.addingTimeInterval(48 * 3600))
        let taskId = UUID()
        let result = CueFiring.pending(now: now, cues: [(taskId, expired)])
        XCTAssertEqual(result, [])
    }

    func testPendingExcludesWakeCueCreatedMinutesAgo() {
        // Regression test for the 2026-08-08 Opus-review bug: an earlier version of `pending`
        // returned every unexpired `.wake` cue unconditionally, so a cue created moments ago (user
        // says "ngủ dậy thì test feature này" at 23:00, opens the popover at 23:01) surfaced
        // immediately — showing the "then" before the "if" (waking up) has happened at all. That is
        // pure noise, exactly the thing implementation intentions are supposed to avoid. A `.wake`
        // cue must NOT be pending until it is at least `wakeGapHours` old.
        let wake = makeCue(kind: .wake, createdAt: now.addingTimeInterval(-5 * 60)) // 5 minutes ago
        let taskId = UUID()
        let result = CueFiring.pending(now: now, cues: [(taskId, wake)])
        XCTAssertEqual(result, [])
    }

    func testPendingIncludesWakeCueOldEnoughToClearTheGap() {
        // Mirror of `firing`'s gap: once a `.wake` cue has aged past `wakeGapHours`, it becomes
        // eligible for `pending` too — this is what keeps a `.wake` cue from being permanently lost
        // when the machine runs continuously and `lastActiveAt` never advances far enough for
        // `firing` to fire it (design.md §2's documented limitation).
        let wake = makeCue(kind: .wake, createdAt: now.addingTimeInterval(-7 * 3600)) // 7h ago
        let taskId = UUID()
        let result = CueFiring.pending(now: now, cues: [(taskId, wake)])
        XCTAssertEqual(result, [taskId])
    }
}
