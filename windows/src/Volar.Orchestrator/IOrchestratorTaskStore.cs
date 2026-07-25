// IOrchestratorTaskStore.cs — seam for the orchestrator's read/mutate access to the app's
// persisted task store, mirroring Swift's `TaskStore` dependency
// (`AppLinkHandler.init(store: TaskStore, ...)` / `DelegationTracker.init(store: TaskStore, ...)`).
//
// Volar.Orchestrator cannot reference Volar.Data (EF Core) directly per this project's dependency
// rules (Orchestrator -> Domain + Core only), so Wave 3 (App shell) is expected to implement this
// against `Volar.Data.TaskRepository` + map `Volar.Data.Entities.TaskEntity` ->
// `Volar.Domain.TaskItem` — the same seam pattern `Volar.Reminders/IReminderTaskStore.cs` already
// uses for the identical problem in a sibling project.
using Volar.Core;
using Volar.Domain;

namespace Volar.Orchestrator;

/// <summary>
/// The subset of Swift's `TaskStore` public surface that `AppLinkHandler` and
/// `DelegationTracker` actually call. Both types are constructed against the same store instance
/// (mirroring the Swift originals' shared `TaskStore` dependency).
/// </summary>
public interface IOrchestratorTaskStore
{
    /// <summary>All persisted tasks, freshly read (mirrors `TaskStore.fetchAll()`).</summary>
    IReadOnlyList<TaskItem> FetchAll();

    /// <summary>
    /// Appends <paramref name="condition"/> to the task's condition list (mirrors
    /// `TaskStore.addCondition(_:to:) throws`). May throw; `DelegationTracker.Delegate` calls this
    /// the same way the Swift original does — via `try?` — swallowing any failure, since a
    /// delegation call is best-effort and must never crash the caller.
    /// </summary>
    void AddCondition(Condition condition, Guid taskId);

    /// <summary>
    /// Flips the first unsatisfied `ExternalCondition` on the task whose description starts with
    /// <paramref name="prefix"/> to satisfied (mirrors
    /// `TaskStore.clearExternalCondition(withPrefix:on:)`). Returns whether anything was actually
    /// changed; a no-op (no matching condition) returns <see langword="false"/>. NEVER touches
    /// <see cref="TaskItem.Status"/> — satisfying a condition only makes a task eligible again, it
    /// does not complete it (Constitution II).
    /// </summary>
    bool ClearExternalCondition(string prefix, Guid taskId);
}
