// Tests/ManualEditDraftTests.swift — XCTest coverage for T-edit-attrs (2026-07-29,
// specs/002-workflow-command-center/contracts/manual-edit-contract.md, Agent A's §1.1/§1.2/§1.4):
// the 4 confirm-card attribute overlays (priority/startTime/estimate/reminder) added alongside
// `editedDeadline`/`editedNotes`, plus `AppState.updateTask` — the one write path for editing an
// already-created task.
//
// Same "AppState()'s no-argument initializer degrades to the no-store fallback" convention every
// other test file in this folder documents (`ConfirmCardManualEditTests.swift`) — every case below
// is deliberately store-free, exactly what the no-store fallback exists for.
//
// UNVERIFIED (written entirely on Windows — no Xcode/simulator available here): not run against a
// real `VolarTests` bundle.
import XCTest
@testable import Volar

@MainActor
final class ManualEditDraftTests: XCTestCase {

    // MARK: - Fixtures

    private func makeParsedTask(
        title: String = "Submit report",
        priority: ParsedValue<Int>? = nil,
        startTime: ParsedValue<Date>? = nil,
        estimateMinutes: ParsedValue<Int>? = nil,
        reminderOverride: ParsedValue<ReminderPolicy>? = nil,
        transcript: String = "submit the report"
    ) -> ParsedTask {
        ParsedTask(
            title: title,
            notes: nil,
            deadline: nil,
            startTime: startTime,
            estimateMinutes: estimateMinutes,
            priority: priority,
            reminderOverride: reminderOverride,
            recurrence: nil,
            kind: .task,
            conditions: [],
            subtasks: [],
            followUpReview: false,
            sourceTranscript: transcript
        )
    }

    // MARK: - Case 1: each of the 4 setters -> `effective*` reflects the new value at confidence 1.0
    // (manual-edit-contract.md §1.1: "confidence: 1.0 is BẮT BUỘC, không phải làm đẹp" — the SAME
    // non-negotiable pin `effectiveDeadline` already documents).

    func testSetDraftPrioritySetsEffectivePriorityAtFullConfidence() {
        let draft = ConfirmDraft(task: makeParsedTask())
        let state = AppState()
        state.confirmDrafts = [draft]

        state.setDraftPriority(1, forDraft: draft.id)

        let updated = state.confirmDrafts.first
        XCTAssertEqual(updated?.editedPriority, 1)
        XCTAssertEqual(updated?.effectivePriority?.value, 1)
        XCTAssertEqual(updated?.effectivePriority?.confidence, 1.0)
    }

    func testSetDraftStartTimeSetsEffectiveStartTimeAtFullConfidence() {
        let draft = ConfirmDraft(task: makeParsedTask())
        let state = AppState()
        state.confirmDrafts = [draft]
        let newStart = Date().addingTimeInterval(1800)

        state.setDraftStartTime(newStart, forDraft: draft.id)

        let updated = state.confirmDrafts.first
        XCTAssertEqual(updated?.editedStartTime, newStart)
        XCTAssertEqual(updated?.effectiveStartTime?.value, newStart)
        XCTAssertEqual(updated?.effectiveStartTime?.confidence, 1.0)
    }

    func testSetDraftEstimateMinutesSetsEffectiveEstimateAtFullConfidence() {
        let draft = ConfirmDraft(task: makeParsedTask())
        let state = AppState()
        state.confirmDrafts = [draft]

        state.setDraftEstimateMinutes(45, forDraft: draft.id)

        let updated = state.confirmDrafts.first
        XCTAssertEqual(updated?.editedEstimateMinutes, 45)
        XCTAssertEqual(updated?.effectiveEstimateMinutes?.value, 45)
        XCTAssertEqual(updated?.effectiveEstimateMinutes?.confidence, 1.0)
    }

    func testSetDraftRemindPeriodSetsEffectiveReminderOverrideAtFullConfidenceFromDefaultPolicy() {
        // No parser-produced `reminderOverride` at all — `effectiveReminderOverride` must fall back
        // to `.defaultPolicy` as its base rather than crashing/returning nil (§1.1: "base =
        // task.reminderOverride?.value ?? .defaultPolicy").
        let draft = ConfirmDraft(task: makeParsedTask())
        let state = AppState()
        state.confirmDrafts = [draft]

        state.setDraftRemindPeriod(7200, forDraft: draft.id)

        let updated = state.confirmDrafts.first
        XCTAssertEqual(updated?.editedRemindPeriod, 7200)
        XCTAssertEqual(updated?.effectiveReminderOverride?.value.remindPeriod, 7200)
        XCTAssertEqual(updated?.effectiveReminderOverride?.confidence, 1.0)
        // The rest of the default policy's shape must survive untouched — only `remindPeriod` was
        // meant to change.
        XCTAssertEqual(updated?.effectiveReminderOverride?.value.offsets, ReminderPolicy.defaultPolicy.offsets)
        XCTAssertEqual(updated?.effectiveReminderOverride?.value.fractionsRemaining, ReminderPolicy.defaultPolicy.fractionsRemaining)
    }

