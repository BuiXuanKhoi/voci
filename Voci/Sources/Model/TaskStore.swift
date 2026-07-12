// Sources/Model/TaskStore.swift — SwiftData ModelContainer + CRUD, mapped VociTask <-> TaskItem
import Foundation
import SwiftData
import VociCore

/// Owns the SwiftData container and exposes `TaskItem`-shaped CRUD so `AppState` never touches
/// `VociTask`/`ModelContext` directly.
///
/// `init()` can throw (container creation can fail); callers (see `VociApp.swift`) are expected
/// to `try?` it and fall back to `AppState`'s in-memory `SampleData.tasks` when it does, per the
/// architecture spec's "degrade gracefully if container init fails" requirement.
@MainActor
final class TaskStore {
    private let container: ModelContainer
    private let context: ModelContext

    init() throws {
        let schema = Schema([VociTask.self])
        let configuration = ModelConfiguration(schema: schema)
        container = try ModelContainer(for: schema, configurations: [configuration])
        context = ModelContext(container)
    }

    /// Loads all persisted tasks, seeding the store with `SampleData.tasks` the first time it's
    /// empty (first run / fresh container).
    func loadOrSeed() -> [TaskItem] {
        let existing = fetchAll()
        guard existing.isEmpty else { return existing }
        for item in SampleData.tasks {
            add(item)
        }
        return fetchAll()
    }

    func fetchAll() -> [TaskItem] {
        let descriptor = FetchDescriptor<VociTask>(sortBy: [SortDescriptor(\.createdAt)])
        let models = (try? context.fetch(descriptor)) ?? []
        return models.map(\.asTaskItem)
    }

    func add(_ item: TaskItem) {
        let model = VociTask(
            id: item.id,
            title: item.title,
            priority: item.priority,
            status: item.status,
            deadline: item.deadline,
            dependsOn: item.dependsOn,
            createdAt: item.createdAt,
            when: item.when,
            durationMinutes: item.durationMinutes,
            frog: item.frog
        )
        context.insert(model)
        save()
    }

    /// Mirrors `AppState.toggleDone`'s semantics: marking done always bumps the task to
    /// `.later`; un-marking leaves its `when` bucket untouched (see `voci-mac.jsx`'s `toggleTask`).
    func toggle(_ id: UUID) {
        guard let model = fetchModel(id) else { return }
        var item = model.asTaskItem
        let wasDone = item.done
        item.status = wasDone ? .todo : .done
        if !wasDone { item.when = .later }
        model.apply(item)
        save()
    }

    func delete(_ id: UUID) {
        guard let model = fetchModel(id) else { return }
        context.delete(model)
        save()
    }

    /// Computes "what's next" straight from the persisted snapshot via `VociCore.nextTask`, for
    /// any caller that only has a `TaskStore` (no full `AppState`) — e.g. a future background
    /// refresh of the menu-bar label.
    func active(now: Date) -> TaskItem? {
        let all = fetchAll()
        guard let winner = VociCore.nextTask(from: all.map { $0.toEngineTask() }, now: now) else { return nil }
        return all.first { $0.id == winner.id }
    }

    private func fetchModel(_ id: UUID) -> VociTask? {
        var descriptor = FetchDescriptor<VociTask>(predicate: #Predicate<VociTask> { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    private func save() {
        try? context.save()
    }
}
