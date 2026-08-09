// Tests/TextCaptureTests.swift — XCTest coverage for the ⌃⌥T typed-capture popup's state machine
// (`AppState.TextCaptureState`/`textCapture`/`textCaptureInput`/`openTextCapture()`/
// `cancelTextCapture()`/`submitTextCapture()`/`applyTextCaptureParseResult(_:session:)`).
//
// SCOPE (per this feature's task brief): test what's testable without AppKit or network — the
// `TextCaptureState` transitions, empty/whitespace input rejection, that a failed parse preserves
// the typed text, and the stale-session guard logic. Deliberately does NOT register a real Carbon
// hotkey (`HotkeyManager`) or open a real `NSPanel` (`CapturePanel.swift`/`TextCapturePanel.swift`)
// — neither is reachable from a pure `AppState` unit test anyway, and both are explicitly
// off-limits per the task brief ("Do NOT write a test that registers a real Carbon hotkey or opens
// a real NSPanel").
//
// `applyTextCaptureParseResult(_:session:)` is `AppState.swift`'s synchronous back half of
// `submitTextCapture()` — split out specifically so the "parse came back with N results" and
// "the session went stale before the parse returned" scenarios below can be driven directly with a
// hand-built `[ParsedTask]`/session token instead of awaiting a real (if not actually
// network-bound for the on-device tiers) `IntentRouter.parse` round trip. Same precedent as
// `AppState.resolveCloudMatch` (see that method's own doc comment in `AppState.swift`) — a method
// made non-`private` specifically so tests can reach it directly. Every test below drives it with
// `session: 0`, relying on the documented fact that a fresh `AppState()`'s `textCaptureSession`
// counter starts at `0` and is untouched as long as the test never calls `openTextCapture()`/
// `cancelTextCapture()`/`submitTextCapture()` first (each of those bumps it) — `textCapture` is set
// directly (a plain, non-private `var`) to satisfy `applyTextCaptureParseResult`'s OTHER guard
// (`textCapture == .saving`) without going through the async entry point at all.
//
// Deliberately PURE, mirroring `CaptureHotkeyAndTitleEditTests.swift`'s own split: `AppState()`'s
// no-argument initializer degrades to the no-store fallback (`store: TaskStore? = nil`), which is
// exactly what every test below wants — `confirmSave()`'s no-store branch commits synchronously
// in-memory, no `TaskStore`/EventKit/live view hierarchy required.
//
// UNVERIFIED (written entirely on Windows — no Xcode/xcodegen/simulator available here): not run
// against a real `VolarTests` bundle.
import XCTest
@testable import Volar

@MainActor
final class TextCaptureTests: XCTestCase {

    // MARK: - Fixtures (mirrors CaptureHotkeyAndTitleEditTests.makeParsedTask)

    private func makeParsedTask(title: String = "Buy milk", transcript: String = "buy milk") -> ParsedTask {
        ParsedTask(
            title: title,
            notes: nil,
            deadline: nil,
            estimateMinutes: nil,
            priority: nil,
            reminderOverride: nil,
            recurrence: nil,
            kind: .task,
            conditions: [],
            subtasks: [],
            followUpReview: false,
            sourceTranscript: transcript
        )
    }

    // MARK: - openTextCapture()

    func testOpenTextCaptureEntersEditingWithAClearField() {
        let state = AppState()

        state.openTextCapture()

        XCTAssertEqual(state.textCapture, .editing)
        XCTAssertEqual(state.textCaptureInput, "")
    }

    func testOpenTextCaptureCancelsAnInFlightVoiceRecording() {
        let state = AppState()
        state.captureState = .recording
        state.liveTranscript = "some partial transcript"

        state.openTextCapture()

        // Mutual exclusion (task brief: "whichever hotkey the user pressed wins"): ⌃⌥T must tear
        // the voice surface down via the existing `cancelCapture()`, not just ignore it.
        XCTAssertEqual(state.captureState, .idle, "opening the typed popup must cancel an in-flight voice recording")
        XCTAssertEqual(state.textCapture, .editing)
    }

    func testOpenTextCaptureCancelsAPendingVoiceConfirmCard() {
        let state = AppState()
        let draft = ConfirmDraft(task: makeParsedTask())
        state.confirmDrafts = [draft]
        state.captureState = .parsed

        state.openTextCapture()

        XCTAssertEqual(state.captureState, .idle, "opening the typed popup must discard a pending unsaved voice confirm card, not save or ignore it")
        XCTAssertTrue(state.confirmDrafts.isEmpty)
        XCTAssertTrue(state.tasks.isEmpty, "the pending draft must be DISCARDED (cancelCapture semantics), never silently auto-saved")
    }

