// ViewModels/SettingsViewModel.cs — B4 (Settings + Onboarding), Wave 4. Backs Views/SettingsView.*
// (all 6 tabs), porting Volar/Sources/Views/SettingsView.swift per
// specs/003-windows-port/views-inventory.md SS1.15 and wave4-contract.md's B4 scope.
//
// PATTERN (wave4-contract.md frozen decision 12): plain INotifyPropertyChanged class, no XAML
// types. Every mutating method here calls straight into the real Wave-3-C service, then re-reads
// state via Refresh() and raises PropertyChanged — mirroring Theme/ThemeState.cs's own
// SetX-then-RaiseChanged idiom (this file's closest in-tree precedent). No ICommand wrapper type:
// like ThemeState, "commands" are just plain public methods the View's code-behind calls directly
// from a control's click/selection event — avoids introducing a new ICommand/RelayCommand type
// into this namespace that a sibling Wave-4 agent's own VM might independently (and collidingly)
// invent; see this task's final report, "deviations."
//
// SCOPE NOTE — recognition-locale picker: wave4-contract.md's B4 scope line is explicit ("Locale
// picker: omit — no OS ASR on Windows, engine picker only") and views-inventory.md SS1.15 point 2
// confirms `appState.recognitionLocaleID`/`setRecognitionLocale` are bound to
// `SFSpeechRecognizer.supportedLocales()`, a macOS-only API with no Windows target. Intentionally
// not ported — not a residual.
using Volar.App.Services;
using Volar.App.Services.State;
using Volar.App.Theme;
using Volar.Domain;
using Volar.Orchestrator;
using Volar.Parsing;
using Volar.Reminders;
using Volar.Speech;
using Volar.Speech.Ambient;
using Volar.Speech.Groq;
using Volar.Speech.Whisper;

namespace Volar.App.ViewModels;

/// <summary>Settings-local named presets over the full <see cref="ReminderPolicy"/> shape, so the
/// Notifications tab's "Default reminders before deadline" row can stay a simple
/// <see cref="Volar.App.Views.Controls.Segmented"/> rather than a free-form offsets editor. Port of
/// SettingsView.swift's private `ReminderPolicyPreset` (lines 331-359).</summary>
public enum ReminderPolicyPreset
{
    DayHourAt,
    HourAt,
    AtOnly,
    None,
}

public static class ReminderPolicyPresetExtensions
{
    public static string Label(this ReminderPolicyPreset preset) => preset switch
    {
        ReminderPolicyPreset.DayHourAt => "1 day, 1 hour, at deadline",
        ReminderPolicyPreset.HourAt => "1 hour, at deadline",
        ReminderPolicyPreset.AtOnly => "At deadline",
        _ => "None",
    };

    public static ReminderPolicy ToPolicy(this ReminderPolicyPreset preset) => preset switch
    {
        ReminderPolicyPreset.DayHourAt => ReminderPolicy.DefaultPolicy,
        ReminderPolicyPreset.HourAt => new ReminderPolicy(new[] { TimeSpan.FromHours(-1), TimeSpan.Zero }, null),
        ReminderPolicyPreset.AtOnly => new ReminderPolicy(new[] { TimeSpan.Zero }, null),
        _ => new ReminderPolicy(Array.Empty<TimeSpan>(), null),
    };

    /// <summary>Port of SettingsView.swift's `ReminderPolicyPreset.init(matching:)` (lines 356-357):
    /// falls back to <see cref="ReminderPolicyPreset.DayHourAt"/> for a policy shape that matches no
    /// named preset, never throws. `ReminderPolicy` is a `readonly record struct` whose `Offsets` is
    /// an `IReadOnlyList&lt;TimeSpan&gt;` — record-struct-synthesized equality compares that member
    /// by REFERENCE (no custom `IEquatable` on the interface), so this compares by VALUE explicitly
    /// (`SequenceEqual` + `RepeatEvery`) instead of relying on `ReminderPolicy`'s own `==`.</summary>
    public static ReminderPolicyPreset FromPolicy(ReminderPolicy policy)
    {
        foreach (var preset in Enum.GetValues<ReminderPolicyPreset>())
        {
            var candidate = preset.ToPolicy();
            if (candidate.Offsets.SequenceEqual(policy.Offsets) && candidate.RepeatEvery == policy.RepeatEvery)
            {
                return preset;
            }
        }
        return ReminderPolicyPreset.DayHourAt;
    }
}

