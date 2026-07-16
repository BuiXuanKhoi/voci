import Foundation
import VociCore

// MARK: - Deterministic time fixtures
//
// All tests anchor on a single fixed reference "now" and a fixed Gregorian calendar with an
// explicit UTC time zone, so "today"/"overdue" classification (and any date arithmetic) never
// depends on the machine's local timezone or the wall-clock time the tests happen to run at.

/// Fixed calendar used by every test: Gregorian, explicit UTC time zone.
let testCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

/// Fixed reference instant: 2026-07-15 12:00:00 UTC.
let referenceNow: Date = {
    var components = DateComponents()
    components.calendar = testCalendar
    components.timeZone = testCalendar.timeZone
    components.year = 2026
    components.month = 7
    components.day = 15
    components.hour = 12
    components.minute = 0
    components.second = 0
    return testCalendar.date(from: components)!
}()

/// A deadline instant later on the same calendar day as `referenceNow` (still "today").
func todayLater(hour: Int = 18) -> Date {
    var components = testCalendar.dateComponents([.year, .month, .day], from: referenceNow)
    components.hour = hour
    return testCalendar.date(from: components)!
}

/// A deadline instant earlier on the same calendar day as `referenceNow` (still "today", and
/// also strictly before `referenceNow`, i.e. simultaneously "overdue" and "today" — both
/// classify as near-term).
func todayEarlier(hour: Int = 6) -> Date {
    var components = testCalendar.dateComponents([.year, .month, .day], from: referenceNow)
    components.hour = hour
    return testCalendar.date(from: components)!
}

/// A deadline `days` calendar days offset from `referenceNow`, preserving time-of-day.
/// Negative `days` yields a past (overdue) deadline; positive yields a future deadline.
func daysFromReferenceNow(_ days: Int) -> Date {
    testCalendar.date(byAdding: .day, value: days, to: referenceNow)!
}

/// A clearly-overdue deadline (yesterday, same time of day as `referenceNow`).
func yesterday() -> Date {
    daysFromReferenceNow(-1)
}

/// A clearly-future deadline beyond today (tomorrow, same time of day as `referenceNow`).
func tomorrow() -> Date {
    daysFromReferenceNow(1)
}

// MARK: - Deterministic id fixtures

/// Produces a stable, orderable `UUID` from a small integer so tests can reason about the
/// id-lexical tiebreak (tier 5) predictably: `fixedUUID(1)` sorts before `fixedUUID(2)`, etc.,
/// because both render as the same-length zero-padded hex suffix.
func fixedUUID(_ n: Int) -> UUID {
    let hex = String(format: "%012x", n)
    return UUID(uuidString: "00000000-0000-0000-0000-\(hex)")!
}

// MARK: - Task builder

/// Builds a `Task` with sensible defaults so each test only needs to specify the fields it
/// actually cares about.
func makeTask(
    id: UUID = UUID(),
    title: String = "Untitled task",
    status: TaskStatus = .todo,
    priority: Int? = nil,
    deadline: Date? = nil,
    conditions: [Condition] = [],
    estimateMinutes: Int? = nil,
    parentId: UUID? = nil,
    createdAt: Date = referenceNow
) -> Task {
    Task(
        id: id,
        title: title,
        status: status,
        priority: priority,
        deadline: deadline,
        conditions: conditions,
        estimateMinutes: estimateMinutes,
        parentId: parentId,
        createdAt: createdAt
    )
}
