// Sources/Reminders/NotificationActions.swift — UNNotificationCategory/action registration
// (T030). Every UNNotificationAction below is declared with `options: []` (never `.foreground`)
// — that is the load-bearing bit that keeps FR-014/015/016's "without opening the app window"
// guarantee true: omitting `.foreground` means the system invokes the delegate in the background
// instead of activating the app's UI. The `UNUserNotificationCenterDelegate` conformance that
// actually routes tapped actions lives on `ReminderScheduler` itself (see the extension at the
// bottom of `Sources/Reminders/ReminderScheduler.swift`) — `AppState` constructs exactly one
// scheduler for the app's lifetime and retains it, so self-assigning
// `UNUserNotificationCenter.current().delegate = self` there needs no separate delegate object
// for another agent to construct/retain.
import Foundation
import UserNotifications

/// Category identifiers (contract §A / T030): "deadline" (Done/Snooze 10m/Tomorrow),
/// "unblocked-ready" (no actions — a calm heads-up, not a decision), "overdue-reschedule"
/// (Tonight/Tomorrow/Weekend). No red/badge/shame styling anywhere here (constitution V) — plain
/// system banner chrome only.
enum ReminderCategory {
    static let deadline = "deadline"
    static let unblockedReady = "unblocked-ready"
    static let overdueReschedule = "overdue-reschedule"
}

enum ReminderAction {
    static let done = "VOCI_REMINDER_DONE"
    static let snooze10 = "VOCI_REMINDER_SNOOZE_10"
    static let tomorrow = "VOCI_REMINDER_TOMORROW"
    static let rescheduleTonight = "VOCI_RESCHEDULE_TONIGHT"
    static let rescheduleTomorrow = "VOCI_RESCHEDULE_TOMORROW"
    static let rescheduleWeekend = "VOCI_RESCHEDULE_WEEKEND"
}

enum NotificationActions {
    /// Registers all three categories with `UNUserNotificationCenter`. Idempotent — safe to call
    /// on every launch. Called from `AppDelegate.applicationDidFinishLaunching`
    /// (`Sources/App/VociApp.swift`, App-wiring-owned) — this file does not call it itself so it
    /// stays a pure declaration the caller controls the timing of.
    static func registerCategories() {
        let done = UNNotificationAction(identifier: ReminderAction.done, title: "Done", options: [])
        let snooze = UNNotificationAction(identifier: ReminderAction.snooze10, title: "Snooze 10 min", options: [])
        let tomorrow = UNNotificationAction(identifier: ReminderAction.tomorrow, title: "Tomorrow", options: [])
        let deadlineCategory = UNNotificationCategory(
            identifier: ReminderCategory.deadline,
            actions: [done, snooze, tomorrow],
            intentIdentifiers: [],
            options: []
        )

        let unblockedCategory = UNNotificationCategory(
            identifier: ReminderCategory.unblockedReady,
            actions: [],
            intentIdentifiers: [],
            options: []
        )

        let tonight = UNNotificationAction(identifier: ReminderAction.rescheduleTonight, title: "Tonight", options: [])
        let tomorrowReschedule = UNNotificationAction(identifier: ReminderAction.rescheduleTomorrow, title: "Tomorrow", options: [])
        let weekend = UNNotificationAction(identifier: ReminderAction.rescheduleWeekend, title: "This weekend", options: [])
        let overdueCategory = UNNotificationCategory(
            identifier: ReminderCategory.overdueReschedule,
            actions: [tonight, tomorrowReschedule, weekend],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([
            deadlineCategory, unblockedCategory, overdueCategory,
        ])
    }

    /// Maps a `ReminderRecord.offsetKind` to the category it should be delivered under. Pure
    /// function (no I/O) so `ReminderSchedulerTests` can assert on it directly. `"resurface"`
    /// covers both `scheduleResurface` (FR-017) and `offerReschedule` (FR-016) — both are "bring
    /// this back to attention" reminders, and both read naturally with tonight/tomorrow/weekend
    /// reschedule actions, so they share one category rather than needing a 7th offset kind
    /// outside the contract's frozen set.
    static func category(forOffsetKind offsetKind: String) -> String {
        switch offsetKind {
        case "unblocked": return ReminderCategory.unblockedReady
        case "resurface": return ReminderCategory.overdueReschedule
        default: return ReminderCategory.deadline
        }
    }
}
