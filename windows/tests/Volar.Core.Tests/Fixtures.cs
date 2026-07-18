using System.Globalization;
using Volar.Core;

namespace Volar.Core.Tests;

/// <summary>
/// Deterministic time/id/task fixtures shared by every test in this project. Port of Swift's
/// <c>Fixtures.swift</c>.
/// </summary>
/// <remarks>
/// All tests anchor on a single fixed reference "now" and a fixed UTC time zone, so
/// "today"/"overdue" classification (and any date arithmetic) never depends on the machine's
/// local time zone or the wall-clock time the tests happen to run at.
/// </remarks>
internal static class Fixtures
{
    /// <summary>Fixed time zone used by every test: explicit UTC, never <see cref="TimeZoneInfo.Local"/>.</summary>
    public static readonly TimeZoneInfo TestTimeZone = TimeZoneInfo.Utc;

    /// <summary>Fixed reference instant: 2026-07-15 12:00:00 UTC.</summary>
    public static readonly DateTimeOffset ReferenceNow = new(2026, 7, 15, 12, 0, 0, TimeSpan.Zero);

    /// <summary>A deadline instant later on the same calendar day as <see cref="ReferenceNow"/> (still "today").</summary>
    public static DateTimeOffset TodayLater(int hour = 18) =>
        new(ReferenceNow.Year, ReferenceNow.Month, ReferenceNow.Day, hour, 0, 0, TimeSpan.Zero);

    /// <summary>
    /// A deadline instant earlier on the same calendar day as <see cref="ReferenceNow"/> (still
    /// "today", and also strictly before <see cref="ReferenceNow"/>, i.e. simultaneously "overdue"
    /// and "today" — both classify as near-term).
    /// </summary>
    public static DateTimeOffset TodayEarlier(int hour = 6) =>
        new(ReferenceNow.Year, ReferenceNow.Month, ReferenceNow.Day, hour, 0, 0, TimeSpan.Zero);

    /// <summary>
    /// A deadline <paramref name="days"/> offset from <see cref="ReferenceNow"/>, preserving
    /// time-of-day. Negative <paramref name="days"/> yields a past (overdue) deadline; positive
    /// yields a future deadline.
    /// </summary>
    public static DateTimeOffset DaysFromReferenceNow(int days) => ReferenceNow.AddDays(days);

    /// <summary>A clearly-overdue deadline (yesterday, same time of day as <see cref="ReferenceNow"/>).</summary>
    public static DateTimeOffset Yesterday() => DaysFromReferenceNow(-1);

    /// <summary>A clearly-future deadline beyond today (tomorrow, same time of day as <see cref="ReferenceNow"/>).</summary>
    public static DateTimeOffset Tomorrow() => DaysFromReferenceNow(1);

    /// <summary>
    /// Produces a stable, orderable <see cref="Guid"/> from a small integer so tests can reason
    /// about the id-ordinal tiebreak (tier 5) predictably: <c>FixedGuid(1)</c> sorts before
    /// <c>FixedGuid(2)</c>, etc., because both render as the same-length zero-padded hex suffix.
    /// </summary>
    public static Guid FixedGuid(int n)
    {
        var hex = n.ToString("x12", CultureInfo.InvariantCulture);
        return Guid.Parse($"00000000-0000-0000-0000-{hex}", CultureInfo.InvariantCulture);
    }

    /// <summary>
    /// Builds a <see cref="TaskSnapshot"/> with sensible defaults so each test only needs to
    /// specify the fields it actually cares about. Port of Swift's <c>makeTask(...)</c> free
    /// function.
    /// </summary>
    public static TaskSnapshot MakeTask(
        Guid? id = null,
        string title = "Untitled task",
        TaskState status = TaskState.Todo,
        int? priority = null,
        DateTimeOffset? deadline = null,
        IReadOnlyList<Condition>? conditions = null,
        int? estimateMinutes = null,
        Guid? parentId = null,
        DateTimeOffset? createdAt = null) =>
        new(
            id ?? Guid.NewGuid(),
            title,
            status,
            priority,
            deadline,
            conditions ?? Array.Empty<Condition>(),
            estimateMinutes,
            parentId,
            createdAt ?? ReferenceNow);
}
