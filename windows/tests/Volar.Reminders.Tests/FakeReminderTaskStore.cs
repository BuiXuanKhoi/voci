using Volar.Domain;
using TaskState = Volar.Core.TaskState;

namespace Volar.Reminders.Tests;

/// <summary>
/// In-memory <see cref="IReminderTaskStore"/> fake — mirrors Swift's `TaskStore(inMemory: true)`
/// fixture used by `ReminderSchedulerTests.makeScheduler()`. Deliberately minimal: enough
/// task-store behavior (fetch/toggle/sensitive) to drive `ReminderScheduler` through its full
/// public surface without any real persistence.
/// </summary>
internal sealed class FakeReminderTaskStore : IReminderTaskStore
{
    private readonly Dictionary<Guid, TaskItem> _tasks = new();
    private readonly HashSet<Guid> _sensitive = new();

    public void Add(TaskItem task) => _tasks[task.Id] = task;

    public IReadOnlyList<TaskItem> FetchAll() => _tasks.Values.ToList();

    /// <summary>Simple done/todo flip — mirrors `TaskStore.toggle(_:now:)`'s non-recurring branch.
    /// (This fake does not model recurrence reset-in-place; no test in this project needs it.)</summary>
    public void Toggle(Guid taskId, DateTimeOffset now)
    {
        if (!_tasks.TryGetValue(taskId, out var task))
        {
            return;
        }
        var nowDone = task.Status != TaskState.Done;
        task.Status = nowDone ? TaskState.Done : TaskState.Todo;
        task.CompletedAt = nowDone ? now : null;
        _tasks[taskId] = task;
    }

    public bool IsSensitive(Guid taskId) => _sensitive.Contains(taskId);

    public void MarkSensitive(Guid taskId) => _sensitive.Add(taskId);
}