/// <summary>Backing VM for the Settings surface (all 6 tabs). Headless-constructible — every
/// constructor parameter is a plain service class already built by
/// <see cref="Volar.App.Services.CompositionRoot"/> (Stage C wires the real instances; a test host
/// can construct the same graph via a hermetic <c>WiringTestEnvironment</c>, see
/// windows/tests/Volar.App.Tests/ViewModels/SettingsViewModelTests.cs).</summary>
public sealed class SettingsViewModel : System.ComponentModel.INotifyPropertyChanged
{
    private readonly SpeechEngineService _speechEngine;
    private readonly GroqEngine _groq;
    private readonly WhisperModelManager? _whisperModelManager;
    private readonly ISettingsStore _settings;
    private readonly ConfigParseCredentialProvider _parseCredentialProvider;
    private readonly ReminderAndDeliverySettingsService _reminderSettings;
    private readonly ThemeState _theme;
    private readonly EditorConnector _editorConnector;
    private readonly DelegationOrchestratorService _delegation;
    private readonly ITimeProvider _clock;
    private readonly Microsoft.UI.Dispatching.DispatcherQueue? _dispatcherQueue;

    /// <summary>Same settings key family as SettingsView.swift's own `ClaudeDirBookmark` — but a
    /// PLAIN path, not a security-scoped bookmark (wave4-contract.md frozen decision 3 / this
    /// wave's brief: "delete-don't-port bookmarks... store a PLAIN path"). Windows has no App
    /// Sandbox, so there is nothing to re-resolve — a stored path is directly usable.</summary>
    private const string ClaudeDirPathSettingsKey = "volar.claudeDirPath.settingsUI";

    private string? _claudeDirPath;
    private DateTimeOffset? _lastObservedAppLinkAt;

    public SettingsViewModel(
        SpeechEngineService speechEngine,
        GroqEngine groq,
        ISettingsStore settings,
        ReminderAndDeliverySettingsService reminderSettings,
        ThemeState theme,
        EditorConnector editorConnector,
        DelegationOrchestratorService delegation,
        ITimeProvider clock,
        WhisperModelManager? whisperModelManager = null,
        Microsoft.UI.Dispatching.DispatcherQueue? dispatcherQueue = null)
    {
        _speechEngine = speechEngine ?? throw new ArgumentNullException(nameof(speechEngine));
        _groq = groq ?? throw new ArgumentNullException(nameof(groq));
        _settings = settings ?? throw new ArgumentNullException(nameof(settings));
        _reminderSettings = reminderSettings ?? throw new ArgumentNullException(nameof(reminderSettings));
        _theme = theme ?? throw new ArgumentNullException(nameof(theme));
        _editorConnector = editorConnector ?? throw new ArgumentNullException(nameof(editorConnector));
        _delegation = delegation ?? throw new ArgumentNullException(nameof(delegation));
        _clock = clock ?? throw new ArgumentNullException(nameof(clock));
        _whisperModelManager = whisperModelManager;
        _dispatcherQueue = dispatcherQueue;
        _parseCredentialProvider = new ConfigParseCredentialProvider(settings);

        // ThemeState is the ONLY exerciser of live accent/density switching (views-inventory.md
        // SS1.15 point 2) — subscribing here means the Accent-swatch row's live repaint (verified
        // visually via brush mutation, per this task's brief) flows back through THIS vm's own
        // PropertyChanged, exactly like every other Wave-4 VM's "subscribe to service events, marshal
        // via UiDispatch" contract (frozen decision 12).
        _theme.Changed += OnThemeChanged;

        _claudeDirPath = _settings.GetString(ClaudeDirPathSettingsKey);
        ClaudeConnected = !string.IsNullOrEmpty(_claudeDirPath);
    }

