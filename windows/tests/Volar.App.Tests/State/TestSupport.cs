// State/TestSupport.cs — small shared test doubles/builders for this folder's TaskListService and
// EligibilityAndResurfaceService tests, mirroring the "Fixtures.cs" convention already established
// in Volar.Data.Tests/Volar.Reminders.Tests.
using Volar.App.Services;
using Volar.Core;
using Volar.Data;
using Volar.Domain;
using Volar.Reminders;
using TaskState = Volar.Core.TaskState;

namespace Volar.App.Tests.State;

/// <summary>Fixed-instant <see cref="ITimeProvider"/> — every C2 test injects this instead of
/// letting a service read the wall clock, per the wave-wide "no DateTimeOffset.Now/UtcNow inside any
/// service" rule.</summary>
internal sealed class FixedTimeProvider(DateTimeOffset now) : ITimeProvider
{
    public DateTimeOffset Now { get; set; } = now;
}

/// <summary>Records every call <see cref="TaskListService"/> makes into the eligibility tail, so
/// tests can assert on exactly what before/after snapshot it was given without depending on the
/// real <see cref="Volar.App.Services.State.EligibilityAndResurfaceService"/>'s own (separately
/// tested) FIX 2 chaining logic.</summary>
internal sealed class RecordingEligibilityService : IEligibilityAndResurfaceService
{
    public List<(IReadOnlyList<TaskItem> Before, IReadOnlyList<TaskItem> After)> Calls { get; } = [];

    public int RearmCallCount { get; private set; }

    public Task NotifyEligibilityAndScheduleResurfaceAsync(IReadOnlyList<TaskItem> before, IReadOnlyList<TaskItem> after)
    {
        Calls.Add((before, after));
        return Task.CompletedTask;
    }

    public Task RearmAsync()
    {
        RearmCallCount++;
        return Task.CompletedTask;
    }
}

/// <summary>Minimal <see cref="IReminderTaskStore"/> fake so a real <see cref="ReminderScheduler"/>
/// can be constructed for the one TaskListService test that verifies the schedule/cancel wiring
/// (Volar.Reminders.Tests' own equivalent fake is `internal` to that assembly and this project has
/// no `InternalsVisibleTo` into it, so this is a small local duplicate, same rationale as
/// SqliteFixture.cs).</summary>
internal sealed class LocalFakeReminderTaskStore : IReminderTaskStore
{
    private readonly Dictionary<Guid, TaskItem> _tasks = [];

    public void Set(TaskItem task) => _tasks[task.Id] = task;

    public IReadOnlyList<TaskItem> FetchAll() => _tasks.Values.ToList();

    public void Toggle(Guid taskId, DateTimeOffset now)
    {
        if (!_tasks.TryGetValue(taskId, out var task))
        {
            return;
        }
        task.Status = task.Status == TaskState.Done ? TaskState.Todo : TaskState.Done;
        _tasks[taskId] = task;
    }

    public bool IsSensitive(Guid taskId) => false;
}

/// <summary>Minimal <see cref="IToastChannel"/> fake — records nothing beyond what
/// <see cref="ReminderScheduler"/> needs to run without throwing.</summary>
internal sealed class LocalFakeToastChannel : IToastChannel
{
    private readonly HashSet<Guid> _pending = [];

    public void DeliverNow(ReminderDelivery delivery) => _pending.Remove(delivery.RecordId);

    public void Schedule(ReminderDelivery delivery, DateTimeOffset fireAt) => _pending.Add(delivery.RecordId);

    public void Speak(string text) { }

    public void CancelPending(IReadOnlyList<Guid> recordIds)
    {
        foreach (var id in recordIds)
        {
            _pending.Remove(id);
        }
    }

    public IReadOnlyList<Guid> GetPendingIds() => _pending.ToList();

    public IReadOnlyList<Guid> GetDeliveredIds() => [];
}

/// <summary>Deterministic <see cref="IRecurrenceResetter"/> — always reopens with the deadline
/// pushed forward by a fixed offset and clears conditions, so FIX 3's sibling-trap test can assert
/// on an exact result without a real recurrence-rule engine. Local duplicate of
/// Volar.Data.Tests/Fixtures.cs's `FixedOffsetRecurrenceResetter` (that one is `internal` to a
/// project this one doesn't own).</summary>
internal sealed class LocalFixedOffsetRecurrenceResetter(TimeSpan offset) : IRecurrenceResetter
{
    public int CallCount { get; private set; }

    public RecurrenceResetResult Reset(RecurrenceResetInput input)
    {
        CallCount++;
        var nextDeadline = input.Deadline is { } deadline ? deadline + offset : (DateTimeOffset?)null;
        return new RecurrenceResetResult(nextDeadline, []);
    }
}

internal static class TestTasks
{
    /// <summary>Builds a minimal, valid <see cref="TaskItem"/> — every field a test doesn't care
    /// about gets an explicit, deterministic default (never <see cref="DateTimeOffset.UtcNow"/>).</summary>
    internal static TaskItem New(
        string title = "Task",
        Priority priority = Priority.Medium,
        When when = When.Now,
        DateTimeOffset? createdAt = null,
        TaskState status = TaskState.Todo,
        DateTimeOffset? deadline = null,
        IReadOnlyList<Condition>? conditions = null,
        bool frog = false,
        Guid? id = null,
        Guid? parentId = null,
        Recurrence? recurrence = null) => new(
            id: id ?? Guid.NewGuid(),
            title: title,
            priority: priority,
            when: when,
            createdAt: createdAt ?? new DateTimeOffset(2026, 7, 25, 9, 0, 0, TimeSpan.Zero),
            status: status,
            deadline: deadline,
            conditions: conditions,
            frog: frog,
            parentId: parentId,
            recurrence: recurrence);
}
