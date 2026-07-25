// Services/Adapters/AppNotificationToastChannel.cs — real IToastChannel over
// Microsoft.Windows.AppNotifications (Windows App SDK 1.8, already referenced by this project),
// replacing Stubs.StubToastChannel per that stub's own TODO. Posts the reminder banner + the
// action buttons Volar.Reminders.NotificationActions declares (done / snooze 10' / tomorrow /
// tonight-tomorrow-weekend), reports which record ids the OS still shows (FIX B reconciliation),
// and speaks via Volar.Speech.Playback.VoicePlayback for the spoken half of a delivery.
//
// SCHEDULING NOTE: AppNotificationManager has no "deliver at a future time" primitive (unlike the
// legacy Windows.UI.Notifications.ScheduledToastNotification, which needs COM-activator registry
// plumbing this unpackaged app does not set up) — Show() always posts immediately. Volar is a
// persistent tray app (always running), so Schedule(delivery, fireAt) is implemented as an
// in-process, cancellable delayed call to DeliverNow, tracked in _pending until it fires or is
// cancelled. A reminder that comes due while the app is NOT running will not fire from this alone
// — Wave 3-B's ReminderScheduler.RebuildFromStorage is the documented recovery path for exactly
// that gap (it re-derives and re-fires anything overdue the next time the app starts), so this
// adapter's contract ("fires while the app is alive; RebuildFromStorage catches the rest") is
// exactly the shape ReminderScheduler already expects of whatever it calls Schedule on.
//
// DEGRADE CONTRACT (hard requirement from this wave's brief): every public member here is wrapped
// so it NEVER throws into ReminderScheduler. Register() failing (Focus Assist, notifications
// disabled by policy, running before the WindowsAppSDK bootstrapper is ready, an unsupported OS)
// degrades to "toasts silently don't show, but pending/delivered-id bookkeeping and Speak() keep
// working" — never a crash.
//
// TESTABILITY SEAM: the actual WinRT calls (Register/Show/GetAllAsync/RemoveByTagAsync) are
// isolated behind the small internal-shaped (but public, so this assembly's test project — a
// separate assembly with no InternalsVisibleTo wired, since editing this project's .csproj is
// outside this agent's file-ownership for this wave — can construct one directly)
// INativeAppNotificationGateway seam below. Everything else in this class (pending-timer
// bookkeeping, cancellation, category -> button mapping, degrade-on-throw) is pure C# logic
// exercised in tests against a fake gateway, with no real toast ever posted during a test run.
using System.Collections.Concurrent;
using Volar.Reminders;
using Volar.Speech.Playback;

namespace Volar.App.Services.Adapters;

/// <summary>One action button to render on a toast: the label the user sees, and the
/// <see cref="Volar.Reminders.ReminderAction"/> identifier <see cref="AppNotificationToastChannel.ActionInvoked"/>
/// reports back when it's pressed.</summary>
public readonly record struct ToastButtonSpec(string Label, string ActionId);

/// <summary>The real OS calls this channel makes, isolated behind an interface purely so tests can
/// substitute a fake and never touch the real notification system. See file header
/// "TESTABILITY SEAM".</summary>
public interface INativeAppNotificationGateway : IDisposable
{
    /// <summary><see langword="false"/> on any failure (never throws) — the caller degrades by
    /// simply not posting/reading anything for the rest of this process's lifetime.</summary>
    bool Register();

    /// <summary>Posts immediately. Never throws — a failure (Focus Assist, disabled notifications,
    /// not registered, ...) is swallowed by the implementation.</summary>
    void Show(Guid recordId, string title, string body, IReadOnlyList<ToastButtonSpec> buttons);

    /// <summary>Record ids (parsed from each notification's Tag) still present in the notification/
    /// action center. Never throws — <c>[]</c> on any failure.</summary>
    IReadOnlyList<Guid> GetDeliveredIds();

    /// <summary>Best-effort removal of anything tagged with <paramref name="recordId"/>. Never
    /// throws.</summary>
    void RemoveByTag(Guid recordId);

