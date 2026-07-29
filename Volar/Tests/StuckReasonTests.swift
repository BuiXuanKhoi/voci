// Tests/StuckReasonTests.swift — XCTest coverage for the "Stuck?" feature (anh Khôi, 2026-07-29,
// REDESIGNED same day for `too_big` after anh Khôi challenged the first version): three different
// reasons a task doesn't get started, three deliberately different responses.
//
//   - `too_big` fetches exactly ONE next physical action (`AppState.stuckNextActionState`,
//     `applyStuckNextActionResult` — the synchronous tail of the async `fetchStuckNextAction`,
//     mirroring `applyBreakdownFetchResult`'s own "split out for direct testability" precedent).
//     It no longer opens `TaskBreakdownView` directly as its first move — the ORIGINAL version of
//     this feature did that, and this file's tests for it were rewritten accordingly; the full
//     breakdown flow is still reachable, but only via the next-action banner's own secondary
//     "See full plan" button (`openFullPlanFromStuck`).
//   - `dread` drives `AppState.stuckDreadState` (`applyStuckDreadResult`) — UNCHANGED by the
//     `too_big` redesign.
//   - `cant_start` drives a small, task-agnostic 2-minute timer (`stuckTimerActive`/
//     `stuckTimerSecondsLeft`) — this file proves it is started/stopped correctly and is
//     completely independent of `focusActive`/`focusSecondsLeft` (the pre-existing Focus session
//     timer this one is deliberately NOT built on top of — see `AppState
//     .startStuckCantStartTimer`'s doc comment for why).
//
// Deliberately PURE, no networking anywhere in this file — same "drive the synchronous tail
// directly" approach `CloudFirstDefaultsAndBreakdownTests.swift` already established for
// `applyBreakdownFetchResult`, applied here to `applyStuckDreadResult`/`applyStuckNextActionResult`.
//
// UNVERIFIED (written entirely on Windows — no Xcode/xcodegen/simulator available here): not run
// against a real `VolarTests` bundle.
import XCTest
@testable import Volar

@MainActor
final class StuckReasonTests: XCTestCase {

    private func makeTask(title: String = "Call the landlord", notes: String? = nil) -> TaskItem {
        TaskItem(title: title, priority: .medium, when: .now, notes: notes)
    }

    // MARK: - Picker open/dismiss

    func testOpenStuckPickerRecordsTheTask() {
        let state = AppState()
        let task = makeTask()

        state.openStuckPicker(for: task)

        XCTAssertEqual(state.stuckPickerTask?.id, task.id)
    }

    func testDismissStuckPickerClearsIt() {
        let state = AppState()
        state.openStuckPicker(for: makeTask())

        state.dismissStuckPicker()

        XCTAssertNil(state.stuckPickerTask)
    }

    // MARK: - too_big (REDESIGNED 2026-07-29): fetches ONE next action, does NOT open
    // TaskBreakdownView directly anymore.

    func testChooseTooBigFetchesANextActionRatherThanOpeningTheFullBreakdownSheet() {
        let state = AppState()
        let task = makeTask(title: "Ship the release notes")
        state.openStuckPicker(for: task)

        state.chooseStuckReason(.tooBig, for: task)

        XCTAssertNil(state.stuckPickerTask, "picker must close the moment a reason is chosen")
        XCTAssertEqual(state.stuckNextActionTask?.id, task.id)
        XCTAssertEqual(state.stuckNextActionState, .loading, "the synchronous part of chooseStuckReason/fetchStuckNextAction must flip to .loading before the async hop, exactly like fetchBreakdown's own breakdownFetchState = .loading")
        XCTAssertNil(state.breakdownTask, "too_big must NOT open the full breakdown sheet as its first move anymore — that used to be the whole reaction, now it's only reachable via the next-action banner's own secondary button")
        XCTAssertFalse(state.showBreakdown)
        XCTAssertEqual(state.stuckDreadState, .idle, "too_big must never touch the dread state machine")
        XCTAssertFalse(state.stuckTimerActive, "too_big must never start the cant_start timer")
    }

    func testApplyStuckNextActionResultWithARealActionLoadsIt() {
        let state = AppState()
        state.stuckNextActionTask = makeTask()
        state.stuckNextActionState = .loading

        state.applyStuckNextActionResult("Open the lease PDF.", session: 0)

        XCTAssertEqual(state.stuckNextActionState, .loaded("Open the lease PDF."))
    }

    func testApplyStuckNextActionResultWithNilBecomesUnavailableNeverAFabricatedFallback() {
        // Unlike dread, too_big has NO static substantive fallback — see
        // `AppState.StuckNextActionState.unavailable`'s doc comment for why inventing a
        // "do something" claim here would misrepresent a guess as a real answer for this task.
        let state = AppState()
        state.stuckNextActionTask = makeTask()
        state.stuckNextActionState = .loading

        state.applyStuckNextActionResult(nil, session: 0)

        XCTAssertEqual(state.stuckNextActionState, .unavailable)
    }

