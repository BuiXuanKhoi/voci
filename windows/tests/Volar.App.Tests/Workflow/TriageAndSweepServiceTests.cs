// Workflow/TriageAndSweepServiceTests.cs — TriageAndSweepService (inventory cluster H): weekly
// stale-task triage (keep/breakdown/defer/drop) and the evening sweep, plus the
// MaybeShowEveningSweep/MaybeShowTriage/MaybeShowMorningFrog gate methods (Opus decision 4). Uses a
// REAL TaskRepository (via SqliteFixture) + OrchestratorTaskStoreAdapter so TriageDeferAsync's
// AddCondition round-trips through genuine persistence, mirroring TaskListServiceTests' own FIX-3
// convention for this file's own store-backed mutations.
using System.Linq;
using Volar.App.Services.Adapters;
using Volar.App.Services.State;
using Volar.App.Tests.State;
using Volar.Core;
using Volar.Data;
using Volar.Data.Entities;
using Volar.Domain;
using Xunit;

namespace Volar.App.Tests.Workflow;

public sealed class TriageAndSweepServiceTests
{
    private static readonly DateTimeOffset Now = new(2026, 7, 25, 9, 0, 0, TimeSpan.Zero);

    private static (TaskListService TaskList, OrchestratorTaskStoreAdapter Orchestrator, RecordingEligibilityService Eligibility, FixedTimeProvider Clock)
        MakeHarness(SqliteFixture db)
    {
        var repository = db.CreateTaskRepository();
        var eligibility = new RecordingEligibilityService();
        var clock = new FixedTimeProvider(Now);
        var taskList = new TaskListService(eligibility, clock, repository);
        var orchestrator = new OrchestratorTaskStoreAdapter(repository);
        return (taskList, orchestrator, eligibility, clock);
    }

    private static TriageAndSweepService MakeService(
        TaskListService taskList,
        OrchestratorTaskStoreAdapter orchestrator,
        RecordingEligibilityService eligibility,
        FixedTimeProvider clock,
        Volar.Domain.ISettingsStore? settings = null,
        DelegationOrchestratorService? delegationOrchestrator = null) =>
        new(taskList, orchestrator, eligibility, settings ?? new InMemorySettingsStore(), clock,
            delegationOrchestrator: delegationOrchestrator, timeZone: TimeZoneInfo.Utc);

    // MARK: - StaleTasks

    [Fact]
    public async Task StaleTasks_IncludesOnlyOpenTasksOlderThanTheThreshold()
    {
        using var db = new SqliteFixture();
        var (taskList, orchestrator, eligibility, clock) = MakeHarness(db);
        var service = MakeService(taskList, orchestrator, eligibility, clock);

        var old = TestTasks.New(title: "old", createdAt: Now - TimeSpan.FromDays(10));
        var fresh = TestTasks.New(title: "fresh", createdAt: Now - TimeSpan.FromDays(1));
        var repository = db.CreateTaskRepository();
        await repository.AddAsync(old.ToEntity());
        await repository.AddAsync(fresh.ToEntity());
        await taskList.RefreshAsync();

        var stale = service.StaleTasks(Now);

        Assert.Single(stale);
        Assert.Equal("old", stale[0].Title);
    }

    [Fact]
    public async Task TriageKeep_ResetsTheStalenessClock_SoTheTaskDropsOutOfNextWeeksBatch()
    {
        using var db = new SqliteFixture();
        var (taskList, orchestrator, eligibility, clock) = MakeHarness(db);
        var settings = new InMemorySettingsStore();
        var service = MakeService(taskList, orchestrator, eligibility, clock, settings);

        var old = TestTasks.New(title: "old", createdAt: Now - TimeSpan.FromDays(10));
        var repository = db.CreateTaskRepository();
        await repository.AddAsync(old.ToEntity());
        await taskList.RefreshAsync();
        var item = taskList.Tasks.Single();
        Assert.Single(service.StaleTasks(Now));

        service.TriageKeep(item);

        Assert.Empty(service.StaleTasks(Now));

        // Persists — a fresh instance sharing the same settings store must see the same "kept" state.
        var second = MakeService(taskList, orchestrator, eligibility, clock, settings);
        Assert.Empty(second.StaleTasks(Now));
    }

