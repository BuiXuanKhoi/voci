// CascadeDeleteTests.cs — verifies the FK cascade/no-cascade behavior configured in
// VolarDbContext.OnModelCreating actually holds at the database level (not just in application
// code): Conditions cascade with their owning Task, ReminderRecords cascade with their owning Task
// (this port's own design decision — see ReminderRecordEntity's doc comment), and CompletionEvents
// deliberately do NOT cascade (by design — historical record, see CompletionEventEntity's doc
// comment) and remain queryable with a now-dangling TaskId after the source task is deleted.
using Volar.Core;
using Volar.Data.Entities;
using Xunit;

namespace Volar.Data.Tests;

public sealed class CascadeDeleteTests
{
    [Fact]
    public async Task DeletingTask_CascadesItsOwnConditions()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();
        var target = Fixtures.NewTask(
            title: "Has conditions",
            conditions: [new ExternalCondition("waiting", Satisfied: false)]);
        await repo.AddAsync(target);

        await repo.DeleteAsync(target.Id);

        await using var context = db.CreateContext();
        Assert.Empty(context.Conditions.Where(c => c.TaskId == target.Id));
    }

    [Fact]
    public async Task DeletingTask_CascadesItsReminderRecords()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();
        var task = Fixtures.NewTask(title: "Has reminders", deadline: DateTimeOffset.UtcNow.AddDays(1));
        await repo.AddAsync(task);

        await using (var context = db.CreateContext())
        {
            context.ReminderRecords.Add(new ReminderRecordEntity
            {
                Id = Guid.NewGuid(),
                TaskId = task.Id,
                FireAt = DateTimeOffset.UtcNow.AddHours(1),
                OffsetKind = "at",
            });
            await context.SaveChangesAsync();
        }

        await repo.DeleteAsync(task.Id);

        await using var verifyContext = db.CreateContext();
        Assert.Empty(verifyContext.ReminderRecords.Where(r => r.TaskId == task.Id));
    }

    [Fact]
    public async Task DeletingTask_DoesNotTouchCompletionEvents_TaskIdDanglesByDesign()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();
        var task = Fixtures.NewTask(title: "Completed once");
        await repo.AddAsync(task);
        await repo.ToggleAsync(task.Id); // records a CompletionEvent for task.Id

        await repo.DeleteAsync(task.Id);

        await using var context = db.CreateContext();
        var events = context.CompletionEvents.Where(e => e.TaskId == task.Id).ToList();
        Assert.Single(events); // still there — history, not a live reference.
    }
}