    /// <summary>Fires when the user activates a toast/button this channel posted: action id first,
    /// record id second (see <see cref="ToastButtonSpec.ActionId"/> / the Tag each notification
    /// carries).</summary>
    event Action<string, Guid>? Invoked;
}

public sealed class AppNotificationToastChannel : IToastChannel, IDisposable
{
    /// <summary>Above the ~24.8-day cap a single <see cref="Task.Delay(TimeSpan,CancellationToken)"/>
    /// call accepts (<see cref="int.MaxValue"/> ms) — <see cref="ScheduleLoopAsync"/> re-checks the
    /// remaining time in chunks no larger than this instead of ever passing a too-large TimeSpan
    /// straight to Task.Delay.</summary>
    private static readonly TimeSpan MaxDelayChunk = TimeSpan.FromHours(6);

    private readonly INativeAppNotificationGateway _gateway;
    private readonly VoicePlayback _voice;
    private readonly Func<TimeSpan, CancellationToken, Task> _delay;
    private readonly Func<DateTimeOffset> _now;
    private readonly ConcurrentDictionary<Guid, CancellationTokenSource> _pending = new();
    private bool _registered;
    private bool _disposed;

    /// <param name="voice">Spoken half of a delivery — see <see cref="Speak"/>.</param>
    /// <param name="gateway">Defaults to <see cref="WinAppSdkNotificationGateway"/> (the real
    /// Microsoft.Windows.AppNotifications-backed implementation); tests inject a fake.</param>
    /// <param name="delay">Defaults to <see cref="Task.Delay(TimeSpan,CancellationToken)"/>; tests
    /// inject an immediately-completing fake so <see cref="Schedule"/> can be exercised without
    /// waiting real wall-clock time.</param>
    /// <param name="now">Defaults to <see cref="DateTimeOffset.UtcNow"/>; injectable per this
    /// project's "every 'now' instant is a parameter" convention.</param>
    public AppNotificationToastChannel(
        VoicePlayback voice,
        INativeAppNotificationGateway? gateway = null,
        Func<TimeSpan, CancellationToken, Task>? delay = null,
        Func<DateTimeOffset>? now = null)
    {
        _voice = voice ?? throw new ArgumentNullException(nameof(voice));
        _gateway = gateway ?? new WinAppSdkNotificationGateway();
        _delay = delay ?? Task.Delay;
        _now = now ?? (() => DateTimeOffset.UtcNow);
        _gateway.Invoked += OnGatewayInvoked;
        _registered = TryRegister();
    }

    /// <summary>Fires when a delivered toast's action button is pressed: (actionId, recordId).
    /// This channel implements <see cref="IToastChannel"/> only — routing an invoked action into
    /// <see cref="ReminderScheduler.HandleAction"/> is the composition root's job (see this agent's
    /// handoff note: C5 must subscribe this event and forward to the scheduler it constructs).</summary>
    public event Action<string, Guid>? ActionInvoked;

    private bool TryRegister()
    {
        try
        {
            return _gateway.Register();
        }
        catch
        {
            return false; // degrade quietly — see file header "DEGRADE CONTRACT"
        }
    }

    private void OnGatewayInvoked(string actionId, Guid recordId)
    {
        try
        {
            ActionInvoked?.Invoke(actionId, recordId);
        }
        catch
        {
            // Never throw out of an OS-invoked callback.
        }
    }

    public void DeliverNow(ReminderDelivery delivery)
    {
        try
        {
            _gateway.Show(delivery.RecordId, delivery.BannerTitle, delivery.BannerBody, ButtonsForCategory(delivery.CategoryId));
        }
        catch
        {
            // Degrade quietly (Focus Assist / disabled notifications / not registered / ...).
        }

        if (delivery.SpokenText is { Length: > 0 } text)
        {
            SafeSpeak(text);
        }
    }

    public void Schedule(ReminderDelivery delivery, DateTimeOffset fireAt)
    {
        try
        {
            CancelPendingOne(delivery.RecordId);
            if (fireAt <= _now())
            {
                DeliverNow(delivery);
                return;
            }
            var cts = new CancellationTokenSource();
            _pending[delivery.RecordId] = cts;
            _ = ScheduleLoopAsync(delivery, fireAt, cts.Token);
        }
        catch
        {
            // Degrade quietly — a reminder that fails to schedule here is still recoverable via
            // ReminderScheduler.RebuildFromStorage the next time it runs.
        }
    }

