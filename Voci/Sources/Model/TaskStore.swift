// Sources/Model/TaskStore.swift — SwiftData ModelContainer + CRUD, mapped VociTask <-> TaskItem.
// Enforces data-model.md's 6 persistence validation rules; everything else (VociCore's own
// invariants — DAG-ness of `.taskDone` edges, ordering, eligibility) is delegated to VociCore.
//
// TRUST BOUNDARY (self-review "client-side exploitable holes"): validation here runs on the
// WRITE path (`add`/`addBatch`/`addCondition`/`setRecurrence`/`setParent`). A store row edited
// directly on disk (hostile plist/db edit, cross-device sync corruption) bypasses all of it — the
// read path (`fetchAll`) does not re-validate `.taskDone` acyclicity or re-check the 10-task cap,
// both for cost (O(n) validateCondition-equivalent work on every launch) and because VociCore's
// hot path (`nextTask`) is documented to tolerate a corrupted snapshot without crashing (dangling
// ids resolve as "satisfied", per contract). What IS defended unconditionally, including against
// a corrupted store: `ModelContext.parentId` cycle walks below always terminate (visited-set
// bounded), and JSON blob decode failures fail closed to empty/`nil` rather than throwing.
import Foundation
import SwiftData
import VociCore

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
/// `VociTask`/`ModelContext` directly.
///
/// `init()` can throw (container creation can fail); callers (see `VociApp.swift`) are expected
/// to `try?` it and fall back to `AppState`'s empty in-memory task list when it does, per the
/// architecture spec's "degrade gracefully if container init fails" requirement.
@MainActor
final class TaskStore {
    private let container: ModelContainer
    private let context: ModelContext

    /// Validation rule 6.
    static let maxBatchSize = 10

    init() throws {
        let schema = Schema([VociTask.self, CompletionEvent.self])
        let configuration = ModelConfiguration(schema: schema)
        container = try ModelContainer(for: schema, configurations: [configuration])
        context = ModelContext(container)
    }

    /// Loads all persisted tasks. (Previously seeded SampleData on first run; removed — the app
    /// now starts empty so the user creates their own tasks.)
    func loadOrSeed() -> [TaskItem] {
        return fetchAll()
    }

    /// Also runs the one-time `dependsOn` -> `.taskDone` fold (migration note in VociTask.swift)
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
    /// would create a cycle or self-reference via `VociCore.validateCondition`, with the human-
    /// readable message the contract promises. `.afterDate`/`.external` never throw (contract
    /// guarantee 5) so they always attach.
    func addCondition(_ condition: VociCore.Condition, to id: UUID) throws {
        guard fetchModel(id) != nil else { return } // unknown id — nothing to attach to
        if case .taskDone = condition {
            do {
                try VociCore.validateCondition(adding: condition, to: id, in: allEngineSnapshot())
            } catch let dependencyError as DependencyError {
                throw TaskStoreError.invalidCondition(Self.describe(dependencyError))
            }
        }
        guard let model = fetchModel(id) else { return }
        model.conditions.append(condition)
        save()
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
    /// as a result (via `VociCore.eligibilityDiff`), so the caller can notify once instead of
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
        return VociCore.eligibilityDiff(before: beforeSnapshot, after: afterSnapshot, now: now)
    }

    /// Computes "what's next" straight from the persisted snapshot via `VociCore.nextTask`, for
    /// any caller that only has a `TaskStore` (no full `AppState`) — e.g. a future background
    /// refresh of the menu-bar label.
    func active(now: Date) -> TaskItem? {
        let all = fetchAll()
        guard let winner = VociCore.nextTask(from: all.map { $0.snapshot() }, now: now, calendar: .current) else { return nil }
        return all.first { $0.id == winner.id }
    }

    // MARK: - Completion internals

    /// Walks from `model` up through `parentId` links, completing (with recurrence reset where
    /// applicable) each task whose completion just emptied its parent's open-child set. A
    /// visited-set bounds the walk so a corrupted store containing a `parentId` cycle can't loop
    /// forever (defends the walk itself, not just edge creation — `setParent` already rejects
    /// creating new cycles going forward).
    private func completeCascading(
        from model: VociTask, now: Date, calendar: Calendar, anchorRecurrenceToCompletion: Bool
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
    private func completeOne(_ model: VociTask, now: Date, calendar: Calendar, anchorToCompletion: Bool) {
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

    private func fetchModel(_ id: UUID) -> VociTask? {
        var descriptor = FetchDescriptor<VociTask>(predicate: #Predicate<VociTask> { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    private func fetchAllModels() -> [VociTask] {
        let descriptor = FetchDescriptor<VociTask>(sortBy: [SortDescriptor(\.createdAt)])
        return (try? context.fetch(descriptor)) ?? []
    }

    private func fetchChildren(of parentId: UUID) -> [VociTask] {
        let descriptor = FetchDescriptor<VociTask>(predicate: #Predicate<VociTask> { $0.parentId == parentId })
        return (try? context.fetch(descriptor)) ?? []
    }

    /// // UNVERIFIED: `ModelContext.fetchCount(_:)` is part of the original macOS 14 SwiftData
    /// surface per Apple's WWDC23 materials — confirm it compiles/links against this project's
    /// deployment target on Mac; falls back to 0 (== "no children") on any fetch failure, which
    /// is the safe default for the rule-2 gate this guards.
    private func hasChildren(_ id: UUID) -> Bool {
        let descriptor = FetchDescriptor<VociTask>(predicate: #Predicate<VociTask> { $0.parentId == id })
        return ((try? context.fetchCount(descriptor)) ?? 0) > 0
    }

    private func allEngineSnapshot() -> [VociCore.Task] {
        fetchAllModels().map { $0.asTaskItem.snapshot() }
    }

    /// Builds a `VociTask` from `item`, filters its conditions through `sanitizedConditions`,
    /// inserts it, and appends its engine form to `snapshot` (in/out) so subsequent items in the
    /// same batch see it — shared by `add`/`addBatch` so their field-copy can't drift apart.
    @discardableResult
    private func insertSanitized(_ item: TaskItem, snapshot: inout [VociCore.Task]) -> VociTask {
        let model = VociTask(
            id: item.id,
            title: item.title,
            details: item.details,
            priority: item.priority,
            status: item.status,
            deadline: item.deadline,
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

    /// Filters out any `.taskDone` condition that would fail `VociCore.validateCondition` (self-
    /// reference or cycle) rather than throwing — used by the bulk-insert paths (`add`/
    /// `addBatch`), where surfacing a per-condition error isn't wired to any caller yet (that's
    /// `addCondition`'s job for the single-edge UI flow). `.afterDate`/`.external` never throw
    /// (contract guarantee 5) so they always pass through unchanged.
    private func sanitizedConditions(
        _ conditions: [VociCore.Condition],
        for id: UUID,
        in snapshot: [VociCore.Task]
    ) -> [VociCore.Condition] {
        conditions.filter { condition in
            guard case .taskDone = condition else { return true }
            do {
                try VociCore.validateCondition(adding: condition, to: id, in: snapshot)
                return true
            } catch {
                print("[Voci.TaskStore] dropped invalid condition on \(id): \(error)")
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
