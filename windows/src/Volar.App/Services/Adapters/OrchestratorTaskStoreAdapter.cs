// Services/Adapters/OrchestratorTaskStoreAdapter.cs — real IOrchestratorTaskStore over
// Volar.Data.TaskRepository, replacing Stubs.StubOrchestratorTaskStore per that stub's own TODO.
//
// Sync-over-async for the same reason as ReminderTaskStoreAdapter (see that file's header):
// IOrchestratorTaskStore is frozen synchronous (DelegationTracker/AppLinkHandler are synchronous,
// UI-thread-confined types per their own doc comments), TaskRepository is async.
//
// Uses Volar.Data.Entities.TaskEntityMapping.ToTaskItem() (C2, wave3c-services.md decision 6) for
// the entity->domain projection — see ReminderTaskStoreAdapter.cs's header for why this replaced an
// earlier local fallback mapper.
using Volar.Core;
using Volar.Data;
using Volar.Data.Entities;
using Volar.Domain;
using Volar.Orchestrator;

namespace Volar.App.Services.Adapters;

public sealed class OrchestratorTaskStoreAdapter : IOrchestratorTaskStore
{
    private readonly TaskRepository _repository;

    public OrchestratorTaskStoreAdapter(TaskRepository repository)
    {
        _repository = repository ?? throw new ArgumentNullException(nameof(repository));
    }

    public IReadOnlyList<TaskItem> FetchAll() =>
        _repository.GetAllAsync().GetAwaiter().GetResult()
            .Select(TaskEntityMapping.ToTaskItem)
            .ToList();

    /// <summary>Propagates <see cref="TaskRepository.AddConditionAsync"/>'s failure modes
    /// unchanged (e.g. an invalid `.taskDone` cycle) — <see cref="IOrchestratorTaskStore.AddCondition"/>'s
    /// own doc comment says callers such as <see cref="DelegationTracker.Delegate"/> are expected to
    /// swallow this via `try`/`catch` themselves, exactly like the Swift original's `try?`; this
    /// adapter must not pre-empt that by swallowing anything itself.</summary>
    public void AddCondition(Condition condition, Guid taskId) =>
        _repository.AddConditionAsync(taskId, condition).GetAwaiter().GetResult();

    /// <summary>
    /// TaskRepository's clear-external-condition methods report newly-ELIGIBLE task ids, not a
    /// changed/unchanged bool — so "did anything change" is determined here by checking, BEFORE
    /// calling the repository, whether the task actually carries a matching unsatisfied
    /// <c>external</c> condition (the exact predicate <see cref="TaskRepository"/>'s own
    /// <c>ClearFirstExternalAsync</c> uses internally: first unsatisfied external condition, in
    /// <see cref="Data.Entities.ConditionEntity.OrderIndex"/> order, whose description starts with
    /// <paramref name="prefix"/>). If one exists, the repository call is guaranteed to flip it
    /// (it never fails once a match is found), so finding a match IS the "changed" signal; if none
    /// exists, this returns <see langword="false"/> without making the round trip at all.
    /// </summary>
    public bool ClearExternalCondition(string prefix, Guid taskId)
    {
        var all = _repository.GetAllAsync().GetAwaiter().GetResult();
        var task = all.FirstOrDefault(t => t.Id == taskId);
        if (task is null)
        {
            return false;
        }

        var hasMatch = task.Conditions
            .OrderBy(c => c.OrderIndex)
            .Any(c => c.Kind == "external"
                && c.ExternalSatisfied == false
                && c.ExternalDescription is not null
                && c.ExternalDescription.StartsWith(prefix, StringComparison.Ordinal));
        if (!hasMatch)
        {
            return false;
        }

        _repository.ClearExternalConditionAsync(prefix, taskId).GetAwaiter().GetResult();
        return true;
    }
}
