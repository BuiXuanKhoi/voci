// Tests/WaitingModeTests.swift — XCTest coverage for the pure waiting-mode holder
// (`Sources/Model/WaitingMode.swift`). Every test drives `WaitingMode.decide` directly with
// hand-built `TaskItem` values and an explicit `now`/`eligibleOrder` — no `AppState`/SwiftData/
// `VolarCore.nextTask` involved, mirroring `FullScreenEscalationDecisionTests`'s own "drive the
// pure function directly" style.
//
// UNVERIFIED (written entirely on Windows — no Xcode/Swift toolchain available here): confirm on
// Mac that `xcodebuild test`/`swift test` picks this file up and every assertion below still
// holds once compiled for real. In particular: the exact `Int(TimeInterval / 60)` truncation
// behavior at the `horizonMinutes`/`bufferMinutes` boundaries has not been run through a real
// Swift runtime.
import XCTest
@testable import Volar

final class WaitingModeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func minutes(_ n: Int) -> TimeInterval { TimeInterval(n * 60) }

    private func task(
        id: UUID = UUID(),
        title: String = "task",
        status: TaskStatus = .todo,
        deadline: Date? = nil,
        durationMinutes: Int? = nil
    ) -> TaskItem {
        TaskItem(
            id: id,
            title: title,
            priority: .medium,
            status: status,
            deadline: deadline,
            when: .later,
            durationMinutes: durationMinutes
        )
    }

    // MARK: - 1. No deadline anywhere -> nil

    func testNoDeadlineAnywhereReturnsNil() {
        let tasks = [task(title: "a"), task(title: "b"), task(title: "c")]
        let decision = WaitingMode.decide(now: now, tasks: tasks, eligibleOrder: tasks.map(\.id))
        XCTAssertNil(decision)
    }

    // MARK: - 2. Deadline outside horizon -> nil

    func testDeadlineOutsideHorizonReturnsNil() {
        let farTask = task(deadline: now.addingTimeInterval(minutes(WaitingMode.horizonMinutes + 1)))
        let decision = WaitingMode.decide(now: now, tasks: [farTask], eligibleOrder: [farTask.id])
        XCTAssertNil(decision)
    }

    func testDeadlineExactlyAtHorizonBoundaryCounts() {
        // `<= horizonEnd` — the boundary itself is inclusive per design.md §2's `(now, now+240']`.
        let boundaryTask = task(deadline: now.addingTimeInterval(minutes(WaitingMode.horizonMinutes)))
        let decision = WaitingMode.decide(now: now, tasks: [boundaryTask], eligibleOrder: [boundaryTask.id])
        XCTAssertEqual(decision?.anchorTaskId, boundaryTask.id)
    }

    // MARK: - 3. Deadline in the past -> nil

    func testPastDeadlineReturnsNil() {
        let pastTask = task(deadline: now.addingTimeInterval(-minutes(5)))
        let decision = WaitingMode.decide(now: now, tasks: [pastTask], eligibleOrder: [pastTask.id])
        XCTAssertNil(decision)
    }

    func testDeadlineExactlyNowDoesNotCount() {
        // "đúng bằng now không tính" — strict future only.
        let nowTask = task(deadline: now)
        let decision = WaitingMode.decide(now: now, tasks: [nowTask], eligibleOrder: [nowTask.id])
        XCTAssertNil(decision)
    }

    // MARK: - 4. Earliest deadline wins among several candidates

    func testSelectsEarliestDeadlineAmongMultipleAnchors() {
        let soon = task(title: "soon", deadline: now.addingTimeInterval(minutes(30)))
        let later = task(title: "later", deadline: now.addingTimeInterval(minutes(120)))
        let latest = task(title: "latest", deadline: now.addingTimeInterval(minutes(200)))
        let tasks = [latest, soon, later] // deliberately out of chronological order
        let decision = WaitingMode.decide(now: now, tasks: tasks, eligibleOrder: tasks.map(\.id))
        XCTAssertEqual(decision?.anchorTaskId, soon.id)
        XCTAssertEqual(decision?.anchorTitle, "soon")
    }

    // MARK: - 5. fitMinutes subtracts the buffer correctly

    func testFitMinutesSubtractsBuffer() {
        let anchor = task(deadline: now.addingTimeInterval(minutes(60)))
        let decision = WaitingMode.decide(now: now, tasks: [anchor], eligibleOrder: [anchor.id])
        XCTAssertEqual(decision?.minutesUntil, 60)
        XCTAssertEqual(decision?.fitMinutes, 60 - WaitingMode.bufferMinutes)
    }

    // MARK: - 6. Buffer larger than the gap -> fitMinutes floors at 0

    func testBufferLargerThanGapFloorsFitMinutesAtZero() {
        // Gap smaller than bufferMinutes (10) but still inside the future/horizon window.
        // eligibleOrder deliberately excludes the anchor (`anchorIsEligible == false`) so this
        // case isolates the fitMinutes-floors-at-0 math from the separate
        // anchorIsEligible-forces-nil rule covered by the tests below.
        let anchor = task(deadline: now.addingTimeInterval(minutes(5)))
        let decision = WaitingMode.decide(now: now, tasks: [anchor], eligibleOrder: [])
        XCTAssertEqual(decision?.minutesUntil, 5)
        XCTAssertEqual(decision?.fitMinutes, 0)
        XCTAssertFalse(decision?.anchorIsEligible ?? true)
        XCTAssertNil(decision?.suggestedTaskId)
    }

    // MARK: - 7. Suggests the FIRST fitting task per eligibleOrder, not the shortest one

    func testSuggestsFirstFittingTaskInEligibleOrderNotShortest() {
        let anchor = task(title: "anchor", deadline: now.addingTimeInterval(minutes(70)))
        // fitMinutes = 70 - 10 = 60. Both "longer" (55m) and "shorter" (10m) fit inside 60.
        let longerButFirst = task(title: "longerButFirst", durationMinutes: 55)
        let shorterButSecond = task(title: "shorterButSecond", durationMinutes: 10)
        let tasks = [anchor, longerButFirst, shorterButSecond]
        // eligibleOrder deliberately puts the LONGER-but-still-fitting task first — proves
        // `decide` never re-sorts by duration/"best fit", only filters the engine's own order.
        let eligibleOrder = [longerButFirst.id, shorterButSecond.id]
        let decision = WaitingMode.decide(now: now, tasks: tasks, eligibleOrder: eligibleOrder)
        XCTAssertEqual(decision?.suggestedTaskId, longerButFirst.id)
    }

    // MARK: - 8. Nothing fits -> suggestedTaskId nil, but Decision is still returned

    func testNothingFitsReturnsNilSuggestionButStillReturnsDecision() {
        let anchor = task(deadline: now.addingTimeInterval(minutes(40)))
        // fitMinutes = 40 - 10 = 30. Every candidate is too long.
        let tooLong1 = task(durationMinutes: 45)
        let tooLong2 = task(durationMinutes: 90)
        let tasks = [anchor, tooLong1, tooLong2]
        let decision = WaitingMode.decide(now: now, tasks: tasks, eligibleOrder: [tooLong1.id, tooLong2.id])
        XCTAssertNotNil(decision)
        XCTAssertEqual(decision?.anchorTaskId, anchor.id)
        XCTAssertNil(decision?.suggestedTaskId)
    }

    // MARK: - 9. Anchor never suggests itself
    //
    // CHANGED by the Opus review (2026-08-08, see the three
    // `testAnchorEligible*`/`testAnchorNotEligible*` regression tests below): this case used to
    // assert `suggestedTaskId == other.id` when the anchor's id led `eligibleOrder` — i.e. "the
    // self-exclusion guard skips the anchor and falls through to the next candidate." That
    // expectation is now WRONG. Once the anchor's id is in `eligibleOrder`, `anchorIsEligible`
    // is `true` and `suggestedTaskId` must be `nil` unconditionally (see
    // `WaitingMode.Decision.suggestedTaskId`'s doc comment for the bug this prevents: never
    // suggest a substitute task for time the user should be spending on their own upcoming
    // deadline). The old scenario is superseded by `testAnchorEligiblePerfectFitStillSuggestsNothing`
    // below; kept here (renamed) only to keep asserting the still-true invariant that
    // `suggestedTaskId`, whenever non-nil, is never equal to `anchorTaskId`.
    func testSuggestedTaskIdIsNeverEqualToAnchorTaskId() {
        let anchor = task(deadline: now.addingTimeInterval(minutes(60)), durationMinutes: 5)
        let other = task(durationMinutes: 5)
        let tasks = [anchor, other]
        // Anchor deliberately NOT eligible here (excluded from eligibleOrder) so the suggestion
        // search actually runs — otherwise `anchorIsEligible == true` would force `nil` before
        // the self-exclusion guard is even reached (see tests below for that branch).
        let decision = WaitingMode.decide(now: now, tasks: tasks, eligibleOrder: [other.id])
        XCTAssertEqual(decision?.suggestedTaskId, other.id)
        XCTAssertNotEqual(decision?.suggestedTaskId, anchor.id)
    }

    // MARK: - Opus review 2026-08-08 regression: anchor eligible ⇒ never suggest a substitute

    /// The exact bug from the review: task "Nộp báo cáo" 40 minutes out, `durationMinutes = 30`,
    /// with a DIFFERENT task that fits `fitMinutes` (30) perfectly sitting right there in
    /// `eligibleOrder`. Before the fix this would suggest the other task and let the user spend
    /// their last 30 minutes on the wrong thing. `anchorIsEligible` must short-circuit this to
    /// `nil` regardless of how good the "fit" looks.
    func testAnchorEligiblePerfectFitStillSuggestsNothing() {
        let anchor = task(title: "Nộp báo cáo", deadline: now.addingTimeInterval(minutes(40)), durationMinutes: 30)
        let perfectFit = task(title: "other task", durationMinutes: 30) // fitMinutes = 40-10 = 30, exact match
        let tasks = [anchor, perfectFit]
        let decision = WaitingMode.decide(now: now, tasks: tasks, eligibleOrder: [anchor.id, perfectFit.id])
        XCTAssertEqual(decision?.anchorIsEligible, true)
        XCTAssertNil(decision?.suggestedTaskId, "must never suggest a substitute for the user's own imminent deadline")
    }

    /// Mirror case: anchor is NOT in `eligibleOrder` (blocked by a condition, or otherwise not
    /// actionable right now) — the pre-fix suggestion search still applies unchanged.
    func testAnchorNotEligibleStillSuggestsFittingTask() {
        let anchor = task(deadline: now.addingTimeInterval(minutes(40)), durationMinutes: 30)
        let fitting = task(durationMinutes: 30)
        let tasks = [anchor, fitting]
        // Anchor's id deliberately absent from eligibleOrder.
        let decision = WaitingMode.decide(now: now, tasks: tasks, eligibleOrder: [fitting.id])
        XCTAssertEqual(decision?.anchorIsEligible, false)
        XCTAssertEqual(decision?.suggestedTaskId, fitting.id)
    }

    /// Anchor not eligible AND nothing fits either — `Decision` (the "hold the anchor" value) is
    /// still returned; only the suggestion is empty.
    func testAnchorNotEligibleAndNothingFitsStillReturnsDecision() {
        let anchor = task(deadline: now.addingTimeInterval(minutes(40)), durationMinutes: 30)
        let tooLong = task(durationMinutes: 90)
        let tasks = [anchor, tooLong]
        let decision = WaitingMode.decide(now: now, tasks: tasks, eligibleOrder: [tooLong.id])
        XCTAssertNotNil(decision)
        XCTAssertEqual(decision?.anchorTaskId, anchor.id)
        XCTAssertEqual(decision?.anchorIsEligible, false)
        XCTAssertNil(decision?.suggestedTaskId)
    }

    // MARK: - Extra: status filtering, default duration, and non-anchor candidates outside eligibleOrder

    func testDoneAndArchivedTasksAreNeverAnchors() {
        let done = task(title: "done", status: .done, deadline: now.addingTimeInterval(minutes(20)))
        let archived = task(title: "archived", status: .archived, deadline: now.addingTimeInterval(minutes(30)))
        let openLater = task(title: "openLater", status: .todo, deadline: now.addingTimeInterval(minutes(90)))
        let tasks = [done, archived, openLater]
        let decision = WaitingMode.decide(now: now, tasks: tasks, eligibleOrder: tasks.map(\.id))
        XCTAssertEqual(decision?.anchorTaskId, openLater.id)
    }

    func testInProgressTaskCanBeAnAnchor() {
        let anchor = task(status: .inProgress, deadline: now.addingTimeInterval(minutes(60)))
        let decision = WaitingMode.decide(now: now, tasks: [anchor], eligibleOrder: [anchor.id])
        XCTAssertEqual(decision?.anchorTaskId, anchor.id)
    }

    func testMissingDurationFallsBackToDefaultDurationMinutesParameter() {
        let anchor = task(deadline: now.addingTimeInterval(minutes(60))) // fitMinutes = 50
        let noDuration = task(durationMinutes: nil)
        let decision = WaitingMode.decide(
            now: now,
            tasks: [anchor, noDuration],
            eligibleOrder: [noDuration.id],
            defaultDurationMinutes: 45
        )
        XCTAssertEqual(decision?.suggestedTaskId, noDuration.id, "45 <= fitMinutes(50) should fit")

        let decisionTooLongDefault = WaitingMode.decide(
            now: now,
            tasks: [anchor, noDuration],
            eligibleOrder: [noDuration.id],
            defaultDurationMinutes: 55
        )
        XCTAssertNil(decisionTooLongDefault?.suggestedTaskId, "55 > fitMinutes(50) should not fit")
    }

    func testCandidateNotInEligibleOrderIsNeverSuggestedEvenIfItWouldFit() {
        let anchor = task(deadline: now.addingTimeInterval(minutes(60)))
        let fitsButExcluded = task(durationMinutes: 5)
        // eligibleOrder deliberately omits `fitsButExcluded` — only the engine's own eligible set
        // may ever be suggested.
        let decision = WaitingMode.decide(now: now, tasks: [anchor, fitsButExcluded], eligibleOrder: [])
        XCTAssertNil(decision?.suggestedTaskId)
    }
}