    public event System.ComponentModel.PropertyChangedEventHandler? PropertyChanged;

    private void OnThemeChanged(object? sender, EventArgs e) =>
        UiDispatch.Post(_dispatcherQueue, () => Raise(
            nameof(Accent), nameof(Density), nameof(Ambient), nameof(CustomImagePath), nameof(ShowCustomImageRow)));

    private void Raise(params string[] propertyNames)
    {
        foreach (var name in propertyNames)
        {
            PropertyChanged?.Invoke(this, new System.ComponentModel.PropertyChangedEventArgs(name));
        }
    }

    // ============================================================================================
    // MARK: - General tab (SettingsView.swift:146-250)
    // ============================================================================================

    public static IReadOnlyList<SpeechEngineChoice> SpeechEngineChoices { get; } =
        new[] { SpeechEngineChoice.WhisperOnDevice, SpeechEngineChoice.GroqCloud };

    public static string Label(SpeechEngineChoice choice) => choice switch
    {
        SpeechEngineChoice.GroqCloud => "Groq (cloud)",
        _ => "Whisper (on-device)",
    };

    public static IReadOnlyList<ParseEnginePreference> ParseEnginePreferences { get; } =
        new[] { ParseEnginePreference.OnDevice, ParseEnginePreference.Cloud };

    public static string Label(ParseEnginePreference preference) => preference switch
    {
        ParseEnginePreference.Cloud => "Cloud AI (better quality)",
        _ => "On-device (private, free)",
    };

    public SpeechEngineChoice SpeechEngineChoice => _speechEngine.Choice;

    /// <summary>SettingsView.swift:165 shows the WhisperKit-model row only when the WhisperKit tier
    /// is selected; Windows' `WhisperOnDevice` is both the default AND the universal fallback
    /// (SpeechEngineService.cs's own doc comment), so this row is offered on that same selection.</summary>
    public bool ShowWhisperStatusRow => SpeechEngineChoice == SpeechEngineChoice.WhisperOnDevice;

    /// <summary>Port of `whisperKitStatusText` (SettingsView.swift:130-138), collapsed to the two
    /// states <see cref="WhisperModelManager"/> can actually report (no live download-progress/
    /// failure-message plumbing exists yet on this port — see this task's final report,
    /// "residuals"). <see langword="null"/> <see cref="_whisperModelManager"/> (not wired by the
    /// caller) degrades to a neutral placeholder rather than throwing.</summary>
    public string WhisperStatusText =>
        _whisperModelManager is null
            ? "Status unavailable"
            : _whisperModelManager.IsModelCached(WhisperModelSize.Base) ? "Ready" : "Not downloaded";

    public bool IsGroqConfigured => _groq.IsConfigured;

    public bool ShowGroqNotConfiguredRow => SpeechEngineChoice == SpeechEngineChoice.GroqCloud && !IsGroqConfigured;

    public ParseEnginePreference ParseEnginePreference => ParseEnginePreferenceStore.Get(_settings);

    public bool IsCloudParseConfigured => _parseCredentialProvider.IsConfigured;

    public bool ShowCloudParseNotConfiguredRow => ParseEnginePreference == ParseEnginePreference.Cloud && !IsCloudParseConfigured;

    // Cosmetic-only local settings (SettingsView.swift:42-54's own header: "not part of the frozen
    // AppState API" — session-only `@State`, never persisted in the Swift original either, so a
    // plain in-memory VM property is a 1:1 port, not a placeholder for a future service).
    public bool LaunchAtLogin { get; private set; } = true;

    public int DefaultTaskDurationMinutes { get; private set; } = 30;

