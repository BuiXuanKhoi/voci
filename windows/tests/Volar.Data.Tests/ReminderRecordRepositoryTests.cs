// ReminderRecordRepositoryTests.cs — Wave 3-B (A2): coverage for ReminderRecordRepository.cs, the
// real SQLite-backed Volar.Reminders.IReminderRecordStore implementation. Uses SqliteTestDatabase
// (this project's existing fixture — a fresh, migrated, temp-file-backed database per test) and
// Fixtures.NewTask to satisfy ReminderRecordEntity.TaskId's cascade-delete FK to TaskEntity, exactly
// like every other Volar.Data.Tests file that needs a real parent row.
using Volar.Reminders;
using Xunit;

namespace Volar.Data.Tests;

public sealed class ReminderRecordRepositoryTests
{
    private static ReminderRecordRepository CreateRepository(SqliteTestDatabase db) => new(db.Factory);

    [Fact]
    public void LoadAll_OnEmptyStore_ReturnsEmpty()
    {
        using var db = new SqliteTestDatabase();
        var repo = CreateRepository(db);

        Assert.Empty(repo.LoadAll());
    }

    [Fact]
    public async Task Upsert_InsertsNewRow_ThenLoadAllReturnsIt()
    {
        using var db = new SqliteTestDatabase();
        var task = Fixtures.NewTask();
        await db.CreateTaskRepository().AddAsync(task);
        var repo = CreateRepository(db);
        var fireAt = new DateTimeOffset(2026, 8, 1, 9, 0, 0, TimeSpan.Zero);
        var record = new ReminderRecord(taskId: task.Id, fireAt: fireAt, offsetKind: "-1d", isHighUrgency: false);

        repo.Upsert(record);
        var all = repo.LoadAll();

        var stored = Assert.Single(all);
        Assert.Equal(record.Id, stored.Id);
        Assert.Equal(task.Id, stored.TaskId);
        Assert.Equal(fireAt, stored.FireAt);
        Assert.Equal("-1d", stored.OffsetKind);
        Assert.Equal("scheduled", stored.State);
        Assert.False(stored.IsHighUrgency);
    }

    [Fact]
    public async Task Upsert_SameIdTwice_UpdatesInPlace_NeverDuplicates()
    {
        using var db = new SqliteTestDatabase();
        var task = Fixtures.NewTask();
        await db.CreateTaskRepository().AddAsync(task);
        var repo = CreateRepository(db);
        var record = new ReminderRecord(taskId: task.Id, fireAt: DateTimeOffset.UtcNow, offsetKind: "at", isHighUrgency: true);
        repo.Upsert(record);

        // Mutate in place (mirrors ReminderScheduler.Fire's `record.State = "delivered"` then
        // PersistUpsert(record) — the write-through path this repository exists to serve) and
        // upsert again under the SAME id.
        record.State = "delivered";
        repo.Upsert(record);

        var all = repo.LoadAll();
        var stored = Assert.Single(all); // must still be exactly one row, not two
        Assert.Equal("delivered", stored.State);
    }

    [Fact]
    public async Task Delete_RemovesRow()
    {
        using var db = new SqliteTestDatabase();
        var task = Fixtures.NewTask();
        await db.CreateTaskRepository().AddAsync(task);
        var repo = CreateRepository(db);
        var record = new ReminderRecord(taskId: task.Id, fireAt: DateTimeOffset.UtcNow, offsetKind: "at");
        repo.Upsert(record);

        repo.Delete(record.Id);

        Assert.Empty(repo.LoadAll());
    }

    [Fact]
    public void Delete_UnknownId_IsNoOp()
    {
        using var db = new SqliteTestDatabase();
        var repo = CreateRepository(db);

        var exception = Record.Exception(() => repo.Delete(Guid.NewGuid()));

        Assert.Null(exception);
    }

