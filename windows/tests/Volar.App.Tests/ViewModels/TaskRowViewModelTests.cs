// ViewModels/TaskRowViewModelTests.cs — Wave 4 Stage B1. TaskRowViewModel (port of TaskRow.swift,
// views-inventory.md §1.4) headlessly against Volar.App.Tests.Capture's FakeTaskListService (reused
// per this project's "same test assembly, no cross-folder duplication" convention — see
// WorkflowTestSupport.cs's own header comment; deliberately importing ONLY the Capture namespace's
// FakeTaskListService here, not Workflow's, to avoid an ambiguous-reference collision between the
// two same-named internal fakes in this one file).
using Volar.App.Services;
using Volar.App.Tests.Capture;
using Volar.App.Tests.State;
using Volar.App.ViewModels;
using Volar.Domain;
using Xunit;
using TaskState = Volar.Core.TaskState;

namespace Volar.App.Tests.ViewModels;

public sealed class TaskRowViewModelTests
{
    private static readonly DateTimeOffset Now = CaptureTestData.Now;

    // MARK: - Presentation derivation (TaskRow.swift:20-41,123-171)

    [Fact]
    public void OpenTask_ExposesPriorityLabel_AndNoDoneOnlyFields()
    {
        var task = TestTasks.New(title: "write the report", priority: Priority.High, status: TaskState.Todo, createdAt: Now);
        var taskList = new FakeTaskListService();

        var row = new TaskRowViewModel(task, isActive: false, taskList);

        Assert.Equal(task.Id, row.Id);
        Assert.Equal("write the report", row.Title);
        Assert.False(row.IsDone);
        Assert.Equal(Priority.High, row.Priority);
        Assert.Equal("High", row.PriorityOrStatusLabel);
        Assert.Null(row.DoneTimeLabel);
    }

    [Theory]
    [InlineData(Priority.High, "High")]
    [InlineData(Priority.Medium, "Medium")]
    [InlineData(Priority.Low, "Low")]
    public void PriorityOrStatusLabel_MapsEachPriority_WhenNotDone(Priority priority, string expected)
    {
        var task = TestTasks.New(priority: priority, status: TaskState.Todo, createdAt: Now);
        var row = new TaskRowViewModel(task, isActive: false, new FakeTaskListService());

        Assert.Equal(expected, row.PriorityOrStatusLabel);
    }

    [Fact]
    public void DoneTask_StatusLabelIsDone_AndDurationTimeBadgeAreSuppressed()
    {
        // TaskRow.swift:143-144,163: `task.done ? "Done" : priorityLabel`, and both
        // durationLabel/timeBadge are gated `!task.done`.
        var task = TestTasks.New(status: TaskState.Done, deadline: Now.AddHours(2), createdAt: Now) with { DurationMinutes = 30 };
        var row = new TaskRowViewModel(task, isActive: false, new FakeTaskListService());

        Assert.True(row.IsDone);
        Assert.Equal("Done", row.PriorityOrStatusLabel);
        Assert.Null(row.DurationLabel);
        Assert.Null(row.TimeBadgeText);
    }

    [Fact]
    public void DoneTask_WithADeadline_ExposesDoneTimeLabel()
    {
        // TaskRow.swift:38-41 `rawTimeLabel` — the muted done-state deadline readout.
        var deadline = new DateTimeOffset(2026, 7, 25, 14, 30, 0, TimeSpan.Zero);
        var task = TestTasks.New(status: TaskState.Done, deadline: deadline, createdAt: Now);
        var row = new TaskRowViewModel(task, isActive: false, new FakeTaskListService());

        Assert.Equal("2:30 PM", row.DoneTimeLabel);
    }

    [Fact]
    public void OpenTask_ShowFrogMarker_OnlyWhenFrogAndNotDone()
    {
        var frogOpen = TestTasks.New(frog: true, status: TaskState.Todo, createdAt: Now);
        var frogDone = TestTasks.New(frog: true, status: TaskState.Done, createdAt: Now);
        var plain = TestTasks.New(frog: false, status: TaskState.Todo, createdAt: Now);

        Assert.True(new TaskRowViewModel(frogOpen, false, new FakeTaskListService()).ShowFrogMarker);
        Assert.False(new TaskRowViewModel(frogDone, false, new FakeTaskListService()).ShowFrogMarker);
        Assert.False(new TaskRowViewModel(plain, false, new FakeTaskListService()).ShowFrogMarker);
    }

