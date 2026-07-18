// DateTimeOffsetRoundTripTests.cs — proves the UTC-string ValueConverter (Converters/
// DateTimeOffsetUtcConverters.cs) round-trips the INSTANT exactly through SQLite, for both a
// non-nullable and a nullable DateTimeOffset column, and that a non-UTC input offset still compares
// equal after round-tripping (DateTimeOffset equality is instant-based, not offset-based — the
// converter deliberately discards the original offset, see that file's header comment for why).
using Volar.Data.Converters;
using Xunit;

namespace Volar.Data.Tests;

public sealed class DateTimeOffsetRoundTripTests
{
    [Fact]
    public void Converter_UtcInput_RoundTripsExactInstant()
    {
        var converter = new DateTimeOffsetToUtcStringConverter();
        var original = new DateTimeOffset(2026, 7, 18, 13, 45, 30, 123, TimeSpan.Zero);

        var stored = (string)converter.ConvertToProvider(original)!;
        var restored = (DateTimeOffset)converter.ConvertFromProvider(stored)!;

        Assert.Equal(original, restored);
        Assert.Equal(TimeSpan.Zero, restored.Offset);
    }

    [Fact]
    public void Converter_NonUtcInput_PreservesInstant_ButNormalizesOffsetToUtc()
    {
        var converter = new DateTimeOffsetToUtcStringConverter();
        // 09:00 at +07:00 is the same instant as 02:00 UTC.
        var original = new DateTimeOffset(2026, 7, 18, 9, 0, 0, TimeSpan.FromHours(7));

        var stored = (string)converter.ConvertToProvider(original)!;
        var restored = (DateTimeOffset)converter.ConvertFromProvider(stored)!;

        Assert.Equal(original, restored); // DateTimeOffset == compares by absolute instant.
        Assert.Equal(TimeSpan.Zero, restored.Offset); // offset itself is NOT preserved, by design.
        Assert.Equal(2, restored.UtcDateTime.Hour);
    }

    [Fact]
    public void NullableConverter_Null_RoundTripsToNull()
    {
        var converter = new NullableDateTimeOffsetToUtcStringConverter();

        var stored = converter.ConvertToProvider(null);
        Assert.Null(stored);

        var restored = converter.ConvertFromProvider(null);
        Assert.Null(restored);
    }

    [Fact]
    public async Task FullRoundTrip_ThroughSqlite_PreservesInstantForNonUtcInput()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();
        var deadline = new DateTimeOffset(2026, 12, 25, 9, 0, 0, TimeSpan.FromHours(-5)); // EST-ish
        var task = Fixtures.NewTask(title: "Holiday deadline", deadline: deadline);

        await repo.AddAsync(task);
        var stored = (await repo.GetAllAsync()).Single();

        Assert.Equal(deadline, stored.Deadline); // instant-equal despite offset normalization.
        Assert.Equal(deadline.UtcDateTime, stored.Deadline!.Value.UtcDateTime);
    }

    [Fact]
    public async Task FullRoundTrip_NullDeadline_StaysNull()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();
        var task = Fixtures.NewTask(title: "No deadline", deadline: null);

        await repo.AddAsync(task);

        Assert.Null((await repo.GetAllAsync()).Single().Deadline);
    }

    [Fact]
    public async Task StoredColumn_SortsChronologically_RegardlessOfOriginalOffset()
    {
        // Two events at the same wall-clock hour but different offsets, so a naive text sort on a
        // provider default (offset-suffixed) representation could get this backwards — the earlier
        // instant here is expressed with a LARGER local hour number and a positive offset.
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();
        var earlierInstant = new DateTimeOffset(2026, 7, 18, 15, 0, 0, TimeSpan.FromHours(9)); // 06:00 UTC
        var laterInstant = new DateTimeOffset(2026, 7, 18, 8, 0, 0, TimeSpan.FromHours(-2)); // 10:00 UTC
        await repo.AddBatchAsync(
        [
            Fixtures.NewTask(title: "Later", createdAt: laterInstant),
            Fixtures.NewTask(title: "Earlier", createdAt: earlierInstant),
        ]);

        var all = await repo.GetAllAsync(); // ordered by CreatedAt at the SQL level.

        Assert.Equal(["Earlier", "Later"], all.Select(t => t.Title));
    }
}
