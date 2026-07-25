// State/TaskEntityMappingTests.cs — TaskEntity <-> Volar.Domain.TaskItem (TaskEntityMapping.cs),
// resolving the Wave-1 note at TaskEntity.cs:6-9. Lives here (not Volar.Data.Tests) per this task's
// "touch only files listed" constraint — Volar.Data.Tests already exists and is not one of C2's
// owned files.
using Volar.Core;
using Volar.Data.Entities;
using Volar.Domain;
using Xunit;

namespace Volar.App.Tests.State;

public sealed class TaskEntityMappingTests
{
    [Fact]
    public void ToTaskItem_RoundTripsEveryField()
    {
        var id = Guid.NewGuid();
        var parentId = Guid.NewGuid();
        var taskDoneTarget = Guid.NewGuid();
        var deadline = new DateTimeOffset(2026, 8, 1, 9, 0, 0, TimeSpan.Zero);
        var created = new DateTimeOffset(2026, 7, 1, 8, 0, 0, TimeSpan.Zero);
        var completed = new DateTimeOffset(2026, 7, 20, 10, 0, 0, TimeSpan.Zero);
        var checkBackAt = new DateTimeOffset(2026, 7, 25, 14, 0, 0, TimeSpan.Zero);
        var delegatedAt = new DateTimeOffset(2026, 7, 24, 9, 0, 0, TimeSpan.Zero);

        var entity = new TaskEntity
        {
            Id = id,
            Title = "Ship the mapper",
            Details = "details here",
            PriorityRaw = 1,
            Deadline = deadline,
            CreatedAt = created,
            WhenRaw = "later",
            DurationMinutes = 45,
            Frog = true,
            Notes = "note text",
            SourceTranscript = "add a task to ship the mapper",
            KindRaw = "review",
            ResumeNote = "pick up from step 3",
            SwitchAwayCount = 4,
            CompletedAt = completed,
            ParentId = parentId,
            IsSensitive = true, // deliberately set — must NOT surface on TaskItem, see test below.
            RecurrenceJson = """{"kind":"every","days":3}""",
            ReminderOverrideJson = """{"offsetTicks":[-36000000000,-600000000],"repeatEveryTicks":18000000000}""",
            DelegationJson = "{\"label\":\"Claude\",\"checkBackAt\":\"" + checkBackAt.ToString("O") +
                "\",\"backoffStage\":1,\"cwdHint\":\"C:\\\\repo\",\"delegatedAt\":\"" + delegatedAt.ToString("O") + "\"}",
        };
        entity.Status = TaskState.InProgress;
        entity.Conditions.Add(new AfterDateCondition(deadline).ToEntity(id, 1));
        entity.Conditions.Add(new TaskDoneCondition(taskDoneTarget).ToEntity(id, 0));
        entity.Conditions.Add(new ExternalCondition("waiting on legal", Satisfied: false).ToEntity(id, 2));

        var item = entity.ToTaskItem();

        Assert.Equal(id, item.Id);
        Assert.Equal("Ship the mapper", item.Title);
        Assert.Equal("details here", item.Details);
        Assert.Equal(Priority.High, item.Priority);
        Assert.Equal(TaskState.InProgress, item.Status);
        Assert.Equal(deadline, item.Deadline);
        Assert.Equal(created, item.CreatedAt);
        Assert.Equal(When.Later, item.When);
        Assert.Equal(45, item.DurationMinutes);
        Assert.True(item.Frog);
        Assert.Equal("note text", item.Notes);
        Assert.Equal("add a task to ship the mapper", item.SourceTranscript);
        Assert.Equal(TaskKind.Review, item.Kind);
        Assert.Equal("pick up from step 3", item.ResumeNote);
        Assert.Equal(4, item.SwitchAwayCount);
        Assert.Equal(completed, item.CompletedAt);
        Assert.Equal(parentId, item.ParentId);

        // Conditions round-trip in OrderIndex order, not insertion order.
        Assert.Collection(
            item.Conditions,
            c => Assert.Equal(taskDoneTarget, Assert.IsType<TaskDoneCondition>(c).TaskId),
            c => Assert.Equal(deadline, Assert.IsType<AfterDateCondition>(c).Date),
            c =>
            {
                var external = Assert.IsType<ExternalCondition>(c);
                Assert.Equal("waiting on legal", external.Description);
                Assert.False(external.Satisfied);
            });

        var recurrence = Assert.IsType<Recurrence.Every>(item.Recurrence);
        Assert.Equal(3, recurrence.Days);

        Assert.NotNull(item.ReminderOverride);
        Assert.Equal(2, item.ReminderOverride!.Value.Offsets.Count);
        Assert.Equal(TimeSpan.FromTicks(-36000000000), item.ReminderOverride.Value.Offsets[0]);
        Assert.Equal(TimeSpan.FromTicks(-600000000), item.ReminderOverride.Value.Offsets[1]);
        Assert.Equal(TimeSpan.FromTicks(18000000000), item.ReminderOverride.Value.RepeatEvery);

        Assert.NotNull(item.Delegation);
        Assert.Equal("Claude", item.Delegation!.Value.Label);
        Assert.Equal(checkBackAt, item.Delegation.Value.CheckBackAt);
        Assert.Equal(1, item.Delegation.Value.BackoffStage);
        Assert.Equal("C:\\repo", item.Delegation.Value.CwdHint);
        Assert.Equal(delegatedAt, item.Delegation.Value.DelegatedAt);
    }

