// ViewModels/SweepViewModelTests.cs — SweepViewModel (Wave 4 Stage B3), backed by a real
// TriageAndSweepService over fakes, mirroring TriageViewModelTests' own harness shape (sibling
// views, sibling test files).
using System.Linq;
using Volar.App.Services.State;
using Volar.App.Tests.State;
using Volar.App.Tests.Workflow;
using Volar.App.ViewModels;
using Volar.Domain;
using Xunit;
using TaskState = Volar.Core.TaskState;

namespace Volar.App.Tests.ViewModels;

public sealed class SweepViewModelTests
{
    private static readonly DateTimeOffset Now = new(2026, 7, 26, 19, 0, 0, TimeSpan.Zero);

    private static (SweepViewModel Vm, TriageAndSweepService Service, FakeTaskListService TaskList) MakeHarness(
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
        var vm = new SweepViewModel(service, taskList);
        return (vm, service, taskList);
    }

    [Fact]
    public void Refresh_ReflectsShowSweep_AndTheOpenTaskSet()
    {
        var open = TestTasks.New(title: "still open");
        var (vm, _, _) = MakeHarness(new[] { open });

        Assert.False(vm.IsVisible);
        Assert.Single(vm.Items);
        Assert.Equal("1 task open", vm.FooterCountText);
    }

    [Fact]
    public void Refresh_AfterMaybeShowEveningSweep_BecomesVisible()
    {
        var open = TestTasks.New(title: "still open");
        var (vm, service, _) = MakeHarness(new[] { open });

        service.MaybeShowEveningSweep(Now);
        vm.Refresh();

        Assert.True(vm.IsVisible);
    }

    [Fact]
    public async Task CompleteCommand_TogglesTheTaskDoneThroughTheSharedTaskList()
    {
        var open = TestTasks.New(title: "finish me", status: TaskState.Todo);
        var (vm, _, taskList) = MakeHarness(new[] { open });

        vm.CompleteCommand.Execute(taskList.Tasks[0]);
        await AsyncPoll.WaitUntilAsync(() => taskList.Tasks[0].Done);

        Assert.True(taskList.Tasks[0].Done);
        Assert.Empty(vm.Items); // done tasks drop out of OpenTasks/SweepItems.
    }

    [Fact]
    public void SkipCommand_LeavesTheTaskUntouched_ButRefreshesTheCard()
    {
        var open = TestTasks.New(title: "carry over", status: TaskState.Todo);
        var (vm, _, taskList) = MakeHarness(new[] { open });

        vm.SkipCommand.Execute(taskList.Tasks[0]);

        Assert.False(taskList.Tasks[0].Done);
        Assert.Single(vm.Items); // still open — "skip" carries it over silently, no shame styling.
    }

    [Fact]
    public void DismissCommand_HidesTheCard()
    {
        var open = TestTasks.New(title: "still open");
        var (vm, service, _) = MakeHarness(new[] { open });
        service.MaybeShowEveningSweep(Now);
        vm.Refresh();
        Assert.True(vm.IsVisible);

        vm.DismissCommand.Execute(null);

        Assert.False(vm.IsVisible);
    }

    [Fact]
    public void FooterCountText_UsesTheOpenSuffix_Always()
    {
        var a = TestTasks.New(title: "a");
        var b = TestTasks.New(title: "b");
        var (vm, _, _) = MakeHarness(new[] { a, b });

        Assert.Equal("2 tasks open", vm.FooterCountText);
    }
}