    func testOpenTextCaptureIsANoOpOnCaptureStateWhenAlreadyIdle() {
        let state = AppState()
        XCTAssertEqual(state.captureState, .idle)

        state.openTextCapture()

        XCTAssertEqual(state.captureState, .idle)
        XCTAssertEqual(state.textCapture, .editing)
    }

    // MARK: - cancelTextCapture()

    func testCancelTextCaptureClosesAndClearsTheField() {
        let state = AppState()
        state.textCapture = .editing
        state.textCaptureInput = "buy oat milk"

        state.cancelTextCapture()

        XCTAssertEqual(state.textCapture, .closed)
        XCTAssertEqual(state.textCaptureInput, "", "Esc must never leave stale text behind for the next ⌃⌥T press")
    }

    func testReopeningAfterCancelStartsWithAnEmptyField() {
        let state = AppState()
        state.openTextCapture()
        state.textCaptureInput = "half-typed thought"
        state.cancelTextCapture()

        state.openTextCapture()

        XCTAssertEqual(state.textCaptureInput, "", "a fresh ⌃⌥T press must never resurrect text from a previously-cancelled popup")
    }

    // MARK: - handleHotkey(): ⌃⌥M closes an open typed-capture popup ("whichever hotkey wins")

    func testHandleHotkeyClosesAnOpenTextCapturePopupAndStartsRecording() {
        let state = AppState()
        state.textCapture = .editing
        state.textCaptureInput = "half-typed thought"
        state.captureState = .idle

        state.handleHotkey()

        XCTAssertEqual(state.textCapture, .closed, "⌃⌥M must close the typed popup — the two capture surfaces are mutually exclusive")
        XCTAssertEqual(state.textCaptureInput, "")
        // Falls through to `handleHotkey()`'s normal `.idle -> startCapture()` branch afterward —
        // its own toggle semantics are unchanged by the popup-closing side effect.
        XCTAssertNotEqual(state.captureState, .idle, "closing the typed popup must not swallow the hotkey press — voice capture should still start")
    }

    // MARK: - submitTextCapture(): synchronous guards (empty input / re-entrancy)

    func testSubmitTextCaptureRejectsEmptyInput() {
        let state = AppState()
        state.textCapture = .editing
        state.textCaptureInput = ""

        state.submitTextCapture()

        XCTAssertEqual(state.textCapture, .editing, "empty input must never advance to .saving")
    }

    func testSubmitTextCaptureRejectsWhitespaceOnlyInput() {
        let state = AppState()
        state.textCapture = .editing
        state.textCaptureInput = "   \n  "

        state.submitTextCapture()

        XCTAssertEqual(state.textCapture, .editing, "whitespace-only input must never advance to .saving")
    }

    func testSubmitTextCaptureIsANoOpWhileAlreadySaving() {
        let state = AppState()
        state.textCapture = .saving
        state.textCaptureInput = "buy milk"

        state.submitTextCapture()

        // Re-entrancy guard: a second Return/click landing while a save is already in flight must
        // not restart/duplicate the save.
        XCTAssertEqual(state.textCapture, .saving)
    }

    // MARK: - applyTextCaptureParseResult(_:session:) — the synchronous "parse landed" tail

    func testApplyParseResultIgnoresAStaleSession() {
        let state = AppState()
        state.textCapture = .saving
        state.textCaptureInput = "buy milk"

        // Any session token other than the untouched fresh-`AppState` value (0) is stale by
        // construction — mirrors a user hitting Esc (which bumps `textCaptureSession`) while an
        // earlier submit's parse is still in flight.
        state.applyTextCaptureParseResult([makeParsedTask()], session: 999)

        XCTAssertEqual(state.textCapture, .saving, "a stale parse result must be dropped, not applied on top of whatever the user did since")
        XCTAssertTrue(state.tasks.isEmpty, "a stale result must never materialize a task")
    }

    func testApplyParseResultIgnoresAResultThatArrivesAfterTheUserClosedThePopup() {
        let state = AppState()
        state.textCapture = .saving
        state.textCaptureInput = "buy milk"

        // Simulates Esc firing between the parse starting and finishing: `cancelTextCapture()`
        // would have moved `textCapture` off `.saving` (to `.closed`) even if it happened to bump
        // the session to something that — by coincidence — still matched.
        state.textCapture = .closed

        state.applyTextCaptureParseResult([makeParsedTask()], session: 0)

        XCTAssertEqual(state.textCapture, .closed, "a result must never resurrect a popup the user already closed")
        XCTAssertTrue(state.tasks.isEmpty)
    }