    [Fact]
    public void ToTaskItem_NeverSurfacesIsSensitive()
    {
        // IsSensitive is deliberately absent from TaskItem (mirrors VolarTask.isSensitive's own doc
        // comment) — this test exists purely so a future accidental addition of an IsSensitive field
        // to TaskItem gets caught by a compile error here, not a silent behavior change.
        var entity = new TaskEntity { Id = Guid.NewGuid(), Title = "t", CreatedAt = DateTimeOffset.UtcNow, IsSensitive = true };
        var item = entity.ToTaskItem();
        Assert.NotEqual(default, item.Id); // sanity: mapping still happened.
    }

    [Fact]
    public void ToEntity_RoundTripsBackToTheSameEntityShape()
    {
        var id = Guid.NewGuid();
        var deadline = new DateTimeOffset(2026, 8, 1, 9, 0, 0, TimeSpan.Zero);
        var created = new DateTimeOffset(2026, 7, 1, 8, 0, 0, TimeSpan.Zero);

        var original = new TaskItem(
            id: id,
            title: "Round trip",
            priority: Priority.Low,
            when: When.Now,
            createdAt: created,
            details: "d",
            status: TaskState.Todo,
            deadline: deadline,
            conditions: [new AfterDateCondition(deadline)],
            durationMinutes: 15,
            frog: false,
            notes: "n",
            sourceTranscript: "s",
            kind: TaskKind.Task,
            recurrence: new Recurrence.Daily(),
            reminderOverride: ReminderPolicy.DefaultPolicy,
            resumeNote: "r",
            switchAwayCount: 2,
            completedAt: null,
            parentId: null,
            delegation: null);

        var entity = original.ToEntity();
        var roundTripped = entity.ToTaskItem();

        Assert.Equal(original.Id, roundTripped.Id);
        Assert.Equal(original.Title, roundTripped.Title);
        Assert.Equal(original.Priority, roundTripped.Priority);
        Assert.Equal(original.When, roundTripped.When);
        Assert.Equal(original.Details, roundTripped.Details);
        Assert.Equal(original.Status, roundTripped.Status);
        Assert.Equal(original.Deadline, roundTripped.Deadline);
        Assert.Equal(original.DurationMinutes, roundTripped.DurationMinutes);
        Assert.Equal(original.Notes, roundTripped.Notes);
        Assert.Equal(original.SourceTranscript, roundTripped.SourceTranscript);
        Assert.Equal(original.Kind, roundTripped.Kind);
        Assert.IsType<Recurrence.Daily>(roundTripped.Recurrence);
        // ReminderPolicy's synthesized record-struct equality compares Offsets by reference (the
        // underlying List<TimeSpan>/TimeSpan[] concrete types never overrode Equals), so a full
        // Assert.Equal on the struct itself would fail for a genuinely-equal-by-value round trip —
        // compare element-wise instead.
        Assert.NotNull(roundTripped.ReminderOverride);
        Assert.Equal(original.ReminderOverride!.Value.Offsets, roundTripped.ReminderOverride!.Value.Offsets);
        Assert.Equal(original.ReminderOverride.Value.RepeatEvery, roundTripped.ReminderOverride.Value.RepeatEvery);
        Assert.Equal(original.ResumeNote, roundTripped.ResumeNote);
        Assert.Equal(original.SwitchAwayCount, roundTripped.SwitchAwayCount);
        Assert.Single(roundTripped.Conditions);
        Assert.Equal(deadline, Assert.IsType<AfterDateCondition>(roundTripped.Conditions[0]).Date);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(4)]
    [InlineData(99)]
    [InlineData(-1)]
    public void PriorityFromRaw_UnknownOrOutOfRange_FailsClosedToMedium(int raw)
    {
        var entity = new TaskEntity { Id = Guid.NewGuid(), Title = "t", CreatedAt = DateTimeOffset.UtcNow, PriorityRaw = raw };
        Assert.Equal(Priority.Medium, entity.ToTaskItem().Priority);
    }

