// NotificationActions.cs — port of Sources/Reminders/NotificationActions.swift: category/action
// identifier declarations + the pure offsetKind -> category mapping.
//
// `NotificationActions.registerCategories()` (Swift) — which calls
// `UNUserNotificationCenter.current().setNotificationCategories(...)` — is deliberately NOT ported
// here: it is pure OS registration I/O against a not-yet-built Windows toast adapter (the Windows
// App SDK `AppNotificationManager`/action-button equivalent), which is this task's explicitly
// DEFERRED Wave-3 concern (see `IToastChannel`). Every action below is still declared with no
// "activate app" behavior implied — routing a tapped action to `ReminderScheduler.HandleAction`
// never opens any window (FR-014/015/016), matching the Swift original's `options: []` intent; the
// concrete Wave-3 adapter is responsible for registering these identifiers with the OS without a
// foreground/activation flag.
namespace Volar.Reminders;

/// <summary>
/// Category identifiers (contract §A): "deadline" (Done/Snooze 10m/Tomorrow), "unblocked-ready" (no
/// actions — a calm heads-up, not a decision), "overdue-reschedule" (Tonight/Tomorrow/Weekend). No
/// red/badge/shame styling anywhere here (constitution V) — plain system banner chrome only.
/// </summary>
public static class ReminderCategory
{
    public const string Deadline = "deadline";
    public const string UnblockedReady = "unblocked-ready";
    public const string OverdueReschedule = "overdue-reschedule";
}

public static class ReminderAction
{
    public const string Done = "VOLAR_REMINDER_DONE";
    public const string Snooze10 = "VOLAR_REMINDER_SNOOZE_10";
    public const string Tomorrow = "VOLAR_REMINDER_TOMORROW";
    public const string RescheduleTonight = "VOLAR_RESCHEDULE_TONIGHT";
    public const string RescheduleTomorrow = "VOLAR_RESCHEDULE_TOMORROW";
    public const string RescheduleWeekend = "VOLAR_RESCHEDULE_WEEKEND";
}

public static class NotificationActions
{
    /// <summary>
    /// Maps a <see cref="ReminderRecord.OffsetKind"/> to the category it should be delivered under.
    /// Pure function (no I/O) so tests can assert on it directly. "resurface" covers both
    /// <see cref="ReminderScheduler.ScheduleResurface"/> (FR-017) and
    /// <see cref="ReminderScheduler.OfferReschedule"/> (FR-016) — both are "bring this back to
    /// attention" reminders, and both read naturally with tonight/tomorrow/weekend reschedule
    /// actions, so they share one category rather than needing a 7th offset kind outside the
    /// contract's frozen set.
    /// </summary>
    public static string CategoryForOffsetKind(string offsetKind) => offsetKind switch
    {
        "unblocked" => ReminderCategory.UnblockedReady,
        "resurface" => ReminderCategory.OverdueReschedule,
        _ => ReminderCategory.Deadline
    };
}
