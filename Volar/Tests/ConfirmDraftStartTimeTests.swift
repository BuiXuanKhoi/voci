// Tests/ConfirmDraftStartTimeTests.swift — XCTest coverage for the "disposition code ngay lập
// tức" urgent-task flow (2026-07-28/29): `ParsedTask.startTime` (the instant the user said they'd
// START, set by the parse/router layer for an urgent utterance like "làm ngay lập tức") flowing
// through the confirm-card draft (`ConfirmDraft`/`ChipKind.startTime`, `PopoverView.attributeChips`)
// into the persisted `TaskItem.startTime` via `AppState.confirmSave()`.
//
// Deliberately does NOT re-derive or re-test the deadline = startTime + 30' inference — that
// derivation happens entirely at the router/parse layer, BEFORE a `ConfirmDraft` ever exists here.
// This file only proves: (1) the confirm-card save path carries `startTime` through exactly like
// every other scalar attribute chip (dismiss/uncertain-accept gating included), and (2) a fully
// "urgent" task (priority 1 + startTime + a deadline landing today) genuinely wins `VolarCore`'s
// real ordering once saved — WITHOUT any "emergency" kind/flag anywhere in this codebase: a
// today-or-overdue deadline is already tier 2 of `Task.orderedBefore`, ahead of tier 3's priority,
// so the urgent task jumps the queue purely because of where its deadline lands, exactly per this
// task's design brief.
//
// Same "pure where possible, no-store fallback" split every other file in this folder documents:
// `AppState`'s no-argument/no-store initializer degrades to the in-memory path, which is exactly
// what every test below wants.
//
// UNVERIFIED (written entirely on Windows — no Xcode/simulator available here): not run against a
// real `VolarTests` bundle.
import XCTest
@testable import Volar
import VolarCore

@MainActor
final class ConfirmDraftStartTimeTests: XCTestCase {

