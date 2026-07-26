// ViewModels/TriageViewModelTests.cs — TriageViewModel (Wave 4 Stage B3), backed by a real
// TriageAndSweepService over fakes (FakeTaskListService/FakeOrchestratorTaskStore/
// RecordingEligibilityService/InMemorySettingsStore/FixedTimeProvider — all reused from this
// project's existing Workflow/State test support, per this folder's own ViewModelsTestSupport.cs
// header note).
using Volar.App.Services.State;
using Volar.App.Tests.State;
using Volar.App.Tests.Workflow;
using Volar.App.ViewModels;
using Volar.Domain;
using Xunit;

namespace Volar.App.Tests.ViewModels;

public sealed class TriageViewModelTests
{
    private static readonly DateTimeOffset Now = new(2026, 7, 26, 9, 0, 0, TimeSpan.Zero);

    private static (TriageViewModel Vm, TriageAndSweepService Service, FakeTaskListService TaskList) MakeHarness(
        IEnumerable<TaskItem>? tasks = null)
    {
        var taskList = new FakeTaskListService(tasks);
        var clock = new FixedTimeProvider(Now);
        var service = new TriageAndSweepService(
            taskList,
            new FakeOrchestratorTaskStore(),
            new RecordingEligibilityService(),
            new InMemorySettingsStore(),
            clock,
            timeZone: TimeZoneInfo.Utc);
        var vm = new TriageViewModel(service, taskList, clock);
        return (vm, service, taskList);
    }

    [Fact]
    public void Refresh_ReflectsShowTriage_AndTheStaleTaskSet()
    {
        var old = TestTasks.New(title: "stale", createdAt: Now - TimeSpan.FromDays(10));
        var (vm, _, _) = MakeHarness(new[] { old });

        Assert.False(vm.IsVisible); // ShowTriage starts false — nobody called MaybeShowTriage yet.
        Assert.Single(vm.Items);
        Assert.Equal("1 task", vm.FooterCountText);
    }

    [Fact]
    public void Refresh_AfterMaybeShowTriage_BecomesVisible()
    {
        var old = TestTasks.New(title: "stale", createdAt: Now - TimeSpan.FromDays(10));
        var (vm, service, _) = MakeHarness(new[] { old });

        service.MaybeShowTriage(Now);
        vm.Refresh(); // Stage C's own contract — MaybeShowTriage raises no event, see VM header.

        Assert.True(vm.IsVisible);
    }

    [Fact]
    public void KeepCommand_RemovesTheItemFromTheNextStaleBatch()
    {
        var old = TestTasks.New(title: "stale", createdAt: Now - TimeSpan.FromDays(10));
        var (vm, _, taskList) = MakeHarness(new[] { old });
        Assert.Single(vm.Items);

        vm.KeepCommand.Execute(taskList.Tasks[0]);

        Assert.Empty(vm.Items);
        Assert.Equal("0 tasks", vm.FooterCountText);
    }

    [Fact]
    public void BreakdownCommand_RaisesBreakdownRequestedOnTheService()
    {
        var old = TestTasks.New(title: "stale", createdAt: Now - TimeSpan.FromDays(10));
        var (vm, service, taskList) = MakeHarness(new[] { old });
        TaskItem? received = null;
        service.BreakdownRequested += t => received = t;

        vm.BreakdownCommand.Execute(taskList.Tasks[0]);

        Assert.NotNull(received);
        Assert.Equal(old.Id, received!.Value.Id);
    }

    [Fact]
    public async Task DropCommand_DeletesTheTaskThroughTheSharedTaskList()
    {
        var old = TestTasks.New(title: "stale", createdAt: Now - TimeSpan.FromDays(10));
        var (vm, _, taskList) = MakeHarness(new[] { old });

        vm.DropCommand.Execute(taskList.Tasks[0]);
        await AsyncPoll.WaitUntilAsync(() => taskList.Tasks.Count == 0);

        Assert.Empty(taskList.Tasks);
        Assert.Empty(vm.Items);
    }

    [Fact]
    public async Task DeferCommand_AddsAnAfterDateConditionViaTheOrchestratorStore()
    {
        var old = TestTasks.New(title: "stale", createdAt: Now - TimeSpan.FromDays(10));
        var taskList = new FakeTaskListService(new[] { old });
        var clock = new FixedTimeProvider(Now);
        var orchestrator = new FakeOrchestratorTaskStore();
        var service = new TriageAndSweepService(
            taskList, orchestrator, new RecordingEligibilityService(), new InMemorySettingsStore(), clock, timeZone: TimeZoneInfo.Utc);
        var vm = new TriageViewModel(service, taskList, clock);

        vm.DeferCommand.Execute(taskList.Tasks[0]);
        await AsyncPoll.WaitUntilAsync(() => orchestrator.AddedConditions.Count == 1);

        Assert.Equal(old.Id, orchestrator.AddedConditions[0].TaskId);
    }

    [Fact]
    public void DismissCommand_HidesTheCard()
    {
        var old = TestTasks.New(title: "stale", createdAt: Now - TimeSpan.FromDays(10));
        var (vm, service, _) = MakeHarness(new[] { old });
        service.MaybeShowTriage(Now);
        vm.Refresh();
        Assert.True(vm.IsVisible);

        vm.DismissCommand.Execute(null);

        Assert.False(vm.IsVisible);
    }

    [Fact]
    public void FooterCountText_Pluralizes_ExceptForExactlyOne()
    {
        var a = TestTasks.New(title: "a", createdAt: Now - TimeSpan.FromDays(10));
        var b = TestTasks.New(title: "b", createdAt: Now - TimeSpan.FromDays(10));
        var (vm, _, _) = MakeHarness(new[] { a, b });

        Assert.Equal("2 tasks", vm.FooterCountText);
    }
}
