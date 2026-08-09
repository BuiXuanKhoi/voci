// Tests/OverdueDeadlineSuggestionTests.swift — XCTest coverage for the confirm-card overdue
// nudge (T-overdue, 2026-07-28): when the parser hands back a deadline already in the past at
// capture time (e.g. "submit the report this morning" said at 3pm), the confirm card offers a
// one-tap "Move to tomorrow, same time" suggestion — never auto-applied (constitution II).
//
// Covers:
//   (1) `OverdueSuggestion.makeIfOverdue(deadline:now:calendar:)` — the pure, client-side,
//       deterministic detection/suggestion logic, unit-tested directly (no `AppState`/
//       `ConfirmDraft` needed) per this task's own test guidance. Includes a real DST-crossing
//       case proving the +1 is calendar-day arithmetic, not a raw 86,400-second add.
//   (2) `AppState.applyOverdueSuggestion(forDraft:)` — writes `ConfirmDraft.editedDeadline`
//       without ever mutating the underlying (contract-owned, "never mutated in place")
//       `ParsedTask`, mirroring `CaptureHotkeyAndTitleEditTests`'s `editedTitle` coverage.
//   (3) `AppState.confirmSave()` — the applied suggestion actually reaches the persisted
//       `TaskItem.deadline`, the single easiest place for this feature to silently do nothing
//       (self-review "save path": every deadline-reading call site must go through
//       `ConfirmDraft.effectiveDeadline`, never `task.deadline` directly).
//
// Deliberately PURE where possible, same split `CaptureHotkeyAndTitleEditTests.swift`/
// `TourFlowTests.swift` already document: `AppState()`'s no-argument initializer degrades to the
// no-store fallback, which is exactly what every test below wants.
//
// UNVERIFIED (written entirely on Windows — no Xcode/simulator available here): not run against a
// real `VolarTests` bundle. `Calendar(identifier: .gregorian)` + explicit `TimeZone(identifier:)`
// are used throughout instead of `.current`/`Date()` wherever a test's outcome depends on exact
// day/hour arithmetic, so results should be deterministic regardless of the machine's local
// timezone — but this has not been confirmed by an actual test run.
import XCTest
@testable import Volar

@MainActor
final class OverdueDeadlineSuggestionTests: XCTestCase {

    // MARK: - Fixtures

