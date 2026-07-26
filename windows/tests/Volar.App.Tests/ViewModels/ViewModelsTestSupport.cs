// ViewModels/ViewModelsTestSupport.cs — small shared test doubles for this folder's B3 modal VM
// tests (Triage/Sweep/MorningFrog — all backed by `TriageAndSweepService`, which itself needs an
// `IOrchestratorTaskStore` this project's other fakes don't already provide as a lightweight,
// non-SQLite double). Reuses Volar.App.Tests.State/Workflow's `FixedTimeProvider`/
// `RecordingEligibilityService`/`InMemorySettingsStore`/`FakeTaskListService`/`TestTasks` per this
// project's established "same test assembly, no cross-folder duplication" convention
// (WorkflowTestSupport.cs's own header comment).
using Volar.Core;
using Volar.Domain;
using Volar.Orchestrator;

namespace Volar.App.Tests.ViewModels;

/// <summary>Minimal in-memory <see cref="IOrchestratorTaskStore"/> — this folder's VM tests only
/// exercise <see cref="TriageAndSweepService.TriageDeferAsync"/>'s `AddCondition` call (recorded
/// here, not actually applied to any backing task — the paired `FakeTaskListService` is the source
/// of truth these VMs read through), so a full SQLite-backed
/// <see cref="Volar.App.Services.Adapters.OrchestratorTaskStoreAdapter"/> (Workflow/
/// TriageAndSweepServiceTests.cs's own choice, for exercising REAL persistence) is unnecessary
/// weight for VM-layer tests that only need "does the ViewModel forward the call and refresh."</summary>
internal sealed class FakeOrchestratorTaskStore : IOrchestratorTaskStore
{
    public List<(Condition Condition, Guid TaskId)> AddedConditions { get; } = new();

    public IReadOnlyList<TaskItem> FetchAll() => Array.Empty<TaskItem>();

    public void AddCondition(Condition condition, Guid taskId) => AddedConditions.Add((condition, taskId));

    public bool ClearExternalCondition(string prefix, Guid taskId) => false;
}
