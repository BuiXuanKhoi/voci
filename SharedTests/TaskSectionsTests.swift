// Tests/TaskSectionsTests.swift — XCTest coverage for Sources/Model/TaskSections.swift, the
// sidebar Today/Upcoming/Inbox membership rules. Mirrors the Windows reference suite's case list
// 1:1 (voci-windows/windows/tests/Volar.Domain.Tests/TaskSectionsTests.cs), adapted to
// TaskItem/VolarCore.Condition's Swift shapes instead of C#'s Task/Condition.
//
// UNVERIFIED (written entirely on Windows — no Xcode/xcodegen/simulator available here): confirm on
// Mac that `xcodegen generate` + `xcodebuild test` actually discovers and runs this file under the
// `VolarTests` target, same as every other file already in this directory.
import Foundation
import XCTest
import VolarCore
@testable import Volar

final class TaskSectionsTests: XCTestCase {

    // MARK: - Deterministic time fixtures (fixed, non-DST zone; nothing here reads the system clock)

    private static let ict = TimeZone(identifier: "Asia/Bangkok")! // UTC+7, no DST — mirrors the
    // Windows suite's own fixed "ICT-sections-test" custom zone.

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = ict
        return calendar
    }

    /// Monday 2026-03-16, 09:00 +07:00 — same reference instant as the Windows suite.
    private static let now: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 16
        components.hour = 9
        components.minute = 0
        components.second = 0
        return calendar.date(from: components)!
    }()

    private static var cutoff: Date { TaskSections.startOfTomorrow(now: now, timeZone: ict) }

    /// A local instant on 2026-03-`day` at `hour`:00 +07:00.
    private static func local(_ day: Int, _ hour: Int) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = day
        components.hour = hour
        components.minute = 0
        components.second = 0
        return calendar.date(from: components)!
    }

    private func makeTask(
        deadline: Date? = nil,
        conditions: [VolarCore.Condition] = [],
        status: TaskStatus = .todo
    ) -> TaskItem {
        TaskItem(title: "t", priority: .medium, status: status, deadline: deadline, conditions: conditions, when: .later)
    }

    // MARK: - The day boundary itself

    func testStartOfTomorrowIsLocalMidnightNotNowPlus24h() {
        let components = Self.calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: Self.cutoff
        )
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 3)
        XCTAssertEqual(components.day, 17)
        XCTAssertEqual(components.hour, 0)
        XCTAssertEqual(components.minute, 0)
        XCTAssertEqual(components.second, 0)
    }

    // MARK: - Inbox

    func testInboxNoDeadlineNoConditionsIsInbox() {
        XCTAssertTrue(TaskSections.isInbox(makeTask()))
    }

    func testInboxWithDeadlineIsNotInbox() {
        XCTAssertFalse(TaskSections.isInbox(makeTask(deadline: Self.local(20, 9))))
    }

    func testInboxWithAnyConditionIsNotInbox() {
        // Blocked-on-another-task is a chain, not an unsorted capture — even though it has no date.
        let blocked = makeTask(conditions: [.taskDone(UUID())])
        XCTAssertFalse(TaskSections.isInbox(blocked))
    }

    func testInboxResolvedTaskIsNotInbox() {
        XCTAssertFalse(TaskSections.isInbox(makeTask(status: .done)))
        XCTAssertFalse(TaskSections.isInbox(makeTask(status: .archived)))
    }

    // MARK: - Upcoming: deadlines

    func testUpcomingDeadlineTomorrowIsUpcoming() {
        let task = makeTask(deadline: Self.local(17, 9))
        XCTAssertEqual(TaskSections.upcomingDate(task, startOfTomorrow: Self.cutoff), Self.local(17, 9))
    }

    func testUpcomingDeadlineLaterTodayIsNotUpcoming() {
        // Still due today -> Today owns it, even though the instant is in the future.
        let task = makeTask(deadline: Self.local(16, 23))
        XCTAssertNil(TaskSections.upcomingDate(task, startOfTomorrow: Self.cutoff))
    }

    func testUpcomingOverdueDeadlineIsNotUpcoming() {
        let task = makeTask(deadline: Self.local(14, 9))
        XCTAssertNil(TaskSections.upcomingDate(task, startOfTomorrow: Self.cutoff))
    }

    func testUpcomingDeadlineExactlyAtMidnightIsUpcoming() {
        // The boundary is inclusive on the Upcoming side: 00:00 tomorrow is a later calendar day.
        let task = makeTask(deadline: Self.cutoff)
        XCTAssertEqual(TaskSections.upcomingDate(task, startOfTomorrow: Self.cutoff), Self.cutoff)
    }

    // MARK: - Upcoming: deferred tasks (the reason this section exists at all)

    func testUpcomingDeferredToFutureDateIsUpcomingEvenWithNoDeadline() {
        let deferred = makeTask(conditions: [.afterDate(Self.local(19, 8))])
        XCTAssertEqual(TaskSections.upcomingDate(deferred, startOfTomorrow: Self.cutoff), Self.local(19, 8))
    }

    func testUpcomingDeferPassedIsNotUpcoming() {
        let deferred = makeTask(conditions: [.afterDate(Self.local(15, 8))])
        XCTAssertNil(TaskSections.upcomingDate(deferred, startOfTomorrow: Self.cutoff))
    }

    func testUpcomingNonDateConditionDoesNotQualify() {
        let blocked = makeTask(conditions: [.external(description: "waiting on Bob", satisfied: false)])
        XCTAssertNil(TaskSections.upcomingDate(blocked, startOfTomorrow: Self.cutoff))
    }

    func testUpcomingDeadlineAndDeferGroupsUnderTheEarlier() {
        // Deferred to Wednesday, due Friday: Wednesday is the next date the user must care about.
        let both = makeTask(deadline: Self.local(20, 17), conditions: [.afterDate(Self.local(18, 8))])
        XCTAssertEqual(TaskSections.upcomingDate(both, startOfTomorrow: Self.cutoff), Self.local(18, 8))
    }

    func testUpcomingFutureDeadlineWithPastDeferUsesTheDeadline() {
        let both = makeTask(deadline: Self.local(20, 17), conditions: [.afterDate(Self.local(15, 8))])
        XCTAssertEqual(TaskSections.upcomingDate(both, startOfTomorrow: Self.cutoff), Self.local(20, 17))
    }

    func testUpcomingMultipleFutureDefersUsesTheEarliest() {
        let many = makeTask(conditions: [
            .afterDate(Self.local(22, 8)),
            .afterDate(Self.local(18, 8)),
            .afterDate(Self.local(25, 8)),
        ])
        XCTAssertEqual(TaskSections.upcomingDate(many, startOfTomorrow: Self.cutoff), Self.local(18, 8))
    }

    func testUpcomingResolvedTaskIsNotUpcoming() {
        let done = makeTask(deadline: Self.local(20, 9), status: .done)
        let archived = makeTask(deadline: Self.local(20, 9), status: .archived)
        XCTAssertNil(TaskSections.upcomingDate(done, startOfTomorrow: Self.cutoff))
        XCTAssertNil(TaskSections.upcomingDate(archived, startOfTomorrow: Self.cutoff))
    }

    // MARK: - The sections must not overlap

    func testInboxAndUpcomingAreDisjoint() {
        let candidates: [TaskItem] = [
            makeTask(),
            makeTask(deadline: Self.local(20, 9)),
            makeTask(deadline: Self.local(16, 23)),
            makeTask(conditions: [.afterDate(Self.local(19, 8))]),
            makeTask(conditions: [.taskDone(UUID())]),
        ]

        for task in candidates {
            XCTAssertFalse(TaskSections.isInbox(task) && TaskSections.isUpcoming(task, startOfTomorrow: Self.cutoff))
        }
    }
}
