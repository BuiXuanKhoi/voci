// CompletionEventRepositoryTests.cs — port of CompletionLog.swift's range-query surface
// (events(in:)/forDay/forWeek/forMonth/groupedByParent).
using Volar.Data.Entities;
using Xunit;

namespace Volar.Data.Tests;

public sealed class CompletionEventRepositoryTests
{
    private static async Task<Guid> SeedCompletedTaskAsync(SqliteTestDatabase db, DateTimeOffset completedAt, Guid? parentId = null)
    {
        await using var context = db.CreateContext();
        var id = Guid.NewGuid();
        context.CompletionEvents.Add(new CompletionEventEntity
        {
            Id = Guid.NewGuid(),
            TaskId = id,
            TitleSnapshot = "Task",
            ParentIdSnapshot = parentId,
            CompletedAt = completedAt,
        });
        await context.SaveChangesAsync();
        return id;
    }

    [Fact]
    public async Task EventsInRangeAsync_IsHalfOpen_IncludesStartExcludesEnd()
    {
        using var db = new SqliteTestDatabase();
        var start = new DateTimeOffset(2026, 7, 1, 0, 0, 0, TimeSpan.Zero);
        var end = start.AddDays(1);
        await SeedCompletedTaskAsync(db, start); // at the boundary — included
        await SeedCompletedTaskAsync(db, end); // at the boundary — excluded
        await SeedCompletedTaskAsync(db, start.AddHours(12)); // inside — included

        var repo = db.CreateCompletionEventRepository();
        var result = await repo.EventsInRangeAsync(start, end);

        Assert.Equal(2, result.Count);
    }

    [Fact]
    public async Task EventsInRangeAsync_OrdersDescendingByCompletedAt()
    {
        using var db = new SqliteTestDatabase();
        var start = new DateTimeOffset(2026, 7, 1, 0, 0, 0, TimeSpan.Zero);
        await SeedCompletedTaskAsync(db, start.AddHours(1));
        await SeedCompletedTaskAsync(db, start.AddHours(3));
        await SeedCompletedTaskAsync(db, start.AddHours(2));

        var repo = db.CreateCompletionEventRepository();
        var result = await repo.EventsInRangeAsync(start, start.AddDays(1));

        Assert.Equal(
            [start.AddHours(3), start.AddHours(2), start.AddHours(1)],
            result.Select(e => e.CompletedAt));
    }

    [Fact]
    public async Task EventsForDayAsync_ExcludesAdjacentDays()
    {
        using var db = new SqliteTestDatabase();
        var midDay = new DateTimeOffset(2026, 7, 18, 12, 0, 0, TimeSpan.Zero);
        await SeedCompletedTaskAsync(db, midDay);
        await SeedCompletedTaskAsync(db, midDay.AddDays(-1));
        await SeedCompletedTaskAsync(db, midDay.AddDays(1));

        var repo = db.CreateCompletionEventRepository();
        var result = await repo.EventsForDayAsync(midDay, TimeZoneInfo.Utc);

        Assert.Single(result);
    }

    [Fact]
    public async Task EventsForWeekAsync_CoversSevenDays()
    {
        using var db = new SqliteTestDatabase();
        // 2026-07-18 is a Saturday; the containing Sunday-start week is 2026-07-12 .. 2026-07-19.
        var reference = new DateTimeOffset(2026, 7, 18, 12, 0, 0, TimeSpan.Zero);
        await SeedCompletedTaskAsync(db, new DateTimeOffset(2026, 7, 12, 0, 0, 0, TimeSpan.Zero)); // start of week
        await SeedCompletedTaskAsync(db, new DateTimeOffset(2026, 7, 18, 23, 59, 0, TimeSpan.Zero)); // same week
        await SeedCompletedTaskAsync(db, new DateTimeOffset(2026, 7, 19, 0, 0, 0, TimeSpan.Zero)); // next week — excluded

        var repo = db.CreateCompletionEventRepository();
        var result = await repo.EventsForWeekAsync(reference, TimeZoneInfo.Utc);

        Assert.Equal(2, result.Count);
    }

    [Fact]
    public async Task EventsForMonthAsync_CoversCalendarMonth()
    {
        using var db = new SqliteTestDatabase();
        var reference = new DateTimeOffset(2026, 7, 15, 0, 0, 0, TimeSpan.Zero);
        await SeedCompletedTaskAsync(db, new DateTimeOffset(2026, 7, 1, 0, 0, 0, TimeSpan.Zero));
        await SeedCompletedTaskAsync(db, new DateTimeOffset(2026, 7, 31, 23, 0, 0, TimeSpan.Zero));
        await SeedCompletedTaskAsync(db, new DateTimeOffset(2026, 8, 1, 0, 0, 0, TimeSpan.Zero)); // excluded
        await SeedCompletedTaskAsync(db, new DateTimeOffset(2026, 6, 30, 23, 0, 0, TimeSpan.Zero)); // excluded

        var repo = db.CreateCompletionEventRepository();
        var result = await repo.EventsForMonthAsync(reference, TimeZoneInfo.Utc);

        Assert.Equal(2, result.Count);
    }

    [Fact]
    public async Task GroupedByParent_GroupsStandaloneCompletionsUnderNullKey()
    {
        using var db = new SqliteTestDatabase();
        var parentId = Guid.NewGuid();
        var now = DateTimeOffset.UtcNow;
        await SeedCompletedTaskAsync(db, now, parentId);
        await SeedCompletedTaskAsync(db, now, parentId);
        await SeedCompletedTaskAsync(db, now, null);

        var repo = db.CreateCompletionEventRepository();
        var events = await repo.EventsInRangeAsync(now.AddMinutes(-1), now.AddMinutes(1));
        var grouped = Volar.Data.CompletionEventRepository.GroupedByParent(events);

        Assert.Equal(2, grouped[parentId].Count());
        Assert.Single(grouped[null]);
    }
}
