// App.xaml.cs — composition root + shell lifecycle. Wave 3-C stage 3 (agent C5): builds the real
// DI ServiceProvider via CompositionRoot.Build(), handles volar:// single-instance activation, wires
// the global hotkey/tray to the real CaptureFlowService, and mirrors VolarApp.swift's gate cadence
// (specs/003-windows-port/wave3c-services.md, "Shell/startup obligations"; VolarApp.swift lines
// ~49-101 for the exact cadence being mirrored). This is the app's process-lifetime object — the
// closest Windows analog to Swift's AppDelegate (appstate-inventory.md §2).
using System;
using System.Diagnostics;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;
using Volar.App.Services;
using Volar.App.Services.Adapters;
using Volar.App.Services.State;
using Volar.Domain;
using Volar.Orchestrator;
using Volar.Reminders;

namespace Volar.App;

public partial class App : Application
{
    /// <summary>The composition root's resolved provider — exposed statically per this task's
    /// brief so any part of the shell can resolve a Wave-2/Wave-3 seam without threading a provider
    /// reference through every constructor. TODO(Wave 4): once a real DI-aware navigation/view-model
    /// layer exists, prefer constructor injection over this static access.</summary>
    public static IServiceProvider Services { get; private set; } = null!;

    /// <summary>Same literal key Swift's <c>VolarApp.swift</c> reads via
    /// <c>@AppStorage("hasOnboardedV1")</c> (appstate-inventory.md §2/§8 — this key lives on the
    /// shell's own persistence surface, not inside any Wave 3-C service). Wave 4 owns the onboarding
    /// sheet that actually flips it; this shell only READS it to gate the three Maybe-show sheets.</summary>
    private const string HasOnboardedKey = "hasOnboardedV1";

    /// <summary>Arbitrary but stable — identifies "the one Volar instance" to
    /// <see cref="AppInstance.FindOrRegisterForKey"/>. Must never change across releases (a changed
    /// key would let two instances run side by side after an update).</summary>
    private const string SingleInstanceKey = "Volar.SingleInstance";

