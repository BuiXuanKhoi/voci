// Tests/DependencyCycleTests.swift — XCTest coverage for
// specs/002-workflow-command-center/contracts/cycle-detection-contract.md §2: `AppState.
// recomputeConfirmCycle()` (private, exercised only through the public mutators that call it —
// `resolveTaskDoneToDraft`/`dismissCondition`/`setDraftIncluded`/`setDuplicateResolution`) and the
// `confirmCycle == nil` guard `confirmSave()` now enforces before it ever touches the store.
//
// Deliberately PURE — no-store `AppState()` degrades to the in-memory fallback, same convention
// `ConfirmCardManualEditTests.swift` already establishes for this exact reason: nothing here needs
// a real `TaskStore`, only `tasks`/`confirmDrafts` state and the pure `VolarCore.findCycle` call
// underneath `recomputeConfirmCycle()`.
//
// UNVERIFIED (written entirely on Windows — no Xcode/simulator available here): not run against a
// real `VolarTests` bundle. Also depends on `VolarCore.findCycle`/`cyclePath` (Agent 1) and
// `TaskStore.removeCondition` (Agent 4) landing with the exact signatures frozen in the contract's
// §1.1/§1.4 — this file was written against those signatures, not against a build.
import XCTest
@testable import Volar

@MainActor
final class DependencyCycleTests: XCTestCase {

    // MARK: - Fixtures

