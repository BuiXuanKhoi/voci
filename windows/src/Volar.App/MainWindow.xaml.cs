// MainWindow.xaml.cs — Wave 4 Stage C: the real shell. Constructs every VM this task's contract
// (specs/003-windows-port/wave4-contract.md) names, wires them to the Wave 3-C service graph
// (App.Services, built by CompositionRoot), assigns each to its view, and wires every cross-cutting
// seam the "SEAM DIGEST" section of this task's brief calls out: ThemeState construction, the
// TaskDetail/TaskBreakdown open/breakdown-request routing, the gate-VM Refresh() calls App.xaml.cs's
// startup/onboarding-complete paths need, the capture scrim, the AppLinkHandler.OnCapture wiring
// (task 8's caller side), and the NotificationBanner action routing.
//
// Menu-bar-app behavior (mirrors Sources/App/VolarApp.swift's LSUIElement Window group, unchanged
// from Wave 3-C): closing this window via the title-bar X does NOT exit the process — it hides the
// window instead. Only the tray "Quit Volar" command (TrayIconService) actually terminates the app.
using System;
using System.Diagnostics;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Input;
using Volar.App.Services;
using Volar.App.Services.State;
using Volar.App.Theme;
using Volar.App.ViewModels;
using Volar.Domain;
using Volar.Orchestrator;
using Volar.Reminders;
using WinRT.Interop;

namespace Volar.App;

public sealed partial class MainWindow : Window
{
    private const int MinWidth = 820;
    private const int MinHeight = 560;

    private readonly AppWindow _appWindow;
    private bool _allowClose;

    // ---- Wave 3-C services this shell wires views/VMs to (resolved once in ComposeShell) ----
    private ITaskListService _taskList = null!;
    private CaptureFlowService _captureFlow = null!;
    private FocusSessionService _focusSession = null!;
    private DelegationOrchestratorService _delegation = null!;
    private ThemeState _theme = null!;

    // ---- Wave 4 ViewModels (one per overlay surface, per this task's contract) ----
    private TodayViewModel _todayVm = null!;
    private CapturePopoverViewModel _captureVm = null!;
    private FocusViewModel _focusVm = null!;
    private NotificationBannerViewModel _notificationVm = null!;
    private TaskDetailViewModel _taskDetailVm = null!;
    private TaskBreakdownViewModel _taskBreakdownVm = null!;
    private TriageViewModel _triageVm = null!;
    private SweepViewModel _sweepVm = null!;
    private MorningFrogViewModel _morningFrogVm = null!;
    private SettingsViewModel _settingsVm = null!;
    private OnboardingViewModel _onboardingVm = null!;

    public MainWindow()
    {
        InitializeComponent();
        Title = "Volar";

        var hWnd = WindowNative.GetWindowHandle(this);
        var windowId = Win32Interop.GetWindowIdFromWindow(hWnd);
        _appWindow = AppWindow.GetFromWindowId(windowId);

        _appWindow.Resize(new Windows.Graphics.SizeInt32(MinWidth, MinHeight));
        _appWindow.Closing += OnAppWindowClosing;

        ComposeShell();
    }

    // ------------------------------------------------------------------------------------------
    // MARK: Shell composition — construct every VM, assign to its view, wire every seam
    // ------------------------------------------------------------------------------------------