    public int HyperfocusInterruptMinutes { get; private set; } = 90;

    public bool ShowMorningFrogPrompt { get; private set; } = true;

    public bool CaptureAppContext { get; private set; } = true;

    public bool CalendarIntegration { get; private set; }

    public void SetSpeechEngine(SpeechEngineChoice choice)
    {
        _speechEngine.SetChoice(choice);
        Raise(nameof(SpeechEngineChoice), nameof(ShowWhisperStatusRow), nameof(WhisperStatusText), nameof(ShowGroqNotConfiguredRow));
    }

    public void SetParseEngine(ParseEnginePreference preference)
    {
        ParseEnginePreferenceStore.Set(_settings, preference);
        Raise(nameof(ParseEnginePreference), nameof(ShowCloudParseNotConfiguredRow));
    }

    public void SetLaunchAtLogin(bool value) { LaunchAtLogin = value; Raise(nameof(LaunchAtLogin)); }

    public void SetDefaultTaskDurationMinutes(int minutes) { DefaultTaskDurationMinutes = minutes; Raise(nameof(DefaultTaskDurationMinutes)); }

    public void SetHyperfocusInterruptMinutes(int minutes) { HyperfocusInterruptMinutes = minutes; Raise(nameof(HyperfocusInterruptMinutes)); }

    public void SetShowMorningFrogPrompt(bool value) { ShowMorningFrogPrompt = value; Raise(nameof(ShowMorningFrogPrompt)); }

    public void SetCaptureAppContext(bool value) { CaptureAppContext = value; Raise(nameof(CaptureAppContext)); }

    public void SetCalendarIntegration(bool value) { CalendarIntegration = value; Raise(nameof(CalendarIntegration)); }

    // ============================================================================================
    // MARK: - Notifications tab (SettingsView.swift:286-326)
    // ============================================================================================

    // Cosmetic-only local settings — same rationale as the General tab's own trio above
    // (SettingsView.swift:50-52, also un-backed `@State` in the Swift original).
    public bool ShowReminders { get; private set; } = true;

    public bool NotificationSound { get; private set; } = true;

    public bool FocusModeAware { get; private set; }

    public VoiceDeliveryMode VoiceDeliveryMode => _reminderSettings.VoiceDeliveryMode;

    public static string Label(VoiceDeliveryMode mode) => mode switch
    {
        VoiceDeliveryMode.VisualOnly => "Visual only",
        VoiceDeliveryMode.VoiceOnly => "Voice only",
        _ => "Visual + voice",
    };

    public ReminderPolicyPreset GlobalReminderPolicyPreset => ReminderPolicyPresetExtensions.FromPolicy(_reminderSettings.GlobalReminderPolicy);

    public void SetShowReminders(bool value) { ShowReminders = value; Raise(nameof(ShowReminders)); }

    public void SetNotificationSound(bool value) { NotificationSound = value; Raise(nameof(NotificationSound)); }

    public void SetFocusModeAware(bool value) { FocusModeAware = value; Raise(nameof(FocusModeAware)); }

    public void SetVoiceDeliveryMode(VoiceDeliveryMode mode)
    {
        _reminderSettings.SetVoiceDeliveryMode(mode);
        Raise(nameof(VoiceDeliveryMode));
    }

    public void SetGlobalReminderPolicyPreset(ReminderPolicyPreset preset)
    {
        _reminderSettings.SetGlobalReminderPolicy(preset.ToPolicy());
        Raise(nameof(GlobalReminderPolicyPreset));
    }

    // ============================================================================================
    // MARK: - Appearance tab (SettingsView.swift:363-487)
    // ============================================================================================

    public VolarAccent Accent => _theme.Accent;

    public Density Density => _theme.Density;

    public static string Label(Density density) => density switch
    {
        Density.Cozy => "Cozy",
        Density.Roomy => "Roomy",
        _ => "Comfy",
    };

    public AmbientMode Ambient => _theme.Ambient;

