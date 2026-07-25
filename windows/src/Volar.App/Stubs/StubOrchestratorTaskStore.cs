// Stubs/StubOrchestratorTaskStore.cs — minimal Wave-2 seam adapter for Volar.Orchestrator.
//
// TODO(W3-B): replace with a real adapter over Volar.Data.TaskRepository (map TaskEntity <->
// Volar.Domain.TaskItem, including Condition read/write), per IOrchestratorTaskStore.cs's own doc
// comment ("Wave 3 (App shell) is expected to implement this against Volar.Data.TaskRepository").
using System.Diagnostics;
using Volar.Core;
using Volar.Domain;
using Volar.Orchestrator;

namespace Volar.App.Stubs;

/// <summary>Empty in-memory task store — <see cref="AppLinkHandler"/>/<see cref="DelegationTracker"/>
/// resolve and can be exercised end-to-end against this fake, but nothing here is persisted yet.</summary>
public sealed class StubOrchestratorTaskStore : IOrchestratorTaskStore
{
    public IReadOnlyList<TaskItem> FetchAll() => Array.Empty<TaskItem>();

    public void AddCondition(Condition condition, Guid taskId) =>
        Debug.WriteLine($"[StubOrchestratorTaskStore] AddCondition({condition}) on {taskId} (no-op)");

    public bool ClearExternalCondition(string prefix, Guid taskId)
    {
        Debug.WriteLine($"[StubOrchestratorTaskStore] ClearExternalCondition(prefix=\"{prefix}\") on {taskId} (no-op)");
        return false;
    }
}