    /// <summary>
    /// Runs once, from the constructor, on the UI thread (MainWindow is always constructed from
    /// App.OnLaunched, which WinUI guarantees runs on the UI thread) — load-bearing for
    /// <see cref="ThemeState"/>'s own "construct on the UI thread" requirement (its
    /// <see cref="ApplicationAccentBrushWriter"/> touches <c>Application.Current.Resources</c>
    /// directly) and every VM constructor below that accepts a live <see cref="DispatcherQueue"/>.
    /// </summary>
    private void ComposeShell()
    {
        var services = App.Services;
        var dispatcherQueue = DispatcherQueue;

        var appearance = services.GetRequiredService<AppearanceAndPersistenceService>();
        _theme = new ThemeState(appearance, new ApplicationAccentBrushWriter());

        _taskList = services.GetRequiredService<ITaskListService>();
        _captureFlow = services.GetRequiredService<CaptureFlowService>();
        _focusSession = services.GetRequiredService<FocusSessionService>();
        _delegation = services.GetRequiredService<DelegationOrchestratorService>();
        var triageAndSweep = services.GetRequiredService<TriageAndSweepService>();
        var voice = services.GetRequiredService<Volar.Speech.Playback.VoicePlayback>();
        var clock = services.GetRequiredService<ITimeProvider>();
        var settingsStore = services.GetRequiredService<ISettingsStore>();
        var speechEngine = services.GetRequiredService<SpeechEngineService>();
        var groq = services.GetRequiredService<Volar.Speech.Groq.GroqEngine>();
        var reminderSettings = services.GetRequiredService<ReminderAndDeliverySettingsService>();
        var editorConnector = services.GetRequiredService<EditorConnector>();
        var whisperModelManager = services.GetRequiredService<Volar.Speech.Whisper.WhisperModelManager>();
        var reminderScheduler = services.GetRequiredService<ReminderScheduler>();

        ComposeTodayAndSidebar(dispatcherQueue, clock);
        ComposeTaskDetail(voice, dispatcherQueue);
        ComposeTaskBreakdown(triageAndSweep, dispatcherQueue);
        ComposeTriageSweepMorningFrog(triageAndSweep, clock, dispatcherQueue);
        ComposeCapturePopover(dispatcherQueue);
        ComposeFocusOverlay(dispatcherQueue);
        ComposeNotificationBanner(dispatcherQueue, reminderScheduler, clock);
        ComposeSettings(speechEngine, groq, settingsStore, reminderSettings, editorConnector, clock, whisperModelManager, dispatcherQueue);
        ComposeOnboarding(settingsStore);
        ComposeAmbientBackground();
        WireAppLinkCapture();
    }

    // MARK: Today / Sidebar (TodayView owns Sidebar internally — see TodayView.xaml.cs header).

    private void ComposeTodayAndSidebar(Microsoft.UI.Dispatching.DispatcherQueue dispatcherQueue, ITimeProvider clock)
    {
        _todayVm = new TodayViewModel(_taskList, _focusSession, _captureFlow, _delegation, _theme, clock, dispatcherQueue);
        TodayHost.ViewModel = _todayVm;

        // Seams TodayView.xaml.cs's own header names explicitly: "the ONE seam Stage C needs to wire
        // the TaskDetailView overlay to" / "...TaskBreakdownView overlay to."
        _todayVm.OpenDetailRequested += id => _taskDetailVm?.Show(id);
        _todayVm.BreakdownRequested += id => ShowBreakdownFor(id);

        // Settings entry point #2 (task 2): TodayView's new toolbar gear button. Routes through the
        // SAME ShowSettings() the tray's "Settings…" item already calls (App.xaml.cs's WireTray) —
        // not a second Settings-opening path, just a second caller of the existing one.
        TodayHost.SettingsRequested += (_, _) => ShowSettings();
    }

    // MARK: TaskDetail

    private void ComposeTaskDetail(Volar.Speech.Playback.VoicePlayback voice, Microsoft.UI.Dispatching.DispatcherQueue dispatcherQueue)
    {
        _taskDetailVm = new TaskDetailViewModel(_taskList, voice, dispatcherQueue);
        TaskDetailHost.ViewModel = _taskDetailVm;
    }

    // MARK: TaskBreakdown

    private void ComposeTaskBreakdown(TriageAndSweepService triageAndSweep, Microsoft.UI.Dispatching.DispatcherQueue dispatcherQueue)
    {
        _taskBreakdownVm = new TaskBreakdownViewModel();
        TaskBreakdownHost.ViewModel = _taskBreakdownVm;

        // TaskBreakdownViewModel.cs's own header: "Trigger comes via TriageAndSweepService
        // .BreakdownRequested event (Stage C wires; your VM just exposes Show/Task/Close)." May fire
        // off the UI thread (no documented thread contract on this event) — marshaled defensively.
        triageAndSweep.BreakdownRequested += task => dispatcherQueue.TryEnqueue(() => _taskBreakdownVm.Show(task));
    }

    private void ShowBreakdownFor(Guid taskId)
    {
        foreach (var task in _taskList.Tasks)
        {
            if (task.Id == taskId)
            {
                _taskBreakdownVm.Show(task);
                return;
            }
        }
    }

    // MARK: Triage / Sweep / MorningFrog (the daily/weekly gate cadence trio)

    private void ComposeTriageSweepMorningFrog(TriageAndSweepService triageAndSweep, ITimeProvider clock, Microsoft.UI.Dispatching.DispatcherQueue dispatcherQueue)
    {
        _triageVm = new TriageViewModel(triageAndSweep, _taskList, clock, dispatcherQueue);
        TriageHost.ViewModel = _triageVm;

        _sweepVm = new SweepViewModel(triageAndSweep, _taskList, dispatcherQueue);
        SweepHost.ViewModel = _sweepVm;

        _morningFrogVm = new MorningFrogViewModel(triageAndSweep, _taskList, _captureFlow, dispatcherQueue);
        MorningFrogHost.ViewModel = _morningFrogVm;
    }

