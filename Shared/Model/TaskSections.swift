// Sources/Model/TaskSections.swift — which sidebar section (Today/Upcoming/Inbox) a task belongs
// to. Port of the Windows reference implementation, which shipped and was approved first:
// voci-windows/windows/src/Volar.Domain/TaskSections.cs (+ its own TaskSectionsTests.cs). Anh Khôi
// chốt 2026-07-27 (same decision text as the Windows file's header):
//
//   Inbox    = open, no deadline, no conditions — "nói ra rồi nhưng chưa xếp vào đâu". The pile a
//              voice-first app inevitably produces: capture now, decide later.
//   Upcoming = anything with a time cue after today, whether that cue is a DEADLINE or an
//              `.afterDate` condition (deferred to a date). Including defers is the load-bearing
//              part: a task deferred to next Tuesday is invisible on Today by design, and if
//              Upcoming only looked at deadlines it would be invisible everywhere until Tuesday
//              arrived.
//
// The two sets are disjoint by construction (Inbox demands no deadline AND no conditions; Upcoming
// demands one of those two carrying a future date), and neither overlaps Today, which owns overdue
// and due-today work. A task with only a past-dated condition or a past deadline is therefore in
// none of them — that is Today's business, not this file's.
//
// Pure, per the repo's domain rule (see e.g. VolarCore.nextTask's own doc comment): `now` is always
// a parameter, never a clock read, and the local-day boundary is resolved through an explicit
// `Calendar`/`TimeZone` rather than `Date()`/`Calendar.current` implicitly.
//
// UNVERIFIED — authored on Windows, no Swift toolchain available here; not compiled or run. Needs a
// Mac build/test pass (`Volar/Tests/TaskSectionsTests.swift` covers this file) before shipping.
import Foundation
import VolarCore

enum TaskSections {
    /// The first instant of tomorrow in `timeZone` — the cut-off both queries are written against,
    /// so "after today" means "on a later calendar day", never "more than 24h from now". Anything
    /// at or after this instant is Upcoming; anything before it belongs to Today. Mirrors
    /// `TaskSections.StartOfTomorrow` (TaskSections.cs:34-35).
    static func startOfTomorrow(now: Date, timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: now)
        // `date(byAdding:)` only fails for pathological calendar/date combinations; falling back to
        // `today` (rather than force-unwrapping) keeps this function total instead of crashing on
        // an edge case neither this port nor the Windows original ever exercises.
        return calendar.date(byAdding: .day, value: 1, to: today) ?? today
    }

    /// Open, undated, unblocked — see file header. Mirrors `TaskSections.IsInbox` (TaskSections.cs:38-39).
    static func isInbox(_ task: TaskItem) -> Bool {
        !isResolved(task) && task.deadline == nil && task.conditions.isEmpty
    }

    /// The date this task should sort/group under in Upcoming, or `nil` when it does not belong
    /// there. When a task carries BOTH a future deadline and a future defer, the EARLIER instant
    /// wins: the defer is when it becomes actionable and the deadline is when it is due, so the
    /// earlier of the two is the next date the user has to care about it. Mirrors
    /// `TaskSections.UpcomingDate` (TaskSections.cs:47-65).
    static func upcomingDate(_ task: TaskItem, startOfTomorrow: Date) -> Date? {
        guard !isResolved(task) else { return nil }

        var earliest: Date?
        if let deadline = task.deadline, deadline >= startOfTomorrow {
            earliest = deadline
        }
        for condition in task.conditions {
            guard case .afterDate(let date) = condition, date >= startOfTomorrow else { continue }
            if earliest == nil || date < earliest! {
                earliest = date
            }
        }
        return earliest
    }

    /// Convenience over `upcomingDate(_:startOfTomorrow:)` for callers that only need the predicate
    /// (nav counts). Mirrors `TaskSections.IsUpcoming` (TaskSections.cs:69-70).
    static func isUpcoming(_ task: TaskItem, startOfTomorrow: Date) -> Bool {
        upcomingDate(task, startOfTomorrow: startOfTomorrow) != nil
    }

    /// Done and Archived are both "off the list" — Archived is not a synonym for Done, but neither
    /// belongs in a section that exists to show outstanding work. Mirrors `TaskSections.IsResolved`
    /// (TaskSections.cs:74-75).
    private static func isResolved(_ task: TaskItem) -> Bool {
        task.status == .done || task.status == .archived
    }
}
