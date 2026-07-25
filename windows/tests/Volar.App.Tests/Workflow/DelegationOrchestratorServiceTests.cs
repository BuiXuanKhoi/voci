// Workflow/DelegationOrchestratorServiceTests.cs — DelegationOrchestratorService (inventory
// cluster I): DelegateTaskAsync (the seam C3's voice delegation-intent classification binds into),
// the recheck queue, ambient-card resolution (done/still-waiting/check-later), and app-link
// handling/disambiguation. Uses a REAL TaskRepository (via SqliteFixture) + OrchestratorTaskStoreAdapter
// + the real Volar.Orchestrator.DelegationTracker/AppLinkHandler so every assertion here proves this
// service's ORCHESTRATION, not a hand-simulated substitute for those sibling-owned types' own
// (separately tested) logic.
using System.Linq;
using Volar.App.Services.Adapters;
using Volar.App.Services.State;
using Volar.App.Tests.State;
using Volar.Core;
using Volar.Data;
using Volar.Data.Entities;
using Volar.Domain;
using Volar.Orchestrator;
using Xunit;

namespace Volar.App.Tests.Workflow;

public sealed class DelegationOrchestratorServiceTests
{
    private static readonly DateTimeOffset Now = new(2026, 7, 25, 9, 0, 0, TimeSpan.Zero);

    private sealed class Harness : IDisposable
    {
        public SqliteFixture Db { get; } = new();
        public TaskRepository Repository { get; }
        public OrchestratorTaskStoreAdapter Store { get; }
        public RecordingEligibilityService Eligibility { get; } = new();
        public FixedTimeProvider Clock { get; } = new(Now);
        public TaskListService TaskList { get; }
        public InMemoryDelegationMetaStore MetaStore { get; } = new();
        public DelegationTracker Tracker { get; }
        public AppLinkHandler AppLinks { get; }

        public Harness()
        {
            Repository = Db.CreateTaskRepository();
            Store = new OrchestratorTaskStoreAdapter(Repository);
            TaskList = new TaskListService(Eligibility, Clock, Repository);
            Tracker = new DelegationTracker(Store, MetaStore);
            AppLinks = new AppLinkHandler(Store, Tracker);
        }

        public async Task<Guid> AddTaskAsync(string title)
        {
            var task = TestTasks.New(title: title);
            await Repository.AddAsync(task.ToEntity());
            await TaskList.RefreshAsync();
            return task.Id;
        }

        public void Dispose() => Db.Dispose();
    }

    private static DelegationOrchestratorService MakeService(Harness h, bool wireTracker = true, bool wireAppLinks = true) =>
        new(h.TaskList, h.Eligibility, h.Clock,
            delegation: wireTracker ? h.Tracker : null,
            appLinkHandler: wireAppLinks ? h.AppLinks : null);

    // MARK: - DelegateTaskAsync — the seam C3 binds into

    [Fact]
    public async Task DelegateTaskAsync_WithNoTrackerWired_IsANoOp()
    {
        using var h = new Harness();
        var id = await h.AddTaskAsync("undelegated");
        var service = MakeService(h, wireTracker: false);

        await service.DelegateTaskAsync(id);

        Assert.Empty(service.DueDelegationRechecks);
        Assert.DoesNotContain(h.TaskList.Tasks.Single().Conditions, c => c is ExternalCondition);
    }

    [Fact]
    public async Task DelegateTaskAsync_WithNoLabel_ResolvesTheLabelFromTheTasksOwnTitle()
    {
        using var h = new Harness();
        var id = await h.AddTaskAsync("write the report");
        var service = MakeService(h);

        await service.DelegateTaskAsync(id);

        var condition = Assert.Single(h.TaskList.Tasks.Single().Conditions.OfType<ExternalCondition>());
        Assert.Equal(DelegationTracker.WaitingPrefix + "write the report", condition.Description);
        Assert.False(condition.Satisfied);
    }

    [Fact]
    public async Task DelegateTaskAsync_RefreshesTheTaskList_AndRefreshesTheRecheckQueue()
    {
        using var h = new Harness();
        var id = await h.AddTaskAsync("delegate me");
        var service = MakeService(h);

        await service.DelegateTaskAsync(id, checkBackMinutes: 5);

        // Not yet due (check-back is 5 minutes out).
        Assert.DoesNotContain(id, service.DueDelegationRechecks);

        h.Clock.Now = Now.AddMinutes(6);
        service.RefreshDelegationQueue();
        Assert.Contains(id, service.DueDelegationRechecks);
    }

