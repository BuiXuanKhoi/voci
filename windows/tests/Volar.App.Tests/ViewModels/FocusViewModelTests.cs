// ViewModels/FocusViewModelTests.cs — FocusViewModel (Wave 4 Stage B5). Constructed with a null
// DispatcherQueue (the "headless test host" case UiDispatch.Post's own doc comment describes —
// callbacks run inline instead of being enqueued), reusing Volar.App.Tests.Workflow's
// FakeTaskListService/Poll and Volar.App.Tests.State's TestTasks, per those files' own "same test
// assembly" precedent (WorkflowTestSupport.cs header).
//
// `WorkflowPoll` alias: this file's own namespace (Volar.App.Tests.ViewModels) also contains a
// SEPARATE `Poll` type (TaskDetailViewModelTests.cs, a sibling Wave-4 agent's async-flavored
// duplicate) — a same-namespace type always wins over a `using`-imported one with the same simple
// name, so a bare `Poll` here would silently resolve to THAT type instead of
// Volar.App.Tests.Workflow.Poll. Aliased explicitly rather than relying on namespace-declaration
// order.
using Volar.App.Services.State;
using Volar.App.Tests.State;
using Volar.App.Tests.Workflow;
using Volar.App.ViewModels;
using Volar.Domain;
using Volar.Speech.Playback;
using Xunit;
using WorkflowPoll = Volar.App.Tests.Workflow.Poll;

namespace Volar.App.Tests.ViewModels;

public sealed class FocusViewModelTests
{
    // MARK: - ComputeUrgency (FocusOverlay.swift:212-217's timerColor thresholds)

    [Theory]
    [InlineData(0, FocusTimerUrgency.Danger)]
    [InlineData(60, FocusTimerUrgency.Danger)]
    [InlineData(61, FocusTimerUrgency.Warning)]
    [InlineData(300, FocusTimerUrgency.Warning)]
    [InlineData(301, FocusTimerUrgency.Normal)]
    [InlineData(1500, FocusTimerUrgency.Normal)]
    public void ComputeUrgency_MatchesFocusOverlaySwiftThresholds(int secondsLeft, FocusTimerUrgency expected)
    {
        Assert.Equal(expected, FocusViewModel.ComputeUrgency(secondsLeft));
    }

    // MARK: - IsVisible (FocusOverlay.swift:27-35's `openTasks.isEmpty` guard + the "mounted only
    // when focusActive" gate, both folded into one VM bool per this VM's own doc comment).

    [Fact]
    public void Refresh_WithNoOpenTasks_IsNeverVisible_EvenAfterStartFocus()
    {
        var taskList = new FakeTaskListService();
        var service = new FocusSessionService(taskList, new VoicePlayback());
        service.StartFocus(); // FocusActive becomes true, but there is nothing to show.

        var vm = new FocusViewModel(service, taskList);

        Assert.False(vm.IsVisible);
        service.EndFocus();
    }

    [Fact]
    public void Refresh_BeforeStartFocus_IsNotVisible()
    {
        var taskList = new FakeTaskListService(new[] { TestTasks.New(title: "a") });
        var service = new FocusSessionService(taskList, new VoicePlayback());

        var vm = new FocusViewModel(service, taskList);

        Assert.False(vm.IsVisible);
    }

    [Fact]
    public void StartFocus_ThenRefresh_PopulatesTaskInfoAndNavState()
    {
        var taskList = new FakeTaskListService(new[]
        {
            TestTasks.New(title: "first", priority: Priority.High),
            TestTasks.New(title: "second", priority: Priority.Low),
        });
        var service = new FocusSessionService(taskList, new VoicePlayback());
        service.StartFocus();

        var vm = new FocusViewModel(service, taskList);

        Assert.True(vm.IsVisible);
        Assert.Equal("first", vm.TaskTitle);
        Assert.Equal(Priority.High, vm.TaskPriority);
        Assert.Equal("High", vm.PriorityLabel);
        Assert.Equal("1 of 2", vm.IndexLabel);
        Assert.Equal("2 tasks left today", vm.TasksLeftLabel);
        Assert.False(vm.CanGoPrevious);
        Assert.True(vm.CanGoNext);
        service.EndFocus();
    }

    [Fact]
    public void TasksLeftLabel_UsesSingularForExactlyOneOpenTask()
    {
        var taskList = new FakeTaskListService(new[] { TestTasks.New(title: "only") });
        var service = new FocusSessionService(taskList, new VoicePlayback());
        service.StartFocus();

        var vm = new FocusViewModel(service, taskList);

        Assert.Equal("1 task left today", vm.TasksLeftLabel);
        service.EndFocus();
    }

    // MARK: - GoToPreviousCommand / GoToNextCommand (frozen decision 6: commands, not direct index
    // mutation — StepFocusIndex is FocusSessionService's own already-tested clamp logic; this VM
    // just needs to prove it calls through and re-Refreshes).