    private async Task ScheduleLoopAsync(ReminderDelivery delivery, DateTimeOffset fireAt, CancellationToken token)
    {
        try
        {
            while (true)
            {
                var remaining = fireAt - _now();
                if (remaining <= TimeSpan.Zero)
                {
                    break;
                }
                var chunk = remaining > MaxDelayChunk ? MaxDelayChunk : remaining;
                await _delay(chunk, token).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException)
        {
            return;
        }
        catch
        {
            return; // never let a background scheduling loop crash the process
        }

        if (token.IsCancellationRequested)
        {
            return;
        }
        // Only the owner of the CURRENT token for this record id gets to deliver — guards a
        // resurrected/late loop from firing after CancelPending already replaced/removed it.
        if (_pending.TryGetValue(delivery.RecordId, out var current) && current.Token == token)
        {
            _pending.TryRemove(delivery.RecordId, out _);
            DeliverNow(delivery);
        }
    }

    public void Speak(string text) => SafeSpeak(text);

    private void SafeSpeak(string text)
    {
        try
        {
            _voice.Speak(text);
        }
        catch
        {
            // Degrade quietly — a TTS failure must never surface as a scheduler error.
        }
    }

    public void CancelPending(IReadOnlyList<Guid> recordIds)
    {
        foreach (var id in recordIds)
        {
            CancelPendingOne(id);
        }
    }

    private void CancelPendingOne(Guid recordId)
    {
        if (_pending.TryRemove(recordId, out var cts))
        {
            try
            {
                cts.Cancel();
                cts.Dispose();
            }
            catch
            {
                // Best-effort.
            }
        }
        try
        {
            // Also remove an already-posted (immediate) toast under this id, in case the caller is
            // cancelling after DeliverNow already fired (e.g. the task was completed right as the
            // reminder posted) — mirrors `center.removePendingNotificationRequests`.
            _gateway.RemoveByTag(recordId);
        }
        catch
        {
            // Best-effort.
        }
    }

    public IReadOnlyList<Guid> GetPendingIds() => _pending.Keys.ToList();

    public IReadOnlyList<Guid> GetDeliveredIds()
    {
        try
        {
            return _gateway.GetDeliveredIds();
        }
        catch
        {
            return Array.Empty<Guid>();
        }
    }

    /// <summary>Contract §A (quoted verbatim in <see cref="NotificationActions"/>'s own doc
    /// comment): "deadline" (Done/Snooze 10m/Tomorrow), "unblocked-ready" (no actions — a calm
    /// heads-up, not a decision), "overdue-reschedule" (Tonight/Tomorrow/Weekend). Pure mapping —
    /// no OS call, fully unit-testable on its own.</summary>
    internal static IReadOnlyList<ToastButtonSpec> ButtonsForCategory(string categoryId) => categoryId switch
    {
        ReminderCategory.Deadline => new[]
        {
            new ToastButtonSpec("Done", ReminderAction.Done),
            new ToastButtonSpec("Snooze 10m", ReminderAction.Snooze10),
            new ToastButtonSpec("Tomorrow", ReminderAction.Tomorrow),
        },
        ReminderCategory.OverdueReschedule => new[]
        {
            new ToastButtonSpec("Tonight", ReminderAction.RescheduleTonight),
            new ToastButtonSpec("Tomorrow", ReminderAction.RescheduleTomorrow),
            new ToastButtonSpec("Weekend", ReminderAction.RescheduleWeekend),
        },
        _ => Array.Empty<ToastButtonSpec>(), // "unblocked-ready": a calm heads-up, no actions
    };

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;

        foreach (var kv in _pending)
        {
            try
            {
                kv.Value.Cancel();
                kv.Value.Dispose();
            }
            catch
            {
                // Best-effort.
            }
        }
        _pending.Clear();

        try
        {
            _gateway.Invoked -= OnGatewayInvoked;
            if (_registered)
            {
                _gateway.Dispose();
            }
        }
        catch
        {
            // Best-effort.
        }
    }
}
