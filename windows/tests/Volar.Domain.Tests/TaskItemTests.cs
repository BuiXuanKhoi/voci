using Volar.Core;
using Volar.Domain;
using Xunit;

namespace Volar.Domain.Tests;

public class TaskItemTests
{
    private static readonly DateTimeOffset FixedNow = new(2026, 3, 15, 9, 0, 0, TimeSpan.Zero);

    private static TaskItem MakeTask(
        Priority priority = Priority.Medium,
        When when = When.Now,
        TaskState status = TaskState.Todo,
        DateTimeOffset? deadline = null,
        int? durationMinutes = null,
        IReadOnlyList<Condition>? conditions = null,
        Guid? parentId = null)
        => new(
            Guid.NewGuid(),
            "Write report",
            priority,
            when,
            FixedNow,
            status: status,
            deadline: deadline,
            durationMinutes: durationMinutes,
            conditions: conditions,
            parentId: parentId);

    [Fact]
    public void Constructor_AppliesDefaults_MatchingSwiftInit()
    {
        var task = new TaskItem(Guid.NewGuid(), "Title", Priority.High, When.Later, FixedNow);

        Assert.Equal(string.Empty, task.Details);
        Assert.Equal(TaskState.Todo, task.Status);
        Assert.Null(task.Deadline);
        Assert.Empty(task.Conditions);
        Assert.Null(task.DurationMinutes);
        Assert.False(task.Frog);
        Assert.Null(task.Notes);
        Assert.Null(task.SourceTranscript);
        Assert.Equal(TaskKind.Task, task.Kind);
        Assert.Null(task.Recurrence);
        Assert.Null(task.ReminderOverride);
        Assert.Null(task.ResumeNote);
        Assert.Equal(0, task.SwitchAwayCount);
        Assert.Null(task.CompletedAt);
        Assert.Null(task.ParentId);
        Assert.Null(task.Delegation);
    }

    [Fact]
    public void Conditions_NullArgument_DefaultsToEmptyNotNull()
    {
        var task = MakeTask(conditions: null);
        Assert.NotNull(task.Conditions);
        Assert.Empty(task.Conditions);
    }

    [Theory]
    [InlineData(TaskState.Todo, false)]
    [InlineData(TaskState.InProgress, false)]
    [InlineData(TaskState.Done, true)]
    [InlineData(TaskState.Archived, false)]
    public void Done_IsPurelyDerivedFromStatus(TaskState status, bool expectedDone)
    {
        var task = MakeTask(status: status);
        Assert.Equal(expectedDone, task.Done);
    }

    [Fact]
    public void TimeBadge_NullWhenDone_EvenWithDeadline()
    {
        var task = MakeTask(status: TaskState.Done, deadline: FixedNow.AddHours(2));
        Assert.Null(task.TimeBadge);
    }

    [Fact]
    public void TimeBadge_NullWhenNoDeadline()
    {
        var task = MakeTask(deadline: null);
        Assert.Null(task.TimeBadge);
    }

    [Fact]
    public void TimeBadge_FormatsOpenTaskDeadline_InvariantCulture()
    {
        var deadline = new DateTimeOffset(2026, 3, 15, 11, 30, 0, TimeSpan.Zero);
        var task = MakeTask(status: TaskState.Todo, deadline: deadline);
        Assert.Equal("11:30 AM", task.TimeBadge);
    }

    [Theory]
    [InlineData(null, null)]
    [InlineData(0, null)]
    [InlineData(-5, null)]
    [InlineData(45, "45 min")]
    [InlineData(59, "59 min")]
    [InlineData(60, "1 hr")]
    [InlineData(120, "2 hrs")]
    [InlineData(90, "1h 30m")]
    [InlineData(135, "2h 15m")]
    public void DurationLabel_MatchesSwiftFormatting(int? minutes, string? expected)
    {
        var task = MakeTask(durationMinutes: minutes);
        Assert.Equal(expected, task.DurationLabel);
    }

    [Fact]
    public void Snapshot_MapsEveryEngineRelevantField()
    {
        var id = Guid.NewGuid();
        var parentId = Guid.NewGuid();
        var deadline = FixedNow.AddDays(1);
        var conditions = new Condition[] { new AfterDateCondition(FixedNow) };
        var task = new TaskItem(
            id, "Ship release", Priority.High, When.Now, FixedNow,
            status: TaskState.InProgress,
            deadline: deadline,
            conditions: conditions,
            durationMinutes: 45,
            parentId: parentId);

        var snapshot = task.Snapshot();

        Assert.Equal(id, snapshot.Id);
        Assert.Equal("Ship release", snapshot.Title);
        Assert.Equal(TaskState.InProgress, snapshot.Status);
        Assert.Equal(1, snapshot.Priority); // Priority.High == 1
        Assert.Equal(deadline, snapshot.Deadline);
        Assert.Same(conditions, snapshot.Conditions);
        Assert.Equal(45, snapshot.EstimateMinutes);
        Assert.Equal(parentId, snapshot.ParentId);
        Assert.Equal(FixedNow, snapshot.CreatedAt);
    }

    [Theory]
    [InlineData(Priority.High, 1)]
    [InlineData(Priority.Medium, 2)]
    [InlineData(Priority.Low, 3)]
    public void Snapshot_PriorityMapsToRawValue(Priority priority, int expectedRawValue)
    {
        var task = MakeTask(priority: priority);
        Assert.Equal(expectedRawValue, task.Snapshot().Priority);
    }

    [Fact]
    public void RecordStruct_ValueSemantics_MutatingCopyDoesNotAffectOriginal()
    {
        var original = MakeTask();
        var copy = original;
        copy.Title = "Different title";

        Assert.Equal("Write report", original.Title);
        Assert.Equal("Different title", copy.Title);
    }

    [Fact]
    public void Equality_StructurallyEqualInstancesAreEqual()
    {
        var id = Guid.NewGuid();
        var a = new TaskItem(id, "Same", Priority.Low, When.Later, FixedNow);
        var b = new TaskItem(id, "Same", Priority.Low, When.Later, FixedNow);
        Assert.Equal(a, b);
    }
}