    [Fact]
    public void GoToNextCommand_AdvancesIndex_AndUpdatesCanGoPreviousNext()
    {
        var taskList = new FakeTaskListService(new[]
        {
            TestTasks.New(title: "a"),
            TestTasks.New(title: "b"),
            TestTasks.New(title: "c"),
        });
        var service = new FocusSessionService(taskList, new VoicePlayback());
        service.StartFocus();
        var vm = new FocusViewModel(service, taskList);

        vm.GoToNextCommand.Execute(null);

        Assert.Equal("b", vm.TaskTitle);
        Assert.True(vm.CanGoPrevious);
        Assert.True(vm.CanGoNext);

        vm.GoToNextCommand.Execute(null);
        Assert.Equal("c", vm.TaskTitle);
        Assert.False(vm.CanGoNext);
        Assert.False(vm.GoToNextCommand.CanExecute(null));

        vm.GoToPreviousCommand.Execute(null);
        Assert.Equal("b", vm.TaskTitle);
        service.EndFocus();
    }

    [Fact]
    public void GoToPreviousCommand_CanExecute_IsFalseAtTheFirstTask()
    {
        var taskList = new FakeTaskListService(new[] { TestTasks.New(title: "a"), TestTasks.New(title: "b") });
        var service = new FocusSessionService(taskList, new VoicePlayback());
        service.StartFocus();
        var vm = new FocusViewModel(service, taskList);

        Assert.False(vm.GoToPreviousCommand.CanExecute(null));
        service.EndFocus();
    }

    // MARK: - MarkDoneCommand (FocusOverlay.swift:141-159 -> FocusSessionService.CompleteFocusTaskAsync)

    [Fact]
    public void MarkDoneCommand_CompletesTheCurrentTask_AndRefreshesAfterward()
    {
        var taskList = new FakeTaskListService(new[] { TestTasks.New(title: "only") });
        var service = new FocusSessionService(taskList, new VoicePlayback());
        service.StartFocus();
        var vm = new FocusViewModel(service, taskList);
        Assert.True(vm.IsVisible);

        vm.MarkDoneCommand.Execute(null);
        // MarkDoneCommand's execute is an async-void delegate (ICommand.Execute is synchronous) —
        // give the awaited CompleteFocusTaskAsync + UiDispatch.Post(Refresh) continuation a chance
        // to run before asserting.
        WorkflowPoll.WaitUntil(() => !vm.IsVisible, TimeSpan.FromSeconds(5));

        Assert.False(vm.IsVisible); // batch emptied -> session auto-ends (FocusSessionServiceTests already covers the FIX 3 delta math itself).
    }

    // MARK: - TogglePauseCommand / EndSessionCommand

    [Fact]
    public void TogglePauseCommand_TogglesIsPausedAndPauseButtonShowsResume()
    {
        var taskList = new FakeTaskListService(new[] { TestTasks.New(title: "a") });
        var service = new FocusSessionService(taskList, new VoicePlayback());
        service.StartFocus();
        var vm = new FocusViewModel(service, taskList);

        Assert.False(vm.IsPaused);
        Assert.False(vm.PauseButtonShowsResume);

        vm.TogglePauseCommand.Execute(null);
        Assert.True(vm.IsPaused);
        Assert.True(vm.PauseButtonShowsResume);

        vm.TogglePauseCommand.Execute(null);
        Assert.False(vm.IsPaused);
        service.EndFocus();
    }

    [Fact]
    public void EndSessionCommand_HidesTheOverlay()
    {
        var taskList = new FakeTaskListService(new[] { TestTasks.New(title: "a") });
        var service = new FocusSessionService(taskList, new VoicePlayback());
        service.StartFocus();
        var vm = new FocusViewModel(service, taskList);
        Assert.True(vm.IsVisible);

        vm.EndSessionCommand.Execute(null);

        Assert.False(vm.IsVisible);
    }

    // MARK: - TasksChanged wiring (a mutation from elsewhere — e.g. deleting the current task via
    // another surface — must still refresh this VM without any command being invoked here).

    [Fact]
    public async Task ExternalTasksChanged_RefreshesTheViewModel()
    {
        var taskList = new FakeTaskListService(new[] { TestTasks.New(title: "a"), TestTasks.New(title: "b") });
        var service = new FocusSessionService(taskList, new VoicePlayback());
        service.StartFocus();
        var vm = new FocusViewModel(service, taskList);
        Assert.Equal("2 tasks left today", vm.TasksLeftLabel);

        await taskList.DeleteAsync(taskList.Tasks[1].Id); // raises TasksChanged synchronously in the fake.

        Assert.Equal("1 task left today", vm.TasksLeftLabel);
        service.EndFocus();
    }
}
