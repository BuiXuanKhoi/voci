// TaskRepositoryCrudTests.cs — basic CRUD surface: fetch, add, add-batch, frog, corrections,
// active-task selection, sensitivity flag.
using Volar.Core;
using Volar.Data.Entities;
using Xunit;

namespace Volar.Data.Tests;

public sealed class TaskRepositoryCrudTests
{
    [Fact]
    public async Task GetAllAsync_OnEmptyStore_ReturnsEmpty()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();

        var all = await repo.GetAllAsync();

        Assert.Empty(all);
    }

    [Fact]
    public async Task AddAsync_ThenGetAllAsync_RoundTripsAllScalarFields()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();
        var deadline = new DateTimeOffset(2026, 8, 1, 9, 0, 0, TimeSpan.Zero);
        var created = new DateTimeOffset(2026, 7, 1, 8, 0, 0, TimeSpan.Zero);
        var task = Fixtures.NewTask(
            title: "Ship the report",
            status: TaskState.InProgress,
            priority: 1,
            deadline: deadline,
            createdAt: created,
            frog: true);
        task.Details = "Quarterly numbers";
        task.Notes = "double check totals";
        task.DurationMinutes = 45;

        await repo.AddAsync(task);
        var all = await repo.GetAllAsync();

        var stored = Assert.Single(all);
        Assert.Equal(task.Id, stored.Id);
        Assert.Equal("Ship the report", stored.Title);
        Assert.Equal("Quarterly numbers", stored.Details);
        Assert.Equal(TaskState.InProgress, stored.Status);
        Assert.Equal(1, stored.PriorityRaw);
        Assert.Equal(deadline, stored.Deadline);
        Assert.Equal(created, stored.CreatedAt);
        Assert.True(stored.Frog);
        Assert.Equal("double check totals", stored.Notes);
        Assert.Equal(45, stored.DurationMinutes);
    }

    [Fact]
    public async Task AddAsync_WithoutExplicitId_GeneratesOne()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();
        var task = Fixtures.NewTask();
        task.Id = Guid.Empty;

        await repo.AddAsync(task);
        var all = await repo.GetAllAsync();

        var stored = Assert.Single(all);
        Assert.NotEqual(Guid.Empty, stored.Id);
    }

    [Fact]
    public async Task GetAllAsync_OrdersByCreatedAt()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();
        var now = DateTimeOffset.UtcNow;
        var later = Fixtures.NewTask(title: "Later", createdAt: now.AddHours(2));
        var earlier = Fixtures.NewTask(title: "Earlier", createdAt: now);

        await repo.AddAsync(later);
        await repo.AddAsync(earlier);
        var all = await repo.GetAllAsync();

        Assert.Equal(["Earlier", "Later"], all.Select(t => t.Title));
    }

    [Fact]
    public async Task AddBatchAsync_UpToLimit_InsertsAll()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();
        var items = Enumerable.Range(0, TaskRepository.MaxBatchSize)
            .Select(i => Fixtures.NewTask(title: $"Task {i}"))
            .ToList();

        await repo.AddBatchAsync(items);
        var all = await repo.GetAllAsync();

        Assert.Equal(TaskRepository.MaxBatchSize, all.Count);
    }

    [Fact]
    public async Task AddBatchAsync_IntraBatchTaskDoneReference_ValidatesAgainstGrowingSnapshot()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();
        var first = Fixtures.NewTask(title: "Step 1");
        // Step 2 depends on Step 1, which is only in the SAME batch, earlier in the list — must
        // validate against the growing in-batch snapshot, matching TaskStore.addBatch's contract.
        var second = Fixtures.NewTask(title: "Step 2", conditions: [new TaskDoneCondition(first.Id)]);

        await repo.AddBatchAsync([first, second]);
        var all = await repo.GetAllAsync();

        var stepTwo = all.Single(t => t.Title == "Step 2");
        var condition = Assert.Single(stepTwo.Conditions);
        Assert.Equal("taskDone", condition.Kind);
        Assert.Equal(first.Id, condition.TaskDoneTargetId);
    }

    [Fact]
    public async Task SetFrogAsync_SetsExactlyOneFrog()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();
        var a = Fixtures.NewTask(title: "A", frog: true);
        var b = Fixtures.NewTask(title: "B");
        await repo.AddBatchAsync([a, b]);

        await repo.SetFrogAsync(b.Id);
        var all = await repo.GetAllAsync();

        Assert.False(all.Single(t => t.Id == a.Id).Frog);
        Assert.True(all.Single(t => t.Id == b.Id).Frog);
    }

    [Fact]
    public async Task SetFrogAsync_WithNull_ClearsEveryFrog()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();
        var a = Fixtures.NewTask(title: "A", frog: true);
        await repo.AddAsync(a);

        await repo.SetFrogAsync(null);
        var all = await repo.GetAllAsync();

        Assert.False(all.Single().Frog);
    }

    [Fact]
    public async Task RecordCorrectionAsync_InsertsRow()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();

        await repo.RecordCorrectionAsync("deadline", "Tomorrow 2pm", "Tomorrow 5pm", "remind me tomorrow at 5");

        await using var context = db.CreateContext();
        var correction = Assert.Single(context.ParseCorrections);
        Assert.Equal("deadline", correction.Attribute);
        Assert.Equal("Tomorrow 2pm", correction.ParsedValue);
        Assert.Equal("Tomorrow 5pm", correction.CorrectedValue);
        Assert.Equal("remind me tomorrow at 5", correction.Transcript);
    }

    [Fact]
    public async Task IsSensitiveAsync_UnknownId_ReturnsFalse()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();

        Assert.False(await repo.IsSensitiveAsync(Guid.NewGuid()));
    }

    [Fact]
    public async Task IsSensitiveAsync_ReflectsStoredFlag()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();
        var task = Fixtures.NewTask(isSensitive: true);
        await repo.AddAsync(task);

        Assert.True(await repo.IsSensitiveAsync(task.Id));
    }

    [Fact]
    public async Task GetActiveAsync_ReturnsEngineWinner()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();
        var now = new DateTimeOffset(2026, 7, 18, 12, 0, 0, TimeSpan.Zero);
        var highPriority = Fixtures.NewTask(title: "Urgent", priority: 1, createdAt: now.AddDays(-1));
        var lowPriority = Fixtures.NewTask(title: "Someday", priority: 4, createdAt: now.AddDays(-2));
        await repo.AddBatchAsync([lowPriority, highPriority]);

        var active = await repo.GetActiveAsync(now, TimeZoneInfo.Utc);

        Assert.NotNull(active);
        Assert.Equal("Urgent", active!.Title);
    }

    [Fact]
    public async Task GetActiveAsync_WhenNothingEligible_ReturnsNull()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();
        var done = Fixtures.NewTask(status: TaskState.Done);
        await repo.AddAsync(done);

        var active = await repo.GetActiveAsync(DateTimeOffset.UtcNow, TimeZoneInfo.Utc);

        Assert.Null(active);
    }
}
