// Sources/Model/TaskStore.swift — SwiftData ModelContainer + CRUD, mapped VolarTask <-> TaskItem.
// Enforces data-model.md's 6 persistence validation rules; everything else (VolarCore's own
// invariants — DAG-ness of `.taskDone` edges, ordering, eligibility) is delegated to VolarCore.
//
// TRUST BOUNDARY (self-review "client-side exploitable holes"): validation here runs on the
// WRITE path (`add`/`addBatch`/`addCondition`/`setRecurrence`/`setParent`). A store row edited
// directly on disk (hostile plist/db edit, cross-device sync corruption) bypasses all of it — the
// read path (`fetchAll`) does not re-validate `.taskDone` acyclicity or re-check the 10-task cap,
// both for cost (O(n) validateCondition-equivalent work on every launch) and because VolarCore's
// hot path (`nextTask`) is documented to tolerate a corrupted snapshot without crashing (dangling
// ids resolve as "satisfied", per contract). What IS defended unconditionally, including against
// a corrupted store: `ModelContext.parentId` cycle walks below always terminate (visited-set
// bounded), and JSON blob decode failures fail closed to empty/`nil` rather than throwing.
import Foundation
import SwiftData
import VolarCore

/// Errors surfaced by `TaskStore`'s validated mutation APIs. Every case carries a human-readable
/// message (constitution II: never silently guess or drop — always explain) suitable for direct
/// display.
enum TaskStoreError: Error, LocalizedError, Equatable {
    case invalidCondition(String)
    case parentNotFound
    case parentCycle(childTitle: String, parentTitle: String)
    case parentHasRecurrence(String)
    case recurrenceRequiresLeaf(String)
    case batchTooLarge(limit: Int)

    var errorDescription: String? {
        switch self {
        case .invalidCondition(let message):
            return message
        case .parentNotFound:
            return "That parent task no longer exists."
        case .parentCycle(let child, let parent):
            return "\u{201C}\(parent)\u{201D} can't become a sub-task of \u{201C}\(child)\u{201D} — that would create a loop."
        case .parentHasRecurrence(let title):
            return "\u{201C}\(title)\u{201D} repeats, so it can't have sub-tasks."
        case .recurrenceRequiresLeaf(let title):
            return "\u{201C}\(title)\u{201D} has sub-tasks, so it can't repeat on its own."
        case .batchTooLarge(let limit):
            return "Only \(limit) tasks can be created at once."
        }
    }
}

/// Owns the SwiftData container and exposes `TaskItem`-shaped CRUD so `AppState` never touches
/// `VolarTask`/`ModelContext` directly.
///
/// `init()` can throw (container creation can fail); callers (see `VolarApp.swift`) are expected
/// to `try?` it and fall back to `AppState`'s empty in-memory task list when it does, per the
/// architecture spec's "degrade gracefully if container init fails" requirement.
@MainActor
final class TaskStore {
    private let container: ModelContainer
    private let context: ModelContext

    /// Validation rule 6.
    static let maxBatchSize = 10

    init() throws {
        let schema = Schema([VolarTask.self, CompletionEvent.self, ParseCorrection.self])
        let configuration = ModelConfiguration(schema: schema)
        container = try ModelContainer(for: schema, configurations: [configuration])
        context = ModelContext(container)
    }

