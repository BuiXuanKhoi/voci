using Volar.Core;
using Volar.Domain;
using Xunit;

namespace Volar.Domain.Tests;

public class RecurrenceTests
{
    // Fixed, deterministic, non-DST zone (Indochina Time, UTC+7, no DST transitions) for tests that
    // don't specifically target DST behavior.
    private static readonly TimeZoneInfo Ict = TimeZoneInfo.CreateCustomTimeZone("ICT-test", TimeSpan.FromHours(7), "ICT", "ICT");

    // Real DST zone (Windows id) for the DST-specific tests below — 2024 US rules: spring-forward
    // 2024-03-10 02:00 -> 03:00, fall-back 2024-11-03 02:00 -> 01:00.
    private static readonly TimeZoneInfo Pacific = TimeZoneInfo.FindSystemTimeZoneById("Pacific Standard Time");

    // MARK: - Advance

    [Fact]
    public void Advance_Daily_AddsOneLocalDay()
    {
        var anchor = new DateTimeOffset(2026, 3, 15, 9, 0, 0, TimeSpan.FromHours(7));
        var next = RecurrenceEngine.Advance(anchor, new Recurrence.Daily(), Ict);
        Assert.Equal(new DateTimeOffset(2026, 3, 16, 9, 0, 0, TimeSpan.FromHours(7)), next);
    }

    [Fact]
    public void Advance_Weekly_AddsSevenLocalDays()
    {
        var anchor = new DateTimeOffset(2026, 3, 15, 9, 0, 0, TimeSpan.FromHours(7));
        var next = RecurrenceEngine.Advance(anchor, new Recurrence.Weekly(), Ict);
        Assert.Equal(new DateTimeOffset(2026, 3, 22, 9, 0, 0, TimeSpan.FromHours(7)), next);
    }

    [Fact]
    public void Advance_Monthly_JanuaryThirtyFirst_ClampsToFebruaryTwentyEighth()
    {
        var anchor = new DateTimeOffset(2026, 1, 31, 10, 0, 0, TimeSpan.FromHours(7)); // 2026 is not a leap year
        var next = RecurrenceEngine.Advance(anchor, new Recurrence.Monthly(), Ict);
        Assert.Equal(new DateTimeOffset(2026, 2, 28, 10, 0, 0, TimeSpan.FromHours(7)), next);
    }

    [Fact]
    public void Advance_Monthly_LeapYearFebruaryTwentyNinth_ClampsToMarchTwentyNinth()
    {
        var anchor = new DateTimeOffset(2024, 2, 29, 10, 0, 0, TimeSpan.FromHours(7)); // 2024 is a leap year
        var next = RecurrenceEngine.Advance(anchor, new Recurrence.Monthly(), Ict);
        Assert.Equal(new DateTimeOffset(2024, 3, 29, 10, 0, 0, TimeSpan.FromHours(7)), next);
    }

    [Fact]
    public void Advance_Every_AddsExactDayCount()
    {
        var anchor = new DateTimeOffset(2026, 3, 15, 9, 0, 0, TimeSpan.FromHours(7));
        var next = RecurrenceEngine.Advance(anchor, new Recurrence.Every(10), Ict);
        Assert.Equal(new DateTimeOffset(2026, 3, 25, 9, 0, 0, TimeSpan.FromHours(7)), next);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(-3)]
    public void Advance_Every_MalformedNonPositiveDays_ReturnsNull(int days)
    {
        var anchor = new DateTimeOffset(2026, 3, 15, 9, 0, 0, TimeSpan.FromHours(7));
        var next = RecurrenceEngine.Advance(anchor, new Recurrence.Every(days), Ict);
        Assert.Null(next);
    }

    // MARK: - Advance: DST

    [Fact]
    public void Advance_Daily_AcrossSpringForwardGap_ResolvesToValidInstant_NeverThrows()
    {
        // 2024-03-09 02:30 local (PST, -08:00) + 1 day = 2024-03-10 02:30, which never occurred
        // (clocks jumped 02:00 -> 03:00 that day). Must resolve to a valid instant, not throw.
        var anchor = new DateTimeOffset(2024, 3, 9, 2, 30, 0, TimeSpan.FromHours(-8));
        var next = RecurrenceEngine.Advance(anchor, new Recurrence.Daily(), Pacific);

        Assert.NotNull(next);
        var localNext = TimeZoneInfo.ConvertTime(next!.Value, Pacific);
        // Empirically verified (see LocalCalendarTests): the invalid instant resolves by shifting
        // forward to the first valid wall-clock time after the gap, landing on 03:30 PDT.
        Assert.Equal(new DateTime(2024, 3, 10, 3, 30, 0), localNext.DateTime);
        Assert.Equal(TimeSpan.FromHours(-7), localNext.Offset); // now in daylight time (PDT)
    }