    [Fact]
    public async Task DelegateTaskAsync_WithAnExplicitLabel_UsesItInstead()
    {
        using var h = new Harness();
        var id = await h.AddTaskAsync("anything");
        var service = MakeService(h);

        await service.DelegateTaskAsync(id, label: "custom label");

        var condition = Assert.Single(h.TaskList.Tasks.Single().Conditions.OfType<ExternalCondition>());
        Assert.Equal(DelegationTracker.WaitingPrefix + "custom label", condition.Description);
    }

    // MARK: - WipCount passthrough

    [Fact]
    public async Task WipCount_ReflectsTheTrackersLiveCount_AndZeroWithoutOne()
    {
        using var h = new Harness();
        var id = await h.AddTaskAsync("in flight");
        var service = MakeService(h);
        Assert.Equal(0, service.WipCount());

        await service.DelegateTaskAsync(id);
        Assert.Equal(1, service.WipCount());

        var unwired = MakeService(h, wireTracker: false);
        Assert.Equal(0, unwired.WipCount());
    }

    // MARK: - ResolveDelegationDoneAsync / StillWaiting / CheckLater

    [Fact]
    public async Task ResolveDelegationDoneAsync_CompletesTheTask_ThroughTheSharedFunnel()
    {
        using var h = new Harness();
        var id = await h.AddTaskAsync("finish this");
        var service = MakeService(h);
        await service.DelegateTaskAsync(id);

        await service.ResolveDelegationDoneAsync(id);

        Assert.Equal(TaskState.Done, h.TaskList.Tasks.Single().Status);
    }

    [Fact]
    public async Task ResolveDelegationStillWaiting_BumpsBackoffFromTenToThirtyMinutes()
    {
        using var h = new Harness();
        var id = await h.AddTaskAsync("still going");
        var service = MakeService(h);
        await service.DelegateTaskAsync(id); // default 10' check-back.

        service.ResolveDelegationStillWaiting(id, Now);

        h.Clock.Now = Now.AddMinutes(11); // past the original 10', not yet the bumped 30'.
        service.RefreshDelegationQueue();
        Assert.DoesNotContain(id, service.DueDelegationRechecks);

        h.Clock.Now = Now.AddMinutes(31); // past the bumped 30'.
        service.RefreshDelegationQueue();
        Assert.Contains(id, service.DueDelegationRechecks);
    }

    [Fact]
    public async Task ResolveDelegationCheckLater_ReDelegatesTheSameTask_WithAFreshCheckBack()
    {
        using var h = new Harness();
        var id = await h.AddTaskAsync("check on this later");
        var service = MakeService(h);
        await service.DelegateTaskAsync(id, checkBackMinutes: 10);

        service.ResolveDelegationCheckLater(id, Now, minutes: 20);

        h.Clock.Now = Now.AddMinutes(11); // past the original 10'...
        service.RefreshDelegationQueue();
        Assert.DoesNotContain(id, service.DueDelegationRechecks); // ...but not the fresh 20'.

        h.Clock.Now = Now.AddMinutes(21);
        service.RefreshDelegationQueue();
        Assert.Contains(id, service.DueDelegationRechecks);
    }

    // MARK: - ReconcileEveningBatch

    [Fact]
    public async Task ReconcileEveningBatch_MergesNonDuplicateIds_IntoDueDelegationRechecks()
    {
        using var h = new Harness();
        var id = await h.AddTaskAsync("batch-only by now");
        var service = MakeService(h);
        await service.DelegateTaskAsync(id);
        // Push past batch-only backoff (stage 2) so DueForRecheck's own cutoff excludes it, but
        // ReconcileBatch (independent of backoff stage) still surfaces it.
        h.Tracker.BumpBackoff(id, Now);
        h.Tracker.BumpBackoff(id, Now);
        service.RefreshDelegationQueue(Now.AddDays(1));
        Assert.DoesNotContain(id, service.DueDelegationRechecks);

        service.ReconcileEveningBatch();

        Assert.Contains(id, service.DueDelegationRechecks);
    }

    [Fact]
    public void ReconcileEveningBatch_WithNoTrackerWired_IsANoOp()
    {
        using var h = new Harness();
        var service = MakeService(h, wireTracker: false);

        service.ReconcileEveningBatch();

        Assert.Empty(service.DueDelegationRechecks);
    }