    private func makeParsedTask(title: String = "Submit report", transcript: String = "submit the report this morning") -> ParsedTask {
        ParsedTask(
            title: title,
            notes: nil,
            deadline: nil,
            startTime: nil,
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

    /// Fixed UTC calendar for tests where the exact calendar-day math matters but DST is not the
    /// point being tested — keeps the loop/cap tests deterministic regardless of the machine's
    /// local timezone.
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    // MARK: - OverdueSuggestion.makeIfOverdue — no deadline / future deadline

    func testMakeIfOverdueReturnsNilWhenThereIsNoDeadline() {
        XCTAssertNil(OverdueSuggestion.makeIfOverdue(deadline: nil, now: Date()))
    }

    func testMakeIfOverdueReturnsNilForAFutureDeadline() {
        let now = Date()
        let future = now.addingTimeInterval(3600)
        XCTAssertNil(OverdueSuggestion.makeIfOverdue(deadline: future, now: now), "a deadline that hasn't happened yet needs no nudge")
    }

    func testMakeIfOverdueReturnsNilWhenDeadlineExactlyEqualsNow() {
        let now = Date()
        // The gate is strictly `deadline < now`, not `<=` — a deadline landing exactly on "now"
        // has not yet passed.
        XCTAssertNil(OverdueSuggestion.makeIfOverdue(deadline: now, now: now))
    }

    // MARK: - OverdueSuggestion.makeIfOverdue — simple one-day-past case

    func testMakeIfOverdueAddsOneCalendarDayForADeadlineAFewHoursInThePast() {
        let calendar = utcCalendar
        let deadline = calendar.date(from: DateComponents(year: 2026, month: 7, day: 28, hour: 12, minute: 0))!
        let now = calendar.date(from: DateComponents(year: 2026, month: 7, day: 28, hour: 15, minute: 0))!

        let suggestion = OverdueSuggestion.makeIfOverdue(deadline: deadline, now: now, calendar: calendar)

        XCTAssertEqual(suggestion?.originalDeadline, deadline)
        let expected = calendar.date(from: DateComponents(year: 2026, month: 7, day: 29, hour: 12, minute: 0))!
        XCTAssertEqual(suggestion?.suggestedDeadline, expected, "the common case is exactly +1 calendar day, same wall-clock time")
    }

    // MARK: - OverdueSuggestion.makeIfOverdue — DST correctness (self-review "correctness")

    /// Proves the +1 is `Calendar.date(byAdding: .day, value: 1, to:)`, NOT a raw 86,400-second
    /// add. 2026-03-08 is the US spring-forward date (clocks jump 2am -> 3am, so that calendar
    /// day is only 23 hours long in America/New_York) — a naive seconds-based add from 9am the
    /// day before would land at 10am local, an hour later than intended.
    func testMakeIfOverdueAddsOneCalendarDayPreservingWallClockAcrossDSTSpringForward() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!

        let deadline = calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 9, minute: 0))!
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 15, minute: 0))!

        let suggestion = OverdueSuggestion.makeIfOverdue(deadline: deadline, now: now, calendar: calendar)

        XCTAssertNotNil(suggestion)
        guard let suggested = suggestion?.suggestedDeadline else { return }
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: suggested)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 3)
        XCTAssertEqual(comps.day, 8)
        XCTAssertEqual(comps.hour, 9, "wall-clock hour must be preserved across the spring-forward boundary")
        XCTAssertEqual(comps.minute, 0)
        // A raw 24h/86,400s add would land an hour later (10am local) because March 8 loses an
        // hour to the DST transition — assert the actual result is NOT that naive answer.
        XCTAssertNotEqual(suggested, deadline.addingTimeInterval(86_400), "must not be a raw 86,400-second add — that lands an hour off across this DST boundary")
    }

    // MARK: - OverdueSuggestion.makeIfOverdue — multi-day-old deadline (loop test)

    /// A deadline several days in the past (a stale transcript re-parsed days later, or "last
    /// Monday" said today) means +1 day alone is still in the past — this proves the walk-forward
    /// loop keeps going until the suggestion actually clears `now`, landing well within the 366
    /// iteration cap.
    func testMakeIfOverdueForAMultiDayOldDeadlineStillLandsInTheFuture() {
        let calendar = utcCalendar
        // Deadline is 5 days and 1 hour before `now` — the naive +1 day alone (4 days short of
        // `now`) would still be in the past, so the loop must walk forward 6 days total before
        // the candidate reaches/clears `now`.
        let now = calendar.date(from: DateComponents(year: 2026, month: 7, day: 28, hour: 15, minute: 0))!
        let deadline = calendar.date(from: DateComponents(year: 2026, month: 7, day: 23, hour: 14, minute: 0))!

        let suggestion = OverdueSuggestion.makeIfOverdue(deadline: deadline, now: now, calendar: calendar)

        XCTAssertNotNil(suggestion)
        guard let suggested = suggestion?.suggestedDeadline else { return }
        XCTAssertGreaterThanOrEqual(suggested, now, "the suggestion must actually land in the present/future, not just +1 day from a stale deadline")
        let expected = calendar.date(byAdding: .day, value: 6, to: deadline)!
        XCTAssertEqual(suggested, expected)
    }

    // MARK: - OverdueSuggestion.makeIfOverdue — hard cap (self-review "client-exploit")

    /// A deadline far enough in the past (well over a year) must never spin the walk-forward loop
    /// forever — the 366-iteration cap returns `nil` (no sane suggestion) rather than looping.
    func testMakeIfOverdueReturnsNilWhenTheGapExceedsTheCap() {
        let calendar = utcCalendar
        let now = calendar.date(from: DateComponents(year: 2026, month: 7, day: 28, hour: 12, minute: 0))!
        let deadline = calendar.date(byAdding: .day, value: -400, to: now)!

        let suggestion = OverdueSuggestion.makeIfOverdue(deadline: deadline, now: now, calendar: calendar)

        XCTAssertNil(suggestion, "366 daily increments from 400 days ago still lands short of `now` — must degrade to no-suggestion, never loop forever")
    }

    // MARK: - AppState.applyOverdueSuggestion — the "never mutate ParsedTask in place" contract

    func testApplyOverdueSuggestionSetsEditedDeadlineWithoutTouchingTheParsedTask() {
        let now = Date()
        let pastDeadline = now.addingTimeInterval(-3600)
        let suggestedDeadline = now.addingTimeInterval(23 * 3600)

        var task = makeParsedTask()
        task.deadline = ParsedValue(value: pastDeadline, confidence: 0.9)
        var draft = ConfirmDraft(task: task)
        draft.overdueSuggestion = OverdueSuggestion(originalDeadline: pastDeadline, suggestedDeadline: suggestedDeadline)

        let state = AppState()
        state.confirmDrafts = [draft]

        state.applyOverdueSuggestion(forDraft: draft.id)

        let updated = state.confirmDrafts.first
        XCTAssertEqual(updated?.editedDeadline, suggestedDeadline)
        XCTAssertNil(updated?.overdueSuggestion, "the advisory clears itself once the user has acted on it")
        XCTAssertEqual(updated?.task.deadline?.value, pastDeadline, "ParsedTask must never be mutated in place")
        XCTAssertNil(draft.editedDeadline, "the original local `draft` value must be untouched — struct semantics")
    }

    func testApplyOverdueSuggestionMakesEffectiveDeadlineReflectTheEditAtFullConfidence() {
        let now = Date()
        let pastDeadline = now.addingTimeInterval(-3600)
        let suggestedDeadline = now.addingTimeInterval(23 * 3600)

        var task = makeParsedTask()
        // Deliberately uncertain (<0.7) on the ORIGINAL parse, to prove the edit's confidence is
        // pinned to 1.0 regardless of what the parser originally reported.
        task.deadline = ParsedValue(value: pastDeadline, confidence: 0.4)
        var draft = ConfirmDraft(task: task)
        draft.overdueSuggestion = OverdueSuggestion(originalDeadline: pastDeadline, suggestedDeadline: suggestedDeadline)

        let state = AppState()
        state.confirmDrafts = [draft]

        state.applyOverdueSuggestion(forDraft: draft.id)

        let effective = state.confirmDrafts.first?.effectiveDeadline
        XCTAssertEqual(effective?.value, suggestedDeadline)
        XCTAssertEqual(effective?.confidence, 1.0, "an explicit one-tap user action is full confidence — must never require a second explicit accept via the deadline chip's uncertain gate")
        XCTAssertFalse(effective?.isUncertain ?? true)
    }

    func testApplyOverdueSuggestionForAnUnknownDraftIDIsANoOp() {
        var task = makeParsedTask()
        task.deadline = ParsedValue(value: Date().addingTimeInterval(-3600), confidence: 0.9)
        var draft = ConfirmDraft(task: task)
        draft.overdueSuggestion = OverdueSuggestion(originalDeadline: Date(), suggestedDeadline: Date())

        let state = AppState()
        state.confirmDrafts = [draft]

        state.applyOverdueSuggestion(forDraft: UUID())

        XCTAssertNil(state.confirmDrafts.first?.editedDeadline)
        XCTAssertNotNil(state.confirmDrafts.first?.overdueSuggestion)
    }

    // MARK: - AppState.dismissOverdueSuggestion — dismiss never touches the deadline

    func testDismissOverdueSuggestionSetsTheFlagWithoutChangingTheDeadline() {
        var task = makeParsedTask()
        let pastDeadline = Date().addingTimeInterval(-3600)
        task.deadline = ParsedValue(value: pastDeadline, confidence: 0.9)
        var draft = ConfirmDraft(task: task)
        draft.overdueSuggestion = OverdueSuggestion(originalDeadline: pastDeadline, suggestedDeadline: pastDeadline.addingTimeInterval(86_400))

        let state = AppState()
        state.confirmDrafts = [draft]

        state.dismissOverdueSuggestion(forDraft: draft.id)

        let updated = state.confirmDrafts.first
        XCTAssertEqual(updated?.overdueDismissed, true)
        XCTAssertNotNil(updated?.overdueSuggestion, "dismissing the nudge must not clear the suggestion data itself, only the UI flag")
        XCTAssertNil(updated?.editedDeadline)
        XCTAssertEqual(updated?.task.deadline?.value, pastDeadline)
    }

    // MARK: - AppState.confirmSave() — the applied suggestion must actually persist (self-review "save path")

    func testConfirmSavePersistsTheAppliedOverdueSuggestionNotTheOriginalPastDeadline() {
        let now = Date()
        let pastDeadline = now.addingTimeInterval(-3600)
        let suggestedDeadline = now.addingTimeInterval(23 * 3600)

        var task = makeParsedTask(title: "Submit report")
        task.deadline = ParsedValue(value: pastDeadline, confidence: 0.9)
        var draft = ConfirmDraft(task: task)
        draft.overdueSuggestion = OverdueSuggestion(originalDeadline: pastDeadline, suggestedDeadline: suggestedDeadline)

        let state = AppState()
        state.confirmDrafts = [draft]
        state.captureState = .parsed

        state.applyOverdueSuggestion(forDraft: draft.id)
        state.confirmSave()

        let saved = state.tasks.first { $0.title == "Submit report" }
        XCTAssertNotNil(saved, "the task must still save")
        XCTAssertEqual(saved?.deadline, suggestedDeadline, "confirmSave must materialize the EDITED deadline, not the original overdue one — the whole point of the 'Move to tomorrow' action")
        XCTAssertNotEqual(saved?.deadline, pastDeadline)
    }

    func testConfirmSaveMaterializesTheOriginalDeadlineWhenTheSuggestionWasNeverApplied() {
        let now = Date()
        let pastDeadline = now.addingTimeInterval(-3600)

        var task = makeParsedTask(title: "Submit report")
        task.deadline = ParsedValue(value: pastDeadline, confidence: 0.9)
        var draft = ConfirmDraft(task: task)
        draft.overdueSuggestion = OverdueSuggestion(originalDeadline: pastDeadline, suggestedDeadline: pastDeadline.addingTimeInterval(86_400))

        let state = AppState()
        state.confirmDrafts = [draft]
        state.captureState = .parsed

        // Note: `applyOverdueSuggestion` is deliberately NOT called here — Save must still work,
        // unmodified, for a user who ignores/dismisses the nudge (constitution II: suggest, never
        // auto-act).
        state.confirmSave()

        let saved = state.tasks.first { $0.title == "Submit report" }
        XCTAssertEqual(saved?.deadline, pastDeadline)
    }
}