    public static string Label(AmbientMode mode) => mode switch
    {
        AmbientMode.Rain => "Rain",
        AmbientMode.Snow => "Snow",
        AmbientMode.Embers => "Fireflies",
        AmbientMode.Custom => "Custom",
        _ => "None",
    };

    public static IReadOnlyList<AmbientMode> AmbientModes { get; } =
        new[] { AmbientMode.None, AmbientMode.Rain, AmbientMode.Snow, AmbientMode.Embers, AmbientMode.Custom };

    public string? CustomImagePath => _theme.CustomImagePath;

    public bool ShowCustomImageRow => Ambient == AmbientMode.Custom;

    public void SetAccent(VolarAccent accent)
    {
        _theme.SetAccent(accent); // fires ThemeState.Changed -> OnThemeChanged -> Raise(...).
    }

    public void SetDensity(Density density)
    {
        _theme.SetDensity(density);
    }

    public void SetAmbient(AmbientMode ambient)
    {
        _theme.SetAmbient(ambient);
    }

    /// <summary>Called from SettingsView's code-behind after a <c>FileOpenPicker</c> round trip
    /// (the picker itself needs a window handle, so it lives in code-behind per this wave's VM
    /// rule — see this file's header).</summary>
    public void SetCustomImage(string? path)
    {
        _theme.SetCustomImage(path);
    }

    public void RemoveCustomImage()
    {
        // Port of SettingsView.swift:397-400's "Remove" button: clears ONLY the image path, leaves
        // Ambient exactly where it is (still `.custom`) — matches the Swift original's asymmetry
        // exactly (ThemeState.SetCustomImage(null) mirrors AppearanceAndPersistenceService's own
        // documented asymmetric contract).
        _theme.SetCustomImage(null);
    }

    // ============================================================================================
    // MARK: - Integrations tab (SettingsView.swift:489-706)
    // ============================================================================================

    public bool ClaudeDetected { get; private set; }

    public bool ClaudeConnected { get; private set; }

    public string? ClaudeConnectError { get; private set; }

    public bool TestSignalAwaitingReceipt { get; private set; }

    public bool TestSignalReceived { get; private set; }

    /// <summary>Port of `claudeTestSignalSafe` (SettingsView.swift:511-513) — M1's exactly-one-
    /// in-flight-delegation gate on the "Send test signal" affordance.</summary>
    public bool ClaudeTestSignalSafe => _delegation.WipCount() == 0;

    /// <summary>Port of `claudeConnectHint` (SettingsView.swift:541-548).</summary>
    public string ClaudeConnectHint
    {
        get
        {
            if (ClaudeConnected)
            {
                return "Installs a Stop hook so Claude Code tells Volar when an agent run finishes — Volar never reads Claude Code's own state, only receives this one signal.";
            }
            return ClaudeDetected
                ? "Found ~/.claude on this PC — connect to install a Stop hook so Claude Code tells Volar when an agent run finishes."
                : "Choose your ~/.claude folder to connect. Volar couldn't confirm it's there automatically — it may still exist; pick it below.";
        }
    }

    public string ClaudeHookPreview => _editorConnector.PreviewHookEntry();

    /// <summary>Port of the `.task` modifier (SettingsView.swift:528-531) — call once when the
    /// Integrations tab is first shown (View code-behind's tab-selection handler / `Loaded`).</summary>
    public void InitializeIntegrationsTab()
    {
        ClaudeDetected = _editorConnector.Detect(_claudeDirPath);
        Raise(nameof(ClaudeDetected), nameof(ClaudeConnectHint));
    }

