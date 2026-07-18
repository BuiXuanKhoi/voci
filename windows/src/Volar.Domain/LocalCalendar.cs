namespace Volar.Domain;

/// <summary>
/// Small injected-timezone date-math helpers shared by <see cref="RecurrenceEngine"/> and
/// <see cref="HeuristicNLParser"/>.
/// </summary>
/// <remarks>
/// Every method here converts a <see cref="DateTimeOffset"/> instant into <c>timeZone</c>'s local
/// wall-clock time, performs the requested arithmetic against that wall-clock
/// <see cref="DateTime"/> (so day/month addition and day-of-week lookups follow local calendar
/// days, not raw 24h/30-day increments), then converts the result back to an absolute instant. This
/// is the injected-<see cref="TimeZoneInfo"/> equivalent of Swift's <c>Calendar</c>-based date
/// arithmetic (see <c>Recurrence.swift</c>'s <c>RecurrenceEngine.advance</c> doc comment) and never
/// reads <see cref="TimeZoneInfo.Local"/> or any system clock — <c>timeZone</c> is always an
/// explicit parameter.
/// </remarks>
internal static class LocalCalendar
{
    /// <summary><paramref name="instant"/> shifted by <paramref name="days"/> local calendar days.</summary>
    public static DateTimeOffset AddDays(DateTimeOffset instant, int days, TimeZoneInfo timeZone)
        => FromLocal(ToLocal(instant, timeZone).AddDays(days), timeZone);

    /// <summary>
    /// <paramref name="instant"/> shifted by <paramref name="months"/> local calendar months.
    /// <see cref="DateTime.AddMonths(int)"/> already clamps an invalid resulting day-of-month down
    /// to the last valid day of the target month (e.g. Jan 31 + 1 month -&gt; Feb 28), which is the
    /// same clamping behavior <c>Recurrence.swift</c>'s doc comment expects (but could not verify on
    /// Mac) from <c>Calendar.date(byAdding: .month...)</c>.
    /// </summary>
    public static DateTimeOffset AddMonths(DateTimeOffset instant, int months, TimeZoneInfo timeZone)
        => FromLocal(ToLocal(instant, timeZone).AddMonths(months), timeZone);

    /// <summary>
    /// The same local calendar day as <paramref name="instant"/>, with the wall-clock time replaced
    /// by <paramref name="hour"/>:<paramref name="minute"/>:00.
    /// </summary>
    public static DateTimeOffset WithTimeOfDay(DateTimeOffset instant, int hour, int minute, TimeZoneInfo timeZone)
    {
        var local = ToLocal(instant, timeZone);
        var replaced = new DateTime(local.Year, local.Month, local.Day, hour, minute, 0, DateTimeKind.Unspecified);
        return FromLocal(replaced, timeZone);
    }

    /// <summary>
    /// ISO-ish weekday number for <paramref name="instant"/>'s local calendar day, using the SAME
    /// convention as Swift's <c>Calendar.component(.weekday, from:)</c>: Sunday = 1 ... Saturday = 7
    /// (NOT .NET's own <see cref="DayOfWeek"/>, which is zero-based starting at Sunday).
    /// </summary>
    public static int LocalWeekday(DateTimeOffset instant, TimeZoneInfo timeZone)
        => (int)ToLocal(instant, timeZone).DayOfWeek + 1;

    private static DateTime ToLocal(DateTimeOffset instant, TimeZoneInfo timeZone)
        => TimeZoneInfo.ConvertTime(instant, timeZone).DateTime;

    /// <summary>
    /// Converts a local (<see cref="DateTimeKind.Unspecified"/>) wall-clock <see cref="DateTime"/>
    /// back to an absolute instant under <paramref name="timeZone"/>.
    /// </summary>
    /// <remarks>
    /// Deliberately built on <see cref="TimeZoneInfo.GetUtcOffset(DateTime)"/> rather than
    /// <see cref="TimeZoneInfo.ConvertTimeToUtc(DateTime, TimeZoneInfo)"/> — empirically verified
    /// (this project's own tests, against a real DST zone; something the Swift source's equivalent
    /// comment could not do without a Mac) that <c>ConvertTimeToUtc</c> THROWS
    /// <see cref="ArgumentException"/> for a local time that falls in a spring-forward gap (e.g.
    /// 2024-03-10 02:30 America/Los_Angeles, which never occurred), which would crash a perfectly
    /// legitimate recurrence/reminder computation that happens to land in a gap. <c>GetUtcOffset</c>
    /// never throws for gap/overlap times: for a gap it returns the offset in effect just before the
    /// transition, which — combined with the arithmetic below — has the effect of shifting the
    /// invalid wall-clock instant forward by exactly the gap's width (02:30 invalid resolves to a
    /// real 03:30 post-transition instant); for a fall-back overlap it resolves to the later
    /// (post-transition, standard-time) occurrence. Both outcomes are "always a valid instant, never
    /// an exception", matching what <c>Recurrence.swift</c>'s doc comment wanted from
    /// <c>Calendar</c> but could not confirm.
    /// </remarks>
    private static DateTimeOffset FromLocal(DateTime local, TimeZoneInfo timeZone)
    {
        var unspecified = DateTime.SpecifyKind(local, DateTimeKind.Unspecified);
        var offset = timeZone.GetUtcOffset(unspecified);
        return new DateTimeOffset(unspecified, offset).ToUniversalTime();
    }
}
