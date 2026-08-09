// Sources/Model/CompletionLog.swift — append-only completion history (research.md R7).
// Independent of live task state so recurrence reset-in-place (which erases per-task history by
// design) still leaves a durable record of every "did it" instant. No UI here — just the @Model
// and clean fetch APIs for the later accomplishment/rollup surfaces (FR-035).
import Foundation
import SwiftData
import VolarCore

/// One completed instant — a task, a recurring reset, or (later) a breakdown step. The CONTENT
/// fields — `taskId`, `titleSnapshot`, `parentIdSnapshot`, `estimateSnapshot`, `completedAt` — are
/// immutable once created: no code path may ever change them after insert. `syncedAt` is the one
/// exception, and it is sync METADATA, not content (specs/008-sync/client-contract.md §2): it is
/// written later, by `CompletionLog.markSynced`, once the server has confirmed the push. Nothing
/// else about this type is mutable after insert. Retention/pruning is intentionally NOT
/// implemented here (see backlog).
@Model
final class CompletionEvent {
    @Attribute(.unique) var id: UUID
    /// May dangle after the source task is deleted — by design (data-model.md): the event is the
    /// historical record, not a live reference, so `TaskStore.delete` never touches this log.
    var taskId: UUID
    var titleSnapshot: String
    var parentIdSnapshot: UUID?
    var estimateSnapshot: Int?
    var completedAt: Date
    /// Sync metadata, not content — see the class doc comment above. Non-nil means "the server has
    /// this row"; that's the entire meaning. Completions are append-only and never conflict
    /// (client-contract.md §2), so unlike `VolarTask.syncedAt` there is no `updatedAt` to compare
    /// this against — any non-nil value marks the row as no longer pending.
    var syncedAt: Date?

    init(
        id: UUID = UUID(),
        taskId: UUID,
        titleSnapshot: String,
        parentIdSnapshot: UUID?,
        estimateSnapshot: Int?,
        completedAt: Date
    ) {
        self.id = id
        self.taskId = taskId
        self.titleSnapshot = titleSnapshot
        self.parentIdSnapshot = parentIdSnapshot
        self.estimateSnapshot = estimateSnapshot
        self.completedAt = completedAt
    }
}

/// Append + query surface. Namespaced as a caseless enum (not a stored type) since every
/// operation only needs a `ModelContext` — mirrors `TaskStore`'s ownership of the container
/// without introducing a second stateful object; `TaskStore` calls into this from its completion
/// path (see `TaskStore.completeOne`).
enum CompletionLog {
    /// Appends one immutable record for `task`'s current `completedAt` — the caller (`TaskStore`)
    /// is responsible for setting that field *before* calling this, and for calling
    /// `context.save()` afterward so this can be batched with the rest of the same completion
    /// transaction (status flip, recurrence reset, parent cascade).
    @discardableResult
    static func recordCompletion(of task: VolarTask, in context: ModelContext) -> CompletionEvent {
        let event = CompletionEvent(
            taskId: task.id,
            titleSnapshot: task.title,
            parentIdSnapshot: task.parentId,
            estimateSnapshot: task.durationMinutes,
            completedAt: task.completedAt ?? Date()
        )
        context.insert(event)
        return event
    }

    // MARK: - Range queries (FR-035 rollups)
    //
    // All queries filter via `#Predicate` + `SortDescriptor` at the SwiftData/store level — never
    // `fetchAll then filter in memory` — so this stays cheap as the log grows unbounded (append-
    // only, no retention yet; see backlog).

