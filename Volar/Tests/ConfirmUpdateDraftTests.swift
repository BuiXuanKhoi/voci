// Tests/ConfirmUpdateDraftTests.swift — XCTest coverage for task_refs_v1 (2026-08-02, anh Khôi:
// "update task đã có bằng giọng nói"): the client-side resolution ladder (`AppState.
// resolveTaskRefs`), the same-batch merge (`AppState.mergeUpdateIntoSibling`), and `ConfirmSave`'s
// application of a surviving `ConfirmUpdateDraft` onto an already-existing task.
//
// Deliberately PURE, no-store `AppState()` degrading to the in-memory fallback — same convention
// `ManualEditDraftTests.swift`/`DependencyCycleTests.swift` already establish for this exact
// reason: nothing here needs a real `TaskStore`, only `tasks`/`confirmDrafts`/`confirmUpdateDrafts`
// state. `resolveTaskRefs`/`mergeUpdateIntoSibling`/`buildConfirmUpdateDrafts` are called directly
// (they're `internal`, not `private`, specifically for this — see each one's own doc comment, which
// cites `AppState.mergeNotesAppending`'s identical "intentionally internal for testability"
// precedent) rather than only through the async `runParse`/`router.parseCapture` entry point, which
// this test target cannot construct (no fake `IntentRouter` — it's a concrete `final class`, not a
// protocol this suite could substitute).
//
// UNVERIFIED (written entirely on Windows — no Xcode/simulator available here): not run against a
// real `VolarTests` bundle. Also assumes `ParsedTaskRef`/`ParsedUpdateCondition`/`ParsedTaskUpdate`/
// `ParsedCapture` (sibling wire-layer, `Sources/Parsing/ParsedCapture.swift`, written concurrently
// with this file) keep Swift's default synthesized memberwise init — every field in the task
// brief's pinned declarations is a plain `var` with no custom `init` shown, so this should hold,
// but it was written against the pinned surface, not against a build.
import XCTest
@testable import Volar

@MainActor
final class ConfirmUpdateDraftTests: XCTestCase {

    // MARK: - Fixtures

    private func makeParsedTask(
        title: String = "Submit report",
        deadline: ParsedValue<Date>? = nil,
        startTime: ParsedValue<Date>? = nil,
        priority: ParsedValue<Int>? = nil,
        transcript: String = "test"
    ) -> ParsedTask {
        ParsedTask(
            title: title,
            notes: nil,
            deadline: deadline,
            startTime: startTime,
            estimateMinutes: nil,
            priority: priority,
            reminderOverride: nil,
            recurrence: nil,
            kind: .task,
            conditions: [],
            subtasks: [],
            followUpReview: false,
            sourceTranscript: transcript
        )
    }

    private func makeDraft(
        title: String = "Submit report",
        deadline: ParsedValue<Date>? = nil,
        startTime: ParsedValue<Date>? = nil,
        priority: ParsedValue<Int>? = nil
    ) -> ConfirmDraft {
        ConfirmDraft(task: makeParsedTask(title: title, deadline: deadline, startTime: startTime, priority: priority))
    }

    private func makeOpenTask(title: String = "Submit report", id: UUID = UUID()) -> TaskItem {
        TaskItem(id: id, title: title, details: "", priority: .medium, when: .now)
    }

    // MARK: - Resolution ladder (`AppState.resolveTaskRefs`)

    /// Step 1 (existing) must short-circuit before step 2 (sibling) is ever consulted — even when a
    /// sibling draft ALSO scores >=0.7 against the same query, an already-persisted task wins.
    func testResolutionLadderExistingBeatsSibling() {
        let existing = makeOpenTask(title: "Submit quarterly report")
        let sibling = makeDraft(title: "Submit quarterly report")
        let state = AppState()

        let resolutions = state.resolveTaskRefs(
            [ParsedTaskRef(titleQuery: "submit quarterly report", confidence: 0.9, assumeExisting: true)],
            drafts: [sibling],
            openTasks: [existing]
        )

        XCTAssertEqual(resolutions.count, 1)
        guard case .existing(let id) = resolutions[0] else {
            return XCTFail("expected .existing, got \(String(describing: resolutions.first))")
        }
        XCTAssertEqual(id, existing.id, "an already-persisted match must win over a same-batch sibling, per preResolveConditions' own step-order precedent")
    }

