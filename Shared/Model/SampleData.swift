// Sources/Model/SampleData.swift — ports SAMPLE_TASKS (design/tokens.jsx)
import Foundation

/// Static sample data for previews and first-run seeding (`TaskStore.loadOrSeed()`). Deadlines
/// are built from a fixed reference day — never `Date.now` — so every preview/snapshot is
/// stable across runs instead of drifting with the wall clock.
enum SampleData {
    /// Wednesday, May 21, 2025 — matches the "Wed, May 21" date shown in `design/volar-mac.jsx`'s
    /// Today header. Fixed in UTC so the derived times below never shift with the host's locale
    /// or the machine's local timezone.
    static let referenceDay: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar.date(from: DateComponents(year: 2025, month: 5, day: 21)) ?? Date(timeIntervalSince1970: 0)
    }()

    private static func time(_ hour: Int, _ minute: Int, dayOffset: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let day = calendar.date(byAdding: .day, value: dayOffset, to: referenceDay) ?? referenceDay
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    /// Ported from `SAMPLE_TASKS` — an indie hacker's day. Ids are fixed literals (rather than
    /// random `UUID()`s) so sample data has stable identity across app launches/previews.
    static let tasks: [TaskItem] = [
        TaskItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            title: "Ship the auth fix to staging", priority: .high, status: .todo,
            deadline: time(11, 30), conditions: [], createdAt: time(7, 0),
            when: .now, durationMinutes: 45, frog: true
        ),
        TaskItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            title: "Customer call — Acme onboarding feedback", priority: .high, status: .todo,
            deadline: time(14, 0), conditions: [], createdAt: time(7, 1),
            when: .now, durationMinutes: 30
        ),
        TaskItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            title: "Write landing page hero copy", priority: .medium, status: .todo,
            deadline: time(16, 0), conditions: [], createdAt: time(7, 2),
            when: .later, durationMinutes: 60
        ),
        TaskItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
            title: "Reply to investor email — Mira @ Lux Ventures", priority: .medium, status: .todo,
            deadline: time(17, 0), conditions: [], createdAt: time(7, 3),
            when: .later, durationMinutes: 20
        ),
        TaskItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
            title: "Push v0.4.2 build to TestFlight", priority: .high, status: .todo,
            deadline: time(19, 30), conditions: [], createdAt: time(7, 4),
            when: .later, durationMinutes: 15
        ),
        TaskItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!,
            title: "Set up Xcode project for v2", priority: .low, status: .done,
            deadline: time(9, 30), conditions: [], createdAt: time(7, 5),
            when: .later, durationMinutes: nil
        ),
        TaskItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000007")!,
            title: "Post launch teaser on X", priority: .low, status: .done,
            deadline: time(8, 50), conditions: [], createdAt: time(7, 6),
            when: .later, durationMinutes: nil
        ),
    ]
}