    private func makeParsedTask(title: String) -> ParsedTask {
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
            sourceTranscript: "test"
        )
    }

    private func makeDraft(title: String) -> ConfirmDraft {
        ConfirmDraft(task: makeParsedTask(title: title))
    }

    // MARK: - Cycle entirely within the batch (intra-batch `.taskDone`)

    func testThreeDraftCycleEntirelyInBatchIsDetected() {
        var draftA = makeDraft(title: "A")
        var draftB = makeDraft(title: "B")
        let draftC = makeDraft(title: "C")
        // A waits on B, B waits on C — set directly on the structs before they ever reach
        // `AppState` (no recompute has run yet); the THIRD edge (C waits on A) is added below via
        // the real mutator, which is what actually triggers `recomputeConfirmCycle()` against the
        // full, now-cyclic batch.
        draftA.intraBatchTaskDone[0] = draftB.id
        draftB.intraBatchTaskDone[0] = draftC.id

        let state = AppState()
        state.confirmDrafts = [draftA, draftB, draftC]
        state.resolveTaskDoneToDraft(draftC.id, conditionIndex: 0, target: draftA.id)

        let cycle = state.confirmCycle
        XCTAssertNotNil(cycle, "A→B→C→A must be caught the moment the closing edge is added")
        XCTAssertEqual(cycle?.titles.first, cycle?.titles.last, "the reported path must be closed")
        XCTAssertEqual(cycle?.titles.count, 4, "3 distinct tasks + the closing repeat")
        XCTAssertEqual(Set(cycle?.titles ?? []), ["A", "B", "C"])
        XCTAssertEqual(cycle?.removableEdges.count, 3, "every edge in a fully intra-batch cycle belongs to some draft, so all 3 must be removable from the card")
    }

    func testCleanBatchWithARealDependencyButNoCycleStaysNil() {
        var draftA = makeDraft(title: "A")
        let draftB = makeDraft(title: "B")
        // A waits on B, nothing waits back on A — a plain chain, not a cycle.
        draftA.intraBatchTaskDone[0] = draftB.id

        let state = AppState()
        state.confirmDrafts = [draftA, draftB]
        // Any mutator triggers a recompute; `setDraftIncluded` re-including an already-included
        // draft is a convenient no-op-shaped trigger that still exercises the real code path.
        state.setDraftIncluded(draftB.id, true)

        XCTAssertNil(state.confirmCycle, "a real but acyclic dependency must never be reported as a cycle")
    }

    // MARK: - Cycle passing through an already-persisted task (`.useExisting` merge)

    func testCycleThroughAnAlreadyPersistedTaskViaUseExistingIsDetectedAndNodesAreNotDuplicated() {
        let existing = TaskItem(title: "Ship the report", priority: .medium, when: .now)

        // Draft A: a brand-new task that waits on the ALREADY-PERSISTED "Ship the report".
        var draftA = makeDraft(title: "Email the client")
        draftA.resolvedTaskDone[0] = existing.id

        // Draft B: the user says this is the SAME task as "Ship the report" (`.useExisting`), AND
        // in the same utterance says it waits on draft A — so once merged, "Ship the report"
        // itself gains a brand-new edge onto A, closing the loop through the persisted task.
        var draftB = makeDraft(title: "Ship report (dup)")
        draftB.intraBatchTaskDone[0] = draftA.id

        let state = AppState()
        state.tasks = [existing]
        state.confirmDrafts = [draftA, draftB]
        // Triggers the recompute against the final state (this call also sets the resolution
        // itself — redundant with `makeDraft`'s default `.addNew`, but that's exactly the point:
        // exercise the real mutator, not a hand-assembled `confirmCycle`).
        state.setDuplicateResolution(draftB.id, .useExisting(existing.id))

        let cycle = state.confirmCycle
        XCTAssertNotNil(cycle, "existing waits on A (via B's merge) + A waits on existing must close a loop")
        XCTAssertEqual(cycle?.titles.count, 3, "exactly 2 distinct nodes (the existing task + draft A), not 3 — a duplicated node for B would report a longer or different cycle")
        XCTAssertEqual(Set(cycle?.titles ?? []), ["Ship the report", "Email the client"])
        XCTAssertFalse(
            (cycle?.titles ?? []).contains("Ship report (dup)"),
            "draft B's OWN title must never appear — its edges merge into the existing node's identity, it never becomes a second node"
        )
        XCTAssertEqual(cycle?.removableEdges.count, 2)
        let labels = Set((cycle?.removableEdges ?? []).map(\.label))
        XCTAssertEqual(labels, [
            "Ship the report waits on Email the client",
            "Email the client waits on Ship the report",
        ])
    }

    // MARK: - Breaking the cycle

    func testDismissingOneConditionInABatchCycleClearsConfirmCycle() {
        var draftA = makeDraft(title: "A")
        var draftB = makeDraft(title: "B")
        let draftC = makeDraft(title: "C")
        draftA.intraBatchTaskDone[0] = draftB.id
        draftB.intraBatchTaskDone[0] = draftC.id

        let state = AppState()
        state.confirmDrafts = [draftA, draftB, draftC]
        state.resolveTaskDoneToDraft(draftC.id, conditionIndex: 0, target: draftA.id)
        XCTAssertNotNil(state.confirmCycle, "test setup: the 3-draft batch must actually be cyclic before the dismiss")

        state.dismissCondition(at: 0, forDraft: draftA.id)

        XCTAssertNil(state.confirmCycle, "removing ANY one edge in the loop must clear the cycle")
    }

    func testUntickingADraftRemovesItsEdgesFromTheGraph() {
        var draftA = makeDraft(title: "A")
        var draftB = makeDraft(title: "B")
        let draftC = makeDraft(title: "C")
        draftA.intraBatchTaskDone[0] = draftB.id
        draftB.intraBatchTaskDone[0] = draftC.id

        let state = AppState()
        state.confirmDrafts = [draftA, draftB, draftC]
        state.resolveTaskDoneToDraft(draftC.id, conditionIndex: 0, target: draftA.id)
        XCTAssertNotNil(state.confirmCycle, "test setup: the 3-draft batch must actually be cyclic before unticking")

        // Unticking B removes B as a node entirely — A's edge TO B (a draft no longer in
        // `targetID`) is dropped, and B's own edge to C never gets built at all (B is filtered
        // out of `includedDrafts` before its edges are even walked). Only C→A is left, which
        // alone can't close a loop.
        state.setDraftIncluded(draftB.id, false)

        XCTAssertNil(state.confirmCycle, "unticking one link of the cycle must break it")
    }

    // MARK: - Batch sạch (empty / fully unticked) → always nil

    func testFullyUntickedBatchAlwaysReportsNoCycle() {
        var draftA = makeDraft(title: "A")
        var draftB = makeDraft(title: "B")
        // A mutual 2-cycle, so `confirmCycle` starts non-nil before either draft is unticked.
        draftA.intraBatchTaskDone[0] = draftB.id

        let state = AppState()
        state.confirmDrafts = [draftA, draftB]
        state.resolveTaskDoneToDraft(draftB.id, conditionIndex: 0, target: draftA.id)
        XCTAssertNotNil(state.confirmCycle, "test setup: A↔B must be cyclic before either is unticked")

        state.setDraftIncluded(draftA.id, false)
        state.setDraftIncluded(draftB.id, false)

        XCTAssertNil(state.confirmCycle, "an empty (fully unticked) batch is trivially acyclic")
    }

    // MARK: - confirmSave() must refuse to save anything while a cycle is still open

    func testConfirmSaveDoesNothingWhileConfirmCycleIsSet() {
        var draftA = makeDraft(title: "A")
        var draftB = makeDraft(title: "B")
        let draftC = makeDraft(title: "C")
        draftA.intraBatchTaskDone[0] = draftB.id
        draftB.intraBatchTaskDone[0] = draftC.id

        let state = AppState()
        state.confirmDrafts = [draftA, draftB, draftC]
        state.captureState = .parsed
        state.resolveTaskDoneToDraft(draftC.id, conditionIndex: 0, target: draftA.id)
        XCTAssertNotNil(state.confirmCycle, "test setup: the batch must still be cyclic going into confirmSave()")

        state.confirmSave()

        XCTAssertTrue(state.tasks.isEmpty, "confirmSave() must not materialize ANY task out of a still-cyclic batch")
        XCTAssertEqual(state.confirmDrafts.count, 3, "the batch must be left intact for the user to fix, exactly like every other confirmSave() rejection")
        XCTAssertEqual(state.captureState, .parsed, "must not even flip to .saving while blocked by a cycle")
    }
}