    func testSetDraftRemindPeriodPreservesTheParsersOwnBasePolicyFieldsOtherThanRemindPeriod() {
        // This time the parser DID produce a `reminderOverride` — the base must be THAT policy, not
        // `.defaultPolicy`, and only `remindPeriod` on top of it changes.
        let parserPolicy = ReminderPolicy(offsets: [-3600, 0], repeatEvery: 600)
        var task = makeParsedTask()
        task.reminderOverride = ParsedValue(value: parserPolicy, confidence: 0.9)
        let draft = ConfirmDraft(task: task)
        let state = AppState()
        state.confirmDrafts = [draft]

        state.setDraftRemindPeriod(900, forDraft: draft.id)

        let effective = state.confirmDrafts.first?.effectiveReminderOverride
        XCTAssertEqual(effective?.value.remindPeriod, 900)
        XCTAssertEqual(effective?.value.offsets, [-3600, 0], "offsets from the parser's own policy must survive")
        XCTAssertEqual(effective?.value.repeatEvery, 600, "repeatEvery from the parser's own policy must survive")
        XCTAssertEqual(effective?.confidence, 1.0)
    }

    // MARK: - Case 2: an UNCERTAIN (<0.7) parser guess on a field the user then edits by hand must
    // still save the user's value WITHOUT requiring a separate accept tap — this is the whole reason
    // `effective*` pins confidence to 1.0 rather than inheriting the parser's own (§1.1's "bug
    // protection" case).

    func testManualPriorityEditOverridesAnUncertainParserGuessWithoutAnExplicitAccept() {
        var task = makeParsedTask(priority: ParsedValue(value: 3, confidence: 0.4)) // uncertain guess: Low
        task.title = "Uncertain priority task"
        let draft = ConfirmDraft(task: task)

        let state = AppState()
        state.confirmDrafts = [draft]
        state.captureState = .parsed

        // User never taps the uncertain chip to accept it — they just pick a different priority by
        // hand. `draft.accepted` stays empty on purpose (this is the whole point of the test).
        state.setDraftPriority(1, forDraft: draft.id) // High
        XCTAssertFalse(state.confirmDrafts.first?.accepted.contains(.priority) ?? true)

        state.confirmSave()

        let saved = state.tasks.first { $0.title == "Uncertain priority task" }
        XCTAssertEqual(saved?.priority, .high, "the user's manual edit must win over the uncertain 0.4-confidence parser guess, with no separate accept required")
    }

    // MARK: - Case 3: the parser returned NOTHING for a field (`task.priority == nil`) but the user
    // set one by hand — must still save (there is no parser value to be "more confident" than; the
    // edit is simply the only value that ever existed).

    func testManualEstimateEditPersistsWhenTheParserNeverProducedOneAtAll() {
        var task = makeParsedTask() // estimateMinutes: nil — parser said nothing about duration
        task.title = "No parser estimate task"
        XCTAssertNil(task.estimateMinutes)
        let draft = ConfirmDraft(task: task)

        let state = AppState()
        state.confirmDrafts = [draft]
        state.captureState = .parsed

        state.setDraftEstimateMinutes(30, forDraft: draft.id)
        state.confirmSave()

        let saved = state.tasks.first { $0.title == "No parser estimate task" }
        XCTAssertEqual(saved?.durationMinutes, 30, "a field the parser never touched at all must still persist the user's manual value")
    }

    // MARK: - Case 4: `dismissed.contains(kind)` beats an `edited*` value outright — constitution II,
    // dismiss always wins, no cửa sau (back door) even through the manual-edit overlay.

    func testDismissedPriorityChipIsNeverSavedEvenWithAManualEditSetOnTopOfIt() {
        var task = makeParsedTask(priority: ParsedValue(value: 3, confidence: 0.9)) // confident Low
        task.title = "Dismissed priority task"
        var draft = ConfirmDraft(task: task)
        draft.dismissed.insert(.priority)
        // The user (or a stray call) still sets an edit on top of the dismissed chip — this must be
        // completely inert; dismiss must win regardless of ordering.
        draft.editedPriority = 1 // High

        let state = AppState()
        state.confirmDrafts = [draft]
        state.captureState = .parsed

        // Sanity check the overlay itself is non-nil (proves the assertion below is really about
        // `dismissed` winning, not about the edit silently failing to apply).
        XCTAssertNotNil(state.confirmDrafts.first?.effectivePriority)

        state.confirmSave()

        let saved = state.tasks.first { $0.title == "Dismissed priority task" }
        XCTAssertNotEqual(saved?.priority, .high, "a dismissed chip must never save, even with an edited* value sitting on top of it")
        XCTAssertEqual(saved?.priority, .medium, "dismissed + no accepted value falls back to materialize's neutral default, not the parser's original Low guess either")
    }

