// Entities/CompletionEventEntity.cs — port of Sources/Model/CompletionLog.swift's @Model
// CompletionEvent.
namespace Volar.Data.Entities;

/// <summary>
/// One completed instant — a task, a recurring reset, or (later) a breakdown step. Immutable once
/// created: nothing in this project ever mutates a row after insert, only appends/queries.
/// </summary>
/// <remarks>
/// <see cref="TaskId"/> is intentionally NOT a foreign key (see VolarDbContext's model config — no
/// relationship is configured for this entity) — it may dangle after the source task is deleted, by
/// design: this is the historical record, not a live reference, so <c>TaskRepository.DeleteAsync</c>
/// never touches this table (mirrors `TaskStore.delete` never touching `CompletionEvent` rows in the
/// Swift original).
/// </remarks>
public sealed class CompletionEventEntity
{
    public Guid Id { get; set; }

    public Guid TaskId { get; set; }

    public required string TitleSnapshot { get; set; }

    public Guid? ParentIdSnapshot { get; set; }

    public int? EstimateSnapshot { get; set; }

    public DateTimeOffset CompletedAt { get; set; }
}