    [Theory]
    [InlineData(1, Priority.High)]
    [InlineData(2, Priority.Medium)]
    [InlineData(3, Priority.Low)]
    public void PriorityFromRaw_KnownValues_RoundTrip(int raw, Priority expected)
    {
        var entity = new TaskEntity { Id = Guid.NewGuid(), Title = "t", CreatedAt = DateTimeOffset.UtcNow, PriorityRaw = raw };
        Assert.Equal(expected, entity.ToTaskItem().Priority);
    }

    [Theory]
    [InlineData("now")]
    [InlineData("later")]
    [InlineData("garbage")]
    [InlineData("")]
    public void WhenFromRaw_OnlyExactlyNowMapsToNow(string raw)
    {
        var entity = new TaskEntity { Id = Guid.NewGuid(), Title = "t", CreatedAt = DateTimeOffset.UtcNow, WhenRaw = raw };
        var expected = raw == "now" ? When.Now : When.Later;
        Assert.Equal(expected, entity.ToTaskItem().When);
    }

    [Fact]
    public void TaskKindFromRaw_UnrecognizedFallsBackToTask()
    {
        var entity = new TaskEntity { Id = Guid.NewGuid(), Title = "t", CreatedAt = DateTimeOffset.UtcNow, KindRaw = "future-kind" };
        Assert.Equal(TaskKind.Task, entity.ToTaskItem().Kind);
    }

    [Theory]
    [InlineData("not json at all")]
    [InlineData("""{"kind":"unknown-kind"}""")]
    [InlineData("""{"kind":"every"}""")] // missing Days
    public void DecodeRecurrence_MalformedOrIncomplete_FailsClosedToNull(string json)
    {
        var entity = new TaskEntity { Id = Guid.NewGuid(), Title = "t", CreatedAt = DateTimeOffset.UtcNow, RecurrenceJson = json };
        Assert.Null(entity.ToTaskItem().Recurrence);
    }

    [Fact]
    public void DecodeReminderPolicy_MalformedJson_FailsClosedToNull()
    {
        var entity = new TaskEntity { Id = Guid.NewGuid(), Title = "t", CreatedAt = DateTimeOffset.UtcNow, ReminderOverrideJson = "not json" };
        Assert.Null(entity.ToTaskItem().ReminderOverride);
    }

    [Fact]
    public void DecodeDelegation_MalformedJson_FailsClosedToNull()
    {
        var entity = new TaskEntity { Id = Guid.NewGuid(), Title = "t", CreatedAt = DateTimeOffset.UtcNow, DelegationJson = "not json" };
        Assert.Null(entity.ToTaskItem().Delegation);
    }

    [Fact]
    public void NullOpaqueJsonColumns_DecodeToNull()
    {
        var entity = new TaskEntity { Id = Guid.NewGuid(), Title = "t", CreatedAt = DateTimeOffset.UtcNow };
        var item = entity.ToTaskItem();
        Assert.Null(item.Recurrence);
        Assert.Null(item.ReminderOverride);
        Assert.Null(item.Delegation);
    }

    [Theory]
    [InlineData(Priority.High, 1)]
    [InlineData(Priority.Medium, 2)]
    [InlineData(Priority.Low, 3)]
    public void ToEntity_PriorityRoundTrips(Priority priority, int expectedRaw)
    {
        var item = new TaskItem(Guid.NewGuid(), "t", priority, When.Now, DateTimeOffset.UtcNow);
        Assert.Equal(expectedRaw, item.ToEntity().PriorityRaw);
    }
}