    [Fact]
    public void IsTimeBadgeFilled_MirrorsIsActive()
    {
        var task = TestTasks.New(status: TaskState.Todo, createdAt: Now);
        Assert.True(new TaskRowViewModel(task, isActive: true, new FakeTaskListService()).IsTimeBadgeFilled);
        Assert.False(new TaskRowViewModel(task, isActive: false, new FakeTaskListService()).IsTimeBadgeFilled);
    }

    [Fact]
    public void RowPadYAndRowGap_DefaultToComfyDensityValues_UnlessOverridden()
    {
        var task = TestTasks.New(createdAt: Now);
        var defaultRow = new TaskRowViewModel(task, false, new FakeTaskListService());
        var customRow = new TaskRowViewModel(task, false, new FakeTaskListService(), rowPadY: 14, rowGap: 6);

        Assert.Equal(10.0, defaultRow.RowPadY);
        Assert.Equal(4.0, defaultRow.RowGap);
        Assert.Equal(14.0, customRow.RowPadY);
        Assert.Equal(6.0, customRow.RowGap);
    }

    // MARK: - Actions (TaskRow.swift:87,95-99 -> ITaskListService)

    [Fact]
    public async Task ToggleDoneAsync_CallsThroughToTaskListServiceWithThisRowsId()
    {
        var task = TestTasks.New(createdAt: Now);
        var taskList = new FakeTaskListService();
        var row = new TaskRowViewModel(task, false, taskList);

        await row.ToggleDoneAsync();

        Assert.Equal(new[] { task.Id }, taskList.ToggledIds);
    }

    [Fact]
    public async Task DeleteAsync_CallsThroughToTaskListServiceWithThisRowsId()
    {
        var task = TestTasks.New(createdAt: Now);
        var taskList = new FakeTaskListService();
        taskList.BackingTasks.Add(task);
        var row = new TaskRowViewModel(task, false, taskList);

        await row.DeleteAsync();

        Assert.DoesNotContain(taskList.BackingTasks, t => t.Id == task.Id);
    }

    [Fact]
    public void OpenDetail_RaisesOpenDetailRequested_WithThisRowsId()
    {
        var task = TestTasks.New(createdAt: Now);
        var row = new TaskRowViewModel(task, false, new FakeTaskListService());
        Guid? raised = null;
        row.OpenDetailRequested += id => raised = id;

        row.OpenDetail();

        Assert.Equal(task.Id, raised);
    }

    [Fact]
    public void RequestBreakdown_RaisesBreakdownRequested_WithThisRowsId()
    {
        // Mirrors TaskRow.swift:96's `appState.showBreakdown = true` — task-agnostic in Swift too
        // (views-inventory.md §1.4 row 2), the id still rides along as useful context for whatever
        // Stage C wires this to.
        var task = TestTasks.New(createdAt: Now);
        var row = new TaskRowViewModel(task, false, new FakeTaskListService());
        Guid? raised = null;
        row.BreakdownRequested += id => raised = id;

        row.RequestBreakdown();

        Assert.Equal(task.Id, raised);
    }

    [Fact]
    public void UpdateTask_ReplacesBackingTaskAndRaisesPropertyChanged()
    {
        var original = TestTasks.New(title: "before", status: TaskState.Todo, createdAt: Now);
        var row = new TaskRowViewModel(original, false, new FakeTaskListService());
        var raised = new List<string?>();
        row.PropertyChanged += (_, e) => raised.Add(e.PropertyName);

        var updated = original with { Title = "after", Status = TaskState.Done };
        row.UpdateTask(updated);

        Assert.Equal("after", row.Title);
        Assert.True(row.IsDone);
        Assert.Contains(nameof(TaskRowViewModel.Title), raised);
        Assert.Contains(nameof(TaskRowViewModel.IsDone), raised);
    }
}
