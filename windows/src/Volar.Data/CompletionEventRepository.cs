// CompletionEventRepository.cs — port of Sources/Model/CompletionLog.swift's `enum CompletionLog`
// query surface. `recordCompletion(of:in:)` itself is NOT ported here — it is embedded directly in
// TaskRepository.CompleteOne (see TaskRepository.cs) so it shares the SAME DbContext/SaveChanges
// call as the rest of a completion transaction (status flip, recurrence reset, parent cascade),
// exactly matching the Swift original's comment: "the caller is responsible for ... calling
// context.save() afterward so this can be batched with the rest of the same completion
// transaction." This type covers only the pure range-query surface (FR-035 rollups).
//
// CALENDAR NOTE: `EventsForDayAsync`/`ForWeekAsync`/`ForMonthAsync` need a caller-supplied
// TimeZoneInfo (never TimeZoneInfo.Local implicitly, matching Volar.Core's purity convention) to
// decide interval boundaries. Week start is Sunday (System.Globalization.CultureInfo.InvariantCulture's
// default DFirstDayOfWeek) — Swift's `Calendar.current.dateInterval(of: .weekOfYear, ...)` depends
// on the device's region setting, so an exact match isn't achievable without also threading a
// locale through; Sunday-start was chosen as the most common default and is easy to revisit later.
using Microsoft.EntityFrameworkCore;
using Volar.Data.Entities;

namespace Volar.Data;

public sealed class CompletionEventRepository(IDbContextFactory<VolarDbContext> contextFactory)
{
    private readonly IDbContextFactory<VolarDbContext> _contextFactory = contextFactory;

    /// Port of `CompletionLog.events(in:context:)`. Half-open interval: `start <= completedAt <
    /// end`, matching the Swift `#Predicate`.
    public async Task<IReadOnlyList<CompletionEventEntity>> EventsInRangeAsync(
        DateTimeOffset start, DateTimeOffset end, CancellationToken ct = default)
    {
        await using var context = await _contextFactory.CreateDbContextAsync(ct);
        return await context.CompletionEvents
            .Where(e => e.CompletedAt >= start && e.CompletedAt < end)
            .OrderByDescending(e => e.CompletedAt)
            .ToListAsync(ct);
    }

    /// Port of `CompletionLog.events(forDay:calendar:context:)`.
    public Task<IReadOnlyList<CompletionEventEntity>> EventsForDayAsync(
        DateTimeOffset date, TimeZoneInfo timeZone, CancellationToken ct = default)
    {
        var (start, end) = DayInterval(date, timeZone);
        return EventsInRangeAsync(start, end, ct);
    }

    /// Port of `CompletionLog.events(forWeek:calendar:context:)`.
    public Task<IReadOnlyList<CompletionEventEntity>> EventsForWeekAsync(
        DateTimeOffset date, TimeZoneInfo timeZone, CancellationToken ct = default)
    {
        var (start, end) = WeekInterval(date, timeZone);
        return EventsInRangeAsync(start, end, ct);
    }

    /// Port of `CompletionLog.events(forMonth:calendar:context:)`.
    public Task<IReadOnlyList<CompletionEventEntity>> EventsForMonthAsync(
        DateTimeOffset date, TimeZoneInfo timeZone, CancellationToken ct = default)
    {
        var (start, end) = MonthInterval(date, timeZone);
        return EventsInRangeAsync(start, end, ct);
    }

    /// Port of `CompletionLog.groupedByParent(_:)`. Pure in-memory grouping of an already-narrow
    /// (range-queried) result set — not a full-history scan. The `null` key holds standalone
    /// (no-parent) completions.
    public static ILookup<Guid?, CompletionEventEntity> GroupedByParent(IEnumerable<CompletionEventEntity> events) =>
        // `Dictionary<TKey, TValue>` requires a `notnull` TKey, which `Guid?` (the `null` bucket
        // holds standalone, no-parent completions) does not satisfy — `ILookup` has no such
        // constraint and is otherwise an equally natural "key -> group" shape for this read-only
        // result.
        events.ToLookup(e => e.ParentIdSnapshot);

    private static (DateTimeOffset Start, DateTimeOffset End) DayInterval(DateTimeOffset instant, TimeZoneInfo timeZone)
    {
        var local = TimeZoneInfo.ConvertTime(instant, timeZone);
        var startLocal = new DateTimeOffset(local.Year, local.Month, local.Day, 0, 0, 0, timeZone.GetUtcOffset(local));
        return (startLocal, startLocal.AddDays(1));
    }

    private static (DateTimeOffset Start, DateTimeOffset End) WeekInterval(DateTimeOffset instant, TimeZoneInfo timeZone)
    {
        var local = TimeZoneInfo.ConvertTime(instant, timeZone);
        var daysSinceSunday = (int)local.DayOfWeek; // Sunday = 0
        var startOfDay = new DateTimeOffset(local.Year, local.Month, local.Day, 0, 0, 0, timeZone.GetUtcOffset(local));
        var startOfWeek = startOfDay.AddDays(-daysSinceSunday);
        return (startOfWeek, startOfWeek.AddDays(7));
    }

    private static (DateTimeOffset Start, DateTimeOffset End) MonthInterval(DateTimeOffset instant, TimeZoneInfo timeZone)
    {
        var local = TimeZoneInfo.ConvertTime(instant, timeZone);
        var startOfMonth = new DateTimeOffset(local.Year, local.Month, 1, 0, 0, 0, timeZone.GetUtcOffset(local));
        var startOfNextMonth = startOfMonth.AddMonths(1);
        return (startOfMonth, startOfNextMonth);
    }
}
