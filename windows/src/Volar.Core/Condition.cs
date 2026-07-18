namespace Volar.Core;

/// <summary>
/// A single eligibility gate on a <see cref="TaskSnapshot"/>. A task's <c>Conditions</c> combine
/// with AND semantics: the task is eligible only once <i>every</i> condition is satisfied (see
/// <c>NextTask.cs</c>). Unlike <c>Deadline</c>, conditions never influence ordering — only
/// eligibility.
/// </summary>
/// <remarks>
/// Modeled as a closed discriminated union (an <see langword="abstract record"/> with exactly
/// three <see langword="sealed"/> subtypes, mirroring Swift's
/// <c>enum Condition: Sendable, Equatable</c> with associated values), matched exhaustively via
/// <see langword="switch"/> expressions rather than a Swift-style <see langword="switch"/>
/// statement over an enum.
/// </remarks>
public abstract record Condition
{
    // `private protected` constructor: only sealed subtypes within this assembly may derive from
    // Condition (a plain `private` constructor would not even be visible to derived types), which
    // keeps the union effectively closed to the three subtypes declared in this file, mirroring
    // the Swift enum.
    private protected Condition() { }

    /// <summary>
    /// Whether this condition currently holds, given a precomputed id -&gt; status lookup over the
    /// snapshot and the reference instant <paramref name="now"/>. Pure: no I/O, no clock reads.
    /// </summary>
    internal bool IsSatisfied(IReadOnlyDictionary<Guid, TaskState> statusById, DateTimeOffset now) => this switch
    {
        // Absent from the snapshot: deleted, therefore satisfied.
        TaskDoneCondition c => !statusById.TryGetValue(c.TaskId, out var status)
            || status == TaskState.Done
            || status == TaskState.Archived,
        AfterDateCondition c => now >= c.Date,
        ExternalCondition c => c.Satisfied,
        _ => throw new NotSupportedException($"Unhandled {nameof(Condition)} subtype: {GetType()}")
    };
}

/// <summary>
/// Satisfied when the referenced task is <see cref="TaskState.Done"/>,
/// <see cref="TaskState.Archived"/>, or absent from the snapshot entirely (deleted). Blocking
/// while the referenced task is <see cref="TaskState.Todo"/>/<see cref="TaskState.InProgress"/>.
/// Same resolution mapping as 001 FR-003 — see <see cref="TaskState"/>'s doc comment.
/// </summary>
public sealed record TaskDoneCondition(Guid TaskId) : Condition;

/// <summary>
/// Satisfied when <c>now &gt;= Date</c> — exact equality counts as satisfied, not just strictly
/// later instants.
/// </summary>
public sealed record AfterDateCondition(DateTimeOffset Date) : Condition;

/// <summary>
/// An externally-tracked condition (e.g. "waiting on a delegated reply"). The engine never mutates
/// <c>Satisfied</c> itself; it is satisfied iff the caller has already flipped it.
/// </summary>
public sealed record ExternalCondition(string Description, bool Satisfied) : Condition;
