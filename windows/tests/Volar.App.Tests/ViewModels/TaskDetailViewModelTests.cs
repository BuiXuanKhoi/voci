// ViewModels/TaskDetailViewModelTests.cs — TaskDetailViewModel (Wave 4 Stage B3). Constructed with
// a null DispatcherQueue (headless test host — UiDispatch.Post runs inline), reusing
// Volar.App.Tests.Workflow.FakeTaskListService and Volar.App.Tests.State.TestTasks per those files'
// own "same test assembly" precedent (WorkflowTestSupport.cs header).
using Volar.App.Tests.State;
using Volar.App.Tests.Workflow;
using Volar.App.ViewModels;
using Volar.Domain;
using Volar.Speech.Playback;
using Xunit;
using TaskState = Volar.Core.TaskState;

namespace Volar.App.Tests.ViewModels;

public sealed class TaskDetailViewModelTests
{
    [Fact]
    public void Show_WithAKnownTask_PopulatesEveryBoundField()
    {
        var task = TestTasks.New(title: "Renew SSL certificate", priority: Priority.High, deadline: new DateTimeOffset(2026, 7, 26, 15, 30, 0, TimeSpan.Zero));
        task.Details = "Renew via the registrar dashboard.";
        task.DurationMinutes = 45;
        task.Frog = true;
        var taskList = new FakeTaskListService(new[] { task });
        var vm = new TaskDetailViewModel(taskList, new VoicePlayback());

        vm.Show(task.Id);

        Assert.True(vm.HasTask);
        Assert.Equal("Renew SSL certificate", vm.Title);
        Assert.True(vm.ShowFrogDot); // frog && !done
        Assert.Equal(Priority.High, vm.Priority);
        Assert.Equal("High", vm.PriorityLabel);
        Assert.True(vm.HasDeadline);
        Assert.True(vm.HasDuration);
        Assert.Equal("45 min", vm.DurationText);
        Assert.Equal("Open", vm.StatusText);
        Assert.True(vm.HasDescription);
        Assert.Equal("Renew via the registrar dashboard.", vm.DescriptionText);
        Assert.False(vm.IsDone);
        Assert.Equal("Mark done", vm.ToggleDoneLabel);
    }

    [Fact]
    public void Show_WithATaskThatHasNoDescription_HasDescriptionIsFalse()
    {
        var task = TestTasks.New(title: "Untitled");
        var taskList = new FakeTaskListService(new[] { task });
        var vm = new TaskDetailViewModel(taskList, new VoicePlayback());

        vm.Show(task.Id);

        Assert.False(vm.HasDescription);
        Assert.Equal(string.Empty, vm.DescriptionText);
    }

    [Fact]
    public void Show_WithAnUnknownId_LeavesHasTaskFalse()
    {
        var taskList = new FakeTaskListService();
        var vm = new TaskDetailViewModel(taskList, new VoicePlayback());

        vm.Show(Guid.NewGuid());

        Assert.False(vm.HasTask);
    }

    [Fact]
    public void Close_ClearsHasTask()
    {
        var task = TestTasks.New(title: "a");
        var taskList = new FakeTaskListService(new[] { task });
        var vm = new TaskDetailViewModel(taskList, new VoicePlayback());
        vm.Show(task.Id);
        Assert.True(vm.HasTask);

        vm.Close();

        Assert.False(vm.HasTask);
    }

    // MARK: - The nil-task defensive pattern (wave4-contract.md's own framing of this view's
    // hardest point): the backing task disappearing while the sheet is open must flip HasTask to
    // false via the TasksChanged subscription, not just leave stale data bound.

    [Fact]
    public async Task WhenTheTrackedTaskIsDeletedElsewhere_TasksChangedFlipsHasTaskFalse()
    {
        var task = TestTasks.New(title: "will be deleted");
        var taskList = new FakeTaskListService(new[] { task });
        var vm = new TaskDetailViewModel(taskList, new VoicePlayback());
        vm.Show(task.Id);
        Assert.True(vm.HasTask);

        await taskList.DeleteAsync(task.Id); // raises TasksChanged, not routed through the VM's own DeleteCommand

        Assert.False(vm.HasTask);
    }

    [Fact]
    public async Task DeleteCommand_DeletesTheTaskAndCloses()
    {
        var task = TestTasks.New(title: "delete me");
        var taskList = new FakeTaskListService(new[] { task });
        var vm = new TaskDetailViewModel(taskList, new VoicePlayback());
        vm.Show(task.Id);

        vm.DeleteCommand.Execute(null);
        await AsyncPoll.WaitUntilAsync(() => !vm.HasTask);

        Assert.False(vm.HasTask);
        Assert.DoesNotContain(taskList.Tasks, t => t.Id == task.Id);
    }

    [Fact]
    public async Task ToggleDoneCommand_TogglesDoneButStaysOpen()
    {
        var task = TestTasks.New(title: "finish me", status: TaskState.Todo);
        var taskList = new FakeTaskListService(new[] { task });
        var vm = new TaskDetailViewModel(taskList, new VoicePlayback());
        vm.Show(task.Id);

        vm.ToggleDoneCommand.Execute(null);
        await AsyncPoll.WaitUntilAsync(() => vm.IsDone);

        Assert.True(vm.HasTask);
        Assert.True(vm.IsDone);
        Assert.Equal("Mark not done", vm.ToggleDoneLabel);
    }

    [Fact]
    public void CommandsAreDisabled_WhenNoTaskIsShown()
    {
        var vm = new TaskDetailViewModel(new FakeTaskListService(), new VoicePlayback());

        Assert.False(vm.ReadAloudCommand.CanExecute(null));
        Assert.False(vm.DeleteCommand.CanExecute(null));
        Assert.False(vm.ToggleDoneCommand.CanExecute(null));
    }

    [Fact]
    public void ReadAloudCommand_NeverThrows_RegardlessOfDescriptionPresence()
    {
        var withDetails = TestTasks.New(title: "has details");
        withDetails.Details = "Full description text.";
        var withoutDetails = TestTasks.New(title: "no details");
        var taskList = new FakeTaskListService(new[] { withDetails, withoutDetails });
        var vm = new TaskDetailViewModel(taskList, new VoicePlayback());

        vm.Show(withDetails.Id);
        vm.ReadAloudCommand.Execute(null); // falls back to title when Details is empty, never throws

        vm.Show(withoutDetails.Id);
        vm.ReadAloudCommand.Execute(null);
    }
}

/// <summary>Polling helper for the fire-and-forget async command handlers this VM uses (Delete/
/// ToggleDone dispatch via `_ = XAsync()`), same shape as
/// Volar.App.Tests.Workflow.WorkflowTestSupport's own `Poll.WaitUntil` — an async variant, named
/// distinctly (NOT `Poll`) to avoid colliding with `Volar.App.Tests.Workflow.Poll` for every other
/// file in this shared `Volar.App.Tests.ViewModels` namespace (a same-namespace type always wins
/// over a `using`-imported one with the same simple name — a bare `Poll` here would have silently
/// shadowed the Workflow one for every sibling Wave-4 test file, forcing them into an alias
/// workaround; this name avoids that class of problem entirely).</summary>
internal static class AsyncPoll
{
    public static async Task WaitUntilAsync(Func<bool> condition, int timeoutMs = 2000)
    {
        var deadline = DateTime.UtcNow.AddMilliseconds(timeoutMs);
        while (!condition())
        {
            if (DateTime.UtcNow > deadline)
            {
                throw new TimeoutException("Condition was not met within the timeout.");
            }
            await Task.Delay(5);
        }
    }
}
