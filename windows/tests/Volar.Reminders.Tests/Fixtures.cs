using Volar.Domain;
using TaskState = Volar.Core.TaskState;

namespace Volar.Reminders.Tests;

/// <summary>Deterministic time/task fixtures shared by every test in this project.</summary>
internal static class Fixtures
{
    /// <summary>Fixed time zone used by tests that don't specifically exercise a DST zone: explicit
    /// UTC, never <see cref="TimeZoneInfo.Local"/>.</summary>
    public static readonly TimeZoneInfo TestTimeZone = TimeZoneInfo.Utc;

    /// <summary>Fixed reference instant: 2026-07-15 12:00:00 UTC.</summary>
    public static readonly DateTimeOffset ReferenceNow = new(2026, 7, 15, 12, 0, 0, TimeSpan.Zero);

    /// <summary>
    /// Builds a <see cref="TaskItem"/> with sensible defaults so each test only needs to specify
    /// the fields it actually cares about — mirrors <c>Volar.Core.Tests.Fixtures.MakeTask</c> and
    /// the Swift original's own `TaskItem(...)` fixture calls.
    /// </summary>
    public static TaskItem MakeTask(
        Guid? id = null,
        string title = "Untitled task",
        Priority priority = Priority.Medium,
        When when = When.Later,
        DateTimeOffset? createdAt = null,
        TaskState status = TaskState.Todo,
        DateTimeOffset? deadline = null,
        ReminderPolicy? reminderOverride = null) =>
        new(
            id: id ?? Guid.NewGuid(),
            title: title,
            priority: priority,
            when: when,
            createdAt: createdAt ?? ReferenceNow,
            status: status,
            deadline: deadline,
            reminderOverride: reminderOverride);

    /// <summary>Wires a fresh <see cref="ReminderScheduler"/> against fresh fakes, mirroring the
    /// Swift tests' <c>makeScheduler()</c> fixture.</summary>
    public static (ReminderScheduler Scheduler, FakeReminderTaskStore Store, FakeToastChannel Channel) MakeScheduler(
        TimeZoneInfo? timeZone = null, IReminderSettingsProvider? settings = null)
    {
        var store = new FakeReminderTaskStore();
        var channel = new FakeToastChannel();
        var gate = new ReminderContextGate();
        var scheduler = new ReminderScheduler(store, channel, gate, settings, timeZone ?? TestTimeZone);
        return (scheduler, store, channel);
    }
}