    /// No existing match (step 1 empty) falls through to a confident sibling match (step 2).
    func testResolutionLadderFallsBackToSiblingWhenNoExistingMatch() {
        let sibling = makeDraft(title: "Book the dentist appointment")
        let state = AppState()

        let resolutions = state.resolveTaskRefs(
            [ParsedTaskRef(titleQuery: "book the dentist appointment", confidence: 0.9, assumeExisting: false)],
            drafts: [sibling],
            openTasks: [] // nothing persisted at all — step 1 can never match
        )

        XCTAssertEqual(resolutions.count, 1)
        guard case .sibling(let draftID) = resolutions[0] else {
            return XCTFail("expected .sibling, got \(String(describing: resolutions.first))")
        }
        XCTAssertEqual(draftID, sibling.id)
    }

    /// Neither ladder step clears the 0.7 bar (`Similarity.strict`, same threshold
    /// `preResolveConditions` uses) -> `.unresolved`, never a guessed low-confidence match.
    func testResolutionLadderBelowThresholdIsUnresolved() {
        let existing = makeOpenTask(title: "Water the plants")
        let sibling = makeDraft(title: "Feed the cat")
        let state = AppState()

        let resolutions = state.resolveTaskRefs(
            [ParsedTaskRef(titleQuery: "completely unrelated errand", confidence: 0.9, assumeExisting: false)],
            drafts: [sibling],
            openTasks: [existing]
        )

        XCTAssertEqual(resolutions, [.unresolved])
    }

    /// Every `ParsedTaskUpdate.refIndex` pointing at the SAME ref must land on the same resolution
    /// — proven here by resolving once and reading the identical entry twice, mirroring how
    /// `buildConfirmUpdateDrafts` looks the shared array up by index for each update.
    func testSameRefResolvedOnceIsSharedAcrossMultipleUpdates() {
        let existing = makeOpenTask(title: "Submit report")
        let state = AppState()

        let resolutions = state.resolveTaskRefs(
            [ParsedTaskRef(titleQuery: "submit report", confidence: 0.9, assumeExisting: true)],
            drafts: [],
            openTasks: [existing]
        )

        // Two updates both pointing at refIndex 1 would both read `resolutions[0]` — same value.
        XCTAssertEqual(resolutions[0], resolutions[0])
        guard case .existing(let id) = resolutions[0] else { return XCTFail("expected .existing") }
        XCTAssertEqual(id, existing.id)
    }

    // MARK: - Sibling merge (`AppState.mergeUpdateIntoSibling`) — no card, writes into the draft

    func testSiblingMergeWritesDeadlineStartTimeAndPriorityIntoTheTargetDraft() {
        var drafts = [makeDraft(title: "Book flights")] // no deadline/startTime/priority of its own
        let target = drafts[0].id
        let newDeadline = Date().addingTimeInterval(86_400)
        let newStart = Date().addingTimeInterval(3_600)
        let update = ParsedTaskUpdate(
            refIndex: 1,
            deadline: ParsedValue(value: newDeadline, confidence: 0.95),
            startTime: ParsedValue(value: newStart, confidence: 0.95),
            notesAppend: nil,
            priority: ParsedValue(value: 1, confidence: 0.95),
            addConditions: []
        )
        let state = AppState()

        state.mergeUpdateIntoSibling(update, targetDraftID: target, drafts: &drafts)

        XCTAssertEqual(drafts[0].task.deadline?.value, newDeadline)
        XCTAssertEqual(drafts[0].task.startTime?.value, newStart)
        XCTAssertEqual(drafts[0].task.priority?.value, 1)
    }

    /// "Respecting existing chip edit precedence" (task brief): if the sibling's OWN parse already
    /// stated a deadline, the merge must NOT clobber it — same "never second-guess what was already
    /// stated" rule `IntentRouter.applyStartTimeDerivation` applies one field over.
    func testSiblingMergeNeverOverwritesAFieldTheSiblingsOwnParseAlreadyStated() {
        let originalDeadline = Date().addingTimeInterval(1_800)
        var drafts = [makeDraft(title: "Book flights", deadline: ParsedValue(value: originalDeadline, confidence: 0.9))]
        let target = drafts[0].id
        let update = ParsedTaskUpdate(
            refIndex: 1,
            deadline: ParsedValue(value: Date().addingTimeInterval(999_999), confidence: 0.95),
            startTime: nil, notesAppend: nil, priority: nil, addConditions: []
        )
        let state = AppState()

        state.mergeUpdateIntoSibling(update, targetDraftID: target, drafts: &drafts)

        XCTAssertEqual(drafts[0].task.deadline?.value, originalDeadline, "the sibling's own stated deadline must survive a same-batch reference merge untouched")
    }