    [Fact]
    public void Advance_Daily_AcrossFallBackOverlap_ResolvesWithoutThrowing()
    {
        // 2024-11-02 01:30 local + 1 day = 2024-11-03 01:30, which occurs TWICE that day (clocks
        // fall back 02:00 -> 01:00). Must resolve to one definite instant, not throw.
        var anchor = new DateTimeOffset(2024, 11, 2, 1, 30, 0, TimeSpan.FromHours(-7));
        var next = RecurrenceEngine.Advance(anchor, new Recurrence.Daily(), Pacific);

        Assert.NotNull(next);
        var localNext = TimeZoneInfo.ConvertTime(next!.Value, Pacific);
        Assert.Equal(new DateTime(2024, 11, 3, 1, 30, 0), localNext.DateTime);
        // Resolves to the LATER (post-fallback, standard time) occurrence.
        Assert.Equal(TimeSpan.FromHours(-8), localNext.Offset);
    }

    // MARK: - Reset: schedule-anchored (default) vs anchor-to-completion

    [Fact]
    public void Reset_ScheduleAnchored_WeeklyMondayStaysMonday()
    {
        // A weekly task due Monday, completed late on Wednesday: schedule-anchored reset must land
        // on the FOLLOWING Monday, not "a week from Wednesday".
        var deadline = new DateTimeOffset(2026, 3, 16, 9, 0, 0, TimeSpan.FromHours(7)); // Monday
        var completedAt = new DateTimeOffset(2026, 3, 18, 14, 0, 0, TimeSpan.FromHours(7)); // Wednesday

        var reset = RecurrenceEngine.Reset(
            new Recurrence.Weekly(), deadline, Array.Empty<Condition>(), completedAt,
            anchorToCompletion: false, timeZone: Ict);

        Assert.Equal(new DateTimeOffset(2026, 3, 23, 9, 0, 0, TimeSpan.FromHours(7)), reset.Deadline); // next Monday
    }

    [Fact]
    public void Reset_AnchorToCompletion_ReanchorsThisOneCycle()
    {
        var deadline = new DateTimeOffset(2026, 3, 16, 9, 0, 0, TimeSpan.FromHours(7)); // Monday
        var completedAt = new DateTimeOffset(2026, 3, 18, 14, 0, 0, TimeSpan.FromHours(7)); // Wednesday

        var reset = RecurrenceEngine.Reset(
            new Recurrence.Weekly(), deadline, Array.Empty<Condition>(), completedAt,
            anchorToCompletion: true, timeZone: Ict);

        // Anchored to completedAt: one week after Wednesday's completion.
        Assert.Equal(new DateTimeOffset(2026, 3, 25, 14, 0, 0, TimeSpan.FromHours(7)), reset.Deadline);
    }

    [Fact]
    public void Reset_NoDeadline_NoAnchorToCompletion_StaysUndated()
    {
        var reset = RecurrenceEngine.Reset(
            new Recurrence.Daily(), null, Array.Empty<Condition>(), DateTimeOffset.UtcNow,
            anchorToCompletion: false, timeZone: Ict);

        Assert.Null(reset.Deadline);
    }

    [Fact]
    public void Reset_NoDeadline_AnchorToCompletion_AdvancesFromCompletion()
    {
        var completedAt = new DateTimeOffset(2026, 3, 18, 14, 0, 0, TimeSpan.FromHours(7));
        var reset = RecurrenceEngine.Reset(
            new Recurrence.Daily(), null, Array.Empty<Condition>(), completedAt,
            anchorToCompletion: true, timeZone: Ict);

        Assert.Equal(completedAt.AddDays(1), reset.Deadline);
    }