    [Fact]
    public async Task TriageBreakdown_RaisesBreakdownRequestedWithTheGivenItem()
    {
        using var db = new SqliteFixture();
        var (taskList, orchestrator, eligibility, clock) = MakeHarness(db);
        var service = MakeService(taskList, orchestrator, eligibility, clock);
        var repository = db.CreateTaskRepository();
        var task = TestTasks.New(title: "break this down");
        await repository.AddAsync(task.ToEntity());
        await taskList.RefreshAsync();
        var item = taskList.Tasks.Single();

        TaskItem? received = null;
        service.BreakdownRequested += t => received = t;

        service.TriageBreakdown(item);

        Assert.NotNull(received);
        Assert.Equal(item.Id, received!.Value.Id);
    }

    [Fact]
    public async Task TriageDeferAsync_AddsAnAfterDateConditionThreeDaysOut_AndRunsTheEligibilityTail()
    {
        using var db = new SqliteFixture();
        var (taskList, orchestrator, eligibility, clock) = MakeHarness(db);
        var service = MakeService(taskList, orchestrator, eligibility, clock);
        var repository = db.CreateTaskRepository();
        var task = TestTasks.New(title: "defer me");
        await repository.AddAsync(task.ToEntity());
        await taskList.RefreshAsync();
        var item = taskList.Tasks.Single();

        await service.TriageDeferAsync(item);

        var reloaded = taskList.Tasks.Single();
        var afterDate = Assert.Single(reloaded.Conditions.OfType<AfterDateCondition>());
        Assert.Equal(Now + TimeSpan.FromDays(3), afterDate.Date);
        Assert.Single(eligibility.Calls); // the shared tail ran exactly once.
    }

    [Fact]
    public async Task TriageDropAsync_DeletesTheTask_AndClosesTheTriageSheetOnceItsBatchEmpties()
    {
        using var db = new SqliteFixture();
        var (taskList, orchestrator, eligibility, clock) = MakeHarness(db);
        var settings = new InMemorySettingsStore();
        var service = MakeService(taskList, orchestrator, eligibility, clock, settings);
        var repository = db.CreateTaskRepository();
        var stale = TestTasks.New(title: "stale", createdAt: Now - TimeSpan.FromDays(10));
        await repository.AddAsync(stale.ToEntity());
        await taskList.RefreshAsync();
        service.MaybeShowTriage(Now);
        Assert.True(service.ShowTriage);
        var item = taskList.Tasks.Single();

        await service.TriageDropAsync(item);

        Assert.Empty(taskList.Tasks);
        Assert.False(service.ShowTriage); // batch emptied -> sheet auto-closes.
    }

    // MARK: - Evening sweep

    [Fact]
    public async Task MaybeShowEveningSweep_ShowsOnceAndOnlyOncePerDay_WhenThereAreOpenTasks()
    {
        using var db = new SqliteFixture();
        var (taskList, orchestrator, eligibility, clock) = MakeHarness(db);
        var settings = new InMemorySettingsStore();
        var service = MakeService(taskList, orchestrator, eligibility, clock, settings);
        var repository = db.CreateTaskRepository();
        await repository.AddAsync(TestTasks.New(title: "today").ToEntity());
        await taskList.RefreshAsync();

        service.MaybeShowEveningSweep(Now);
        Assert.True(service.ShowSweep);

        service.DismissSweep();
        service.MaybeShowEveningSweep(Now.AddHours(1)); // same day, later.
        Assert.False(service.ShowSweep); // already shown today -> gated.

        service.MaybeShowEveningSweep(Now.AddDays(1)); // next day.
        Assert.True(service.ShowSweep);
    }

