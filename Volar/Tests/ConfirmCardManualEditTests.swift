// Tests/ConfirmCardManualEditTests.swift — XCTest coverage for the confirm card's manual
// in-place edit controls (2026-07-28, anh Khôi: "khi user ra task, có thể update time và
// description của task" — a manual fix on THIS confirm card right after capture, explicitly NOT
// the separate "speak to edit an already-saved task" feature, which is a different, later piece
// of work):
//   (1) `AppState.setDraftDeadline(_:forDraft:)` (`PopoverView.DeadlineControl`'s `DatePicker`) —
//       reuses the SAME `editedDeadline`/`effectiveDeadline` infrastructure the overdue-nudge
//       feature (`OverdueDeadlineSuggestionTests.swift`) already added, so most of the save-path
//       correctness is already covered there; this file focuses on the NEW entry point and the
//       nil-deadline-> real-deadline path that infrastructure didn't exercise yet.
//   (2) `ConfirmDraft.editedNotes`/`effectiveNotes` + `AppState.updateDraftNotes(_:forDraft:)` —
//       same "overlay, never mutate `ParsedTask`" shape as `editedTitle`/`effectiveTitle`
//       (`CaptureHotkeyAndTitleEditTests.swift`), with the one deliberate difference that notes
//       are NOT newline-flattened.
//
// Deliberately PURE where possible, same split every other test file in this folder documents:
// `AppState()`'s no-argument initializer degrades to the no-store fallback, which is exactly what
// every test below wants.
//
// UNVERIFIED (written entirely on Windows — no Xcode/simulator available here): not run against a
// real `VolarTests` bundle.
import XCTest
@testable import Volar

@MainActor
final class ConfirmCardManualEditTests: XCTestCase {

    // MARK: - Fixtures