    [Fact]
    public async Task UpsertRange_BatchInsertsMultipleRowsInOneCall()
    {
        using var db = new SqliteTestDatabase();
        var task = Fixtures.NewTask();
        await db.CreateTaskRepository().AddAsync(task);
        var repo = CreateRepository(db);
        var deadline = new DateTimeOffset(2026, 8, 1, 9, 0, 0, TimeSpan.Zero);
        var records = ReminderRecord.Derive(task.Id, deadline, reminderOverride: null); // 3 offsets

        repo.UpsertRange(records);
        var all = repo.LoadAll();

        Assert.Equal(3, all.Count);
        Assert.Equal(
            records.Select(r => r.Id).OrderBy(id => id),
            all.Select(r => r.Id).OrderBy(id => id));
    }

    [Fact]
    public async Task UpsertRange_MixOfNewAndExisting_UpdatesExistingAndInsertsNew()
    {
        using var db = new SqliteTestDatabase();
        var task = Fixtures.NewTask();
        await db.CreateTaskRepository().AddAsync(task);
        var repo = CreateRepository(db);
        var existing = new ReminderRecord(taskId: task.Id, fireAt: DateTimeOffset.UtcNow, offsetKind: "-1h");
        repo.Upsert(existing);

        existing.State = "satisfied";
        var brandNew = new ReminderRecord(taskId: task.Id, fireAt: DateTimeOffset.UtcNow.AddDays(1), offsetKind: "at");
        repo.UpsertRange([existing, brandNew]);

        var all = repo.LoadAll();
        Assert.Equal(2, all.Count);
        Assert.Equal("satisfied", all.Single(r => r.Id == existing.Id).State);
        Assert.Contains(all, r => r.Id == brandNew.Id);
    }

    [Fact]
    public async Task UtcRoundTrip_NonUtcInputOffset_PreservesTheAbsoluteInstant()
    {
        using var db = new SqliteTestDatabase();
        var task = Fixtures.NewTask();
        await db.CreateTaskRepository().AddAsync(task);
        var repo = CreateRepository(db);
        // Deliberately a non-UTC offset — DateTimeOffsetUtcConverters normalizes to UTC on write
        // and every stored value shares that zero offset; equality is by absolute instant, not by
        // the original offset (see Converters/DateTimeOffsetUtcConverters.cs's own doc comment).
        var fireAt = new DateTimeOffset(2026, 8, 1, 16, 0, 0, TimeSpan.FromHours(7));
        var record = new ReminderRecord(taskId: task.Id, fireAt: fireAt, offsetKind: "at");

        repo.Upsert(record);
        var stored = Assert.Single(repo.LoadAll());

        Assert.Equal(fireAt, stored.FireAt); // DateTimeOffset == compares by instant
        Assert.Equal(TimeSpan.Zero, stored.FireAt.Offset); // ...but the stored offset is always UTC
    }

    [Fact]
    public async Task Upsert_ForATaskIdWithNoMatchingTaskRow_ThrowsInsteadOfSilentlyOrphaning()
    {
        // FK note (see ReminderRecordRepository.cs's header): ReminderRecordEntity.TaskId is a
        // cascade-delete FK to TaskEntity. A reminder can only ever legitimately be derived from a
        // task that already exists, so a caller passing an unknown taskId is a real bug, and the
        // FK constraint is expected to surface it loudly rather than insert an orphan row.
        using var db = new SqliteTestDatabase();
        var repo = CreateRepository(db);
        var orphan = new ReminderRecord(taskId: Guid.NewGuid(), fireAt: DateTimeOffset.UtcNow, offsetKind: "at");

        Assert.ThrowsAny<Exception>(() => repo.Upsert(orphan));
    }

    [Fact]
    public async Task DeletingTheParentTask_CascadesToItsReminderRecords()
    {
        using var db = new SqliteTestDatabase();
        var task = Fixtures.NewTask();
        var taskRepo = db.CreateTaskRepository();
        await taskRepo.AddAsync(task);
        var repo = CreateRepository(db);
        repo.UpsertRange(ReminderRecord.Derive(task.Id, task.Deadline ?? DateTimeOffset.UtcNow.AddDays(1), null));
        Assert.NotEmpty(repo.LoadAll());

        await taskRepo.DeleteAsync(task.Id);

        Assert.Empty(repo.LoadAll());
    }
}
