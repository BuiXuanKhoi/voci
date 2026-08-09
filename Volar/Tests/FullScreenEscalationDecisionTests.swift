// Tests/FullScreenEscalationDecisionTests.swift — XCTest coverage for the pure full-screen
// takeover gate (`Sources/Reminders/FullScreenEscalationDecision.swift`). Every test drives
// `FullScreenEscalationDecision.shouldEscalate` directly with hand-built `EscalationSignals` — no
// `ModelContext`/`UNUserNotificationCenter`/CoreAudio/`TaskStore` involved, mirroring
// `ReminderSchedulerTests`'s own "drive the pure function directly" style for
// `ReminderRecord.derive`/`ReminderScheduler.nearestCandidates`.
//
// UNVERIFIED (written entirely on Windows — no Xcode/xcodegen/simulator available here): confirm
// on Mac that `xcodebuild test` picks this file up and every assertion below still holds once
// compiled for real.
import XCTest
@testable import Volar

final class FullScreenEscalationDecisionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Every field true/eligible — the one baseline every other test flips exactly one field away
    /// from, so each test isolates exactly the condition it claims to cover.
    private func passingSignals(
        isHighUrgency: Bool = true,
        offsetKind: String = "at",
        isTaskOpen: Bool = true,
        stillInNotificationCenter: Bool = true,
        deliveredAt: Date? = nil,
        isMicrophoneInUse: Bool = false,
        isVolarCapturing: Bool = false,
        settingEnabled: Bool = true
    ) -> EscalationSignals {
        EscalationSignals(
            isHighUrgency: isHighUrgency,
            offsetKind: offsetKind,
            isTaskOpen: isTaskOpen,
            stillInNotificationCenter: stillInNotificationCenter,
            deliveredAt: deliveredAt ?? now.addingTimeInterval(-FullScreenEscalationDecision.ignoredAfter),
            isMicrophoneInUse: isMicrophoneInUse,
            isVolarCapturing: isVolarCapturing,
            settingEnabled: settingEnabled
        )
    }

    func testAllConditionsHoldEscalates() {
        XCTAssertTrue(FullScreenEscalationDecision.shouldEscalate(signals: passingSignals(), now: now))
    }

    // MARK: - anh Khôi's frozen ranting boundary — a nudge must NEVER escalate

    func testNudgeOffsetKindNeverEscalatesEvenIfHighUrgency() {
        // Hypothetical: `isHighUrgency == true` AND `offsetKind == "nudge"` together should never
        // happen in practice (`ReminderRecord.derive`'s no-deadline branch always pairs "nudge"
        // with `isHighUrgency == false`) — this test proves the SECOND, independent guard still
        // blocks it even if that invariant were ever violated upstream.
        let signals = passingSignals(isHighUrgency: true, offsetKind: "nudge")
        XCTAssertFalse(FullScreenEscalationDecision.shouldEscalate(signals: signals, now: now))
    }

    func testLowUrgencyOffsetNeverEscalates() {
        // A plain before-deadline heads-up (`-1d`/`-1h`/`override`, `isHighUrgency == false`) must
        // stay visual-only, exactly like the existing voice-escalation rule.
        for kind in ["-1d", "-1h", "override", "resurface", "unblocked"] {
            let signals = passingSignals(isHighUrgency: false, offsetKind: kind)
            XCTAssertFalse(
                FullScreenEscalationDecision.shouldEscalate(signals: signals, now: now),
                "offsetKind \(kind) with isHighUrgency == false must not escalate"
            )
        }
    }

    // MARK: - Task lifecycle (fresh read, not stale snapshot)

    func testClosedTaskDoesNotEscalate() {
        let signals = passingSignals(isTaskOpen: false)
        XCTAssertFalse(FullScreenEscalationDecision.shouldEscalate(signals: signals, now: now))
    }

    // MARK: - "ignored" signal: getDeliveredNotifications() + the N-minute window

    func testAlreadyDismissedNotificationDoesNotEscalate() {
        // Identifier no longer in Notification Center == the user already interacted with it.
        let signals = passingSignals(stillInNotificationCenter: false)
        XCTAssertFalse(FullScreenEscalationDecision.shouldEscalate(signals: signals, now: now))
    }

    func testBeforeIgnoredWindowDoesNotEscalate() {
        let justUnderThreshold = now.addingTimeInterval(-(FullScreenEscalationDecision.ignoredAfter - 1))
        let signals = passingSignals(deliveredAt: justUnderThreshold)
        XCTAssertFalse(FullScreenEscalationDecision.shouldEscalate(signals: signals, now: now))
    }

    func testExactlyAtIgnoredWindowEscalates() {
        // `>=`, not `>` — landing exactly on the threshold still counts as "ignored long enough",
        // mirroring `ReminderRecord.derive`'s own documented boundary-inclusive philosophy for its
        // `remindPeriod` walk (`candidate < now` is strict, `==` still keeps the mark).
        let exactlyAtThreshold = now.addingTimeInterval(-FullScreenEscalationDecision.ignoredAfter)
        let signals = passingSignals(deliveredAt: exactlyAtThreshold)
        XCTAssertTrue(FullScreenEscalationDecision.shouldEscalate(signals: signals, now: now))
    }

    // MARK: - Regression: wake-from-sleep / due-but-missed recovery must NOT escalate instantly
    //
    // The most important test in this file (Opus review, 2026-07-29). `EscalationSignals` never
    // carries a `ReminderRecord.fireAt` at all — deliberately, precisely so this scenario can't
    // sneak back in: `ReminderScheduler.sweepForFullScreenEscalation` used to pass
    // `record.fireAt` as `deliveredAt`, which is WRONG for a due-but-missed recovery fire (Mac
    // asleep overnight, task's deadline was hours ago, `fire(_:using:)` posts the notification
    // "now" once the Mac wakes). `fireAt` there is hours old even though the user has had exactly
    // zero seconds to see the banner — using it as `deliveredAt` would blow past `ignoredAfter`
    // instantly and take over the screen the moment the user's machine wakes up, before they've
    // ever had a chance to notice the notification. The fix reads the REAL delivery moment
    // (`UNNotification.date`) instead — this test proves the pure function itself only ever
    // reasons about that real moment, with no way for an old `fireAt` to leak in as a substitute.
    func testRecordFiredHoursAgoButJustDeliveredDoesNotEscalate() {
        // `fireAt` (the original, possibly-hours-overdue scheduled time) never appears anywhere in
        // `EscalationSignals` — only `deliveredAt` does. Simulating "fireAt was 8 hours ago" is
        // therefore simply "irrelevant to this call" by construction; what matters is that the
        // REAL delivery moment (`deliveredAt`) is only 30 seconds old.
        let justDelivered = now.addingTimeInterval(-30)
        let signals = passingSignals(deliveredAt: justDelivered)
        XCTAssertFalse(
            FullScreenEscalationDecision.shouldEscalate(signals: signals, now: now),
            "a notification delivered 30s ago must never escalate just because its underlying task was due hours earlier"
        )
    }

    // MARK: - "busy" signals (mic in use / Volar's own capture)

    func testMicrophoneInUseSuppressesEscalation() {
        let signals = passingSignals(isMicrophoneInUse: true)
        XCTAssertFalse(FullScreenEscalationDecision.shouldEscalate(signals: signals, now: now))
    }

    func testVolarOwnCaptureSuppressesEscalation() {
        let signals = passingSignals(isVolarCapturing: true)
        XCTAssertFalse(FullScreenEscalationDecision.shouldEscalate(signals: signals, now: now))
    }

    // MARK: - Settings opt-out

    func testSettingDisabledSuppressesEscalation() {
        let signals = passingSignals(settingEnabled: false)
        XCTAssertFalse(FullScreenEscalationDecision.shouldEscalate(signals: signals, now: now))
    }

    // MARK: - Determinism (no hidden clock read)

    func testSameInputsAlwaysProduceSameAnswer() {
        let signals = passingSignals()
        let first = FullScreenEscalationDecision.shouldEscalate(signals: signals, now: now)
        let second = FullScreenEscalationDecision.shouldEscalate(signals: signals, now: now)
        XCTAssertEqual(first, second)
    }
}