    func testApplyStuckNextActionResultWithBlankMessageBecomesUnavailableToo() {
        let state = AppState()
        state.stuckNextActionTask = makeTask()
        state.stuckNextActionState = .loading

        state.applyStuckNextActionResult("   ", session: 0)

        XCTAssertEqual(state.stuckNextActionState, .unavailable)
    }

    func testApplyStuckNextActionResultIgnoresAStaleSession() {
        let state = AppState()
        state.stuckNextActionTask = makeTask()
        state.stuckNextActionState = .loading

        state.applyStuckNextActionResult("late message", session: 999)

        XCTAssertEqual(state.stuckNextActionState, .loading, "a stale result must be dropped, not applied on top of whatever the banner is doing now")
    }

    func testDismissStuckNextActionResetsEverythingAndInvalidatesAnyInFlightFetch() {
        let state = AppState()
        let task = makeTask()
        state.stuckNextActionTask = task
        state.stuckNextActionState = .loading

        state.dismissStuckNextAction()

        XCTAssertEqual(state.stuckNextActionState, .idle)
        XCTAssertNil(state.stuckNextActionTask)

        state.applyStuckNextActionResult("late", session: 0)
        XCTAssertEqual(state.stuckNextActionState, .idle, "a fetch in flight when the banner was dismissed must never repopulate it")
    }

    func testAcceptingTheNextActionStartsTheSameTimerAndClearsTheBanner() {
        let state = AppState()
        state.stuckNextActionTask = makeTask()
        state.stuckNextActionState = .loaded("Open the lease PDF.")

        state.acceptStuckNextActionAction()

        XCTAssertTrue(state.stuckTimerActive)
        XCTAssertEqual(state.stuckTimerSecondsLeft, 120)
        XCTAssertEqual(state.stuckNextActionState, .idle)
        XCTAssertNil(state.stuckNextActionTask)
    }

    func testOpenFullPlanFromStuckIsTheOnlyRemainingPathIntoTheFullBreakdownSheet() {
        // The next-action banner's own secondary button — proves it reuses openBreakdown(for:)
        // verbatim (same breakdownTask/showBreakdown effects CloudFirstDefaultsAndBreakdownTests
        // already proves for that method) rather than a second implementation.
        let state = AppState()
        let task = makeTask(title: "Ship the release notes")
        state.stuckNextActionTask = task
        state.stuckNextActionState = .loaded("Open the release notes doc.")

        state.openFullPlanFromStuck(for: task)

        XCTAssertEqual(state.breakdownTask?.id, task.id)
        XCTAssertTrue(state.showBreakdown)
        XCTAssertEqual(state.stuckNextActionState, .idle, "opening the full plan must close the next-action banner")
        XCTAssertNil(state.stuckNextActionTask)
    }

    // MARK: - dread: applyStuckDreadResult, the synchronous tail of the async fetch

    func testChooseDreadOpensLoadingStateForTheRightTask() {
        let state = AppState()
        let task = makeTask()
        state.openStuckPicker(for: task)

        state.chooseStuckReason(.dread, for: task)

        // The async fetch itself needs a real router round trip (not exercised here, matching
        // CloudFirstDefaultsAndBreakdownTests' own precedent) — but the SYNCHRONOUS part of
        // `chooseStuckReason`/`fetchStuckDread` must already have flipped state before the async
        // hop, exactly like `openBreakdown(for:)` flips `breakdownFetchState = .loading`
        // synchronously.
        XCTAssertNil(state.stuckPickerTask)
        XCTAssertEqual(state.stuckDreadTask?.id, task.id)
        XCTAssertEqual(state.stuckDreadState, .loading)
    }

    func testApplyStuckDreadResultWithARealMessageLoadsIt() {
        let state = AppState()
        state.stuckDreadTask = makeTask()
        state.stuckDreadState = .loading

        state.applyStuckDreadResult("Open the lease PDF and read the first paragraph.", session: 0)

        XCTAssertEqual(
            state.stuckDreadState,
            .loaded("Open the lease PDF and read the first paragraph.")
        )
    }

    func testApplyStuckDreadResultWithNilFallsBackToTheStaticMessage() {
        // Neither FM nor Cloud produced anything usable (offline / not opted in / decode failure)
        // — must degrade to the STATIC fallback state, never silence and never a fabricated
        // message about the task.
        let state = AppState()
        state.stuckDreadTask = makeTask()
        state.stuckDreadState = .loading

        state.applyStuckDreadResult(nil, session: 0)

        XCTAssertEqual(state.stuckDreadState, .fallback)
    }