    /// M-4 (test hygiene): in-memory variant (`ModelConfiguration(isStoredInMemoryOnly:)`) so
    /// callers like `ReminderSchedulerTests` don't accumulate/pollute rows in the real on-disk
    /// store across repeated local runs. Functionally identical to `init()` otherwise — same
    /// schema, same validated CRUD surface.
    init(inMemory: Bool) throws {
        let schema = Schema([VolarTask.self, CompletionEvent.self, ParseCorrection.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        container = try ModelContainer(for: schema, configurations: [configuration])
        context = ModelContext(container)
    }

    /// Loads all persisted tasks. (Previously seeded SampleData on first run; removed — the app
    /// now starts empty so the user creates their own tasks.)
    func loadOrSeed() -> [TaskItem] {
        return fetchAll()
    }

    /// Also runs the one-time `dependsOn` -> `.taskDone` fold (migration note in VolarTask.swift)
    /// on any row that still carries legacy data, saving once for the whole batch if anything
    /// changed.
    func fetchAll() -> [TaskItem] {
        let models = fetchAllModels()
        var didMigrate = false
        for model in models where model.foldLegacyDependsOn() {
            didMigrate = true
        }
        if didMigrate {
            save()
        }
        return models.map(\.asTaskItem)
    }

    func add(_ item: TaskItem) {
        var snapshot = allEngineSnapshot()
        insertSanitized(item, snapshot: &snapshot)
        save()
    }

    /// Validation rule 6: caps any batch materialization at `maxBatchSize`. Each item is
    /// sanitized against a snapshot that grows as earlier items in the SAME batch are accepted,
    /// so intra-batch `.taskDone` references (e.g. an AI breakdown's later steps depending on
    /// earlier ones) validate correctly without a second pass.
    func addBatch(_ items: [TaskItem]) throws {
        guard items.count <= Self.maxBatchSize else {
            throw TaskStoreError.batchTooLarge(limit: Self.maxBatchSize)
        }
        var snapshot = allEngineSnapshot()
        for item in items {
            insertSanitized(item, snapshot: &snapshot)
        }
        save()
    }

    /// Validation rule 1: adds `condition` to task `id`, rejecting a `.taskDone` payload that
    /// would create a cycle or self-reference via `VolarCore.validateCondition`, with the human-
    /// readable message the contract promises. `.afterDate`/`.external` never throw (contract
    /// guarantee 5) so they always attach.
    func addCondition(_ condition: VolarCore.Condition, to id: UUID) throws {
        guard fetchModel(id) != nil else { return } // unknown id — nothing to attach to
        if case .taskDone = condition {
            do {
                try VolarCore.validateCondition(adding: condition, to: id, in: allEngineSnapshot())
            } catch let dependencyError as DependencyError {
                throw TaskStoreError.invalidCondition(Self.describe(dependencyError))
            }
        }
        guard let model = fetchModel(id) else { return }
        model.conditions.append(condition)
        save()
    }

    /// Việc 3 (confirm-list data layer, duplicate-detection merge, 2026-07-28): merges a freshly-
    /// confirmed draft into an ALREADY-PERSISTED task the user chose instead of creating a
    /// duplicate row (`AppState.ConfirmDraft.DuplicateResolution.useExisting`). `applying` receives
    /// the task's CURRENT `TaskItem` and returns the merged version — building it this way (a
    /// caller-supplied transform, rather than a long list of optional-field parameters) keeps every
    /// "present vs. absent" / "dismissed vs. accepted" rule exactly where it already lives
    /// (`AppState.resolvedValue`/`AppState.mergeTransform`), while this method owns the two things
    /// a bare field copy would get wrong:
    ///   - Validation rule 2 (recurrence only on a leaf): if the merged result would set a
    ///     recurrence on a task that has children, that ONE field is silently reverted back to the
    ///     task's existing recurrence rather than rejecting the whole merge outright (the merge
    ///     already represents something the user explicitly asked for — a save failing over one
    ///     attribute the calling utterance likely didn't even care about would be a worse
    ///     experience than dropping that one field, mirroring `sanitizedConditions`'s "partial
    ///     success beats losing everything" precedent below).
    ///   - Validation rule 1 (`.taskDone` cycle/self-reference): the merged `conditions` array is
    ///     re-run through `sanitizedConditions` — the SAME bulk-insert gate `add`/`addBatch` use —
    ///     so a merge can never smuggle in a cyclic edge `addCondition`'s single-edge path would
    ///     have caught.
    /// Reuses `VolarTask.apply(_:)` (already documented there as "the one obvious place a future
    /// 'edit task' API writes through") for the actual field sync, so this file has exactly one
    /// place that copies a `TaskItem`'s fields onto a live model. A no-op (returns `nil`, no save)
    /// for an unknown id — nothing to merge into.
    @discardableResult
    func mergeIntoExisting(_ id: UUID, applying transform: (TaskItem) -> TaskItem) -> TaskItem? {
        guard let model = fetchModel(id) else { return nil }
        var merged = transform(model.asTaskItem)
        if merged.recurrence != nil, hasChildren(id) {
            merged.recurrence = model.recurrence
        }
        merged.conditions = sanitizedConditions(merged.conditions, for: id, in: allEngineSnapshot())
        model.apply(merged)
        save()
        return merged
    }

    /// Validation rule 2: recurrence is only ever allowed on a task with no children.
    func setRecurrence(_ recurrence: Recurrence?, on id: UUID) throws {
        guard let model = fetchModel(id) else { return }
        if recurrence != nil, hasChildren(id) {
            throw TaskStoreError.recurrenceRequiresLeaf(model.title)
        }
        model.recurrence = recurrence
        save()
    }

    /// Validation rule 3: `parentId` must reference an existing task, and the parent-link graph
    /// must stay acyclic. Also enforces the flip side of rule 2 (a recurring task can't gain
    /// children) since that's only checkable from this direction once a child is being attached.
    func setParent(_ childId: UUID, to parentId: UUID?) throws {
        guard let child = fetchModel(childId) else { return }
        guard let parentId else {
            child.parentId = nil
            save()
            return
        }
        if childId == parentId {
            throw TaskStoreError.parentCycle(childTitle: child.title, parentTitle: child.title)
        }
        guard let parent = fetchModel(parentId) else {
            throw TaskStoreError.parentNotFound
        }
        if parent.recurrence != nil {
            throw TaskStoreError.parentHasRecurrence(parent.title)
        }
        // Walk up from the PROPOSED parent following existing `parentId` links; if `childId` is
        // reached, attaching would close a cycle. The visited-set bounds the walk even against a
        // store that already contains a corrupted parent cycle above `parent` (defends the walk
        // itself, not just the edge being added — self-review "parentId cycle... must terminate").
        var visited: Set<UUID> = []
        var cursor: UUID? = parentId
        while let current = cursor {
            guard visited.insert(current).inserted else { break }
            if current == childId {
                throw TaskStoreError.parentCycle(childTitle: child.title, parentTitle: parent.title)
            }
            cursor = fetchModel(current)?.parentId
        }
        child.parentId = parentId
        save()
    }

    /// Mirrors `AppState.toggleDone`'s open/close semantics, but the persisted side now owns
    /// strictly more: marking done always appends an immutable `CompletionEvent` (research.md R7
    /// — the only durable record once a recurring task resets in place); a completed recurring
    /// task reopens at its next occurrence instead of staying `.done` (state machine: open ->
    /// done(moment) -> open(next), R8); completing the last open child of a parent auto-completes
    /// the parent too, cascading upward (validation rule 5).
    func toggle(
        _ id: UUID,
        now: Date = Date(),
        calendar: Calendar = .current,
        anchorRecurrenceToCompletion: Bool = false
    ) {
        guard let model = fetchModel(id) else { return }
        if model.status == .done {
            model.status = .todo
            model.completedAt = nil
            save()
            return
        }
        completeCascading(
            from: model, now: now, calendar: calendar,
            anchorRecurrenceToCompletion: anchorRecurrenceToCompletion
        )
        save()
    }

    /// Validation rule 4: strips the deleted id from every other task's `.taskDone` conditions
    /// and nulls children's `parentId`, then returns ids of OTHER tasks that flip newly-eligible
    /// as a result (via `VolarCore.eligibilityDiff`), so the caller can notify once instead of
    /// re-deriving it separately. `CompletionEvent`s referencing this id are left untouched by
    /// design (history, not a live reference — see CompletionLog.swift).
    @discardableResult
    func delete(_ id: UUID, now: Date = Date()) -> [UUID] {
        let before = fetchAllModels()
        guard before.contains(where: { $0.id == id }) else { return [] }
        let beforeSnapshot = before.map { $0.asTaskItem.snapshot() }

        for model in before where model.id != id {
            if model.parentId == id {
                model.parentId = nil
            }
            let stripped = model.conditions.filter { condition in
                if case .taskDone(let referenced) = condition { return referenced != id }
                return true
            }
            if stripped.count != model.conditions.count {
                model.conditions = stripped
            }
        }
        if let target = before.first(where: { $0.id == id }) {
            context.delete(target)
        }
        save()

        let afterSnapshot = fetchAllModels().map { $0.asTaskItem.snapshot() }
        return VolarCore.eligibilityDiff(before: beforeSnapshot, after: afterSnapshot, now: now)
    }

    /// T036 (phase5-contract.md §C): voice-done's `.clearExternal` intent resolves to a task id
    /// only (contract A's `VoiceMatch` carries `taskId`/`title`/`score`, not which specific
    /// `.external` description matched) — this clears the FIRST still-unsatisfied `.external`
    /// condition on `id`, which covers the common case of exactly one outstanding external wait
    /// per task. A no-op (returns `[]`) for an unknown id or a task with nothing unsatisfied to
    /// clear. Mirrors `delete`'s pattern: returns newly-eligible task ids (via
    /// `VolarCore.eligibilityDiff`) so the caller notifies the scheduler once instead of
    /// recomputing the diff a second time (self-review "performance").
    ///
    /// Behavior UNCHANGED from before FIX 1 — now implemented via `clearFirstExternal(on:now:matching:)`
    /// with an always-true predicate, shared with `clearExternalCondition(withPrefix:on:now:)` below.
    @discardableResult
    func clearFirstExternalCondition(on id: UUID, now: Date = Date()) -> [UUID] {
        clearFirstExternal(on: id, now: now, matching: { _ in true })
    }

    /// FIX 1 (security, DelegationTracker.markNeedsReview): like `clearFirstExternalCondition`,
    /// but only matches the first unsatisfied `.external` condition whose description
    /// `hasPrefix(prefix)`, instead of blindly taking the first unsatisfied `.external` condition
    /// on the task regardless of which one it is. Without this, an inbound `volar://ai-done`
    /// signal could satisfy a HUMAN-tracked external gate (e.g. "waiting on legal") that happens
    /// to be first in the list, just because it was unsatisfied — this lets the caller (the AI
    /// delegation tracker) target only the condition it actually owns
    /// (`DelegationTracker.waitingPrefix`, "waiting on AI: "). A no-op (returns `[]`) for an
    /// unknown id or a task with no matching unsatisfied condition.
    @discardableResult
    func clearExternalCondition(withPrefix prefix: String, on id: UUID, now: Date = Date()) -> [UUID] {
        clearFirstExternal(on: id, now: now, matching: { $0.hasPrefix(prefix) })
    }

    /// Shared implementation for `clearFirstExternalCondition`/`clearExternalCondition(withPrefix:)`:
    /// finds the first unsatisfied `.external` condition on `id` whose description satisfies
    /// `match`, flips it to satisfied, saves, and returns newly-eligible task ids. A no-op
    /// (returns `[]`, no save) if `id` is unknown or nothing matches.
    private func clearFirstExternal(
        on id: UUID, now: Date, matching match: (String) -> Bool
    ) -> [UUID] {
        guard let model = fetchModel(id) else { return [] }
        guard let index = model.conditions.firstIndex(where: {
            if case .external(let description, let satisfied) = $0 { return !satisfied && match(description) }
            return false
        }) else { return [] }
        let beforeSnapshot = fetchAllModels().map { $0.asTaskItem.snapshot() }
        guard case .external(let description, _) = model.conditions[index] else { return [] }
        model.conditions[index] = .external(description: description, satisfied: true)
        save()
        let afterSnapshot = fetchAllModels().map { $0.asTaskItem.snapshot() }
        return VolarCore.eligibilityDiff(before: beforeSnapshot, after: afterSnapshot, now: now)
    }

    /// FIX 7 (seam): sets `id` as the single "frog of the day" on the PERSISTED side, clearing the
    /// flag on every other task (`nil` clears it everywhere, matching no task being frog). Mirrors
    /// `AppState.setFrog`'s in-memory single-frog invariant (`Volar/Sources/App/AppState.swift`)
    /// so the app-wiring agent's `store.setFrog(id)` call keeps the persisted store in sync with
    /// that in-memory array. Only touches models whose `frog` value actually changes, then saves
    /// once (or not at all if nothing changed) — same "don't churn the store" discipline as the
    /// rest of this file's mutators.
    func setFrog(_ id: UUID?) {
        var changed = false
        for model in fetchAllModels() {
            let shouldBeFrog = model.id == id
            if model.frog != shouldBeFrog {
                model.frog = shouldBeFrog
                changed = true
            }
        }
        if changed {
            save()
        }
    }

    /// Constitution V / FR-044: appends one `ParseCorrection` row for a confirm-card chip edit
    /// (`AppState`'s chip-interaction methods, T024) — the only call site able to reach
    /// `ParseCorrectionLog.record` since it needs this store's private `ModelContext`
    /// (`ParseCorrection.swift`/T026 deliberately exposes no context of its own — see that file's
    /// header comment). Saves immediately: unlike `addBatch`, a chip edit isn't naturally batched
    /// with a larger transaction — it happens well before the user hits Save.
    func recordCorrection(attribute: String, parsed: String, corrected: String, transcript: String) {
        ParseCorrectionLog.record(attribute: attribute, parsed: parsed, corrected: corrected, transcript: transcript, in: context)
        save()
    }

    /// Computes "what's next" straight from the persisted snapshot via `VolarCore.nextTask`, for
    /// any caller that only has a `TaskStore` (no full `AppState`) — e.g. a future background
    /// refresh of the menu-bar label.
    func active(now: Date) -> TaskItem? {
        let all = fetchAll()
        guard let winner = VolarCore.nextTask(from: all.map { $0.snapshot() }, now: now, calendar: .current) else { return nil }
        return all.first { $0.id == winner.id }
    }

    /// Reminders subsystem seam (specs/002-workflow-command-center/contracts/phase4-contract.md
    /// §B): `VolarTask.isSensitive` is deliberately not threaded through `TaskItem` (see that
    /// field's doc comment in `VolarTask.swift`) — `ReminderScheduler`'s fire-time fresh reload
    /// needs to read it directly off the persisted model instead. Defaults to `false` (never
    /// sensitive) for an unknown/deleted id, matching every other "task not found" fallback in
    /// this file.
    func isSensitive(_ id: UUID) -> Bool {
        fetchModel(id)?.isSensitive ?? false
    }

    // MARK: - Completion internals

    /// Walks from `model` up through `parentId` links, completing (with recurrence reset where
    /// applicable) each task whose completion just emptied its parent's open-child set. A
    /// visited-set bounds the walk so a corrupted store containing a `parentId` cycle can't loop
    /// forever (defends the walk itself, not just edge creation — `setParent` already rejects
    /// creating new cycles going forward).
    private func completeCascading(
        from model: VolarTask, now: Date, calendar: Calendar, anchorRecurrenceToCompletion: Bool
    ) {
        var current = model
        var visited: Set<UUID> = []
        var anchorOverride = anchorRecurrenceToCompletion // only the task the user actually
        // completed gets the capture-time override; cascaded parent auto-completions always
        // reset on their own schedule.
        while visited.insert(current.id).inserted {
            completeOne(current, now: now, calendar: calendar, anchorToCompletion: anchorOverride)
            anchorOverride = false
            guard
                let parentId = current.parentId,
                let parent = fetchModel(parentId),
                parent.status != .done
            else { break }
            let hasOpenSiblings = fetchChildren(of: parentId).contains { $0.id != current.id && $0.status != .done }
            guard !hasOpenSiblings else { break }
            current = parent
        }
    }

    /// Completion for exactly one task: log + either recurrence reset-in-place or a plain
    /// `.done`.
    private func completeOne(_ model: VolarTask, now: Date, calendar: Calendar, anchorToCompletion: Bool) {
        model.completedAt = now
        if let recurrence = model.recurrence {
            // Validation rule 2 guarantees a recurring task has no children, so a parent reached
            // via the cascade above never hits this branch while also being "the auto-completed
            // parent" case — `assert` (not `precondition`) so a corrupted store that somehow
            // violates the invariant degrades to "resets like normal" in a release build instead
            // of crashing (self-review "must not crash-loop the app").
            assert(!hasChildren(model.id), "rule 2: a recurring task must have no children")
            let reset = RecurrenceEngine.reset(
                recurrence: recurrence,
                deadline: model.deadline,
                conditions: model.conditions,
                completedAt: now,
                anchorToCompletion: anchorToCompletion,
                calendar: calendar
            )
            model.deadline = reset.deadline
            model.conditions = reset.conditions
            model.status = .todo
        } else {
            model.status = .done
        }
        CompletionLog.recordCompletion(of: model, in: context)
    }

    // MARK: - Fetch helpers

    private func fetchModel(_ id: UUID) -> VolarTask? {
        var descriptor = FetchDescriptor<VolarTask>(predicate: #Predicate<VolarTask> { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    private func fetchAllModels() -> [VolarTask] {
        let descriptor = FetchDescriptor<VolarTask>(sortBy: [SortDescriptor(\.createdAt)])
        return (try? context.fetch(descriptor)) ?? []
    }

    private func fetchChildren(of parentId: UUID) -> [VolarTask] {
        let descriptor = FetchDescriptor<VolarTask>(predicate: #Predicate<VolarTask> { $0.parentId == parentId })
        return (try? context.fetch(descriptor)) ?? []
    }

    /// // UNVERIFIED: `ModelContext.fetchCount(_:)` is part of the original macOS 14 SwiftData
    /// surface per Apple's WWDC23 materials — confirm it compiles/links against this project's
    /// deployment target on Mac; falls back to 0 (== "no children") on any fetch failure, which
    /// is the safe default for the rule-2 gate this guards.
    private func hasChildren(_ id: UUID) -> Bool {
        let descriptor = FetchDescriptor<VolarTask>(predicate: #Predicate<VolarTask> { $0.parentId == id })
        return ((try? context.fetchCount(descriptor)) ?? 0) > 0
    }

    private func allEngineSnapshot() -> [VolarCore.Task] {
        fetchAllModels().map { $0.asTaskItem.snapshot() }
    }

    /// Builds a `VolarTask` from `item`, filters its conditions through `sanitizedConditions`,
    /// inserts it, and appends its engine form to `snapshot` (in/out) so subsequent items in the
    /// same batch see it — shared by `add`/`addBatch` so their field-copy can't drift apart.
    @discardableResult
    private func insertSanitized(_ item: TaskItem, snapshot: inout [VolarCore.Task]) -> VolarTask {
        let model = VolarTask(
            id: item.id,
            title: item.title,
            details: item.details,
            priority: item.priority,
            status: item.status,
            deadline: item.deadline,
            startTime: item.startTime,
            createdAt: item.createdAt,
            when: item.when,
            durationMinutes: item.durationMinutes,
            frog: item.frog
        )
        model.conditions = sanitizedConditions(item.conditions, for: item.id, in: snapshot)
        model.parentId = item.parentId
        model.notes = item.notes
        model.sourceTranscript = item.sourceTranscript
        model.kind = item.kind
        // Rule 2 (recurrence only on leaves): a brand-new task has no children yet, so accepting
        // `item.recurrence` unconditionally here can never violate it — children can only be
        // attached afterward via `setParent`, which itself rejects attaching to a recurring
        // parent.
        model.recurrence = item.recurrence
        model.reminderOverride = item.reminderOverride
        model.resumeNote = item.resumeNote
        model.switchAwayCount = item.switchAwayCount
        model.completedAt = item.completedAt
        model.delegation = item.delegation
        context.insert(model)
        snapshot.append(model.asTaskItem.snapshot())
        return model
    }

    /// Filters out any `.taskDone` condition that would fail `VolarCore.validateCondition` (self-
    /// reference or cycle) rather than throwing — used by the bulk-insert paths (`add`/
    /// `addBatch`), where surfacing a per-condition error isn't wired to any caller yet (that's
    /// `addCondition`'s job for the single-edge UI flow). `.afterDate`/`.external` never throw
    /// (contract guarantee 5) so they always pass through unchanged.
    private func sanitizedConditions(
        _ conditions: [VolarCore.Condition],
        for id: UUID,
        in snapshot: [VolarCore.Task]
    ) -> [VolarCore.Condition] {
        conditions.filter { condition in
            guard case .taskDone = condition else { return true }
            do {
                try VolarCore.validateCondition(adding: condition, to: id, in: snapshot)
                return true
            } catch {
                print("[Volar.TaskStore] dropped invalid condition on \(id): \(error)")
                return false
            }
        }
    }

    private static func describe(_ error: DependencyError) -> String {
        switch error {
        case .cycle(let from, let to):
            return "\u{201C}\(from)\u{201D} is already waiting on \u{201C}\(to)\u{201D} — making \u{201C}\(to)\u{201D} wait on \u{201C}\(from)\u{201D} would create a loop."
        case .selfDependency(let title):
            return "\u{201C}\(title)\u{201D} can't wait on itself."
        }
    }

    private func save() {
        try? context.save()
    }
}
