using Volar.Core;
using Volar.Domain;

namespace Volar.Orchestrator.Tests;

/// <summary>
/// In-memory fake of <see cref="IOrchestratorTaskStore"/> for unit tests — no persistence, no
/// EF Core, just a mutable in-memory list of <see cref="TaskItem"/>.
/// </summary>
internal sealed class FakeOrchestratorTaskStore : IOrchestratorTaskStore
{
    private readonly Dictionary<Guid, TaskItem> _tasks = new();

    /// <summary>When set, <see cref="AddCondition"/> throws this instead of mutating — used to exercise the "try?"-equivalent swallow path in <see cref="DelegationTracker.Delegate"/>.</summary>
    public Exception? ThrowOnAddCondition { get; set; }

    public void AddTask(TaskItem task) => _tasks[task.Id] = task;

    public TaskItem? Get(Guid id) => _tasks.TryGetValue(id, out var task) ? task : null;

    public IReadOnlyList<TaskItem> FetchAll() => _tasks.Values.ToList();

    public void AddCondition(Condition condition, Guid taskId)
    {
        if (ThrowOnAddCondition is not null)
        {
            throw ThrowOnAddCondition;
        }
        if (!_tasks.TryGetValue(taskId, out var task))
        {
            return;
        }
        var updated = task.Conditions.Append(condition).ToList();
        task.Conditions = updated;
        _tasks[taskId] = task;
    }

    public bool ClearExternalCondition(string prefix, Guid taskId)
    {
        if (!_tasks.TryGetValue(taskId, out var task))
        {
            return false;
        }
        var conditions = task.Conditions;
        for (var i = 0; i < conditions.Count; i++)
        {
            if (conditions[i] is ExternalCondition { Satisfied: false } external
                && external.Description.StartsWith(prefix, StringComparison.Ordinal))
            {
                var updated = conditions.ToList();
                updated[i] = external with { Satisfied = true };
                task.Conditions = updated;
                _tasks[taskId] = task;
                return true;
            }
        }
        return false;
    }
}