    func testApplyStuckDreadResultWithBlankMessageFallsBackToo() {
        // Defensive: a whitespace-only "message" is not a usable message either, even though this
        // should already be impossible post-validation on both the CloudParser and
        // FoundationModelParser sides.
        let state = AppState()
        state.stuckDreadTask = makeTask()
        state.stuckDreadState = .loading

        state.applyStuckDreadResult("   ", session: 0)

        XCTAssertEqual(state.stuckDreadState, .fallback)
    }

    func testApplyStuckDreadResultIgnoresAStaleSession() {
        let state = AppState()
        state.stuckDreadTask = makeTask()
        state.stuckDreadState = .loading

        // Any session other than the untouched fresh-AppState value (0) is stale by construction —
        // mirrors a user dismissing the banner (or reopening Stuck on a different task) while an
        // earlier fetch was still in flight.
        state.applyStuckDreadResult("late message", session: 999)

        XCTAssertEqual(state.stuckDreadState, .loading, "a stale result must be dropped, not applied on top of whatever the banner is doing now")
    }

    func testDismissStuckDreadResetsEverythingAndInvalidatesAnyInFlightFetch() {
        let state = AppState()
        let task = makeTask()
        state.stuckDreadTask = task
        state.stuckDreadState = .loading

        state.dismissStuckDread()

        XCTAssertEqual(state.stuckDreadState, .idle)
        XCTAssertNil(state.stuckDreadTask)

        // A late result from BEFORE the dismissal must not resurrect the banner — same
        // session-token guard `applyBreakdownFetchResult` uses.
        state.applyStuckDreadResult("late", session: 0)
        XCTAssertEqual(state.stuckDreadState, .idle, "a fetch in flight when the banner was dismissed must never repopulate it")
    }

    // MARK: - cant_start: a small, task-agnostic timer, independent of the Focus session timer

    func testChooseCantStartOpensATwoMinuteTimerAndTouchesNothingElse() {
        let state = AppState()
        let task = makeTask()
        state.openStuckPicker(for: task)

        state.chooseStuckReason(.cantStart, for: task)

        XCTAssertNil(state.stuckPickerTask)
        XCTAssertTrue(state.stuckTimerActive)
        XCTAssertEqual(state.stuckTimerSecondsLeft, 120)
        XCTAssertEqual(state.stuckDreadState, .idle, "cant_start must never touch the dread state machine")
        XCTAssertNil(state.stuckDreadTask)
        // Independence from the pre-existing Focus session timer (see
        // `AppState.startStuckCantStartTimer`'s doc comment for why this is a SEPARATE timer):
        // starting the stuck timer must never also start (or otherwise touch) a Focus session.
        XCTAssertFalse(state.focusActive)
    }

    func testEndStuckCantStartTimerResetsState() {
        let state = AppState()
        state.startStuckCantStartTimer()

        state.endStuckCantStartTimer()

        XCTAssertFalse(state.stuckTimerActive)
        XCTAssertEqual(state.stuckTimerSecondsLeft, 0)
    }

    func testAcceptingTheDreadActionStartsTheSameTimerAndClearsTheDreadBanner() {
        // "Start (2 min)" on the dread message/fallback banner deliberately lands on the EXACT
        // same timer cant_start uses — see `AppState.acceptStuckDreadAction`'s doc comment.
        let state = AppState()
        state.stuckDreadTask = makeTask()
        state.stuckDreadState = .loaded("Open the lease PDF.")

        state.acceptStuckDreadAction()

        XCTAssertTrue(state.stuckTimerActive)
        XCTAssertEqual(state.stuckTimerSecondsLeft, 120)
        XCTAssertEqual(state.stuckDreadState, .idle)
        XCTAssertNil(state.stuckDreadTask)
    }

    // MARK: - No counting, no scoring anywhere in this feature

    func testChoosingCantStartRepeatedlyNeverAccumulatesAnyVisibleCount() {
        // The task brief is explicit: no count of "Stuck?" taps may ever be recorded or surfaced.
        // `stuckTimerSecondsLeft` always resets to the same flat 120 on every call — there is no
        // field anywhere on `AppState` this test (or any other in this file) reads that grows with
        // repeated taps.
        let state = AppState()
        let task = makeTask()

        state.chooseStuckReason(.cantStart, for: task)
        state.endStuckCantStartTimer()
        state.chooseStuckReason(.cantStart, for: task)
        state.endStuckCantStartTimer()
        state.chooseStuckReason(.cantStart, for: task)

        XCTAssertEqual(state.stuckTimerSecondsLeft, 120, "must always be the same flat duration, never a count of anything")
    }
}