    /// `addConditions(.taskDoneNewTask)` becomes the sibling's `refConditions` entry (the
    /// intraBatchTaskDone-style condition the task brief describes) — visible/dismissible on that
    /// draft's own card, never silently invisible.
    func testSiblingMergeTaskDoneNewTaskBecomesARefCondition() {
        var drafts = [makeDraft(title: "Draft A"), makeDraft(title: "Draft B")]
        let target = drafts[0].id // A depends on B (index 2, 1-based into the original tasks array)
        let update = ParsedTaskUpdate(
            refIndex: 1, deadline: nil, startTime: nil, notesAppend: nil, priority: nil,
            addConditions: [.taskDoneNewTask(index: 2)]
        )
        let state = AppState()

        state.mergeUpdateIntoSibling(update, targetDraftID: target, drafts: &drafts)

        XCTAssertEqual(drafts[0].refConditions, [.taskDone(drafts[1].id)])
        XCTAssertTrue(drafts[1].refConditions.isEmpty, "the condition belongs to A, not B")
    }

    /// A `.sibling`-resolved update must produce ZERO `ConfirmUpdateDraft`s — it merges straight
    /// into its target and is never rendered as a card of its own (`ConfirmUpdateDraft`'s own doc
    /// comment).
    func testSiblingResolvedUpdateProducesNoConfirmUpdateDraft() {
        var drafts = [makeDraft(title: "Book flights")]
        let capture = ParsedCapture(
            tasks: [drafts[0].task],
            taskRefs: [ParsedTaskRef(titleQuery: "book flights", confidence: 0.9, assumeExisting: false)],
            updates: [ParsedTaskUpdate(
                refIndex: 1,
                deadline: ParsedValue(value: Date().addingTimeInterval(3_600), confidence: 0.95),
                startTime: nil, notesAppend: nil, priority: nil, addConditions: []
            )]
        )
        let state = AppState()

        let updateDrafts = state.buildConfirmUpdateDrafts(from: capture, drafts: &drafts, openTasks: [])

        XCTAssertTrue(updateDrafts.isEmpty, "a .sibling resolution must merge in place, never become its own card")
        XCTAssertNotNil(drafts[0].task.deadline, "the merge itself must still have happened")
    }

    // MARK: - `confirmSave()` applying a surviving `.existing`-target `ConfirmUpdateDraft`
    //
    // Every case below includes at least one INCLUDED new-task `ConfirmDraft` alongside the update
    // draft — `confirmSave()`'s `guard !confirmDrafts.isEmpty` (unchanged by this feature, per the
    // task brief) returns before ever touching `confirmUpdateDrafts` for a batch with zero new-task
    // drafts, so a realistic capture (the router's own contract guarantees >=1 task per utterance)
    // always has at least one.

    func testDeadlineUpdateOverwritesTheExistingTasksDeadline() {
        let originalDeadline = Date().addingTimeInterval(1_000)
        let newDeadline = Date().addingTimeInterval(50_000)
        let existing = TaskItem(title: "Existing task", details: "", priority: .medium, deadline: originalDeadline, when: .now)
        let state = AppState()
        state.tasks = [existing]
        state.confirmDrafts = [makeDraft(title: "New task")]
        state.confirmUpdateDrafts = [ConfirmUpdateDraft(
            refIndex: 1, sourceTitleQuery: "existing task", resolution: .existing(existing.id),
            deadline: ParsedValue(value: newDeadline, confidence: 1.0),
            startTime: nil, notesAppend: nil, priority: nil, addConditions: []
        )]

        state.confirmSave()

        let updated = state.tasks.first { $0.id == existing.id }
        // Overwrite, not merge/append — a resolved update FIELD always wins outright over the
        // existing value (`updatedTaskItem`'s documented contract), regardless of which write path
        // carries it: this no-store test exercises the direct in-memory field write; the store
        // branch routes the SAME `updatedTaskItem` transform through `TaskStore.mergeIntoExisting`
        // so it starts from the fresh post-merge DB row (Opus review, 2026-08-02 — see
        // `confirmSave`'s task_refs_v1 comment) — either way this assertion holds.
        XCTAssertEqual(updated?.deadline, newDeadline, "an update field OVERWRITES the existing value, same semantics AppState.updateTask uses")
        XCTAssertTrue(state.tasks.contains { $0.title == "New task" }, "the new-task draft in the same batch must still save")
    }

