// Fixtures.cs — small shared builders so individual test methods stay focused on the behavior
// under test rather than on constructing valid TaskEntity graphs by hand every time.
using Volar.Core;
using Volar.Data.Entities;

namespace Volar.Data.Tests;

internal static class Fixtures
{
    internal static TaskEntity NewTask(
        string title = "Task",
        TaskState status = TaskState.Todo,
        int priority = 3,
        DateTimeOffset? deadline = null,
        DateTimeOffset? createdAt = null,
        Guid? parentId = null,
        bool frog = false,
        string? recurrenceJson = null,
        bool isSensitive = false,
        IReadOnlyList<Condition>? conditions = null)
    {
        var id = Guid.NewGuid();
        var entity = new TaskEntity
        {
            Id = id,
            Title = title,
            PriorityRaw = priority,
            Deadline = deadline,
            CreatedAt = createdAt ?? DateTimeOffset.UtcNow,
            ParentId = parentId,
            Frog = frog,
            RecurrenceJson = recurrenceJson,
            IsSensitive = isSensitive,
        };
        entity.Status = status;

        if (conditions is not null)
        {
            var index = 0;
            foreach (var condition in conditions)
            {
                entity.Conditions.Add(condition.ToEntity(id, index));
                index++;
            }
        }

        return entity;
    }
}

/// <summary>
/// A trivial, deterministic <see cref="IRecurrenceResetter"/> for tests: always reopens with the
/// deadline pushed forward by a fixed number of days and clears all conditions, so tests can assert
/// on an exact, predictable result without needing a real recurrence-rule engine (which belongs to
/// Volar.Domain and does not exist yet — see IRecurrenceResetter.cs's header comment).
/// </summary>
internal sealed class FixedOffsetRecurrenceResetter(TimeSpan offset) : IRecurrenceResetter
{
    public int CallCount { get; private set; }

    public RecurrenceResetResult Reset(RecurrenceResetInput input)
    {
        CallCount++;
        var nextDeadline = input.Deadline is { } deadline ? deadline + offset : (DateTimeOffset?)null;
        return new RecurrenceResetResult(nextDeadline, []);
    }
}

/// <summary>
/// Like <see cref="FixedOffsetRecurrenceResetter"/>, but returns a caller-supplied, non-empty
/// <see cref="RecurrenceResetResult.Conditions"/> list instead of always clearing to <c>[]</c>.
///
/// EXISTS FOR REGRESSION COVERAGE: <see cref="FixedOffsetRecurrenceResetter"/> always returns an
/// empty conditions list, so it can never exercise TaskRepository.CompleteOne's
/// "write the reset's new conditions back onto the tracked task" branch — the exact branch that
/// used to hit the "Modified vs Added" EF Core footgun documented on CompleteOne (a client-keyed
/// entity appended via `task.Conditions.Add(...)` on an already-tracked parent gets marked Modified
/// instead of Added, producing a DbUpdateConcurrencyException instead of an INSERT). Deliberately a
/// separate class rather than extending FixedOffsetRecurrenceResetter's behavior, since several
/// other tests depend on that fixture's "always empty" default and must not change.
/// </summary>
internal sealed class ConditionsRecurrenceResetter(TimeSpan offset, IReadOnlyList<Condition> conditions) : IRecurrenceResetter
{
    public int CallCount { get; private set; }

    public RecurrenceResetResult Reset(RecurrenceResetInput input)
    {
        CallCount++;
        var nextDeadline = input.Deadline is { } deadline ? deadline + offset : (DateTimeOffset?)null;
        return new RecurrenceResetResult(nextDeadline, conditions);
    }
}