    func testApplyParseResultWithZeroDraftsFailsAndPreservesTheTypedText() {
        let state = AppState()
        state.textCapture = .saving
        state.textCaptureInput = "garbled input the parser couldn't use"

        state.applyTextCaptureParseResult([], session: 0)

        XCTAssertEqual(state.textCapture, .failed("Didn't catch that."))
        XCTAssertEqual(
            state.textCaptureInput, "garbled input the parser couldn't use",
            "a failed parse must never close the popup or discard what the user typed — they must be able to fix and retry"
        )
        XCTAssertTrue(state.tasks.isEmpty)
    }

    func testApplyParseResultOnSuccessSavesThroughConfirmSaveAndClearsTheField() {
        let state = AppState()
        state.textCapture = .saving
        state.textCaptureInput = "buy milk"

        state.applyTextCaptureParseResult([makeParsedTask(title: "Buy milk")], session: 0)

        // Proves the SAME save path (`confirmSave()`) actually ran — this is the no-store
        // fallback's synchronous in-memory commit, the same observable
        // `CaptureHotkeyAndTitleEditTests.testHandleHotkeySavesAPendingParsedDraft...` uses to
        // prove `confirmSave()` (not a parallel path) is what materialized the task.
        XCTAssertTrue(state.tasks.contains { $0.title == "Buy milk" })
        XCTAssertTrue(state.confirmDrafts.isEmpty, "confirmSave() must have cleared the drafts it just materialized")
        XCTAssertEqual(state.textCaptureInput, "", "success must clear the typed input")
        XCTAssertEqual(state.textCapture, .saved(titles: ["Buy milk"]))
    }

    /// Rewritten 2026-07-28. This used to assert that a two-task typed line saved both tasks
    /// immediately, which was correct while typed capture always skipped the confirm card. It no
    /// longer is: a compound utterance is exactly the case where the user needs to see what was
    /// understood — how many tasks came out, which ones depend on which, and whether any of them
    /// duplicates something already in the store. Typed capture now saves directly ONLY for the
    /// simple case (one task, no duplicate candidates, no conditions); anything else routes into
    /// the same confirm list the voice flow uses.
    func testCompoundTypedUtteranceRoutesToConfirmInsteadOfSavingDirectly() {
        let state = AppState()
        state.textCapture = .saving
        state.textCaptureInput = "buy milk and call mom"

        state.applyTextCaptureParseResult(
            [makeParsedTask(title: "Buy milk"), makeParsedTask(title: "Call mom")],
            session: 0
        )

        XCTAssertEqual(state.confirmDrafts.count, 2, "both parsed tasks must reach the confirm list")
        XCTAssertEqual(state.confirmDrafts.map(\.task.title), ["Buy milk", "Call mom"], "every title survives the handoff, in order")
        XCTAssertEqual(state.captureState, .parsed, "confirm review is what opens the popup")
        XCTAssertEqual(state.textCapture, .closed, "the text panel hands off and closes rather than reporting a save")
        XCTAssertFalse(state.tasks.contains { $0.title == "Buy milk" }, "nothing is persisted until the user confirms")
        XCTAssertFalse(state.tasks.contains { $0.title == "Call mom" }, "nothing is persisted until the user confirms")
    }

    /// The other half of the same rule: a single, unambiguous typed task still saves on Enter with
    /// no review step. "type → Add" was a deliberate property of typed capture and only compound or
    /// ambiguous input gives it up.
    func testSingleSimpleTypedTaskStillSavesDirectly() {
        let state = AppState()
        state.textCapture = .saving
        state.textCaptureInput = "buy milk"

        state.applyTextCaptureParseResult([makeParsedTask(title: "Buy milk")], session: 0)

        XCTAssertTrue(state.tasks.contains { $0.title == "Buy milk" })
        XCTAssertEqual(state.textCapture, .saved(titles: ["Buy milk"]), "the typed panel reports the save itself rather than handing off")
        // Deliberately NOT asserting `confirmDrafts.isEmpty`: the simple path assigns
        // `confirmDrafts` before calling `confirmSave()`, and clearing it is part of that method's
        // trailing 900ms auto-dismiss. `captureState` below is the property that actually
        // distinguishes "saved outright" from "handed off for review".
        XCTAssertNotEqual(state.captureState, .parsed, "the simple case must never open confirm review")
    }
}
