// ViewModels/NotificationBannerViewModel.cs — VM for Views/Controls/NotificationBanner.*
// (wave4-contract.md Stage B5; views-inventory.md §1.1, port of NotificationView.swift's 85 lines).
//
// NO IN-APP-BANNER SURFACE EXISTS C#-SIDE YET (this task's brief anticipated this and asked to
// report it): Swift's `AppState.reminderBanner`/`showReminderPreview()`/`dismissBanner()`
// (appstate-inventory.md rows 29/33/150/151) were explicitly deferred by Wave 3-C's C4 agent — see
// Services/State/ReminderAndDeliverySettingsService.cs's own header comment, "NOT IN SCOPE (flagged,
// not silently invented)". There is therefore no existing service surface for this VM to read from;
// per this task's brief ("give the VM a public Show(title,timing,recordId) entry"), <see cref="Show"/>
// below IS that entry point. Stage C is expected to call it from whichever surface ends up firing
// in-app reminder banners — the tray "Preview reminder" menu item (TrayIconService's existing
// `_onPreviewReminder` callback) and/or a future `AppNotificationToastChannel` in-app-visible path —
// this VM does not reach into either itself (no service reference at all; it is pure
// presentation + a self-owned auto-dismiss timer, mirroring NotificationView.swift's own
// `title`/`timing`/`onDone`/`onSnooze`/`onReschedule` parameter-only shape).
using System.ComponentModel;
using System.Windows.Input;
using Microsoft.UI.Dispatching;

namespace Volar.App.ViewModels;

public sealed class NotificationBannerViewModel : INotifyPropertyChanged
{
    private static readonly TimeSpan AutoDismissDelay = TimeSpan.FromSeconds(5);

    private readonly DispatcherQueue? _dispatcherQueue;
    private readonly Func<TimeSpan, CancellationToken, Task> _delay;

    private CancellationTokenSource? _autoDismissCts;

    /// <param name="delay">Defaults to <see cref="Task.Delay(TimeSpan,CancellationToken)"/>; tests
    /// inject an immediately-completing fake, same seam shape as
    /// <c>FocusSessionService</c>'s own <c>_delay</c> parameter.</param>
    public NotificationBannerViewModel(DispatcherQueue? dispatcherQueue = null, Func<TimeSpan, CancellationToken, Task>? delay = null)
    {
        _dispatcherQueue = dispatcherQueue;
        _delay = delay ?? Task.Delay;

        DoneCommand = new DelegateCommand(() => { var id = RecordId; Dismiss(); Done?.Invoke(id); });
        SnoozeCommand = new DelegateCommand(() => { var id = RecordId; Dismiss(); Snoozed?.Invoke(id); });
        RescheduleCommand = new DelegateCommand(() => { var id = RecordId; Dismiss(); Rescheduled?.Invoke(id); });
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>Raised after <see cref="DoneCommand"/> runs (banner already dismissed by the time
    /// this fires) — Stage C wires this to whatever "mark done" means for the underlying reminder
    /// once that surface exists (see this file's header).</summary>
    public event Action<Guid>? Done;

    public event Action<Guid>? Snoozed;

    public event Action<Guid>? Rescheduled;

    public ICommand DoneCommand { get; }

    public ICommand SnoozeCommand { get; }

    public ICommand RescheduleCommand { get; }

    public bool IsVisible { get; private set; }

    public Guid RecordId { get; private set; }

    public string Title { get; private set; } = string.Empty;

    public string Timing { get; private set; } = string.Empty;

    /// <summary>Public entry point (see this file's header) — mirrors
    /// `AppState.showReminderPreview()`'s effect (sets `reminderBanner`) without depending on any
    /// service that doesn't exist yet. Re-arms the 5s auto-dismiss timer even if a banner was
    /// already showing (mirrors TodayView.swift's `.task(id: appState.reminderBanner?.id)` —
    /// a NEW banner id restarts the delay from zero).</summary>
    public void Show(Guid recordId, string title, string timing)
    {
        RecordId = recordId;
        Title = title;
        Timing = timing;
        IsVisible = true;
        RaiseAll();
        ArmAutoDismiss();
    }

    /// <summary>Mirrors `AppState.dismissBanner()`. Idempotent.</summary>
    public void Dismiss()
    {
        _autoDismissCts?.Cancel();
        _autoDismissCts = null;
        if (!IsVisible)
        {
            return;
        }
        IsVisible = false;
        RaiseChanged(nameof(IsVisible));
    }

    private void ArmAutoDismiss()
    {
        _autoDismissCts?.Cancel();
        var cts = new CancellationTokenSource();
        _autoDismissCts = cts;
        _ = RunAutoDismissAsync(RecordId, cts.Token);
    }

    private async Task RunAutoDismissAsync(Guid recordId, CancellationToken token)
    {
        try
        {
            await _delay(AutoDismissDelay, token).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return;
        }
        if (token.IsCancellationRequested)
        {
            return;
        }
        UiDispatch.Post(_dispatcherQueue, () =>
        {
            // Only auto-dismiss the SAME banner this timer was armed for — a re-arm from a newer
            // Show() call already cancelled this token, but guard on the id too in case of a
            // dismiss/re-show race within the same dispatcher tick.
            if (RecordId == recordId && IsVisible)
            {
                Dismiss();
            }
        });
    }

    private void RaiseAll()
    {
        RaiseChanged(nameof(IsVisible));
        RaiseChanged(nameof(RecordId));
        RaiseChanged(nameof(Title));
        RaiseChanged(nameof(Timing));
    }

    private void RaiseChanged(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    /// <summary>Minimal ICommand — nested/private, see FocusViewModel.cs's identical helper for why
    /// (namespace-collision avoidance across concurrently-built Stage B agents' ViewModels).</summary>
    private sealed class DelegateCommand(Action execute) : ICommand
    {
        public event EventHandler? CanExecuteChanged
        {
            add { }
            remove { }
        }

        public bool CanExecute(object? parameter) => true;

        public void Execute(object? parameter) => execute();
    }
}
