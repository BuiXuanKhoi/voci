// Entities/ConditionEntity.cs — normalized child-table storage for VolarCore.Condition, replacing
// VolarTask.swift's JSON-blob `conditionsData` + hand-rolled `ConditionDTO`.
//
// DESIGN DECISION (flagged for Opus review per this task's brief): the brief offered two options —
// a JSON column (closer to the Swift original) or a normalized child table. Chose the child table
// because eligibility queries (Volar.Core.NextTaskSelector.EligibleTasks / DependencyGraph's cycle
// walk) need to reason about individual `.taskDone` edges, and a normalized table lets a future
// query (e.g. "which tasks does X block", "count of unsatisfied external conditions") be expressed
// directly in SQL/LINQ instead of round-tripping every row's JSON blob through the app layer first.
// The tradeoff: three "payload" columns (TaskDoneTargetId / AfterDate / ExternalDescription +
// ExternalSatisfied) are used one-at-a-time depending on Kind — this is the standard EF Core
// "table-per-hierarchy with nullable sum-type columns" shape for a small closed discriminated
// union, chosen over TPH-with-inheritance (Condition itself has no natural "is-a" storage identity)
// or a JSON column-per-condition (which would just move the same problem down one level).
namespace Volar.Data.Entities;

/// <summary>
/// One row of a <see cref="TaskEntity"/>'s ordered <c>Conditions</c> array. Exactly one of the
/// payload groups (TaskDone / AfterDate / External) is populated, selected by <see cref="Kind"/> —
/// see <see cref="ConditionMapping"/> for the conversion to/from <c>Volar.Core.Condition</c>.
/// </summary>
public sealed class ConditionEntity
{
    public Guid Id { get; set; }

    /// FK to the owning <see cref="TaskEntity"/> — see VolarDbContext's cascade-delete config
    /// (deleting a task deletes its conditions; this mirrors VolarTask's own `conditionsData`
    /// column, which is simply gone when the row is gone — there is no separate lifetime to manage
    /// in the Swift original, so cascade delete here reproduces the same effective behavior).
    public Guid TaskId { get; set; }

    /// Preserves the original array order (Swift's `conditions` is an ordered `[Condition]`, and
    /// `TaskRepository.ClearFirstExternalConditionAsync`/`ClearExternalConditionAsync` — port of
    /// `TaskStore.clearFirstExternal` — depend on "first" meaning list order, not row-insertion
    /// order or any other implicit ordering).
    public int OrderIndex { get; set; }

    /// One of "taskDone" / "afterDate" / "external" — matches `ConditionDTO.Kind`'s raw values.
    public required string Kind { get; set; }

    /// Populated iff <see cref="Kind"/> == "taskDone".
    public Guid? TaskDoneTargetId { get; set; }

    /// Populated iff <see cref="Kind"/> == "afterDate".
    public DateTimeOffset? AfterDate { get; set; }

    /// Populated iff <see cref="Kind"/> == "external".
    public string? ExternalDescription { get; set; }

    /// Populated iff <see cref="Kind"/> == "external".
    public bool? ExternalSatisfied { get; set; }
}