    // MARK: - App-link handling / disambiguation

    [Fact]
    public async Task HandleAppLinkAsync_ExactlyOneWaitingTask_ResolvesItUnambiguously()
    {
        using var h = new Harness();
        var id = await h.AddTaskAsync("the only one waiting");
        var service = MakeService(h);
        await service.DelegateTaskAsync(id);

        await service.HandleAppLinkAsync(new Uri("volar://ai-done"), Now.AddMinutes(1));

        var condition = Assert.Single(h.TaskList.Tasks.Single().Conditions.OfType<ExternalCondition>());
        Assert.True(condition.Satisfied); // MarkNeedsReview clears it — never completes the task.
        Assert.Equal(TaskState.Todo, h.TaskList.Tasks.Single().Status);
        Assert.Equal(Now.AddMinutes(1), service.LastAppLinkAt);
        Assert.Empty(service.PendingDisambiguationTaskIds);
    }

    [Fact]
    public async Task HandleAppLinkAsync_MultipleWaitingTasks_NoCwdHint_ExposesADisambiguationCard()
    {
        using var h = new Harness();
        var a = await h.AddTaskAsync("task a");
        var b = await h.AddTaskAsync("task b");
        var service = MakeService(h);
        await service.DelegateTaskAsync(a);
        await service.DelegateTaskAsync(b);

        await service.HandleAppLinkAsync(new Uri("volar://ai-done"), Now.AddMinutes(1));

        Assert.Equal(2, service.PendingDisambiguationTaskIds.Count);
        Assert.Contains(a, service.PendingDisambiguationTaskIds);
        Assert.Contains(b, service.PendingDisambiguationTaskIds);
    }

    [Fact]
    public async Task ResolveAppLinkDisambiguationAsync_ResolvesExactlyTheChosenTask_AndClearsTheCard()
    {
        using var h = new Harness();
        var a = await h.AddTaskAsync("task a");
        var b = await h.AddTaskAsync("task b");
        var service = MakeService(h);
        await service.DelegateTaskAsync(a);
        await service.DelegateTaskAsync(b);
        await service.HandleAppLinkAsync(new Uri("volar://ai-done"), Now.AddMinutes(1));
        Assert.Equal(2, service.PendingDisambiguationTaskIds.Count);

        await service.ResolveAppLinkDisambiguationAsync(a, Now.AddMinutes(2));

        Assert.Empty(service.PendingDisambiguationTaskIds);
        var aTask = h.TaskList.Tasks.Single(t => t.Id == a);
        var bTask = h.TaskList.Tasks.Single(t => t.Id == b);
        Assert.True(Assert.Single(aTask.Conditions.OfType<ExternalCondition>()).Satisfied);
        Assert.False(Assert.Single(bTask.Conditions.OfType<ExternalCondition>()).Satisfied); // untouched.
    }

    [Fact]
    public async Task DismissAppLinkDisambiguation_ClearsTheCard_WithoutTouchingAnyTask()
    {
        using var h = new Harness();
        var a = await h.AddTaskAsync("task a");
        var b = await h.AddTaskAsync("task b");
        var service = MakeService(h);
        await service.DelegateTaskAsync(a);
        await service.DelegateTaskAsync(b);
        await service.HandleAppLinkAsync(new Uri("volar://ai-done"), Now.AddMinutes(1));

        service.DismissAppLinkDisambiguation();

        Assert.Empty(service.PendingDisambiguationTaskIds);
        Assert.All(h.TaskList.Tasks, t => Assert.False(Assert.Single(t.Conditions.OfType<ExternalCondition>()).Satisfied));
    }

    [Fact]
    public async Task HandleAppLinkAsync_WithNoAppLinkHandlerWired_StillRefreshesReceiptState()
    {
        using var h = new Harness();
        await h.AddTaskAsync("irrelevant");
        var service = MakeService(h, wireAppLinks: false);

        await service.HandleAppLinkAsync(new Uri("volar://ai-done"), Now.AddMinutes(1));

        Assert.Equal(Now.AddMinutes(1), service.LastAppLinkAt);
        Assert.Empty(service.PendingDisambiguationTaskIds);
    }

    [Fact]
    public void AppLinkHandler_Passthrough_ReturnsTheWiredInstance()
    {
        using var h = new Harness();
        var service = MakeService(h);

        Assert.Same(h.AppLinks, service.AppLinkHandler);
    }
}
