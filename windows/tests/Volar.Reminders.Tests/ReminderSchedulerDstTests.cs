// ReminderSchedulerDstTests.cs — NEW (not in the Swift original; required by this task's brief).
//
// Covers the DST-gap trap documented on ReminderScheduler.SetLocalTime's doc comment and already
// hit once in this Windows port (Volar.Domain/LocalCalendar.cs): converting a local wall-clock time
// that falls inside a spring-forward gap back to UTC via `TimeZoneInfo.ConvertTimeToUtc` throws
// `ArgumentException`, which would crash a perfectly legitimate "snooze to tomorrow morning"/
// "reschedule tonight/this weekend" computation that happens to land on a gap day. `SetLocalTime`
// is built on `TimeZoneInfo.GetUtcOffset` instead, which never throws.
//
// `TomorrowMorning`/`Tonight`/`NextWeekend` were promoted from `private` to `internal` (see
// ReminderScheduler.cs) specifically so `SetLocalTime` itself — the actual DST-risk function — is
// directly testable here, since none of its three callers' hardcoded hours (09:00/20:00/10:00) ever
// coincides with the US Pacific spring-forward gap (02:00-02:59:59 on the transition date).
using Xunit;

namespace Volar.Reminders.Tests;

public class ReminderSchedulerDstTests
{
    private static TimeZoneInfo PacificTimeZone() => TimeZoneInfo.FindSystemTimeZoneById("Pacific Standard Time");

    [Fact]
    public void ConvertTimeToUtcThrowsForALocalTimeInsideTheSpringForwardGap_DocumentingTheTrapBeingAvoided()
    {
        var timeZone = PacificTimeZone();
        // 2024-03-10 02:30 America/Los_Angeles never occurred: clocks jumped from 02:00 to 03:00.
        var localGapTime = new DateTime(2024, 3, 10, 2, 30, 0, DateTimeKind.Unspecified);

        Assert.Throws<ArgumentException>(() => TimeZoneInfo.ConvertTimeToUtc(localGapTime, timeZone));
    }

    [Fact]
    public void SetLocalTimeResolvesAGapInstantForwardInsteadOfThrowing()
    {
        var timeZone = PacificTimeZone();
        var gapDate = new DateTime(2024, 3, 10);

        // Must not throw for a wall-clock time inside the gap.
        var result = ReminderScheduler.SetLocalTime(gapDate, hour: 2, minute: 30, timeZone: timeZone);

        // GetUtcOffset resolves a gap instant using the offset in effect just before the
        // transition, which shifts the invalid 02:30 wall-clock instant forward by the gap's width
        // (one hour) to a real 03:30 post-transition instant — never backward, never an exception.
        var resultLocal = TimeZoneInfo.ConvertTime(result, timeZone);
        Assert.Equal(new DateTime(2024, 3, 10, 3, 30, 0), resultLocal.DateTime);
    }

    [Fact]
    public void SetLocalTimeIsUnaffectedOutsideTheGap()
    {
        var timeZone = PacificTimeZone();
        var ordinaryDate = new DateTime(2024, 6, 15); // deep summer, no transition nearby

        var result = ReminderScheduler.SetLocalTime(ordinaryDate, hour: 9, minute: 0, timeZone: timeZone);

        var resultLocal = TimeZoneInfo.ConvertTime(result, timeZone);
        Assert.Equal(new DateTime(2024, 6, 15, 9, 0, 0), resultLocal.DateTime);
    }

    [Fact]
    public void SetLocalTimeResolvesFallBackOverlapToThePostTransitionOccurrence()
    {
        var timeZone = PacificTimeZone();
        // 2024-11-03: clocks fall back from 02:00 to 01:00 — 01:30 occurs TWICE (once PDT, once
        // PST). GetUtcOffset resolves the ambiguous local time to the later (standard-time)
        // occurrence, matching the doc comment on SetLocalTime.
        var overlapDate = new DateTime(2024, 11, 3);

        var result = ReminderScheduler.SetLocalTime(overlapDate, hour: 1, minute: 30, timeZone: timeZone);

        // The standard-time (post-transition) 01:30 occurrence is UTC-8; the daylight-time
        // (pre-transition) 01:30 occurrence would have been UTC-7 — one hour earlier in UTC.
        var expectedUtc = new DateTimeOffset(2024, 11, 3, 1, 30, 0, TimeSpan.FromHours(-8)).ToUniversalTime();
        Assert.Equal(expectedUtc, result);
    }

    [Fact]
    public void HandleActionRescheduleActionsNeverThrowAcrossTheSpringForwardTransitionDay()
    {
        var (scheduler, store, _) = Fixtures.MakeScheduler(timeZone: PacificTimeZone());
        var deadline = new DateTimeOffset(2024, 3, 9, 12, 0, 0, TimeSpan.FromHours(-8));
        var task = Fixtures.MakeTask(title: $"DST reschedule test {Guid.NewGuid()}", deadline: deadline);
        store.Add(task);

        scheduler.RebuildFromStorage(deadline);
        var record = scheduler.RecordsForTask(task.Id).First();

        // "now" sits the evening before the spring-forward transition day; Tomorrow/Tonight/Weekend
        // all compute local wall-clock times that may fall on or near the transition day.
        var now = new DateTimeOffset(2024, 3, 9, 22, 0, 0, TimeSpan.FromHours(-8));

        var exception = Record.Exception(() =>
        {
            scheduler.HandleAction(ReminderAction.RescheduleTomorrow, record.Id, now);
            scheduler.HandleAction(ReminderAction.RescheduleTonight, record.Id, now);
            scheduler.HandleAction(ReminderAction.RescheduleWeekend, record.Id, now);
        });

        Assert.Null(exception);
    }
}