    [Fact]
    public void MaybeShowEveningSweep_NeverShows_WhenThereAreNoOpenTasks()
    {
        using var db = new SqliteFixture();
        var (taskList, orchestrator, eligibility, clock) = MakeHarness(db);
        var service = MakeService(taskList, orchestrator, eligibility, clock);

        service.MaybeShowEveningSweep(Now);

        Assert.False(service.ShowSweep);
    }

    [Fact]
    public async Task MaybeShowEveningSweep_ReconcilesTheDelegationBatch_WhenAnOrchestratorIsWired()
    {
        using var db = new SqliteFixture();
        var (taskList, orchestrator, eligibility, clock) = MakeHarness(db);
        var repository = db.CreateTaskRepository();
        var metaStore = new Volar.Orchestrator.InMemoryDelegationMetaStore();
        var tracker = new Volar.Orchestrator.DelegationTracker(orchestrator, metaStore);
        var delegationOrchestrator = new DelegationOrchestratorService(taskList, eligibility, clock, tracker);

        var task = TestTasks.New(title: "delegated");
        await repository.AddAsync(task.ToEntity());
        await taskList.RefreshAsync();
        var id = taskList.Tasks.Single().Id;
        tracker.Delegate(id, "Claude", Now, cwdHint: null);

        var service = MakeService(taskList, orchestrator, eligibility, clock, delegationOrchestrator: delegationOrchestrator);
        service.MaybeShowEveningSweep(Now);

        Assert.Contains(id, delegationOrchestrator.DueDelegationRechecks);
    }

    [Fact]
    public async Task SweepItems_IsOpenTasks_IncludingTheLaterBucket()
    {
        // MINORS fix parity: sweepItems must be openTasks (now + later), never nowTasks alone.
        using var db = new SqliteFixture();
        var (taskList, orchestrator, eligibility, clock) = MakeHarness(db);
        var service = MakeService(taskList, orchestrator, eligibility, clock);
        var repository = db.CreateTaskRepository();
        await repository.AddAsync(TestTasks.New(title: "now", when: When.Now).ToEntity());
        await repository.AddAsync(TestTasks.New(title: "later", when: When.Later).ToEntity());
        await taskList.RefreshAsync();

        Assert.Equal(2, service.SweepItems.Count);
    }

    [Fact]
    public async Task SweepCompleteAsync_TogglesDone_AndClosesTheSweepSheetOnceItsBatchEmpties()
    {
        using var db = new SqliteFixture();
        var (taskList, orchestrator, eligibility, clock) = MakeHarness(db);
        var service = MakeService(taskList, orchestrator, eligibility, clock);
        var repository = db.CreateTaskRepository();
        await repository.AddAsync(TestTasks.New(title: "only").ToEntity());
        await taskList.RefreshAsync();
        service.MaybeShowEveningSweep(Now);
        Assert.True(service.ShowSweep);
        var item = taskList.Tasks.Single();

        await service.SweepCompleteAsync(item);

        Assert.Equal(TaskState.Done, taskList.Tasks.Single().Status);
        Assert.False(service.ShowSweep);
    }

    [Fact]
    public void SweepSkip_IsANoOp_AndNeverThrows()
    {
        var service = new TriageAndSweepService(
            new FakeTaskListService(), new NoOpOrchestratorTaskStore(), new RecordingEligibilityService(),
            new InMemorySettingsStore(), new FixedTimeProvider(Now));

        service.SweepSkip(TestTasks.New(title: "skip me"));

        Assert.False(service.ShowSweep);
    }

    // MARK: - Morning frog gate

