// IToastChannel.cs — the delivery adapter seam ReminderScheduler calls to actually show/speak a
// reminder. Modeled on Sources/Reminders/VoiceReminderChannel.swift (spoken delivery — a thin
// interface wrapper: construct a sentence, hand it to playback) folded together with
// NotificationActions.swift + `UNUserNotificationCenter`'s add/remove/pending/delivered surface
// (visual toast + actions) that `ReminderScheduler.swift` calls directly, since a single Wave-3
// adapter is expected to implement both concerns together (post a Windows toast AND speak via
// Windows' speech synthesis API).
//
// DEFERRED (per this task's brief): the concrete Windows `AppNotificationBuilder`-backed
// implementation belongs to Wave 3 (App shell) — it needs packaged app identity this project
// cannot assume. Only this interface + the in-memory test fake (Volar.Reminders.Tests) exist here.
// All text composition (title/body/spoken sentence, `isSensitive` handling) is done by
// `ReminderScheduler`'s own pure helpers before reaching this seam, so every concrete channel
// renders byte-for-byte the same content — the adapter has no decisions left to make.
namespace Volar.Reminders;

/// <summary>
/// One reminder's fully-composed delivery payload.
/// </summary>
/// <param name="RecordId">The <see cref="ReminderRecord.Id"/> this delivery is for — the identifier
/// a concrete adapter should register/track the underlying toast under, so
/// <see cref="IToastChannel.GetPendingIds"/>/<see cref="IToastChannel.GetDeliveredIds"/> can report
/// it back.</param>
/// <param name="TaskId">The task the reminder is about.</param>
/// <param name="BannerTitle">Toast title — "Volar" in the Swift original.</param>
/// <param name="BannerBody">Toast body — "{task title} — {timing phrase}".</param>
/// <param name="CategoryId">One of <see cref="ReminderCategory"/> — selects which action buttons
/// (if any) the adapter should show.</param>
/// <param name="SpokenText"><see langword="null"/> =&gt; don't speak; otherwise the exact sentence
/// to speak (already isSensitive-aware — see <c>VoiceReminderChannel.speakReminder</c>'s "never the
/// task's title when sensitive" rule, applied by <see cref="ReminderScheduler"/> before this
/// payload is built).</param>
public sealed record ReminderDelivery(
    Guid RecordId,
    Guid TaskId,
    string BannerTitle,
    string BannerBody,
    string CategoryId,
    string? SpokenText);

public interface IToastChannel
{
    /// <summary>
    /// Post <paramref name="delivery"/> for immediate display (+ speak if
    /// <see cref="ReminderDelivery.SpokenText"/> is non-null). Mirrors Swift's
    /// `postImmediateRequest`/`voice.speakReminder` pairing in `fire(_:using:)`.
    /// </summary>
    void DeliverNow(ReminderDelivery delivery);

    /// <summary>
    /// Register <paramref name="delivery"/>'s banner to fire at <paramref name="fireAt"/> with the
    /// system (mirrors `UNTimeIntervalNotificationTrigger` + `center.add`). Speaking a scheduled
    /// delivery — if <see cref="ReminderDelivery.SpokenText"/> is set — happens through the
    /// adapter's own live-presentation path when the OS actually shows the banner
    /// (<see cref="Speak"/>, called from <see cref="ReminderScheduler.PresentationDecision"/>), not
    /// synthesized ahead of time here.
    /// </summary>
    void Schedule(ReminderDelivery delivery, DateTimeOffset fireAt);

    /// <summary>
    /// Speak <paramref name="text"/> immediately, with NO accompanying banner post. Used only by
    /// <see cref="ReminderScheduler.PresentationDecision"/> — the OS is already about to show a
    /// pre-registered banner live; posting a second one here would duplicate it, so only the
    /// spoken half of the delivery goes through this method. Mirrors
    /// `VoiceReminderChannel.speakReminder` being called directly (no `UNNotificationRequest`) from
    /// `ReminderScheduler.presentationDecision(for:)`.
    /// </summary>
    void Speak(string text);

    /// <summary>
    /// Cancel any pending (not yet fired) system registrations for these record ids. No-op for an
    /// id with nothing pending. Mirrors `center.removePendingNotificationRequests(withIdentifiers:)`.
    /// </summary>
    void CancelPending(IReadOnlyList<Guid> recordIds);

    /// <summary>
    /// Record ids currently registered with the system but not yet fired. Mirrors
    /// `center.pendingNotificationRequests()`, used by <see cref="ReminderScheduler"/>'s nearest-N
    /// refill to compute remaining capacity under the system's pending-request cap.
    /// </summary>
    IReadOnlyList<Guid> GetPendingIds();

    /// <summary>
    /// Record ids the OS has already delivered (still present in the notification/action center).
    /// Mirrors `center.deliveredNotifications()` — used by the FIX B reconciliation pass in
    /// <see cref="ReminderScheduler.RebuildFromStorage"/> so an already-delivered record isn't
    /// re-fired as a duplicate.
    /// </summary>
    IReadOnlyList<Guid> GetDeliveredIds();
}