    // MARK: - Case 5: `AppState.updateTask` (no-store) — all 7 fields land, and `details`/`notes`
    // stay in lockstep (manual-edit-contract.md §1.4).

    func testUpdateTaskNoStorePatchesAllSevenEditableFieldsAndKeepsDetailsAndNotesInSync() {
        let original = TaskItem(
            title: "Old title",
            details: "Old details",
            priority: .low,
            deadline: Date().addingTimeInterval(3600),
            startTime: nil,
            when: .now,
            durationMinutes: 15,
            notes: "Old details",
            reminderOverride: nil
        )
        let state = AppState()
        state.tasks = [original]

        let newStart = Date().addingTimeInterval(600)
        let newDeadline = Date().addingTimeInterval(7200)
        state.updateTask(
            original.id,
            title: "New title",
            details: "New details",
            priority: .high,
            startTime: newStart,
            deadline: newDeadline,
            durationMinutes: 90,
            remindPeriod: 1800
        )

        let updated = state.tasks.first { $0.id == original.id }
        XCTAssertEqual(updated?.title, "New title")
        XCTAssertEqual(updated?.details, "New details")
        XCTAssertEqual(updated?.notes, "New details", "details and notes must be written the SAME value, per §1.4")
        XCTAssertEqual(updated?.priority, .high)
        XCTAssertEqual(updated?.startTime, newStart)
        XCTAssertEqual(updated?.deadline, newDeadline)
        XCTAssertEqual(updated?.durationMinutes, 90)
        XCTAssertEqual(updated?.reminderOverride?.remindPeriod, 1800)
    }

    func testUpdateTaskNoStoreClearingDescriptionCollapsesNotesToNilNotEmptyString() {
        let original = TaskItem(
            title: "Task with note",
            details: "Has a note",
            priority: .medium,
            when: .now,
            notes: "Has a note"
        )
        let state = AppState()
        state.tasks = [original]

        state.updateTask(
            original.id,
            title: "Task with note",
            details: "",
            priority: .medium,
            startTime: nil,
            deadline: nil,
            durationMinutes: nil,
            remindPeriod: nil
        )

        let updated = state.tasks.first { $0.id == original.id }
        XCTAssertEqual(updated?.details, "", "details itself stays whatever the field literally contains, even empty")
        XCTAssertNil(updated?.notes, "an emptied description must collapse notes to nil, not a phantom empty string")
    }

    func testUpdateTaskNoStoreClearingRemindPeriodPreservesRestOfAnExistingOverride() {
        let existingOverride = ReminderPolicy(offsets: [-1800, 0], repeatEvery: nil, fractionsRemaining: [0.5], remindPeriod: 3600)
        let original = TaskItem(
            title: "Task with cadence",
            details: "",
            priority: .medium,
            when: .now,
            reminderOverride: existingOverride
        )
        let state = AppState()
        state.tasks = [original]

        // remindPeriod: nil must clear ONLY the cadence, not the whole override.
        state.updateTask(
            original.id,
            title: "Task with cadence",
            details: "",
            priority: .medium,
            startTime: nil,
            deadline: nil,
            durationMinutes: nil,
            remindPeriod: nil
        )

        let updated = state.tasks.first { $0.id == original.id }
        XCTAssertNil(updated?.reminderOverride?.remindPeriod, "clearing the cadence must null out remindPeriod specifically")
        XCTAssertEqual(updated?.reminderOverride?.offsets, [-1800, 0], "the rest of the pre-existing override must survive untouched")
        XCTAssertEqual(updated?.reminderOverride?.fractionsRemaining, [0.5])
    }

    func testUpdateTaskNoStoreForAnUnknownIDIsANoOp() {
        let original = TaskItem(title: "Untouched", details: "", priority: .medium, when: .now)
        let state = AppState()
        state.tasks = [original]

        state.updateTask(
            UUID(),
            title: "Should not apply",
            details: "Should not apply",
            priority: .high,
            startTime: nil,
            deadline: nil,
            durationMinutes: nil,
            remindPeriod: nil
        )

        XCTAssertEqual(state.tasks.count, 1)
        XCTAssertEqual(state.tasks.first?.title, "Untouched")
    }
}