    static func events(in interval: DateInterval, context: ModelContext) -> [CompletionEvent] {
        let start = interval.start
        let end = interval.end
        let descriptor = FetchDescriptor<CompletionEvent>(
            predicate: #Predicate<CompletionEvent> { $0.completedAt >= start && $0.completedAt < end },
            sortBy: [SortDescriptor(\.completedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Events on the calendar day containing `date`, per `calendar` (explicit — no implicit
    /// `.current`/DST assumptions leak in from a bare `Date` comparison).
    static func events(forDay date: Date, calendar: Calendar, context: ModelContext) -> [CompletionEvent] {
        guard let interval = calendar.dateInterval(of: .day, for: date) else { return [] }
        return events(in: interval, context: context)
    }

    static func events(forWeek date: Date, calendar: Calendar, context: ModelContext) -> [CompletionEvent] {
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: date) else { return [] }
        return events(in: interval, context: context)
    }

    static func events(forMonth date: Date, calendar: Calendar, context: ModelContext) -> [CompletionEvent] {
        guard let interval = calendar.dateInterval(of: .month, for: date) else { return [] }
        return events(in: interval, context: context)
    }

    /// Per-parent rollup grouping (FR-035): the `nil` key holds standalone (no-parent)
    /// completions. Pure in-memory grouping of an already-narrow (range-queried) result set —
    /// not a full-history scan.
    static func groupedByParent(_ events: [CompletionEvent]) -> [UUID?: [CompletionEvent]] {
        Dictionary(grouping: events, by: \.parentIdSnapshot)
    }

    // MARK: - Sync (specs/008-sync/client-contract.md §2)
    //
    // `TaskStore`'s `SyncTaskStoring` conformance forwards its three completion-sync methods
    // straight into these three functions — kept here rather than duplicated in `TaskStore.swift`
    // because they are pure `CompletionEvent` fetch/insert/update, the same reasoning as the
    // range-query helpers above.

    /// Completions still to push, oldest `completedAt` first, capped at `limit`. Append-only + no
    /// `updatedAt` (see `CompletionEvent.syncedAt`'s doc comment) means "pending" is simply
    /// `syncedAt == nil` — no LWW, nothing to compare, nothing to conflict.
    static func pendingForSync(limit: Int, in context: ModelContext) -> [PendingCompletion] {
        var descriptor = FetchDescriptor<CompletionEvent>(
            predicate: #Predicate<CompletionEvent> { $0.syncedAt == nil },
            sortBy: [SortDescriptor(\.completedAt)]
        )
        descriptor.fetchLimit = limit
        let events = (try? context.fetch(descriptor)) ?? []
        return events.map {
            PendingCompletion(
                id: $0.id, taskId: $0.taskId, completedAt: $0.completedAt,
                titleSnapshot: $0.titleSnapshot, parentIdSnapshot: $0.parentIdSnapshot,
                estimateSnapshot: $0.estimateSnapshot
            )
        }
    }

    /// Marks `ids` as confirmed by the server. There is no value to compare against on the way
    /// back in (unlike `VolarTask`'s `markSynced(_: [UUID: Date])`) — a completion can never be
    /// edited again after creation, so "synced" only needs a non-nil marker, not a specific value.
    /// // UNVERIFIED: capturing an external `Set<UUID>` inside a `#Predicate` closure
    /// (`idSet.contains($0.id)`) is a documented SwiftData pattern, but never compiled on this
    /// machine (no Swift/Xcode on Windows) — confirm on Mac.
    static func markSynced(_ ids: [UUID], in context: ModelContext) {
        guard !ids.isEmpty else { return }
        let idSet = Set(ids)
        let descriptor = FetchDescriptor<CompletionEvent>(
            predicate: #Predicate<CompletionEvent> { idSet.contains($0.id) }
        )
        let now = Date()
        for event in (try? context.fetch(descriptor)) ?? [] {
            event.syncedAt = now
        }
    }

    /// Inserts any remote completion whose id isn't already present locally; NEVER updates an
    /// existing row — matches the server's own `on conflict do nothing` (0005_sync_schema.sql), so
    /// client and server agree a completion can only ever be created, never edited, from either
    /// direction. Rows inserted this way are immediately marked synced: they came FROM the server,
    /// so pushing them straight back would be a pointless round trip.
    @discardableResult
    static func applyRemote(_ remote: [RemoteCompletion], in context: ModelContext) -> Int {
        guard !remote.isEmpty else { return 0 }
        let incomingIds = Set(remote.map(\.id))
        let existingDescriptor = FetchDescriptor<CompletionEvent>(
            predicate: #Predicate<CompletionEvent> { incomingIds.contains($0.id) }
        )
        let existingIds = Set(((try? context.fetch(existingDescriptor)) ?? []).map(\.id))
        let now = Date()
        var inserted = 0
        for entry in remote where !existingIds.contains(entry.id) {
            let event = CompletionEvent(
                id: entry.id, taskId: entry.taskId, titleSnapshot: entry.titleSnapshot,
                parentIdSnapshot: entry.parentIdSnapshot, estimateSnapshot: entry.estimateSnapshot,
                completedAt: entry.completedAt
            )
            event.syncedAt = now
            context.insert(event)
            inserted += 1
        }
        return inserted
    }
}