    // 2026-07-29: cleanup for the `defaultTaskDurationMinutes` tests appended below (same
    // "remove the specific persisted key in setUp/tearDown" convention `TourFlowTests.swift`/
    // `CalendarSyncTests.swift`/`CaptureHotkeyAndTitleEditTests.swift` already use for their own
    // `UserDefaults`-backed settings) — without this, a leftover value from a previous run/test
    // would make `AppState()`'s "falls back to 30" test flaky.
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: AppState.defaultTaskDurationMinutesKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AppState.defaultTaskDurationMinutesKey)
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeParsedTask(
        title: String = "Handle the disposition code",
        transcript: String = "handle the disposition code right now"
    ) -> ParsedTask {
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

    // MARK: - 1. Draft with startTime -> confirmSave() persists TaskItem.startTime

    func testConfirmSavePersistsStartTimeForANewTask() {
        let now = Date()
        var task = makeParsedTask()
        task.startTime = ParsedValue(value: now, confidence: 0.95)
        let draft = ConfirmDraft(task: task)

        let state = AppState()
        state.confirmDrafts = [draft]
        state.captureState = .parsed

        state.confirmSave()

        let saved = state.tasks.first { $0.title == "Handle the disposition code" }
        XCTAssertNotNil(saved)
        XCTAssertEqual(saved?.startTime, now)
    }

    // MARK: - 2. Dismissing the startTime chip -> NOT saved

    func testDismissingStartTimeChipPreventsItFromBeingSaved() {
        let now = Date()
        var task = makeParsedTask()
        task.startTime = ParsedValue(value: now, confidence: 0.95)
        let draft = ConfirmDraft(task: task)

        let state = AppState()
        state.confirmDrafts = [draft]
        state.captureState = .parsed

        state.dismissAttribute(.startTime, forDraft: draft.id)
        state.confirmSave()

        let saved = state.tasks.first { $0.title == "Handle the disposition code" }
        XCTAssertNotNil(saved)
        XCTAssertNil(saved?.startTime, "a dismissed startTime chip must never be persisted, regardless of confidence")
    }

    // MARK: - 3. No startTime at all -> saved as nil, no crash (the overwhelming common case)

    func testConfirmSaveWithNoStartTimeSavesNilWithoutCrashing() {
        let draft = ConfirmDraft(task: makeParsedTask(title: "Ordinary task, no urgency"))
        XCTAssertNil(draft.task.startTime, "test setup assumption: this task was never parsed as urgent")

        let state = AppState()
        state.confirmDrafts = [draft]
        state.captureState = .parsed

        state.confirmSave()

        let saved = state.tasks.first { $0.title == "Ordinary task, no urgency" }
        XCTAssertNotNil(saved)
        XCTAssertNil(saved?.startTime)
    }

    // MARK: - 4. A fully "urgent" disposition task wins VolarCore's REAL ordering — no "emergency"
    // kind/tier anywhere; it wins purely because its (router-inferred) deadline lands today, which
    // is already VolarCore's tier 2, ahead of tier 3 (priority).

    func testFullyUrgentTaskBecomesTheActiveTaskThroughRealVolarCoreOrdering() {
        let now = Date()

        // An ordinary, already-existing backlog item: lower urgency signal (no deadline at all),
        // present BEFORE the urgent draft is ever saved, so this is a genuine "does the new task
        // jump ahead of what was already there" ordering test, not just "is it the only task."
        let existing = TaskItem(
            title: "Ordinary backlog item",
            priority: .medium,
            when: .later
        )

        let state = AppState(tasks: [existing], clock: { now })

        // Mirrors the task brief's own scenario: Gemini returns priority 1 + startTime = now, no
        // deadline; the router infers `deadline = startTime + 30'`. 2026-07-29 (anh Khôi chốt,
        // REVERSED from this test's original shape): that derived deadline now carries 0.75
        // confidence — clears `ParsedValue.isUncertain`'s 0.7 bar — and `deadlineIsEstimated = true`,
        // so it auto-commits on a plain Save with NO `acceptUncertainAttribute` tap at all. The old
        // version of this test simulated exactly that tap, which is precisely what let the real bug
        // hide: a user who just hits Save after "làm ngay lập tức" must still get a deadline.
        var urgentTask = makeParsedTask(title: "Handle the disposition code")
        urgentTask.priority = ParsedValue(value: 1, confidence: 0.9)
        urgentTask.startTime = ParsedValue(value: now, confidence: 0.95)
        urgentTask.deadline = ParsedValue(value: now.addingTimeInterval(30 * 60), confidence: 0.75)
        urgentTask.deadlineIsEstimated = true
        let draft = ConfirmDraft(task: urgentTask)

        state.confirmDrafts = [draft]
        state.captureState = .parsed
        state.confirmSave()

        let saved = state.tasks.first { $0.title == "Handle the disposition code" }
        XCTAssertNotNil(saved)
        XCTAssertEqual(saved?.startTime, now, "startTime must have persisted alongside the auto-committed deadline")
        XCTAssertNotNil(saved?.deadline, "the derived deadline must auto-commit on a plain Save (no accept tap) — otherwise this test cannot prove the ordering claim")

        // THE actual assertion this whole feature's design rests on: no "emergency" kind, flag, or
        // extra engine tier was added anywhere — `AppState.activeTask` (the real production seam,
        // `VolarCore.nextTask(from:now:calendar:)` under the hood) must independently agree that
        // this task, not the pre-existing backlog item, is the one to work on right now.
        XCTAssertEqual(state.activeTask?.id, saved?.id, "a today-deadline task must win VolarCore's real tier-2 ordering over a no-deadline backlog item, with zero 'emergency' special-casing")
    }

    // MARK: - 5. Save straight through (no accept, no dismiss) on a REAL router-derived urgent
    // task -> `TaskItem.deadline` is present and equals `startTime` + the 30-minute default. This
    // is anh Khôi's core complaint made concrete, exercising the actual production code path
    // (`IntentRouter.applyStartTimeDerivation`) rather than a hand-set confidence/flag: hitting Save
    // with zero extra taps must never leave an urgent task undated (that was the whole bug).

    func testSavingStraightThroughPersistsRouterDerivedDeadlineEqualToStartTimePlusThirtyMinutes() throws {
        let now = Date()
        var task = makeParsedTask(title: "Ship the urgent fix")
        task.startTime = ParsedValue(value: now, confidence: 0.95)
        // Exercises the REAL derivation this feature depends on, not a hand-set confidence/flag —
        // this is the exact code path that broke before 2026-07-29 (confidence 0.35 -> silently
        // dropped by `AppState.resolvedValue` at save unless explicitly accepted).
        let derived = try XCTUnwrap(IntentRouter.applyStartTimeDerivation([task]).first)
        let draft = ConfirmDraft(task: derived)

        let state = AppState()
        state.confirmDrafts = [draft]
        state.captureState = .parsed

        // No `acceptUncertainAttribute`, no `dismissAttribute` — exactly a plain Save.
        state.confirmSave()

        let saved = state.tasks.first { $0.title == "Ship the urgent fix" }
        XCTAssertNotNil(saved)
        let expectedDeadline = try XCTUnwrap(Calendar.current.date(byAdding: .minute, value: 30, to: now))
        XCTAssertEqual(saved?.deadline, expectedDeadline, "a plain Save must persist the derived deadline with zero extra taps")
    }

    // MARK: - 6. Dismissing the deadline chip still wins even though the derived deadline now
    // auto-commits by default — constitution II's "dismiss always wins, regardless of confidence"
    // must not have been quietly broken by raising the confidence above 0.7 (self-review
    // "correctness": `AppState.resolvedValue` checks `dismissed` BEFORE `isUncertain`, so this
    // should already hold, but a derived deadline that auto-commits is new enough behavior to be
    // worth pinning down explicitly rather than trusting that by inspection alone).

    func testDismissingDeadlineChipStillPreventsRouterDerivedDeadlineFromSaving() throws {
        let now = Date()
        var task = makeParsedTask(title: "Ship the urgent fix")
        task.startTime = ParsedValue(value: now, confidence: 0.95)
        let derived = try XCTUnwrap(IntentRouter.applyStartTimeDerivation([task]).first)
        let draft = ConfirmDraft(task: derived)

        let state = AppState()
        state.confirmDrafts = [draft]
        state.captureState = .parsed

        state.dismissAttribute(.deadline, forDraft: draft.id)
        state.confirmSave()

        let saved = state.tasks.first { $0.title == "Ship the urgent fix" }
        XCTAssertNotNil(saved)
        XCTAssertNil(saved?.deadline, "an explicitly dismissed deadline chip must never save, even one confident enough to auto-commit")
    }

    // MARK: - 7. Plain Save on a router-derived urgent task also persists `TaskItem.durationMinutes`
    // (2026-07-29, anh Khôi chốt): `materialize()` maps `estimateMinutes` -> `TaskItem.
    // durationMinutes` (confirmed by reading `TaskItem.swift`'s `durationMinutes: Int?` and
    // `AppState.materialize`'s `durationMinutes: estimate` line — not guessed). Uses an explicit
    // `defaultMinutes: 45` (not the built-in 30) so this test cannot pass by coincidence with the
    // fallback default.

    func testSavingStraightThroughPersistsDurationMinutesEqualToTheDerivationDefault() throws {
        let now = Date()
        var task = makeParsedTask(title: "File the disposition report")
        task.startTime = ParsedValue(value: now, confidence: 0.95)
        let derived = try XCTUnwrap(
            IntentRouter.applyStartTimeDerivation([task], defaultMinutes: 45).first
        )
        let draft = ConfirmDraft(task: derived)

        let state = AppState()
        state.confirmDrafts = [draft]
        state.captureState = .parsed

        // No accept, no dismiss — exactly a plain Save.
        state.confirmSave()

        let saved = state.tasks.first { $0.title == "File the disposition report" }
        XCTAssertNotNil(saved)
        XCTAssertEqual(
            saved?.durationMinutes, 45,
            "materialize() must carry the derived estimateMinutes through onto TaskItem.durationMinutes"
        )
        let expectedDeadline = try XCTUnwrap(Calendar.current.date(byAdding: .minute, value: 45, to: now))
        XCTAssertEqual(saved?.deadline, expectedDeadline, "deadline and durationMinutes must agree on the same number of minutes")
    }

    // MARK: - 8. `AppState.defaultTaskDurationMinutes` — setter round-trip, out-of-range rejection,
    // and the `UserDefaults.integer(forKey:)`-returns-0-for-an-absent-key fallback to 30.

    func testDefaultTaskDurationMinutesFallsBackToThirtyWhenNeverSet() {
        let state = AppState()
        XCTAssertEqual(
            state.defaultTaskDurationMinutes, 30,
            "an absent key must read as the 30-minute default, never as UserDefaults.integer's own 0"
        )
    }

    func testSetDefaultTaskDurationMinutesPersistsAndReadsBackOnAFreshInstance() {
        let state = AppState()
        state.setDefaultTaskDurationMinutes(45)
        XCTAssertEqual(state.defaultTaskDurationMinutes, 45)

        // A second, independent `AppState` instance re-reads `UserDefaults` in its own `init` —
        // proves this is real persistence, not just the in-memory property of the first instance.
        let reloaded = AppState()
        XCTAssertEqual(reloaded.defaultTaskDurationMinutes, 45)
    }

    func testSetDefaultTaskDurationMinutesRejectsOutOfRangeValues() {
        let state = AppState()

        state.setDefaultTaskDurationMinutes(4) // below the 5...480 floor
        XCTAssertEqual(state.defaultTaskDurationMinutes, 30)

        state.setDefaultTaskDurationMinutes(481) // above the 5...480 ceiling
        XCTAssertEqual(state.defaultTaskDurationMinutes, 30)

        state.setDefaultTaskDurationMinutes(0) // UserDefaults.integer's own "absent key" value
        XCTAssertEqual(state.defaultTaskDurationMinutes, 30)
    }
}
