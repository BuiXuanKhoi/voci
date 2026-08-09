// Sources/Model/CompletionLog.swift — append-only completion history (research.md R7).
// Independent of live task state so recurrence reset-in-place (which erases per-task history by
// design) still leaves a durable record of every "did it" instant. No UI here — just the @Model
// and clean fetch APIs for the later accomplishment/rollup surfaces (FR-035).
import Foundation
import SwiftData
import VolarCore

/// One completed instant — a task, a recurring reset, or (later) a breakdown step. Immutable
/// once created: nothing in this file ever mutates a `CompletionEvent` after insert, only
/// appends/queries. Retention/pruning is intentionally NOT implemented here (see backlog).
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
}
