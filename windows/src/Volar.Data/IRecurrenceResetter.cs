// IRecurrenceResetter.cs — extension seam for TaskRepository.ToggleAsync's recurring-task branch.
//
// SEAM NOTE (flagged for Opus review per this task's brief — "nếu cần type Domain chưa có, đừng tự
// tạo, ghi báo cáo để nối dây sau"): TaskStore.swift's `completeOne` calls
// `RecurrenceEngine.reset(recurrence:deadline:conditions:completedAt:anchorToCompletion:calendar:)`
// to compute a recurring task's next occurrence (new deadline + conditions) on completion.
// `RecurrenceEngine` and the `Recurrence` type it operates on are owned by Volar.Domain (per
// plan.md's Wave-1 split: "W1-B: Volar.Domain: TaskItem, Recurrence, NLParser"), which had zero .cs
// files at the time this project was written. Rather than block on it or hand-roll a duplicate
// (and likely divergent) recurrence-reset algorithm inside Volar.Data, this interface is the
// injection point: TaskRepository takes an `IRecurrenceResetter` in its constructor (defaulting to
// `UnsupportedRecurrenceResetter`, which throws clearly rather than silently doing the wrong thing)
// and calls it for the recurring branch of ToggleAsync. Once Volar.Domain's RecurrenceEngine exists,
// Opus should add a small adapter class (in Volar.Domain or the App composition root — NOT in
// Volar.Data, to keep this project decoupled from Volar.Domain) implementing this interface by
// deserializing TaskEntity.RecurrenceJson into the real `Recurrence` type and delegating to
// `RecurrenceEngine.reset`.
using Volar.Core;

namespace Volar.Data;

/// <summary>Input to <see cref="IRecurrenceResetter.Reset"/> — mirrors the parameters
/// `RecurrenceEngine.reset` takes in the Swift original.</summary>
/// <param name="RecurrenceJson">The task's opaque <c>TaskEntity.RecurrenceJson</c> blob (never
/// <see langword="null"/> when this is invoked — <see cref="Volar.Data.TaskRepository"/> only calls
/// the resetter for a task whose <c>RecurrenceJson</c> is non-null).</param>
/// <param name="Deadline">The task's current deadline immediately before this completion.</param>
/// <param name="Conditions">The task's current conditions immediately before this completion.</param>
/// <param name="CompletedAt">The instant this completion is recorded at.</param>
/// <param name="AnchorToCompletion">Whether the next occurrence should be computed relative to
/// <paramref name="CompletedAt"/> rather than the original schedule — same flag
/// <c>TaskRepository.ToggleAsync</c> receives from its own caller.</param>
/// <param name="TimeZone">Explicit injected time zone — never <see cref="TimeZoneInfo.Local"/>,
/// matching Volar.Core's purity convention (see NextTaskSelector's doc comments).</param>
public sealed record RecurrenceResetInput(
    string RecurrenceJson,
    DateTimeOffset? Deadline,
    IReadOnlyList<Condition> Conditions,
    DateTimeOffset CompletedAt,
    bool AnchorToCompletion,
    TimeZoneInfo TimeZone);

/// <summary>Result of a recurrence reset: the recurring task's next-occurrence deadline/conditions,
/// and it always reopens to <see cref="TaskState.Todo"/> (matching `completeOne`'s
/// `model.status = .todo` for the recurring branch — the caller doesn't need to be told this since
/// it's unconditional).</summary>
public sealed record RecurrenceResetResult(DateTimeOffset? Deadline, IReadOnlyList<Condition> Conditions);

public interface IRecurrenceResetter
{
    RecurrenceResetResult Reset(RecurrenceResetInput input);
}

/// <summary>Default resetter — throws clearly rather than silently mishandling a recurring task's
/// completion. <see cref="Volar.Data.TaskRepository"/> only ever reaches this for a task whose
/// <c>RecurrenceJson</c> is non-null, i.e. only once a caller actually creates a recurring task
/// without also supplying a real <see cref="IRecurrenceResetter"/> — until Volar.Domain's
/// RecurrenceEngine lands, callers should either not create recurring tasks, or supply their own
/// interim implementation.</summary>
public sealed class UnsupportedRecurrenceResetter : IRecurrenceResetter
{
    public RecurrenceResetResult Reset(RecurrenceResetInput input) =>
        throw new NotSupportedException(
            "No IRecurrenceResetter was configured — recurring-task completion requires " +
            "Volar.Domain's RecurrenceEngine (not yet available). Inject a real " +
            "IRecurrenceResetter into TaskRepository once it exists.");
}
