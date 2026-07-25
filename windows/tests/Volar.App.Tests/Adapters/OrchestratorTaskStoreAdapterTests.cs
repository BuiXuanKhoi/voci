// OrchestratorTaskStoreAdapterTests.cs — exercises the adapter against a REAL, temp-file-backed
// SQLite TaskRepository (Volar.App.Tests.State.SqliteFixture), plus one test constructing a real
// DelegationTracker on top of it to prove the adapter satisfies that consumer end-to-end, not just
// IOrchestratorTaskStore's shape in isolation.
using Volar.App.Services.Adapters;
using Volar.App.Tests.State;
using Volar.Core;
using Volar.Data.Entities;
using Volar.Data.Exceptions;
using Volar.Orchestrator;
using Xunit;

namespace Volar.App.Tests.Adapters;

public sealed class OrchestratorTaskStoreAdapterTests : IDisposable
{
    private readonly SqliteFixture _fixture = new();

    private static TaskEntity NewEntity(string title = "Ship the feature") => new()
    {
        Id = Guid.NewGuid(),
        Title = title,
        PriorityRaw = 2,
        CreatedAt = new DateTimeOffset(2026, 7, 25, 8, 0, 0, TimeSpan.Zero),
    };

    [Fact]
    public async Task FetchAll_ProjectsPersistedRows()
    {
        var repository = _fixture.CreateTaskRepository();
        var entity = NewEntity();
        await repository.AddAsync(entity);
        var adapter = new OrchestratorTaskStoreAdapter(repository);

        var all = adapter.FetchAll();

        Assert.Contains(all, t => t.Id == entity.Id && t.Title == "Ship the feature");
    }

    [Fact]
    public async Task AddCondition_PersistsAnExternalCondition()
    {
        var repository = _fixture.CreateTaskRepository();
        var entity = NewEntity();
        await repository.AddAsync(entity);
        var adapter = new OrchestratorTaskStoreAdapter(repository);

        adapter.AddCondition(new ExternalCondition("waiting on AI: fix the bug", false), entity.Id);

        var task = adapter.FetchAll().Single(t => t.Id == entity.Id);
        Assert.Contains(task.Conditions, c => c is ExternalCondition { Satisfied: false } e && e.Description == "waiting on AI: fix the bug");
    }

    [Fact]
    public void AddCondition_UnknownTaskId_IsANoOp_MirrorsTaskRepository()
    {
        var adapter = new OrchestratorTaskStoreAdapter(_fixture.CreateTaskRepository());

        adapter.AddCondition(new ExternalCondition("waiting on AI: x", false), Guid.NewGuid()); // must not throw
    }

    [Fact]
    public async Task AddCondition_PropagatesFailure_ForASelfReferencingTaskDoneCondition()
    {
        // IOrchestratorTaskStore.AddCondition's own doc comment: this adapter must NOT swallow a
        // validation failure itself — DelegationTracker.Delegate is the one documented to catch it.
        var repository = _fixture.CreateTaskRepository();
        var entity = NewEntity();
        await repository.AddAsync(entity);
        var adapter = new OrchestratorTaskStoreAdapter(repository);

        Assert.Throws<InvalidConditionException>(() =>
            adapter.AddCondition(new TaskDoneCondition(entity.Id), entity.Id));
    }

    [Fact]
    public async Task ClearExternalCondition_ReturnsFalse_WhenNothingMatches()
    {
        var repository = _fixture.CreateTaskRepository();
        var entity = NewEntity();
        await repository.AddAsync(entity);
        var adapter = new OrchestratorTaskStoreAdapter(repository);

        var changed = adapter.ClearExternalCondition("waiting on AI: ", entity.Id);

        Assert.False(changed);
    }

    [Fact]
    public void ClearExternalCondition_ReturnsFalse_ForUnknownTaskId()
    {
        var adapter = new OrchestratorTaskStoreAdapter(_fixture.CreateTaskRepository());

        Assert.False(adapter.ClearExternalCondition("waiting on AI: ", Guid.NewGuid()));
    }

    [Fact]
    public async Task ClearExternalCondition_ReturnsTrue_AndFlipsTheMatchingCondition()
    {
        var repository = _fixture.CreateTaskRepository();
        var entity = NewEntity();
        await repository.AddAsync(entity);
        var adapter = new OrchestratorTaskStoreAdapter(repository);
        adapter.AddCondition(new ExternalCondition("waiting on AI: fix the bug", false), entity.Id);

        var changed = adapter.ClearExternalCondition("waiting on AI: ", entity.Id);

        Assert.True(changed);
        var task = adapter.FetchAll().Single(t => t.Id == entity.Id);
        Assert.Contains(task.Conditions, c => c is ExternalCondition { Satisfied: true });
    }

    [Fact]
    public async Task ClearExternalCondition_ScopedToPrefix_DoesNotFlipAnUnrelatedHumanGate()
    {
        var repository = _fixture.CreateTaskRepository();
        var entity = NewEntity();
        await repository.AddAsync(entity);
        var adapter = new OrchestratorTaskStoreAdapter(repository);
        adapter.AddCondition(new ExternalCondition("waiting on legal", false), entity.Id);

        var changed = adapter.ClearExternalCondition("waiting on AI: ", entity.Id);

        Assert.False(changed);
        var task = adapter.FetchAll().Single(t => t.Id == entity.Id);
        Assert.Contains(task.Conditions, c => c is ExternalCondition { Satisfied: false, Description: "waiting on legal" });
    }

    [Fact]
    public async Task WorksEndToEnd_WithARealDelegationTracker()
    {
        var repository = _fixture.CreateTaskRepository();
        var entity = NewEntity();
        await repository.AddAsync(entity);
        var adapter = new OrchestratorTaskStoreAdapter(repository);
        var tracker = new DelegationTracker(adapter);
        var now = new DateTimeOffset(2026, 7, 25, 9, 0, 0, TimeSpan.Zero);

        tracker.Delegate(entity.Id, "fix the bug", now, cwdHint: "/repo");

        Assert.Equal(1, tracker.WipCount());
        tracker.MarkNeedsReview(entity.Id);
        Assert.Equal(0, tracker.WipCount());
    }

    public void Dispose() => _fixture.Dispose();
}
