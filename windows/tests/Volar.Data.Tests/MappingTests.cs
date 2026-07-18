// MappingTests.cs — TaskEntity.ToSnapshot() (the Volar.Data -> Volar.Core boundary) and
// ConditionEntity <-> Volar.Core.Condition (ConditionMapping.cs), including the fail-closed
// Status accessor over an unrecognized StatusRaw value.
using Volar.Core;
using Volar.Data.Entities;
using Xunit;

namespace Volar.Data.Tests;

public sealed class MappingTests
{
    [Fact]
    public void ToSnapshot_ProjectsOnlyEngineRelevantFields()
    {
        var deadline = new DateTimeOffset(2026, 8, 1, 9, 0, 0, TimeSpan.Zero);
        var created = new DateTimeOffset(2026, 7, 1, 8, 0, 0, TimeSpan.Zero);
        var parentId = Guid.NewGuid();
        var entity = Fixtures.NewTask(
            title: "Ship it",
            status: TaskState.InProgress,
            priority: 2,
            deadline: deadline,
            createdAt: created,
            parentId: parentId);
        entity.DurationMinutes = 30;

        var snapshot = entity.ToSnapshot();

        Assert.Equal(entity.Id, snapshot.Id);
        Assert.Equal("Ship it", snapshot.Title);
        Assert.Equal(TaskState.InProgress, snapshot.Status);
        Assert.Equal(2, snapshot.Priority);
        Assert.Equal(deadline, snapshot.Deadline);
        Assert.Equal(30, snapshot.EstimateMinutes);
        Assert.Equal(parentId, snapshot.ParentId);
        Assert.Equal(created, snapshot.CreatedAt);
    }

    [Fact]
    public void ToSnapshot_OrdersConditionsByOrderIndex_NotInsertionOrder()
    {
        var entity = Fixtures.NewTask(title: "Multi-condition");
        var first = Guid.NewGuid();
        var second = Guid.NewGuid();
        // Deliberately added out of intended order, then OrderIndex corrected — proves ToSnapshot
        // trusts OrderIndex, not List<T> position.
        entity.Conditions.Add(new ConditionEntity { Id = Guid.NewGuid(), TaskId = entity.Id, OrderIndex = 1, Kind = "taskDone", TaskDoneTargetId = second });
        entity.Conditions.Add(new ConditionEntity { Id = Guid.NewGuid(), TaskId = entity.Id, OrderIndex = 0, Kind = "taskDone", TaskDoneTargetId = first });

        var snapshot = entity.ToSnapshot();

        var ids = snapshot.Conditions.Cast<TaskDoneCondition>().Select(c => c.TaskId).ToList();
        Assert.Equal([first, second], ids);
    }

    [Theory]
    [InlineData("todo", TaskState.Todo)]
    [InlineData("inProgress", TaskState.InProgress)]
    [InlineData("done", TaskState.Done)]
    [InlineData("archived", TaskState.Archived)]
    public void Status_RoundTripsKnownRawValues(string raw, TaskState expected)
    {
        var entity = Fixtures.NewTask();
        entity.StatusRaw = raw;

        Assert.Equal(expected, entity.Status);
    }

    [Fact]
    public void Status_UnrecognizedRawValue_FailsClosedToTodo()
    {
        var entity = Fixtures.NewTask();
        entity.StatusRaw = "some-future-status-this-build-does-not-know";

        Assert.Equal(TaskState.Todo, entity.Status);
    }

    [Fact]
    public void ConditionMapping_TaskDone_RoundTrips()
    {
        var targetId = Guid.NewGuid();
        Condition original = new TaskDoneCondition(targetId);

        var entity = original.ToEntity(Guid.NewGuid(), 0);
        var restored = entity.ToCoreCondition();

        Assert.Equal(original, restored);
        Assert.Equal("taskDone", entity.Kind);
    }

    [Fact]
    public void ConditionMapping_AfterDate_RoundTrips()
    {
        var date = new DateTimeOffset(2026, 9, 1, 0, 0, 0, TimeSpan.Zero);
        Condition original = new AfterDateCondition(date);

        var entity = original.ToEntity(Guid.NewGuid(), 0);
        var restored = entity.ToCoreCondition();

        Assert.Equal(original, restored);
        Assert.Equal("afterDate", entity.Kind);
    }

    [Fact]
    public void ConditionMapping_External_RoundTrips()
    {
        Condition original = new ExternalCondition("waiting on legal", Satisfied: true);

        var entity = original.ToEntity(Guid.NewGuid(), 0);
        var restored = entity.ToCoreCondition();

        Assert.Equal(original, restored);
        Assert.Equal("external", entity.Kind);
    }

    [Fact]
    public void ConditionMapping_UnrecognizedKind_ThrowsRatherThanSilentlyDropping()
    {
        var entity = new ConditionEntity { Id = Guid.NewGuid(), TaskId = Guid.NewGuid(), Kind = "future-kind" };

        Assert.Throws<InvalidOperationException>(() => entity.ToCoreCondition());
    }
}
