// Stubs/StubReminderAdapters.cs — minimal Wave-2 seam adapters for Volar.Reminders.
//
// TODO(W3-B): StubToastChannel -> real Windows toast (Microsoft.Windows.AppNotifications /
// AppNotificationBuilder) + System.Speech TTS via Volar.Speech.Playback.VoicePlayback. The real
// implementation needs a packaged (MSIX) identity for AppNotificationManager per
// IToastChannel.cs's doc comment — this shell is deliberately unpackaged, so a real notification
// channel is out of scope here. StubReminderTaskStore -> real adapter over
// Volar.Data.TaskRepository (map TaskEntity -> Volar.Domain.TaskItem), per IReminderTaskStore.cs's
// own doc comment.
using System.Diagnostics;
using Volar.Domain;
using Volar.Reminders;

namespace Volar.App.Stubs;

/// <summary>Logs to <see cref="Debug"/> instead of posting a real system toast/speaking. Reports
/// nothing as pending/delivered — harmless for a shell where no reminder is ever actually
/// scheduled yet.</summary>
public sealed class StubToastChannel : IToastChannel
{
    public void DeliverNow(ReminderDelivery delivery) =>
        Debug.WriteLine($"[StubToastChannel] DeliverNow: {delivery.BannerTitle} — {delivery.BannerBody}");

    public void Schedule(ReminderDelivery delivery, DateTimeOffset fireAt) =>
        Debug.WriteLine($"[StubToastChannel] Schedule at {fireAt:O}: {delivery.BannerTitle} — {delivery.BannerBody}");

    public void Speak(string text) => Debug.WriteLine($"[StubToastChannel] Speak: {text}");

    public void CancelPending(IReadOnlyList<Guid> recordIds) =>
        Debug.WriteLine($"[StubToastChannel] CancelPending: {recordIds.Count} id(s)");

    public IReadOnlyList<Guid> GetPendingIds() => Array.Empty<Guid>();

    public IReadOnlyList<Guid> GetDeliveredIds() => Array.Empty<Guid>();
}

/// <summary>Empty in-memory task store — no persisted tasks yet in this shell (Volar.Data is wired
/// up separately in <see cref="Services.CompositionRoot"/> and proven reachable, but nothing maps
/// it into <see cref="TaskItem"/> until Wave 3-B).</summary>
public sealed class StubReminderTaskStore : IReminderTaskStore
{
    public IReadOnlyList<TaskItem> FetchAll() => Array.Empty<TaskItem>();

    public void Toggle(Guid taskId, DateTimeOffset now) =>
        Debug.WriteLine($"[StubReminderTaskStore] Toggle {taskId} at {now:O} (no-op — no persisted tasks yet)");

    public bool IsSensitive(Guid taskId) => false;
}