    private MainWindow? _mainWindow;
    private TrayIconService? _tray;
    private HotkeyService? _hotkey;
    private DispatcherQueueTimer? _delegationTimer;

    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        // volar:// single-instance redirection (appstate-inventory.md §2/§7's Windows delta for
        // AppKit's `application(_:open:)`) — MUST run before any window/service exists, so a second
        // `volar://...` launch never spins up a whole duplicate process. UriSchemeRegistrar (run
        // inside CompositionRoot.Build() below, on whichever instance turns out to be "current")
        // writes `"<exe>" "%1"` as the shell\open\command, so an activating URI arrives as this
        // process's own command-line argument — see ExtractVolarUri's remarks.
        var activationArgs = AppInstance.GetCurrent().GetActivatedEventArgs();
        var keyInstance = AppInstance.FindOrRegisterForKey(SingleInstanceKey);
        if (!keyInstance.IsCurrent)
        {
            try
            {
                keyInstance.RedirectActivationToAsync(activationArgs).AsTask().GetAwaiter().GetResult();
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"[Volar.App.App] redirect to running instance failed: {ex.GetType().Name}");
            }
            Environment.Exit(0);
            return;
        }
        keyInstance.Activated += OnRedirectedActivation;

        Services = CompositionRoot.Build();

        _mainWindow = new MainWindow();

        WireHotkey();
        WireTray();

        _mainWindow.ShowAndActivate();

        HandleActivationArgs(activationArgs);

        _ = RunStartupSequenceAsync();
    }

    // ------------------------------------------------------------------------------------------
    // MARK: volar:// activation
    // ------------------------------------------------------------------------------------------

    /// <summary>Fires when a second launch redirected into this already-running instance
    /// (<see cref="AppInstance.Activated"/>). Per that event's own contract this can fire off the UI
    /// thread, so every touch of <see cref="_mainWindow"/>/services below is marshaled.</summary>
    private void OnRedirectedActivation(object? sender, AppActivationArguments args)
    {
        var window = _mainWindow;
        if (window is null)
        {
            return;
        }
        window.DispatcherQueue.TryEnqueue(() =>
        {
            window.ShowAndActivate();
            HandleActivationArgs(args);
        });
    }

    private void HandleActivationArgs(AppActivationArguments args)
    {
        var uri = ExtractVolarUri(args);
        if (uri is not null)
        {
            _ = HandleVolarUriAsync(uri);
        }
    }

    /// <summary>
    /// This app is unpackaged, so a <c>volar://...</c> activation never arrives as
    /// <c>Windows.ApplicationModel.Activation.IProtocolActivatedEventArgs</c> the way a packaged
    /// app's declared protocol extension would — <see cref="Services.Adapters.UriSchemeRegistrar"/>
    /// registers the scheme as a plain <c>shell\open\command</c> of <c>"&lt;exe&gt;" "%1"</c>, so the
    /// OS launches (or redirects into) this process with the URI as a literal command-line argument,
    /// which <see cref="AppInstance.GetActivatedEventArgs"/> surfaces as
    /// <see cref="ExtendedActivationKind.Launch"/> / <c>ILaunchActivatedEventArgs.Arguments</c>. The
    /// <see cref="ExtendedActivationKind.Protocol"/> branch below is kept anyway (cheap, harmless) in
    /// case a future packaged build declares the extension properly — Windows would then deliver it
    /// that way instead.
    /// </summary>
    private static Uri? ExtractVolarUri(AppActivationArguments args)
    {
        if (args.Kind == ExtendedActivationKind.Protocol
            && args.Data is Windows.ApplicationModel.Activation.IProtocolActivatedEventArgs protocolArgs)
        {
            return protocolArgs.Uri;
        }
        if (args.Kind == ExtendedActivationKind.Launch
            && args.Data is Windows.ApplicationModel.Activation.ILaunchActivatedEventArgs launchArgs)
        {
            return TryFindVolarUriInCommandLine(launchArgs.Arguments);
        }
        return null;
    }

    private static Uri? TryFindVolarUriInCommandLine(string? arguments)
    {
        if (string.IsNullOrWhiteSpace(arguments))
        {
            return null;
        }
        var prefix = UriSchemeRegistrar.Scheme + "://";
        foreach (var rawToken in arguments.Split(' ', StringSplitOptions.RemoveEmptyEntries))
        {
            var token = rawToken.Trim('"');
            if (token.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)
                && Uri.TryCreate(token, UriKind.Absolute, out var uri))
            {
                return uri;
            }
        }
        return null;
    }

    private static async Task HandleVolarUriAsync(Uri uri)
    {
        try
        {
            var delegationOrchestrator = Services.GetRequiredService<DelegationOrchestratorService>();
            var clock = Services.GetRequiredService<ITimeProvider>();
            await delegationOrchestrator.HandleAppLinkAsync(uri, clock.Now).ConfigureAwait(true);
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[Volar.App.App] volar:// activation failed: {ex.GetType().Name}");
        }
    }

    // ------------------------------------------------------------------------------------------
    // MARK: Hotkey / tray
    // ------------------------------------------------------------------------------------------

    private void WireHotkey()
    {
        var captureFlow = Services.GetRequiredService<CaptureFlowService>();
        _hotkey = Services.GetRequiredService<HotkeyService>();
        _hotkey.OnToggle += () =>
        {
            // HotkeyManager.OnToggle fires on a thread-pool thread (see that type's own doc
            // comment) — marshal back to the UI thread before touching any service state.
            _mainWindow?.DispatcherQueue.TryEnqueue(() => _ = SafeToggleCaptureAsync(captureFlow));
        };
        _hotkey.TryStart();
    }

    private void WireTray()
    {
        var captureFlow = Services.GetRequiredService<CaptureFlowService>();
        _tray = new TrayIconService(
            onOpen: () => _mainWindow?.DispatcherQueue.TryEnqueue(_mainWindow.ShowAndActivate),
            onNewTask: () => _mainWindow?.DispatcherQueue.TryEnqueue(() =>
            {
                _mainWindow!.ShowAndActivate();
                _ = SafeToggleCaptureAsync(captureFlow);
            }),
            onSettings: () => _mainWindow?.DispatcherQueue.TryEnqueue(_mainWindow.ShowAndActivate),
            onPreviewReminder: () => _mainWindow?.DispatcherQueue.TryEnqueue(_mainWindow.ShowAndActivate),
            onQuit: () =>
            {
                _hotkey?.Stop();
                _mainWindow?.AllowRealClose();
                _mainWindow?.Close();
                Exit();
            });
        _tray.SystemResumedOrUnlocked += OnSystemResumedOrUnlocked;
        _tray.Initialize();
    }

    private static async Task SafeToggleCaptureAsync(CaptureFlowService captureFlow)
    {
        try
        {
            await captureFlow.ToggleCaptureAsync().ConfigureAwait(true);
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[Volar.App.App] ToggleCaptureAsync failed: {ex.GetType().Name}");
        }
    }

    /// <summary>Windows equivalent of macOS's <c>NSWorkspace.didWakeNotification</c> observer
    /// (appstate-inventory.md §5.2) — fires on power resume or session unlock (see
    /// <see cref="TrayIconService.SystemResumedOrUnlocked"/>'s own doc comment for exactly which
    /// Win32 messages). Fires off the UI thread; marshaled here.</summary>
    private void OnSystemResumedOrUnlocked()
    {
        var window = _mainWindow;
        window?.DispatcherQueue.TryEnqueue(() =>
        {
            try
            {
                var reminderScheduler = Services.GetRequiredService<ReminderScheduler>();
                var clock = Services.GetRequiredService<ITimeProvider>();
                reminderScheduler.RebuildFromStorage(clock.Now);
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"[Volar.App.App] RebuildFromStorage (resume/unlock) failed: {ex.GetType().Name}");
            }
        });
    }

    // ------------------------------------------------------------------------------------------
    // MARK: Post-launch startup sequence
    // ------------------------------------------------------------------------------------------

    /// <summary>
    /// Everything VolarApp.swift's main-window `.task` block + `AppDelegate.applicationDidFinishLaunching`
    /// do together (appstate-inventory.md §2, `activateServices()`'s own doc comment: "the double
    /// call is intentional and safe" — this shell only calls each once, since it has a single
    /// process-lifetime entry point instead of Swift's two). Fire-and-forget from
    /// <see cref="OnLaunched"/> so the window paints immediately rather than waiting on a database
    /// read; every step here degrades to a logged no-op on failure, never crashes the app.
    /// </summary>
    private async Task RunStartupSequenceAsync()
    {
        try
        {
            var taskList = Services.GetRequiredService<ITaskListService>();
            var eligibility = Services.GetRequiredService<IEligibilityAndResurfaceService>();
            var reminderScheduler = Services.GetRequiredService<ReminderScheduler>();
            var speechEngine = Services.GetRequiredService<SpeechEngineService>();
            var reminderSettings = Services.GetRequiredService<ReminderAndDeliverySettingsService>();
            var triageAndSweep = Services.GetRequiredService<TriageAndSweepService>();
            var delegationOrchestrator = Services.GetRequiredService<DelegationOrchestratorService>();
            var settings = Services.GetRequiredService<ISettingsStore>();
            var clock = Services.GetRequiredService<ITimeProvider>();

            // Item 5: initial task-list load + idempotent resurface re-arm (FIX 2c).
            await taskList.RefreshAsync().ConfigureAwait(true);
            await eligibility.RearmAsync().ConfigureAwait(true);

            // Item 3: wake-recovery — a reminder due while the app was closed fires via this path.
            // Also called on session unlock/power resume, see OnSystemResumedOrUnlocked above.
            reminderScheduler.RebuildFromStorage(clock.Now);

            // Item 4: fire-and-forget, non-blocking.
            _ = speechEngine.PrepareIfNeededAsync();

            // Mirrors Swift's `activateServices()` call site exactly: unconditional, not gated on
            // hasOnboarded (that gate applies only to the three Maybe-show sheets below, a separate
            // Swift call site — VolarApp.swift's main-window `.task` block, not `activateServices()`).
            reminderSettings.OfferRescheduleForOverdueTasks(clock.Now);

            RunGateCadence(triageAndSweep, settings, clock);

            // Mirrors `startDelegationTimer()`: call once immediately, then arm the repeating timer.
            delegationOrchestrator.RefreshDelegationQueue(clock.Now);
            StartDelegationTimer(delegationOrchestrator, clock);
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[Volar.App.App] startup sequence failed: {ex.GetType().Name}");
        }
    }

    /// <summary>
    /// Item 7 — gate cadence. Mirrors <c>VolarApp.swift</c>'s main-window `.task` block (lines
    /// ~61-100): `MaybeShowMorningFrog`/`MaybeShowTriage` are gated here on `hasOnboardedV1` (no
    /// service owns that flag); `MaybeShowEveningSweep` additionally needs the local hour &gt;= 18
    /// gate applied AT THE CALL SITE (TriageAndSweepService.MaybeShowEveningSweep's own doc comment
    /// says so explicitly — the method itself only self-gates on once-per-day + non-empty items).
    /// Never assigns any `ShowXxx` flag directly — only calls the gate methods, per Opus decision 4.
    /// </summary>
    private static void RunGateCadence(TriageAndSweepService triageAndSweep, ISettingsStore settings, ITimeProvider clock)
    {
        if (!settings.GetBool(HasOnboardedKey, false))
        {
            return;
        }
        var now = clock.Now;
        triageAndSweep.MaybeShowMorningFrog(now);
        triageAndSweep.MaybeShowTriage(now);

        var localHour = TimeZoneInfo.ConvertTime(now, TimeZoneInfo.Local).Hour;
        if (localHour >= 18)
        {
            triageAndSweep.MaybeShowEveningSweep(now);
        }
    }

    /// <summary>Item 7's 60s cadence for <see cref="DelegationOrchestratorService.RefreshDelegationQueue"/>
    /// — mirrors `startDelegationTimer()` (AppState.swift:2230-2244). Uses a
    /// <see cref="DispatcherQueueTimer"/> (UI-thread-affine, per item 8's "Timers = DispatcherQueueTimer"
    /// rule) rather than a plain <see cref="System.Threading.Timer"/>.</summary>
    private void StartDelegationTimer(DelegationOrchestratorService delegationOrchestrator, ITimeProvider clock)
    {
        var window = _mainWindow;
        if (window is null)
        {
            return;
        }
        _delegationTimer = window.DispatcherQueue.CreateTimer();
        _delegationTimer.Interval = TimeSpan.FromSeconds(60);
        _delegationTimer.IsRepeating = true;
        _delegationTimer.Tick += (_, _) =>
        {
            try
            {
                delegationOrchestrator.RefreshDelegationQueue(clock.Now);
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"[Volar.App.App] RefreshDelegationQueue failed: {ex.GetType().Name}");
            }
        };
        _delegationTimer.Start();
    }
}