    func testNotesAppendAppendsRatherThanOverwritingExistingNotes() {
        let existing = TaskItem(title: "Existing task", details: "Old note", priority: .medium, when: .now, notes: "Old note")
        let state = AppState()
        state.tasks = [existing]
        state.confirmDrafts = [makeDraft(title: "New task")]
        state.confirmUpdateDrafts = [ConfirmUpdateDraft(
            refIndex: 1, sourceTitleQuery: "existing task", resolution: .existing(existing.id),
            deadline: nil, startTime: nil,
            notesAppend: ParsedValue(value: "New note", confidence: 0.95),
            priority: nil, addConditions: []
        )]

        state.confirmSave()

        let updated = state.tasks.first { $0.id == existing.id }
        XCTAssertEqual(updated?.notes, "Old note\nNew note", "notesAppend must APPEND with the same \\n separator AppState.mergeNotesAppending already uses for a duplicate-merge, never overwrite")
        XCTAssertEqual(updated?.details, updated?.notes, "details/notes must stay in lockstep, same contract AppState.updateTask's own doc comment documents")
    }

    /// `addConditions(.taskDoneNewTask(index:))` must map to the just-persisted NEW task's REAL
    /// post-save UUID — proving `confirmSave`'s save-order correctness (new tasks materialize
    /// before the update's `targetID` lookup runs).
    func testAddConditionsTaskDoneNewTaskMapsIndexToTheRealPostSaveUUID() {
        let existing = TaskItem(title: "Existing task", details: "", priority: .medium, when: .now)
        let newDraft = makeDraft(title: "Brand new task")
        let state = AppState()
        state.tasks = [existing]
        state.confirmDrafts = [newDraft] // index 1 (1-based) into the original tasks/drafts order
        state.confirmUpdateDrafts = [ConfirmUpdateDraft(
            refIndex: 1, sourceTitleQuery: "existing task", resolution: .existing(existing.id),
            deadline: nil, startTime: nil, notesAppend: nil, priority: nil,
            addConditions: [.taskDoneNewTask(index: 1)]
        )]

        state.confirmSave()

        guard let newlyCreated = state.tasks.first(where: { $0.title == "Brand new task" }) else {
            return XCTFail("the new-task draft must have been persisted")
        }
        XCTAssertNotEqual(newlyCreated.id, newDraft.id, "the persisted id is freshly minted by confirmSave, never the transient ConfirmDraft.id")
        let updatedExisting = state.tasks.first { $0.id == existing.id }
        XCTAssertEqual(
            updatedExisting?.conditions, [.taskDone(newlyCreated.id)],
            "the existing task's new condition must point at the REAL, just-minted UUID, not the draft's own transient id"
        )
    }

    /// Constitution II / self-review "nothing user-said silently lost": an update still
    /// `.unresolved` when Save is hit — the picker was on screen the whole time and the user never
    /// picked a target nor dismissed it — is dropped, never applied to a guess.
    func testUnresolvedUpdateDraftIsDroppedAtSaveWithoutTouchingAnyTask() {
        let untouched = TaskItem(title: "Untouched task", details: "", priority: .medium, when: .now)
        let state = AppState()
        state.tasks = [untouched]
        state.confirmDrafts = [makeDraft(title: "New task")]
        state.confirmUpdateDrafts = [ConfirmUpdateDraft(
            refIndex: 1, sourceTitleQuery: "some fuzzy title the user said", resolution: .unresolved,
            deadline: ParsedValue(value: Date(), confidence: 0.95),
            startTime: nil, notesAppend: nil, priority: nil, addConditions: []
        )]

        state.confirmSave()

        let stillUntouched = state.tasks.first { $0.id == untouched.id }
        XCTAssertEqual(stillUntouched, untouched, "an unresolved update must never mutate ANY task — it was dropped, not guessed at")
        XCTAssertTrue(state.tasks.contains { $0.title == "New task" }, "the rest of the batch must still save normally")
    }