    private func makeParsedTask(
        title: String = "Submit report",
        notes: String? = nil,
        transcript: String = "submit the report"
    ) -> ParsedTask {
        ParsedTask(
            title: title,
            notes: notes,
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

    // MARK: - AppState.setDraftDeadline — editing an EXISTING deadline

    func testSetDraftDeadlineSetsEditedDeadlineWithoutMutatingParsedTask() {
        let originalDeadline = Date().addingTimeInterval(3600)
        let newDeadline = Date().addingTimeInterval(7200)

        var task = makeParsedTask()
        task.deadline = ParsedValue(value: originalDeadline, confidence: 0.9)
        let draft = ConfirmDraft(task: task)

        let state = AppState()
        state.confirmDrafts = [draft]

        state.setDraftDeadline(newDeadline, forDraft: draft.id)

        let updated = state.confirmDrafts.first
        XCTAssertEqual(updated?.editedDeadline, newDeadline)
        XCTAssertEqual(updated?.effectiveDeadline?.value, newDeadline)
        XCTAssertEqual(updated?.effectiveDeadline?.confidence, 1.0, "an explicit manual edit is full confidence, same reasoning as the overdue-suggestion apply path")
        XCTAssertEqual(updated?.task.deadline?.value, originalDeadline, "ParsedTask must never be mutated in place")
    }

    func testSetDraftDeadlineForAnUnknownDraftIDIsANoOp() {
        let draft = ConfirmDraft(task: makeParsedTask())
        let state = AppState()
        state.confirmDrafts = [draft]

        state.setDraftDeadline(Date(), forDraft: UUID())

        XCTAssertNil(state.confirmDrafts.first?.editedDeadline)
    }

    // MARK: - AppState.setDraftDeadline — the nil-deadline -> real-deadline path
    // (self-review "correctness": `effectiveDeadline`'s `if let editedDeadline` branch doesn't
    // care whether `task.deadline` was ever present, but this proves it end-to-end through the
    // actual save path rather than just trusting that by inspection.)

    func testSetDraftDeadlineOnADraftWithNoParsedDeadlineStillPersistsOnSave() {
        let task = makeParsedTask(title: "Water the plants")
        XCTAssertNil(task.deadline, "test setup assumption: this task has no deadline at all")
        let draft = ConfirmDraft(task: task)

        let state = AppState()
        state.confirmDrafts = [draft]
        state.captureState = .parsed

        let newDeadline = Date().addingTimeInterval(3600)
        state.setDraftDeadline(newDeadline, forDraft: draft.id)

        // Sanity-check the draft layer before saving, same as the mutation-only tests above.
        XCTAssertEqual(state.confirmDrafts.first?.effectiveDeadline?.value, newDeadline)

        state.confirmSave()

        let saved = state.tasks.first { $0.title == "Water the plants" }
        XCTAssertNotNil(saved)
        XCTAssertEqual(saved?.deadline, newDeadline, "a deadline set by hand on a draft that never had one must still reach the persisted TaskItem")
    }

    // MARK: - ConfirmDraft.effectiveNotes — overlay, never mutate ParsedTask

    func testUpdateDraftNotesSetsEffectiveNotesWithoutMutatingParsedTask() {
        var task = makeParsedTask()
        task.notes = "Original parsed note"
        let draft = ConfirmDraft(task: task)

        let state = AppState()
        state.confirmDrafts = [draft]

        state.updateDraftNotes("Corrected note text", forDraft: draft.id)

        let updated = state.confirmDrafts.first
        XCTAssertEqual(updated?.editedNotes, "Corrected note text")
        XCTAssertEqual(updated?.effectiveNotes, "Corrected note text")
        XCTAssertEqual(updated?.task.notes, "Original parsed note", "ParsedTask must never be mutated in place")
    }

    func testUpdateDraftNotesFallsBackToTheOriginalNoteWhenTheEditIsBlank() {
        var task = makeParsedTask()
        task.notes = "Original parsed note"
        let draft = ConfirmDraft(task: task)

        let state = AppState()
        state.confirmDrafts = [draft]

        state.updateDraftNotes("   \n   ", forDraft: draft.id)

        XCTAssertEqual(state.confirmDrafts.first?.effectiveNotes, "Original parsed note", "a whitespace-only edit must silently fall back, never blank the note, same convention as effectiveTitle")
    }

    func testEffectiveNotesFallsBackToNilWhenThereWasNeverAnyNote() {
        let draft = ConfirmDraft(task: makeParsedTask()) // notes: nil by default
        XCTAssertNil(draft.effectiveNotes)
    }

    func testUpdateDraftNotesForAnUnknownDraftIDIsANoOp() {
        let draft = ConfirmDraft(task: makeParsedTask())
        let state = AppState()
        state.confirmDrafts = [draft]

        state.updateDraftNotes("should not apply", forDraft: UUID())

        XCTAssertNil(state.confirmDrafts.first?.editedNotes)
    }

    // MARK: - ConfirmDraft.effectiveNotes — multi-line, UNLIKE effectiveTitle

    func testEffectiveNotesPreservesNewlinesUnlikeEffectiveTitle() {
        let draft = ConfirmDraft(task: makeParsedTask())
        let state = AppState()
        state.confirmDrafts = [draft]

        state.updateDraftNotes("Buy milk\nBuy eggs\nBuy bread", forDraft: draft.id)

        XCTAssertEqual(
            state.confirmDrafts.first?.effectiveNotes,
            "Buy milk\nBuy eggs\nBuy bread",
            "notes are genuinely multi-line free text — unlike effectiveTitle, newlines must NOT be flattened into spaces"
        )
    }

    // MARK: - AppState.confirmSave() — edited notes must actually persist

    func testConfirmSavePersistsTheEditedNotes() {
        var task = makeParsedTask(title: "Plan offsite")
        task.notes = "Original parsed note"
        let draft = ConfirmDraft(task: task)

        let state = AppState()
        state.confirmDrafts = [draft]
        state.captureState = .parsed

        state.updateDraftNotes("Book the venue by Friday", forDraft: draft.id)
        state.confirmSave()

        let saved = state.tasks.first { $0.title == "Plan offsite" }
        XCTAssertNotNil(saved)
        XCTAssertEqual(saved?.notes, "Book the venue by Friday")
        XCTAssertNotEqual(saved?.notes, "Original parsed note")
    }

    func testConfirmSaveMaterializesTheOriginalNoteWhenNeverEdited() {
        var task = makeParsedTask(title: "Plan offsite")
        task.notes = "Original parsed note"
        let draft = ConfirmDraft(task: task)

        let state = AppState()
        state.confirmDrafts = [draft]
        state.captureState = .parsed

        state.confirmSave()

        let saved = state.tasks.first { $0.title == "Plan offsite" }
        XCTAssertEqual(saved?.notes, "Original parsed note")
    }

    // MARK: - AppState.mergeNotesAppending — pure helper (T-notes-merge, anh Khôi chốt 2026-07-29)
    //
    // Notes used to be deliberately excluded from `mergeTransform`'s "use existing" merge (a
    // scalar-attribute overwrite would have silently discarded whatever the user just typed on
    // the confirm card, with no warning) — but that exclusion predates notes being editable on
    // the card at all. Now that they are, notes merge too, by APPENDING rather than overwriting.

    func testMergeNotesAppendingAssignsDirectlyWhenExistingHasNoNotes() {
        XCTAssertEqual(
            AppState.mergeNotesAppending(existing: nil, incoming: "Bring the charger"),
            "Bring the charger"
        )
    }

    func testMergeNotesAppendingTreatsWhitespaceOnlyExistingAsNoNotes() {
        XCTAssertEqual(
            AppState.mergeNotesAppending(existing: "   \n  ", incoming: "Bring the charger"),
            "Bring the charger"
        )
    }

    func testMergeNotesAppendingConcatenatesOldBeforeNewSeparatedByNewline() {
        XCTAssertEqual(
            AppState.mergeNotesAppending(existing: "Buy milk", incoming: "Buy eggs"),
            "Buy milk\nBuy eggs",
            "existing content must come FIRST, newly-typed content SECOND"
        )
    }

    func testMergeNotesAppendingReturnsNilWhenIncomingDuplicatesExistingVerbatim() {
        XCTAssertNil(
            AppState.mergeNotesAppending(existing: "Bring the charger", incoming: "Bring the charger"),
            "an exact re-read must not duplicate the note"
        )
    }

    func testMergeNotesAppendingReturnsNilWhenIncomingDuplicatesAfterTrimming() {
        XCTAssertNil(
            AppState.mergeNotesAppending(existing: "Bring the charger", incoming: "  Bring the charger  \n"),
            "the duplicate check must compare TRIMMED text, not raw text"
        )
    }

    func testMergeNotesAppendingReturnsNilWhenIncomingIsAlreadyContainedInExisting() {
        XCTAssertNil(
            AppState.mergeNotesAppending(existing: "Buy milk\nBuy eggs", incoming: "Buy eggs"),
            "re-reading back a fragment already present in the longer existing note must not duplicate it either"
        )
    }

    func testMergeNotesAppendingReturnsNilWhenIncomingIsNil() {
        XCTAssertNil(AppState.mergeNotesAppending(existing: "Bring the charger", incoming: nil))
    }

    func testMergeNotesAppendingReturnsNilWhenIncomingIsWhitespaceOnly() {
        XCTAssertNil(AppState.mergeNotesAppending(existing: "Bring the charger", incoming: "   \n  "))
    }

    func testMergeNotesAppendingReturnsNilWhenBothAreNil() {
        XCTAssertNil(AppState.mergeNotesAppending(existing: nil, incoming: nil))
    }

    // MARK: - AppState.confirmSave() with `.useExisting` — end-to-end notes merge
    //
    // Regression coverage for the exact bug anh Khôi reported: confirm card lets you type notes
    // AND pick "use existing" (merge into an already-saved task) — before this fix, `mergeTransform`
    // never touched `notes`/`details` at all, so the freshly-typed note silently vanished on Save.

    func testConfirmSaveWithUseExistingAppendsNotesIntoTheExistingTask() {
        let existing = TaskItem(title: "Submit report", details: "Old note", priority: .medium, when: .now, notes: "Old note")

        let task = makeParsedTask(title: "Submit report")
        var draft = ConfirmDraft(task: task)
        draft.duplicateResolution = .useExisting(existing.id)

        let state = AppState()
        state.tasks = [existing]
        state.confirmDrafts = [draft]
        state.captureState = .parsed

        state.updateDraftNotes("Attach the Q3 numbers", forDraft: draft.id)
        state.confirmSave()

        XCTAssertEqual(state.tasks.count, 1, "a `.useExisting` merge must not create a second task")
        let merged = state.tasks.first { $0.id == existing.id }
        XCTAssertEqual(merged?.notes, "Old note\nAttach the Q3 numbers")
        XCTAssertEqual(merged?.details, "Old note\nAttach the Q3 numbers", "`details` is what TaskDetailView actually renders — it must stay in lockstep with `notes`")
    }

    func testConfirmSaveWithUseExistingAndNoDraftNotesLeavesExistingNotesUntouched() {
        let existing = TaskItem(title: "Submit report", details: "Old note", priority: .medium, when: .now, notes: "Old note")

        let task = makeParsedTask(title: "Submit report") // notes: nil — never touched on this draft
        var draft = ConfirmDraft(task: task)
        draft.duplicateResolution = .useExisting(existing.id)

        let state = AppState()
        state.tasks = [existing]
        state.confirmDrafts = [draft]
        state.captureState = .parsed

        state.confirmSave()

        let merged = state.tasks.first { $0.id == existing.id }
        XCTAssertEqual(merged?.notes, "Old note", "the most common path — no notes typed on the draft — must never touch the existing task's notes")
        XCTAssertEqual(merged?.details, "Old note")
    }

    func testConfirmSaveWithUseExistingNeverChangesTitleOrKind() {
        let existing = TaskItem(title: "Submit report", details: "", priority: .medium, when: .now, kind: .task)

        let task = makeParsedTask(title: "Something totally different")
        var draft = ConfirmDraft(task: task)
        draft.duplicateResolution = .useExisting(existing.id)

        let state = AppState()
        state.tasks = [existing]
        state.confirmDrafts = [draft]
        state.captureState = .parsed

        state.updateDraftNotes("A new note", forDraft: draft.id)
        state.confirmSave()

        let merged = state.tasks.first { $0.id == existing.id }
        XCTAssertEqual(merged?.title, "Submit report", "merging must never rename the existing task (anh Khôi: title merge is a different, unrequested feature)")
        XCTAssertEqual(merged?.kind, .task)
    }
}