    /// <summary>Called by App.xaml.cs after every <c>MaybeShowMorningFrog</c>/<c>MaybeShowTriage</c>/
    /// <c>MaybeShowEveningSweep</c> call (RunStartupSequenceAsync, and again after onboarding
    /// Complete()) — none of those gate methods raise a change event of their own (each VM's own
    /// header flags this: "GATE TIMING... Stage C's shell... MUST call this VM's Refresh() right
    /// after"), so this is that call.</summary>
    public void RefreshGateViewModels()
    {
        _triageVm?.Refresh();
        _sweepVm?.Refresh();
        _morningFrogVm?.Refresh();
    }

    // MARK: Capture popover — floating-capture-window fix. CapturePopover used to be mounted inline
    // here (CapturePopoverHost + a CaptureScrimHost scrim, both removed from MainWindow.xaml) but
    // that made it invisible whenever MainWindow itself was hidden — the normal state for this tray
    // app (Services/TrayIconService.cs) between hotkey presses (App.xaml.cs's WireHotkey toggles
    // CaptureFlowService directly, with no dependency on MainWindow's visibility at all). MainWindow
    // stays the ONE place that constructs CapturePopoverViewModel (still wired to the same
    // _captureFlow/_taskList this method always used) and now ALSO constructs a dedicated
    // CaptureWindow to host it — see that class's own header for why a separate top-level
    // window, not an in-window overlay, is the actual fix.

    private CaptureWindow? _captureWindow;

    private void ComposeCapturePopover(Microsoft.UI.Dispatching.DispatcherQueue dispatcherQueue)
    {
        _captureVm = new CapturePopoverViewModel(_captureFlow, _taskList, dispatcherQueue);

        // Created ONCE here (MainWindow's own lifetime IS the app's lifetime — see OnAppWindowClosing
        // below) and reused via Show/Hide for every capture from here on; never recreated per-capture
        // (self-review item 3 — recreating a WinUI Window per show would leak the previous HWND and
        // flicker).
        _captureWindow = new CaptureWindow { ViewModel = _captureVm };

        // CaptureFlowService.CaptureChanged carries no thread guarantee (its own header: "may run on
        // whichever thread an ISpeechEngine.OnFinal/OnError callback happens to fire on") — marshal
        // before touching the capture window's visibility.
        _captureFlow.CaptureChanged += () => dispatcherQueue.TryEnqueue(UpdateCaptureWindowVisibility);
        UpdateCaptureWindowVisibility();
    }

    private void UpdateCaptureWindowVisibility()
    {
        if (_captureFlow.State == CaptureState.Idle)
        {
            _captureWindow?.HideWindow();
        }
        else
        {
            _captureWindow?.ShowNearCursor();
        }
    }

    // MARK: FocusOverlay

    private void ComposeFocusOverlay(Microsoft.UI.Dispatching.DispatcherQueue dispatcherQueue)
    {
        _focusVm = new FocusViewModel(_focusSession, _taskList, dispatcherQueue);
        FocusHost.ViewModel = _focusVm;
    }

    // MARK: NotificationBanner

    private void ComposeNotificationBanner(Microsoft.UI.Dispatching.DispatcherQueue dispatcherQueue, ReminderScheduler reminderScheduler, ITimeProvider clock)
    {
        _notificationVm = new NotificationBannerViewModel(dispatcherQueue);
        NotificationHost.ViewModel = _notificationVm;

        // Route Done/Snooze through the SAME ReminderScheduler.HandleAction path the real toast
        // action buttons already use (CompositionRoot.cs's toastChannel.ActionInvoked wiring) rather
        // than double-handling — a preview banner's Guid.Empty (or a real active-task id with no
        // ReminderRecord behind it) resolves to FetchRecord returning null, which HandleAction
        // already no-ops on (ReminderScheduler.cs's own early-return), so this is safe to wire
        // unconditionally even though today's only caller (ShowReminderPreview, below) never has a
        // real record id behind it.
        _notificationVm.Done += id =>
        {
            reminderScheduler.HandleAction(ReminderAction.Done, id, clock.Now);
            _ = _taskList.RefreshAsync();
        };
        _notificationVm.Snoozed += id => reminderScheduler.HandleAction(ReminderAction.Snooze10, id, clock.Now);
        // Rescheduled: deliberately left unwired to a specific ReminderAction. The banner has ONE
        // generic "Reschedule" button, but ReminderAction distinguishes Tonight/Tomorrow/Weekend with
        // no UI signal here to pick between them — and NotificationView.swift's own original wires
        // ALL THREE of onDone/onSnooze/onReschedule to a bare dismissBanner() (that file's own header:
        // "Real reminders delivered via UNUserNotificationCenter ... are still pending — see
        // backlog"), i.e. this banner is preview-only on both platforms today. Guessing an action here
        // would risk a wrong real-world reschedule once this banner IS wired to a live delivered
        // notification; tracked in backlog.md instead of silently guessed.
    }

