// Tests/WaitingModeTests.swift — XCTest coverage for the pure waiting-mode holder
// (`Sources/Model/WaitingMode.swift`). Every test drives `WaitingMode.decide` directly with
// hand-built `TaskItem`/`HardAnchor` values and an explicit `now`/`eligibleOrder` — no `AppState`/
// SwiftData/`VolarCore.nextTask`/EventKit involved, mirroring `FullScreenEscalationDecisionTests`'s
// own "drive the pure function directly" style.
//
// UNVERIFIED (written entirely on Windows — no Xcode/Swift toolchain available here): confirm on
// Mac that `xcodebuild test`/`swift test` picks this file up and every assertion below still
// holds once compiled for real. In particular: the exact `Int(TimeInterval / 60)` truncation
// behavior at the `horizonMinutes`/`bufferMinutes` boundaries has not been run through a real
// Swift runtime.
//
// `anchor(for:)` below is the one new piece vs. the pre-010 version of this file: `decide` no
// longer scans `tasks` for the nearest deadline itself (specs/010-calendar-and-hard-
// deadlines/design.md §2.3), so every test that used to rely on a task's own `deadline` now builds
// a matching `WaitingMode.HardAnchor(source: .deadline(taskID:))` by hand and passes it via
// `anchors:`.
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

    /// Builds the `HardAnchor` a caller would derive from a task's own `deadline` — the shape
    /// `AppState` is expected to produce for every open task with a deadline. `nil` deadline
    /// (or `.done`/`.archived` status) returns `nil`, matching the caller-side filtering `decide`
    /// no longer does itself (see file header).
    private func anchor(for task: TaskItem) -> WaitingMode.HardAnchor? {
        guard task.status != .done, task.status != .archived, let deadline = task.deadline else {
            return nil
        }
        return WaitingMode.HardAnchor(title: task.title, at: deadline, source: .deadline(taskID: task.id))
    }

    private func anchors(for tasks: [TaskItem]) -> [WaitingMode.HardAnchor] {
        tasks.compactMap(anchor(for:))
    }

    // MARK: - 1. No deadline anywhere -> nil

    func testNoDeadlineAnywhereReturnsNil() {
        let tasks = [task(title: "a"), task(title: "b"), task(title: "c")]
        let decision = WaitingMode.decide(now: now, anchors: anchors(for: tasks), tasks: tasks, eligibleOrder: tasks.map(\.id))
        XCTAssertNil(decision)
    }

    // MARK: - 2. Deadline outside horizon -> nil

    func testDeadlineOutsideHorizonReturnsNil() {
        let farTask = task(deadline: now.addingTimeInterval(minutes(WaitingMode.horizonMinutes + 1)))
        let decision = WaitingMode.decide(now: now, anchors: anchors(for: [farTask]), tasks: [farTask], eligibleOrder: [farTask.id])
        XCTAssertNil(decision)
    }

    func testDeadlineExactlyAtHorizonBoundaryCounts() {
        // `<= horizonEnd` — the boundary itself is inclusive per design.md §2's `(now, now+240']`.
        let boundaryTask = task(deadline: now.addingTimeInterval(minutes(WaitingMode.horizonMinutes)))
        let decision = WaitingMode.decide(now: now, anchors: anchors(for: [boundaryTask]), tasks: [boundaryTask], eligibleOrder: [boundaryTask.id])
        XCTAssertEqual(decision?.anchorTaskId, boundaryTask.id)
    }

    // MARK: - 3. Deadline in the past -> nil

    func testPastDeadlineReturnsNil() {
        let pastTask = task(deadline: now.addingTimeInterval(-minutes(5)))
        let decision = WaitingMode.decide(now: now, anchors: anchors(for: [pastTask]), tasks: [pastTask], eligibleOrder: [pastTask.id])
        XCTAssertNil(decision)
    }

    func testDeadlineExactlyNowDoesNotCount() {
        // "đúng bằng now không tính" — strict future only.
        let nowTask = task(deadline: now)
        let decision = WaitingMode.decide(now: now, anchors: anchors(for: [nowTask]), tasks: [nowTask], eligibleOrder: [nowTask.id])
        XCTAssertNil(decision)
    }

    // MARK: - 4. Earliest deadline wins among several candidates

    func testSelectsEarliestDeadlineAmongMultipleAnchors() {
        let soon = task(title: "soon", deadline: now.addingTimeInterval(minutes(30)))
        let later = task(title: "later", deadline: now.addingTimeInterval(minutes(120)))
        let latest = task(title: "latest", deadline: now.addingTimeInterval(minutes(200)))
        let tasks = [latest, soon, later] // deliberately out of chronological order
        let decision = WaitingMode.decide(now: now, anchors: anchors(for: tasks), tasks: tasks, eligibleOrder: tasks.map(\.id))
        XCTAssertEqual(decision?.anchorTaskId, soon.id)
        XCTAssertEqual(decision?.anchorTitle, "soon")
    }

    // MARK: - 5. fitMinutes subtracts the buffer correctly

    func testFitMinutesSubtractsBuffer() {
        let anchorTask = task(deadline: now.addingTimeInterval(minutes(60)))
        let decision = WaitingMode.decide(now: now, anchors: anchors(for: [anchorTask]), tasks: [anchorTask], eligibleOrder: [anchorTask.id])
        XCTAssertEqual(decision?.minutesUntil, 60)
        XCTAssertEqual(decision?.fitMinutes, 60 - WaitingMode.bufferMinutes)
    }

    // MARK: - 6. Buffer larger than the gap -> fitMinutes floors at 0

    func testBufferLargerThanGapFloorsFitMinutesAtZero() {
        // Gap smaller than bufferMinutes (10) but still inside the future/horizon window.
        // eligibleOrder deliberately excludes the anchor (`anchorIsEligible == false`) so this
        // case isolates the fitMinutes-floors-at-0 math from the separate
        // anchorIsEligible-forces-nil rule covered by the tests below.
        let anchorTask = task(deadline: now.addingTimeInterval(minutes(5)))
        let decision = WaitingMode.decide(now: now, anchors: anchors(for: [anchorTask]), tasks: [anchorTask], eligibleOrder: [])
        XCTAssertEqual(decision?.minutesUntil, 5)
        XCTAssertEqual(decision?.fitMinutes, 0)
        XCTAssertFalse(decision?.anchorIsEligible ?? true)
        XCTAssertNil(decision?.suggestedTaskId)
    }

    // MARK: - 7. Suggests the FIRST fitting task per eligibleOrder, not the shortest one

    func testSuggestsFirstFittingTaskInEligibleOrderNotShortest() {
        let anchorTask = task(title: "anchor", deadline: now.addingTimeInterval(minutes(70)))
        // fitMinutes = 70 - 10 = 60. Both "longer" (55m) and "shorter" (10m) fit inside 60.
        let longerButFirst = task(title: "longerButFirst", durationMinutes: 55)
        let shorterButSecond = task(title: "shorterButSecond", durationMinutes: 10)
        let tasks = [anchorTask, longerButFirst, shorterButSecond]
        // eligibleOrder deliberately puts the LONGER-but-still-fitting task first — proves
        // `decide` never re-sorts by duration/"best fit", only filters the engine's own order.
        let eligibleOrder = [longerButFirst.id, shorterButSecond.id]
        let decision = WaitingMode.decide(now: now, anchors: anchors(for: [anchorTask]), tasks: tasks, eligibleOrder: eligibleOrder)
        XCTAssertEqual(decision?.suggestedTaskId, longerButFirst.id)
    }

    // MARK: - 8. Nothing fits -> suggestedTaskId nil, but Decision is still returned

    func testNothingFitsReturnsNilSuggestionButStillReturnsDecision() {
        let anchorTask = task(deadline: now.addingTimeInterval(minutes(40)))
        // fitMinutes = 40 - 10 = 30. Every candidate is too long.
        let tooLong1 = task(durationMinutes: 45)
        let tooLong2 = task(durationMinutes: 90)
        let tasks = [anchorTask, tooLong1, tooLong2]
        let decision = WaitingMode.decide(now: now, anchors: anchors(for: [anchorTask]), tasks: tasks, eligibleOrder: [tooLong1.id, tooLong2.id])
        XCTAssertNotNil(decision)
        XCTAssertEqual(decision?.anchorTaskId, anchorTask.id)
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
        let anchorTask = task(deadline: now.addingTimeInterval(minutes(60)), durationMinutes: 5)
        let other = task(durationMinutes: 5)
        let tasks = [anchorTask, other]
        // Anchor deliberately NOT eligible here (excluded from eligibleOrder) so the suggestion
        // search actually runs — otherwise `anchorIsEligible == true` would force `nil` before
        // the self-exclusion guard is even reached (see tests below for that branch).
        let decision = WaitingMode.decide(now: now, anchors: anchors(for: [anchorTask]), tasks: tasks, eligibleOrder: [other.id])
        XCTAssertEqual(decision?.suggestedTaskId, other.id)
        XCTAssertNotEqual(decision?.suggestedTaskId, anchorTask.id)
    }

    // MARK: - Opus review 2026-08-08 regression: anchor eligible ⇒ never suggest a substitute

    /// The exact bug from the review: task "Nộp báo cáo" 40 minutes out, `durationMinutes = 30`,
    /// with a DIFFERENT task that fits `fitMinutes` (30) perfectly sitting right there in
    /// `eligibleOrder`. Before the fix this would suggest the other task and let the user spend
    /// their last 30 minutes on the wrong thing. `anchorIsEligible` must short-circuit this to
    /// `nil` regardless of how good the "fit" looks.
    func testAnchorEligiblePerfectFitStillSuggestsNothing() {
        let anchorTask = task(title: "Nộp báo cáo", deadline: now.addingTimeInterval(minutes(40)), durationMinutes: 30)
        let perfectFit = task(title: "other task", durationMinutes: 30) // fitMinutes = 40-10 = 30, exact match
        let tasks = [anchorTask, perfectFit]
        let decision = WaitingMode.decide(now: now, anchors: anchors(for: [anchorTask]), tasks: tasks, eligibleOrder: [anchorTask.id, perfectFit.id])
        XCTAssertEqual(decision?.anchorIsEligible, true)
        XCTAssertNil(decision?.suggestedTaskId, "must never suggest a substitute for the user's own imminent deadline")
    }

    /// Mirror case: anchor is NOT in `eligibleOrder` (blocked by a condition, or otherwise not
    /// actionable right now) — the pre-fix suggestion search still applies unchanged.
    func testAnchorNotEligibleStillSuggestsFittingTask() {
        let anchorTask = task(deadline: now.addingTimeInterval(minutes(40)), durationMinutes: 30)
        let fitting = task(durationMinutes: 30)
        let tasks = [anchorTask, fitting]
        // Anchor's id deliberately absent from eligibleOrder.
        let decision = WaitingMode.decide(now: now, anchors: anchors(for: [anchorTask]), tasks: tasks, eligibleOrder: [fitting.id])
        XCTAssertEqual(decision?.anchorIsEligible, false)
        XCTAssertEqual(decision?.suggestedTaskId, fitting.id)
    }

    /// Anchor not eligible AND nothing fits either — `Decision` (the "hold the anchor" value) is
    /// still returned; only the suggestion is empty.
    func testAnchorNotEligibleAndNothingFitsStillReturnsDecision() {
        let anchorTask = task(deadline: now.addingTimeInterval(minutes(40)), durationMinutes: 30)
        let tooLong = task(durationMinutes: 90)
        let tasks = [anchorTask, tooLong]
        let decision = WaitingMode.decide(now: now, anchors: anchors(for: [anchorTask]), tasks: tasks, eligibleOrder: [tooLong.id])
        XCTAssertNotNil(decision)
        XCTAssertEqual(decision?.anchorTaskId, anchorTask.id)
        XCTAssertEqual(decision?.anchorIsEligible, false)
        XCTAssertNil(decision?.suggestedTaskId)
    }

    // MARK: - Extra: status filtering, default duration, and non-anchor candidates outside eligibleOrder

    func testDoneAndArchivedTasksAreNeverAnchors() {
        let done = task(title: "done", status: .done, deadline: now.addingTimeInterval(minutes(20)))
        let archived = task(title: "archived", status: .archived, deadline: now.addingTimeInterval(minutes(30)))
        let openLater = task(title: "openLater", status: .todo, deadline: now.addingTimeInterval(minutes(90)))
        let tasks = [done, archived, openLater]
        // `anchors(for:)` is the caller-side filter now — it drops done/archived tasks itself
        // (see its doc comment), matching what `decide` used to do internally.
        let decision = WaitingMode.decide(now: now, anchors: anchors(for: tasks), tasks: tasks, eligibleOrder: tasks.map(\.id))
        XCTAssertEqual(decision?.anchorTaskId, openLater.id)
    }

    func testInProgressTaskCanBeAnAnchor() {
        let anchorTask = task(status: .inProgress, deadline: now.addingTimeInterval(minutes(60)))
        let decision = WaitingMode.decide(now: now, anchors: anchors(for: [anchorTask]), tasks: [anchorTask], eligibleOrder: [anchorTask.id])
        XCTAssertEqual(decision?.anchorTaskId, anchorTask.id)
    }

    func testMissingDurationFallsBackToDefaultDurationMinutesParameter() {
        let anchorTask = task(deadline: now.addingTimeInterval(minutes(60))) // fitMinutes = 50
        let noDuration = task(durationMinutes: nil)
        let decision = WaitingMode.decide(
            now: now,
            anchors: anchors(for: [anchorTask]),
            tasks: [anchorTask, noDuration],
            eligibleOrder: [noDuration.id],
            defaultDurationMinutes: 45
        )
        XCTAssertEqual(decision?.suggestedTaskId, noDuration.id, "45 <= fitMinutes(50) should fit")

        let decisionTooLongDefault = WaitingMode.decide(
            now: now,
            anchors: anchors(for: [anchorTask]),
            tasks: [anchorTask, noDuration],
            eligibleOrder: [noDuration.id],
            defaultDurationMinutes: 55
        )
        XCTAssertNil(decisionTooLongDefault?.suggestedTaskId, "55 > fitMinutes(50) should not fit")
    }

    func testCandidateNotInEligibleOrderIsNeverSuggestedEvenIfItWouldFit() {
        let anchorTask = task(deadline: now.addingTimeInterval(minutes(60)))
        let fitsButExcluded = task(durationMinutes: 5)
        // eligibleOrder deliberately omits `fitsButExcluded` — only the engine's own eligible set
        // may ever be suggested.
        let decision = WaitingMode.decide(now: now, anchors: anchors(for: [anchorTask]), tasks: [anchorTask, fitsButExcluded], eligibleOrder: [])
        XCTAssertNil(decision?.suggestedTaskId)
    }

    // MARK: - New: calendar-sourced anchor (no backing task)

    func testCalendarSourcedAnchorHasNilAnchorTaskIdAndIsNeverEligible() {
        let calendarAnchor = WaitingMode.HardAnchor(
            title: "Họp nội bộ",
            at: now.addingTimeInterval(minutes(30)),
            source: .calendar
        )
        let fitting = task(durationMinutes: 5)
        let decision = WaitingMode.decide(now: now, anchors: [calendarAnchor], tasks: [fitting], eligibleOrder: [fitting.id])
        XCTAssertNil(decision?.anchorTaskId)
        XCTAssertEqual(decision?.anchorTitle, "Họp nội bộ")
        XCTAssertEqual(decision?.anchorIsEligible, false)
        // Anchor not eligible (calendar anchors never are) ⇒ suggestion search runs normally,
        // with no anchor id to exclude.
        XCTAssertEqual(decision?.suggestedTaskId, fitting.id)
    }

    func testCalendarAnchorAndTaskDeadlineAnchorPickEarliest() {
        let taskDeadline = task(title: "task deadline", deadline: now.addingTimeInterval(minutes(90)))
        let calendarAnchor = WaitingMode.HardAnchor(
            title: "Họp",
            at: now.addingTimeInterval(minutes(30)),
            source: .calendar
        )
        let decision = WaitingMode.decide(
            now: now,
            anchors: anchors(for: [taskDeadline]) + [calendarAnchor],
            tasks: [taskDeadline],
            eligibleOrder: [taskDeadline.id]
        )
        XCTAssertNil(decision?.anchorTaskId, "the calendar event is nearer than the task deadline")
        XCTAssertEqual(decision?.anchorTitle, "Họp")
    }
}