    [Fact]
    public void MaybeShowMorningFrog_ShowsOncePerDay_OnlyWhenThereAreOpenTasks()
    {
        var settings = new InMemorySettingsStore();
        var taskList = new FakeTaskListService(new[] { TestTasks.New(title: "a") });
        var service = new TriageAndSweepService(
            taskList, new NoOpOrchestratorTaskStore(), new RecordingEligibilityService(), settings, new FixedTimeProvider(Now));

        service.MaybeShowMorningFrog(Now);
        Assert.True(service.ShowMorningFrog);

        service.DismissMorningFrog();
        service.MaybeShowMorningFrog(Now.AddHours(2));
        Assert.False(service.ShowMorningFrog); // already shown today.

        service.MaybeShowMorningFrog(Now.AddDays(1));
        Assert.True(service.ShowMorningFrog);
    }

    [Fact]
    public void MaybeShowMorningFrog_NeverShows_WhenThereAreNoOpenTasks()
    {
        var service = new TriageAndSweepService(
            new FakeTaskListService(), new NoOpOrchestratorTaskStore(), new RecordingEligibilityService(),
            new InMemorySettingsStore(), new FixedTimeProvider(Now));

        service.MaybeShowMorningFrog(Now);

        Assert.False(service.ShowMorningFrog);
    }

    [Fact]
    public async Task PickFrogAsync_SetsTheFrog_AndDismissesTheSheet()
    {
        using var db = new SqliteFixture();
        var (taskList, orchestrator, eligibility, clock) = MakeHarness(db);
        var service = MakeService(taskList, orchestrator, eligibility, clock);
        var repository = db.CreateTaskRepository();
        await repository.AddAsync(TestTasks.New(title: "pick me").ToEntity());
        await taskList.RefreshAsync();
        var id = taskList.Tasks.Single().Id;
        service.MaybeShowMorningFrog(Now);

        await service.PickFrogAsync(id);

        Assert.True(taskList.Tasks.Single().Frog);
        Assert.False(service.ShowMorningFrog);
    }

    // MARK: - MaybeShowTriage (ISO-week gate)

    [Fact]
    public async Task MaybeShowTriage_ShowsOncePerIsoWeek_WhenThereAreStaleTasks()
    {
        using var db = new SqliteFixture();
        var (taskList, orchestrator, eligibility, clock) = MakeHarness(db);
        var settings = new InMemorySettingsStore();
        var service = MakeService(taskList, orchestrator, eligibility, clock, settings);
        var repository = db.CreateTaskRepository();
        await repository.AddAsync(TestTasks.New(title: "stale", createdAt: Now - TimeSpan.FromDays(10)).ToEntity());
        await taskList.RefreshAsync();

        // 2026-07-25 is a Saturday in ISO week 2026-W30.
        service.MaybeShowTriage(Now);
        Assert.True(service.ShowTriage);

        service.DismissTriage(); // simulate the shell dismissing it, same week.
        service.MaybeShowTriage(Now.AddDays(1)); // Sunday, same ISO week.
        Assert.False(service.ShowTriage);

        service.MaybeShowTriage(Now.AddDays(3)); // following Tuesday -> a NEW ISO week.
        Assert.True(service.ShowTriage);
    }

    [Fact]
    public void MaybeShowTriage_NeverShows_WhenThereAreNoStaleTasks()
    {
        using var db = new SqliteFixture();
        var (taskList, orchestrator, eligibility, clock) = MakeHarness(db);
        var service = MakeService(taskList, orchestrator, eligibility, clock);

        service.MaybeShowTriage(Now);

        Assert.False(service.ShowTriage);
    }

    /// <summary>Minimal no-op <see cref="Volar.Orchestrator.IOrchestratorTaskStore"/> for the tests
    /// above that never mutate through it (morning-frog gating, sweep-skip) — avoids spinning up a
    /// real <see cref="SqliteFixture"/> where it adds nothing.</summary>
    private sealed class NoOpOrchestratorTaskStore : Volar.Orchestrator.IOrchestratorTaskStore
    {
        public IReadOnlyList<TaskItem> FetchAll() => Array.Empty<TaskItem>();
        public void AddCondition(Condition condition, Guid taskId) { }
        public bool ClearExternalCondition(string prefix, Guid taskId) => false;
    }
}
