// TaskRepositoryCompletionTests.cs — ToggleAsync: open<->done round trip, Rule 5 (completing the
// last open child auto-completes the parent, cascading upward), and recurring-task completion via
// the injected IRecurrenceResetter seam (see IRecurrenceResetter.cs).
using Microsoft.EntityFrameworkCore;
using Volar.Core;
using Volar.Data.Entities;
using Xunit;

namespace Volar.Data.Tests;

public sealed class TaskRepositoryCompletionTests
{
    [Fact]
    public async Task ToggleAsync_OnOpenTask_MarksDoneAndRecordsCompletionEvent()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();
        var task = Fixtures.NewTask(title: "Write report");
        await repo.AddAsync(task);
        var now = new DateTimeOffset(2026, 7, 18, 10, 0, 0, TimeSpan.Zero);

        await repo.ToggleAsync(task.Id, now: now, timeZone: TimeZoneInfo.Utc);

        var stored = (await repo.GetAllAsync()).Single();
        Assert.Equal(TaskState.Done, stored.Status);
        Assert.Equal(now, stored.CompletedAt);

        await using var context = db.CreateContext();
        var completionEvent = Assert.Single(context.CompletionEvents);
        Assert.Equal(task.Id, completionEvent.TaskId);
        Assert.Equal("Write report", completionEvent.TitleSnapshot);
        Assert.Equal(now, completionEvent.CompletedAt);
    }

    [Fact]
    public async Task ToggleAsync_OnDoneTask_ReopensAndClearsCompletedAt()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();
        var task = Fixtures.NewTask(title: "Write report");
        await repo.AddAsync(task);
        await repo.ToggleAsync(task.Id);

        await repo.ToggleAsync(task.Id);

        var stored = (await repo.GetAllAsync()).Single();
        Assert.Equal(TaskState.Todo, stored.Status);
        Assert.Null(stored.CompletedAt);
    }

    [Fact]
    public async Task ToggleAsync_UnknownId_IsANoOp()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();

        await repo.ToggleAsync(Guid.NewGuid());

        Assert.Empty(await repo.GetAllAsync());
    }

    [Fact]
    public async Task Rule5_CompletingLastOpenChild_CascadesParentToDone()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();
        var parent = Fixtures.NewTask(title: "Parent");
        await repo.AddAsync(parent);
        var onlyChild = Fixtures.NewTask(title: "Only child", parentId: parent.Id);
        await repo.AddAsync(onlyChild);

        await repo.ToggleAsync(onlyChild.Id);

        var all = await repo.GetAllAsync();
        Assert.Equal(TaskState.Done, all.Single(t => t.Id == onlyChild.Id).Status);
        Assert.Equal(TaskState.Done, all.Single(t => t.Id == parent.Id).Status);
    }

    [Fact]
    public async Task Rule5_CompletingOneOfSeveralOpenChildren_DoesNotCascadeParent()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();
        var parent = Fixtures.NewTask(title: "Parent");
        await repo.AddAsync(parent);
        var childA = Fixtures.NewTask(title: "Child A", parentId: parent.Id);
        var childB = Fixtures.NewTask(title: "Child B", parentId: parent.Id);
        await repo.AddBatchAsync([childA, childB]);

        await repo.ToggleAsync(childA.Id);

        var all = await repo.GetAllAsync();
        Assert.Equal(TaskState.Done, all.Single(t => t.Id == childA.Id).Status);
        Assert.Equal(TaskState.Todo, all.Single(t => t.Id == parent.Id).Status);
    }

    [Fact]
    public async Task Rule5_CascadeUpThroughGrandparent_WhenEachLevelsLastChildCompletes()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();
        var grandparent = Fixtures.NewTask(title: "Grandparent");
        await repo.AddAsync(grandparent);
        var parent = Fixtures.NewTask(title: "Parent", parentId: grandparent.Id);
        await repo.AddAsync(parent);
        var child = Fixtures.NewTask(title: "Child", parentId: parent.Id);
        await repo.AddAsync(child);

        await repo.ToggleAsync(child.Id);

        var all = await repo.GetAllAsync();
        Assert.Equal(TaskState.Done, all.Single(t => t.Id == child.Id).Status);
        Assert.Equal(TaskState.Done, all.Single(t => t.Id == parent.Id).Status);
        Assert.Equal(TaskState.Done, all.Single(t => t.Id == grandparent.Id).Status);
    }

    [Fact]
    public async Task ToggleAsync_RecurringTask_InvokesResetterAndReopensInstead()
    {
        using var db = new SqliteTestDatabase();
        var resetter = new FixedOffsetRecurrenceResetter(TimeSpan.FromDays(7));
        var repo = db.CreateTaskRepository(resetter);
        var deadline = new DateTimeOffset(2026, 7, 18, 9, 0, 0, TimeSpan.Zero);
        var task = Fixtures.NewTask(title: "Weekly review", deadline: deadline, recurrenceJson: """{"kind":"weekly"}""");
        await repo.AddAsync(task);

        await repo.ToggleAsync(task.Id, now: deadline, timeZone: TimeZoneInfo.Utc);

        Assert.Equal(1, resetter.CallCount);
        var stored = (await repo.GetAllAsync()).Single();
        // Reopens (never stays Done) with the resetter's computed next deadline.
        Assert.Equal(TaskState.Todo, stored.Status);
        Assert.Equal(deadline + TimeSpan.FromDays(7), stored.Deadline);

        await using var context = db.CreateContext();
        // A completion event is still recorded for this occurrence even though the task reopens.
        Assert.Single(context.CompletionEvents);
    }

    [Fact]
    public async Task ToggleAsync_NonRecurringTask_NeverInvokesResetter()
    {
        using var db = new SqliteTestDatabase();
        var resetter = new FixedOffsetRecurrenceResetter(TimeSpan.FromDays(1));
        var repo = db.CreateTaskRepository(resetter);
        var task = Fixtures.NewTask(title: "One-off");
        await repo.AddAsync(task);

        await repo.ToggleAsync(task.Id);

        Assert.Equal(0, resetter.CallCount);
    }

    /// <summary>
    /// Regression test for the "Modified vs Added" EF Core bug fixed in CompleteOne (see that
    /// method's long comment on the `context.Add(condition.ToEntity(...))` line): a recurring
    /// task's reset conditions are written onto an already-tracked <c>TaskEntity</c> loaded via
    /// `Include` earlier in `ToggleAsync`. Because <see cref="ConditionMapping.ToEntity"/> assigns a
    /// real, non-default <see cref="Guid"/> primary key before the entity is ever seen by the
    /// ChangeTracker, appending it via plain `task.Conditions.Add(...)` (as opposed to an explicit
    /// `context.Add(...)`) makes EF Core assume the row already exists and mark it Modified instead
    /// of Added — producing a `DbUpdateConcurrencyException` on save instead of an INSERT.
    ///
    /// <see cref="FixedOffsetRecurrenceResetter"/> (used by every other recurrence test in this
    /// file) always returns an empty conditions list, so it never exercised this write path — hence
    /// <see cref="ConditionsRecurrenceResetter"/>, which returns one condition of each of the three
    /// kinds <see cref="ConditionMapping.ToEntity"/> handles, deliberately covering all three
    /// switch arms.
    /// </summary>
    [Fact]
    public async Task ToggleAsync_RecurringTask_PersistsResetConditionsOfEveryKind()
    {
        using var db = new SqliteTestDatabase();

        // A real target task for the TaskDoneCondition to reference — CompleteOne writes the
        // resetter's conditions verbatim with no re-validation, but a real id keeps the fixture
        // honest/realistic.
        var seedRepo = db.CreateTaskRepository();
        var dependency = Fixtures.NewTask(title: "Dependency");
        await seedRepo.AddAsync(dependency);

        var deadline = new DateTimeOffset(2026, 7, 18, 9, 0, 0, TimeSpan.Zero);
        var oldCondition = new AfterDateCondition(new DateTimeOffset(2026, 1, 1, 0, 0, 0, TimeSpan.Zero));
        var task = Fixtures.NewTask(
            title: "Weekly review",
            deadline: deadline,
            recurrenceJson: """{"kind":"weekly"}""",
            conditions: [oldCondition]);
        await seedRepo.AddAsync(task);
        var oldConditionId = task.Conditions.Single().Id;

        IReadOnlyList<Condition> newConditions =
        [
            new TaskDoneCondition(dependency.Id),
            new AfterDateCondition(new DateTimeOffset(2026, 8, 1, 0, 0, 0, TimeSpan.Zero)),
            new ExternalCondition("waiting on legal", Satisfied: false),
        ];
        var resetter = new ConditionsRecurrenceResetter(TimeSpan.FromDays(7), newConditions);
        var repo = db.CreateTaskRepository(resetter);

        // Bug reproduction: previously threw DbUpdateConcurrencyException when this branch ran with
        // a non-empty reset conditions list.
        await repo.ToggleAsync(task.Id, now: deadline, timeZone: TimeZoneInfo.Utc);

        Assert.Equal(1, resetter.CallCount);

        var storedTask = (await repo.GetAllAsync()).Single(t => t.Id == task.Id);
        Assert.Equal(TaskState.Todo, storedTask.Status);
        Assert.Equal(deadline + TimeSpan.FromDays(7), storedTask.Deadline);

        // Read back via a FRESH context — not the one ToggleAsync used — so this actually proves the
        // rows made it to disk rather than trusting the in-memory object graph.
        await using var context = db.CreateContext();
        var storedConditions = await context.Conditions
            .Where(c => c.TaskId == task.Id)
            .OrderBy(c => c.OrderIndex)
            .ToListAsync();

        Assert.Equal(3, storedConditions.Count);
        // The old pre-reset condition was fully replaced, not appended to — matches
        // TaskStore.swift's completeOne, which does `model.conditions = reset.conditions` (a plain
        // assignment, not an append).
        Assert.DoesNotContain(storedConditions, c => c.Id == oldConditionId);

        Assert.Equal([0, 1, 2], storedConditions.Select(c => c.OrderIndex));

        var taskDoneRow = storedConditions[0];
        Assert.Equal("taskDone", taskDoneRow.Kind);
        Assert.Equal(dependency.Id, taskDoneRow.TaskDoneTargetId);

        var afterDateRow = storedConditions[1];
        Assert.Equal("afterDate", afterDateRow.Kind);
        Assert.Equal(new DateTimeOffset(2026, 8, 1, 0, 0, 0, TimeSpan.Zero), afterDateRow.AfterDate);

        var externalRow = storedConditions[2];
        Assert.Equal("external", externalRow.Kind);
        Assert.Equal("waiting on legal", externalRow.ExternalDescription);
        Assert.False(externalRow.ExternalSatisfied);
    }
}