    /// <summary>Tray "Preview reminder" (TrayIconService's onPreviewReminder). Port of
    /// AppState.swift's <c>showReminderPreview()</c> verbatim, including its own two branches.</summary>
    public void ShowReminderPreview()
    {
        var active = _taskList.ActiveTask;
        if (active is TaskItem task)
        {
            var timing = string.IsNullOrEmpty(task.TimeBadge) ? "Coming up" : $"Coming up · {task.TimeBadge}";
            _notificationVm.Show(task.Id, task.Title, timing);
        }
        else
        {
            _notificationVm.Show(Guid.Empty, "Customer call — Acme onboarding", "In 15 minutes · 2:00 PM");
        }
    }

    // MARK: Settings

    private void ComposeSettings(
        SpeechEngineService speechEngine,
        Volar.Speech.Groq.GroqEngine groq,
        ISettingsStore settingsStore,
        ReminderAndDeliverySettingsService reminderSettings,
        EditorConnector editorConnector,
        ITimeProvider clock,
        Volar.Speech.Whisper.WhisperModelManager whisperModelManager,
        Microsoft.UI.Dispatching.DispatcherQueue dispatcherQueue)
    {
        _settingsVm = new SettingsViewModel(
            speechEngine, groq, settingsStore, reminderSettings, _theme, editorConnector, _delegation, clock, whisperModelManager, dispatcherQueue);
        SettingsHost.Attach(_settingsVm);
        SettingsHost.OwnerWindowHandle = WindowNative.GetWindowHandle(this);
        SettingsHost.CloseRequested += (_, _) => SettingsHost.Visibility = Visibility.Collapsed;
    }

    /// <summary>Tray "Settings…" (replaces Wave 3-C's placeholder "just show the main window"
    /// callback — see App.xaml.cs's WireTray).</summary>
    public void ShowSettings()
    {
        ShowAndActivate();
        SettingsHost.Visibility = Visibility.Visible;
    }

    // MARK: Onboarding

    private void ComposeOnboarding(ISettingsStore settingsStore)
    {
        _onboardingVm = new OnboardingViewModel(settingsStore);
        OnboardingHost.Attach(_onboardingVm);
        OnboardingHost.Finished += OnOnboardingFinished;

        var hasOnboarded = settingsStore.GetBool(OnboardingViewModel.HasOnboardedSettingsKey, false);
        OnboardingHost.Visibility = hasOnboarded ? Visibility.Collapsed : Visibility.Visible;
    }

    /// <summary>Mirrors Swift's onboarding sheet: cadence is skipped pre-onboarding (App.xaml.cs's
    /// RunGateCadence already early-returns on `!hasOnboardedV1`), so once the user finishes/skips
    /// onboarding here, this is the FIRST point the gate cadence can ever run for this session — hide
    /// the overlay, then run it (App.xaml.cs's <see cref="App.RunGateCadenceForOnboardingComplete"/>),
    /// per this task's decision 5/contract note.</summary>
    private void OnOnboardingFinished(object? sender, EventArgs e)
    {
        OnboardingHost.Visibility = Visibility.Collapsed;
        (Microsoft.UI.Xaml.Application.Current as App)?.RunGateCadenceForOnboardingComplete();
    }

    // MARK: AmbientBackground

    private void ComposeAmbientBackground()
    {
        _theme.Changed += (_, _) => UpdateAmbientBackground();
        UpdateAmbientBackground();
    }

    private void UpdateAmbientBackground()
    {
        AmbientBackgroundHost.Mode = _theme.Ambient;
        AmbientBackgroundHost.ImagePath = _theme.CustomImagePath;
    }

    // MARK: AppLinkHandler.OnCapture (task 8's caller side — the Wave 3-C leftover CompositionRoot.cs
    // flagged: "AppLinkHandler.OnCapture ... is left unwired ... Left for Wave 4").