    /// <summary>Called from SettingsView's code-behind after a <c>FolderPicker</c> round trip.
    /// Port of `connectClaudeCode()` (SettingsView.swift:650-679) minus the sandbox bookmark/
    /// real-home-resolution dance (Windows has no App Sandbox — <see cref="EditorConnector"/>'s own
    /// header already documents this platform delta; the folder picker's own default location is
    /// code-behind's concern, not this VM's).</summary>
    public void ConnectClaudeCode(string directoryPath)
    {
        try
        {
            _editorConnector.Connect(directoryPath, _clock.Now);
            _settings.SetString(ClaudeDirPathSettingsKey, directoryPath);
            _claudeDirPath = directoryPath;
            ClaudeConnected = true;
            ClaudeConnectError = null;
        }
        catch (EditorConnector.ConnectorException ex)
        {
            ClaudeConnectError = ex.Message;
        }
        Raise(nameof(ClaudeConnected), nameof(ClaudeConnectError), nameof(ClaudeConnectHint));
    }

    /// <summary>Port of `disconnectClaudeCode()` (SettingsView.swift:681-695).</summary>
    public void DisconnectClaudeCode()
    {
        if (string.IsNullOrEmpty(_claudeDirPath))
        {
            ClaudeConnectError = "Volar lost access to ~/.claude — reconnect once to disconnect cleanly.";
            ClaudeConnected = false;
        }
        else
        {
            try
            {
                _editorConnector.Disconnect(_claudeDirPath, _clock.Now);
                _settings.SetString(ClaudeDirPathSettingsKey, null);
                _claudeDirPath = null;
                ClaudeConnected = false;
                ClaudeConnectError = null;
            }
            catch (EditorConnector.ConnectorException ex)
            {
                ClaudeConnectError = ex.Message;
            }
        }
        Raise(nameof(ClaudeConnected), nameof(ClaudeConnectError), nameof(ClaudeConnectHint));
    }

    /// <summary>Port of `sendClaudeTestSignal()` (SettingsView.swift:702-706) — the "waiting..."/
    /// "received" receipt itself is driven by <see cref="PollAppLinkReceipt"/>, called by the
    /// View's own `DispatcherQueueTimer` (decision 12: "any timer-driven state via a
    /// DispatcherQueueTimer owned by the VM's host"), since
    /// <see cref="DelegationOrchestratorService.LastAppLinkAt"/> has no change EVENT to subscribe
    /// to (unlike Swift's `.onChange(of: appState.lastAppLinkAt)`) — see this task's final report,
    /// "residuals."</summary>
    public void SendClaudeTestSignal()
    {
        TestSignalReceived = false;
        TestSignalAwaitingReceipt = true;
        _lastObservedAppLinkAt = _delegation.LastAppLinkAt;
        _editorConnector.SendTestSignal();
        Raise(nameof(TestSignalAwaitingReceipt), nameof(TestSignalReceived));
    }

    /// <summary>Call periodically (e.g. every 500ms-1s) while <see cref="TestSignalAwaitingReceipt"/>
    /// is <see langword="true"/> — flips to the "received" state the first time
    /// <see cref="DelegationOrchestratorService.LastAppLinkAt"/> advances past whatever it was when
    /// <see cref="SendClaudeTestSignal"/> was called. A no-op once receipt is no longer pending.</summary>
    public void PollAppLinkReceipt()
    {
        if (!TestSignalAwaitingReceipt)
        {
            return;
        }
        var current = _delegation.LastAppLinkAt;
        if (current is not { } value || value == _lastObservedAppLinkAt)
        {
            return;
        }
        TestSignalAwaitingReceipt = false;
        TestSignalReceived = true;
        Raise(nameof(TestSignalAwaitingReceipt), nameof(TestSignalReceived));
    }

    // ============================================================================================
    // MARK: - About tab (SettingsView.swift:708-749)
    // ============================================================================================

    public const string AppDisplayName = "Volar";

    public const string AppVersion = "1.0.2";

    /// <summary>Adapted from SettingsView.swift:724's "Voice-first task manager for Mac. Built in
    /// Cambridge." — the platform noun is a factual statement about this build, not a design token,
    /// so it changes to "Windows" here (everything else ported verbatim).</summary>
    public const string AppTagline = "Voice-first task manager for Windows. Built in Cambridge.";
}