    [Fact]
    public void Reset_MultiPeriodLateCompletion_LoopsUntilStrictlyFuture()
    {
        // A daily task, last due 5 days before it was completed: a single Advance would still land
        // in the past (1 day after the stale deadline) and immediately re-fire as overdue. The reset
        // must loop until the result is strictly after completedAt.
        var staleDeadline = new DateTimeOffset(2026, 3, 10, 9, 0, 0, TimeSpan.FromHours(7));
        var completedAt = new DateTimeOffset(2026, 3, 15, 20, 0, 0, TimeSpan.FromHours(7)); // 5 days later

        var reset = RecurrenceEngine.Reset(
            new Recurrence.Daily(), staleDeadline, Array.Empty<Condition>(), completedAt,
            anchorToCompletion: false, timeZone: Ict);

        Assert.NotNull(reset.Deadline);
        Assert.True(reset.Deadline > completedAt);
        // Same wall-clock time-of-day (09:00) preserved, six days after the stale deadline (the
        // first occurrence strictly after completedAt).
        Assert.Equal(new DateTimeOffset(2026, 3, 16, 9, 0, 0, TimeSpan.FromHours(7)), reset.Deadline);
    }

    // MARK: - Reset: condition handling

    [Fact]
    public void Reset_AfterDateCondition_ShiftsByTheSameRule()
    {
        // The condition's prior date must be at-or-before completedAt for NextOccurrence to advance
        // it at all (a date already strictly after completedAt needs no shift — see
        // Reset_MultiPeriodLateCompletion_LoopsUntilStrictlyFuture for that boundary case).
        var afterDate = new DateTimeOffset(2026, 3, 9, 9, 0, 0, TimeSpan.FromHours(7));
        var completedAt = new DateTimeOffset(2026, 3, 15, 20, 0, 0, TimeSpan.FromHours(7));
        var conditions = new Condition[] { new AfterDateCondition(afterDate) };

        var reset = RecurrenceEngine.Reset(
            new Recurrence.Weekly(), null, conditions, completedAt, anchorToCompletion: false, timeZone: Ict);

        var shifted = Assert.IsType<AfterDateCondition>(Assert.Single(reset.Conditions));
        Assert.Equal(afterDate.AddDays(7), shifted.Date);
    }

    [Fact]
    public void Reset_ExternalCondition_ResetsToUnsatisfied()
    {
        var conditions = new Condition[] { new ExternalCondition("waiting on design review", true) };
        var reset = RecurrenceEngine.Reset(
            new Recurrence.Daily(), null, conditions, DateTimeOffset.UtcNow, anchorToCompletion: false, timeZone: Ict);

        var external = Assert.IsType<ExternalCondition>(Assert.Single(reset.Conditions));
        Assert.False(external.Satisfied);
        Assert.Equal("waiting on design review", external.Description);
    }

    [Fact]
    public void Reset_TaskDoneCondition_LeftUntouched()
    {
        var targetId = Guid.NewGuid();
        var conditions = new Condition[] { new TaskDoneCondition(targetId) };
        var reset = RecurrenceEngine.Reset(
            new Recurrence.Daily(), null, conditions, DateTimeOffset.UtcNow, anchorToCompletion: false, timeZone: Ict);

        var taskDone = Assert.IsType<TaskDoneCondition>(Assert.Single(reset.Conditions));
        Assert.Equal(targetId, taskDone.TaskId);
    }

    [Fact]
    public void Reset_MixedConditions_EachHandledIndependently()
    {
        var targetId = Guid.NewGuid();
        var afterDate = new DateTimeOffset(2026, 3, 16, 9, 0, 0, TimeSpan.FromHours(7));
        var completedAt = new DateTimeOffset(2026, 3, 15, 20, 0, 0, TimeSpan.FromHours(7));
        var conditions = new Condition[]
        {
            new TaskDoneCondition(targetId),
            new AfterDateCondition(afterDate),
            new ExternalCondition("waiting on legal", true)
        };

        var reset = RecurrenceEngine.Reset(
            new Recurrence.Daily(), null, conditions, completedAt, anchorToCompletion: false, timeZone: Ict);

        Assert.Equal(3, reset.Conditions.Count);
        Assert.IsType<TaskDoneCondition>(reset.Conditions[0]);
        Assert.IsType<AfterDateCondition>(reset.Conditions[1]);
        var external = Assert.IsType<ExternalCondition>(reset.Conditions[2]);
        Assert.False(external.Satisfied);
    }
}