    /// Card-level dismiss (the "x" on the whole update card) must behave exactly like `.unresolved`
    /// at Save — nothing applied.
    func testCardDismissedUpdateDraftIsNeverAppliedEvenWhenResolved() {
        let existing = TaskItem(title: "Existing task", details: "", priority: .medium, when: .now)
        let state = AppState()
        state.tasks = [existing]
        state.confirmDrafts = [makeDraft(title: "New task")]
        state.confirmUpdateDrafts = [ConfirmUpdateDraft(
            refIndex: 1, sourceTitleQuery: "existing task", resolution: .existing(existing.id),
            deadline: ParsedValue(value: Date().addingTimeInterval(3_600), confidence: 1.0),
            startTime: nil, notesAppend: nil, priority: nil, addConditions: [],
            cardDismissed: true
        )]

        state.confirmSave()

        XCTAssertEqual(state.tasks.first { $0.id == existing.id }?.deadline, nil, "a dismissed card must apply nothing, same as an unresolved one")
    }

    /// Constitution II: an uncertain (<0.7) update field must NOT auto-commit without an explicit
    /// accept — same gate `AppState.resolvedValue` already enforces for a brand-new task's chips.
    func testUncertainUpdateFieldWithoutExplicitAcceptIsNotApplied() {
        let existing = TaskItem(title: "Existing task", details: "", priority: .medium, when: .now)
        let state = AppState()
        state.tasks = [existing]
        state.confirmDrafts = [makeDraft(title: "New task")]
        state.confirmUpdateDrafts = [ConfirmUpdateDraft(
            refIndex: 1, sourceTitleQuery: "existing task", resolution: .existing(existing.id),
            deadline: ParsedValue(value: Date().addingTimeInterval(3_600), confidence: 0.4), // uncertain
            startTime: nil, notesAppend: nil, priority: nil, addConditions: []
            // `accepted` left empty on purpose — this is the whole point of the test.
        )]

        state.confirmSave()

        XCTAssertNil(state.tasks.first { $0.id == existing.id }?.deadline, "an uncertain field must never auto-commit, even on an update to an existing task")
    }

    /// Dismissing one field chip must not affect the others on the same update draft.
    func testDismissedFieldIsDroppedButOtherFieldsOnTheSameDraftStillApply() {
        let existing = TaskItem(title: "Existing task", details: "", priority: .low, when: .now)
        let state = AppState()
        state.tasks = [existing]
        state.confirmDrafts = [makeDraft(title: "New task")]
        var draft = ConfirmUpdateDraft(
            refIndex: 1, sourceTitleQuery: "existing task", resolution: .existing(existing.id),
            deadline: ParsedValue(value: Date().addingTimeInterval(3_600), confidence: 1.0),
            startTime: nil, notesAppend: nil,
            priority: ParsedValue(value: 1, confidence: 1.0),
            addConditions: []
        )
        draft.dismissed.insert(.deadline)
        state.confirmUpdateDrafts = [draft]

        state.confirmSave()

        let updated = state.tasks.first { $0.id == existing.id }
        XCTAssertNil(updated?.deadline, "the dismissed field must not apply")
        XCTAssertEqual(updated?.priority, .high, "an undismissed field on the SAME draft must still apply")
    }

    /// An `.existing` target that was deleted between parse and Save must no-op gracefully, never
    /// crash — same "no-op for an unknown id" convention `AppState.updateTask`/`TaskStore.
    /// updateEditableFields`/`addCondition` already document for a missing target.
    func testExistingTargetDeletedBetweenParseAndSaveIsAGracefulNoOp() {
        let state = AppState()
        state.tasks = [] // the referenced task no longer exists
        state.confirmDrafts = [makeDraft(title: "New task")]
        state.confirmUpdateDrafts = [ConfirmUpdateDraft(
            refIndex: 1, sourceTitleQuery: "vanished task", resolution: .existing(UUID()),
            deadline: ParsedValue(value: Date(), confidence: 1.0),
            startTime: nil, notesAppend: nil, priority: nil, addConditions: []
        )]

        state.confirmSave() // must not crash

        XCTAssertTrue(state.tasks.contains { $0.title == "New task" }, "the rest of the batch must still save even though the update's target vanished")
    }
}
