// Volar.Domain/TaskSections.cs — which sidebar section a task belongs to.
//
// The sidebar has shipped three nav rows since Wave 1, but only Today was ever real: Upcoming and
// Inbox rendered hardcoded counts (12 and 3) and had no click action, on both platforms
// (Sidebar.swift's own empty `{}` closures, faithfully ported). This file is the definition those
// two rows never had. Anh Khôi chốt 2026-07-27:
//
//   Inbox    = open, no deadline, no conditions — "nói ra rồi nhưng chưa xếp vào đâu". The pile a
//              voice-first app inevitably produces: capture now, decide later.
//   Upcoming = anything with a time cue after today, whether that cue is a DEADLINE or an
//              `AfterDateCondition` (deferred to a date). Including defers is the load-bearing part:
//              a task deferred to next Tuesday is invisible on Today by design, and if Upcoming only
//              looked at deadlines it would be invisible everywhere until Tuesday arrived.
//
// The two sets are disjoint by construction (Inbox demands no deadline AND no conditions; Upcoming
// demands one of those two carrying a future date), and neither overlaps Today, which owns overdue
// and due-today work. A task with only a past-dated condition or a past deadline is therefore in
// none of them — that is Today's business, not this file's.
//
// Pure, per the domain rule every file here follows: `now` is always a parameter, never a clock
// read, and the local day boundary is resolved through LocalCalendar/TimeZoneInfo rather than
// DateTime.Today.
using Volar.Core;

namespace Volar.Domain;

public static class TaskSections
{
    /// <summary>
    /// The first instant of tomorrow in <paramref name="timeZone"/> — the cut-off both queries are
    /// written against, so "after today" means "on a later calendar day", never "more than 24h from
    /// now". Anything at or after this instant is Upcoming; anything before it belongs to Today.
    /// </summary>
    public static DateTimeOffset StartOfTomorrow(DateTimeOffset now, TimeZoneInfo timeZone) =>
        LocalCalendar.WithTimeOfDay(LocalCalendar.AddDays(now, 1, timeZone), 0, 0, timeZone);

    /// <summary>Open, undated, unblocked — see file header.</summary>
    public static bool IsInbox(TaskItem task) =>
        !IsResolved(task) && task.Deadline is null && task.Conditions.Count == 0;

    /// <summary>
    /// The date this task should sort/group under in Upcoming, or <see langword="null"/> when it
    /// does not belong there. When a task carries BOTH a future deadline and a future defer, the
    /// EARLIER instant wins: the defer is when it becomes actionable and the deadline is when it is
    /// due, so the earlier of the two is the next date the user has to care about it.
    /// </summary>
    public static DateTimeOffset? UpcomingDate(TaskItem task, DateTimeOffset startOfTomorrow)
    {
        if (IsResolved(task))
        {
            return null;
        }

        DateTimeOffset? earliest = task.Deadline >= startOfTomorrow ? task.Deadline : null;
        foreach (var condition in task.Conditions)
        {
            if (condition is AfterDateCondition after
                && after.Date >= startOfTomorrow
                && (earliest is null || after.Date < earliest))
            {
                earliest = after.Date;
            }
        }
        return earliest;
    }

    /// <summary>Convenience over <see cref="UpcomingDate"/> for callers that only need the
    /// predicate (nav counts).</summary>
    public static bool IsUpcoming(TaskItem task, DateTimeOffset startOfTomorrow) =>
        UpcomingDate(task, startOfTomorrow) is not null;

    /// <summary>Done and Archived are both "off the list" — Archived is not a synonym for Done, but
    /// neither belongs in a section that exists to show outstanding work.</summary>
    private static bool IsResolved(TaskItem task) =>
        task.Status is TaskState.Done or TaskState.Archived;
}