    private void WireAppLinkCapture()
    {
        var appLinkHandler = _delegation.AppLinkHandler;
        if (appLinkHandler is null)
        {
            Debug.WriteLine("[Volar.App.MainWindow] WireAppLinkCapture: DelegationOrchestratorService.AppLinkHandler was null — volar://capture will log+drop (AppLinkHandler.Handle's own no-op contract).");
            return;
        }
        // AppLinkHandler.Handle(Uri) runs on the UI thread already by the time OnCapture fires (see
        // App.xaml.cs's HandleVolarUriAsync call chain — always reached from either OnLaunched
        // directly, or OnRedirectedActivation's own DispatcherQueue.TryEnqueue), so no extra
        // marshaling is needed here. `source` (the optional volar://capture?...&source= origin
        // reference) has no consumer on this port yet — HandleExternalCaptureAsync only needs the
        // transcript text, matching this task's brief ("route an externally-supplied transcript").
        appLinkHandler.OnCapture = (text, source) => { _ = source; _ = _captureFlow.HandleExternalCaptureAsync(text); };
    }

    // ------------------------------------------------------------------------------------------
    // MARK: Keyboard accelerators (task 3)
    // ------------------------------------------------------------------------------------------

    /// <summary>Escape: closes whichever modal overlay is currently on top (mirrors Swift's
    /// sheet-dismiss — each sheet's own Escape/interactiveDismiss behavior, collapsed into one
    /// dispatch table here since WinUI has no per-overlay "active sheet" concept the way SwiftUI's
    /// `.sheet` stack does). Capture's own Escape (CapturePopoverViewModel.HandleEscape) is NO LONGER
    /// routed through here — it moved to CaptureWindow's own KeyboardAccelerator now that the
    /// popover lives in its own top-level window (see MainWindow.xaml's header + CaptureWindow's own
    /// doc comments for why).</summary>
    private void OnEscapeAccelerator(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (CloseTopmostModalOverlay())
        {
            args.Handled = true;
        }
    }

    /// <summary>Enter: every remaining overlay's primary action is a plain Button a user reaches by
    /// Tab/click, not a global Enter shortcut, so this is now a no-op — capture's own Enter
    /// (CapturePopoverViewModel.HandlePrimaryEnter) moved to CaptureWindow's own
    /// KeyboardAccelerator alongside its Escape handling (see OnEscapeAccelerator's doc comment).
    /// Kept (not deleted) only because it is still declared as MainWindow.xaml's RootGrid
    /// KeyboardAccelerator target — removing the C# handler without removing the XAML accelerator
    /// would fail to compile.</summary>
    private void OnEnterAccelerator(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
    }

    /// <summary>Onboarding is deliberately excluded (Swift's `.interactiveDismissDisabled(true)` on
    /// that one sheet — first-run onboarding must not be Escape-dismissible).</summary>
    private bool CloseTopmostModalOverlay()
    {
        if (_taskDetailVm.HasTask)
        {
            _taskDetailVm.Close();
            return true;
        }
        if (_taskBreakdownVm.IsVisible)
        {
            _taskBreakdownVm.Close();
            return true;
        }
        if (_triageVm.IsVisible)
        {
            _triageVm.DismissCommand.Execute(null);
            return true;
        }
        if (_sweepVm.IsVisible)
        {
            _sweepVm.DismissCommand.Execute(null);
            return true;
        }
        if (_morningFrogVm.IsVisible)
        {
            _morningFrogVm.SkipCommand.Execute(null);
            return true;
        }
        if (SettingsHost.Visibility == Visibility.Visible)
        {
            SettingsHost.Visibility = Visibility.Collapsed;
            return true;
        }
        return false;
    }

    // ------------------------------------------------------------------------------------------
    // MARK: Window lifecycle (unchanged from Wave 3-C)
    // ------------------------------------------------------------------------------------------

    /// <summary>
    /// Menu-bar-style close: hides the window instead of letting the OS destroy it, unless
    /// <see cref="AllowRealClose"/> was called first (the tray "Quit Volar" path).
    /// </summary>
    private void OnAppWindowClosing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (_allowClose)
        {
            return;
        }

        args.Cancel = true;
        _appWindow.Hide();
    }

    /// <summary>Called by TrayIconService's "Quit Volar" handler before actually exiting.</summary>
    public void AllowRealClose() => _allowClose = true;

    public void ShowAndActivate()
    {
        _appWindow.Show();
        Activate();
    }
}
