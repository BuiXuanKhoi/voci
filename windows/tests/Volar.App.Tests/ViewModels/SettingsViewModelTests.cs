// ViewModels/SettingsViewModelTests.cs — B4 (Settings + Onboarding), Wave 4. Covers
// SettingsViewModel's pass-through/mutation logic against REAL Wave-3-C service instances (wired
// the same way this file's own doc comments describe — no service is re-implemented here), using
// the small test doubles already established in this assembly's Capture/ and State/ subfolders
// (FakeTaskListService, RecordingEligibilityService, FixedTimeProvider — all `internal`, same
// assembly, reused via `using` rather than duplicated, mirroring Capture/TestSupport.cs's own
// stated convention for doing exactly this).
using Volar.App.Services.State;
using Volar.App.Tests.Capture;
using Volar.App.Tests.State;
using Volar.App.Theme;
using Volar.App.ViewModels;
using Volar.Domain;
using Volar.Orchestrator;
using Volar.Parsing;
using Volar.Reminders;
using Volar.Speech;
using Volar.Speech.Ambient;
using Volar.Speech.Groq;
using Volar.Speech.Whisper;
using Xunit;

namespace Volar.App.Tests.ViewModels;

public sealed class SettingsViewModelTests
{
    // ------------------------------------------------------------------------------------------
    // MARK: Test doubles / builders
    // ------------------------------------------------------------------------------------------

    private static WhisperNetEngine NewWhisper(string? modelDirectory = null)
    {
        var directory = modelDirectory ?? Path.Combine(Path.GetTempPath(), $"volar-settingsvm-tests-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        return new WhisperNetEngine(new WhisperModelManager(directory), captureService: new FakeAudioCaptureService());
    }

    private static GroqEngine NewGroq(bool configured) =>
        new(
            new GroqTranscriptionClient(new FakeGroqCredentialProvider { IsConfigured = configured }),
            captureService: new FakeAudioCaptureService(),
            credentialProvider: new FakeGroqCredentialProvider { IsConfigured = configured });

    /// <summary>Real file I/O confined to a disposable temp directory that also stands in as
    /// "the user's home" — <see cref="EditorConnector"/>'s own `EnsureWithinUserProfile` guard
    /// requires the target `.claude` path to resolve underneath whatever
    /// <see cref="IEditorTransport.GetHomeDirectory"/> returns, so a fake that reports a real,
    /// writable temp root (rather than mocking file I/O entirely) is both simpler and exercises the
    /// same path-containment check production does.</summary>
    private sealed class FakeEditorTransport : IEditorTransport
    {
        public string HomeDirectory { get; } = Path.Combine(Path.GetTempPath(), $"volar-editorconnector-tests-{Guid.NewGuid():N}");

        public List<Uri> OpenedUris { get; } = new();

        public FakeEditorTransport() => Directory.CreateDirectory(HomeDirectory);

        public bool DirectoryExists(string path) => Directory.Exists(path);

        public bool FileExists(string path) => File.Exists(path);

        public byte[]? TryReadAllBytes(string path) => File.Exists(path) ? File.ReadAllBytes(path) : null;

        public void CopyFile(string sourcePath, string destinationPath) => File.Copy(sourcePath, destinationPath, overwrite: true);

        public void WriteAllBytesAtomic(string path, byte[] data) => File.WriteAllBytes(path, data);

        public string? GetHomeDirectory() => HomeDirectory;

        public string GetCurrentDirectory() => HomeDirectory;

        public void OpenUri(Uri uri) => OpenedUris.Add(uri);
    }

    private sealed class Fixture
    {
        public InMemorySettingsStore Settings { get; } = new();
        public GroqEngine Groq { get; }
        public SpeechEngineService SpeechEngine { get; }
        public FakeTaskListService TaskList { get; } = new();
        public ReminderAndDeliverySettingsService ReminderSettings { get; }
        public ThemeState Theme { get; }
        public FakeEditorTransport EditorTransport { get; } = new();
        public EditorConnector EditorConnector { get; }
        public FixedTimeProvider Clock { get; } = new(new DateTimeOffset(2026, 7, 26, 9, 0, 0, TimeSpan.Zero));
        public DelegationOrchestratorService Delegation { get; }
        public WhisperModelManager WhisperModelManager { get; }

        public Fixture(bool groqConfigured = false, string? whisperModelDirectory = null)
        {
            Groq = NewGroq(groqConfigured);
            var whisperDir = whisperModelDirectory ?? Path.Combine(Path.GetTempPath(), $"volar-settingsvm-tests-{Guid.NewGuid():N}");
            Directory.CreateDirectory(whisperDir);
            WhisperModelManager = new WhisperModelManager(whisperDir);
            SpeechEngine = new SpeechEngineService(NewWhisper(whisperDir), Groq, Settings);
            ReminderSettings = new ReminderAndDeliverySettingsService(Settings, TaskList);
            Theme = new ThemeState(new AppearanceAndPersistenceService(Settings));
            EditorConnector = new EditorConnector(EditorTransport);
            Delegation = new DelegationOrchestratorService(TaskList, new RecordingEligibilityService(), Clock);
        }

        public SettingsViewModel BuildViewModel() => new(
            SpeechEngine, Groq, Settings, ReminderSettings, Theme, EditorConnector, Delegation, Clock, WhisperModelManager);
    }

    // ------------------------------------------------------------------------------------------
    // MARK: General tab
    // ------------------------------------------------------------------------------------------

    [Fact]
    public void SpeechEngineChoice_DefaultsToWhisperOnDevice_AndSetSpeechEngine_PersistsAndRaises()
    {
        var fixture = new Fixture();
        var vm = fixture.BuildViewModel();
        var raised = new List<string>();
        vm.PropertyChanged += (_, e) => raised.Add(e.PropertyName!);

        Assert.Equal(SpeechEngineChoice.WhisperOnDevice, vm.SpeechEngineChoice);
        Assert.True(vm.ShowWhisperStatusRow);

        vm.SetSpeechEngine(SpeechEngineChoice.GroqCloud);

        Assert.Equal(SpeechEngineChoice.GroqCloud, vm.SpeechEngineChoice);
        Assert.False(vm.ShowWhisperStatusRow);
        Assert.Contains(nameof(SettingsViewModel.SpeechEngineChoice), raised);
        // Persisted through the real service, not just the VM's own read.
        Assert.Equal(SpeechEngineChoice.GroqCloud, new SpeechEngineService(NewWhisper(), fixture.Groq, fixture.Settings).Choice);
    }

    [Fact]
    public void ShowGroqNotConfiguredRow_TrueOnlyWhenGroqSelectedAndUnconfigured()
    {
        var fixture = new Fixture(groqConfigured: false);
        var vm = fixture.BuildViewModel();

        Assert.False(vm.ShowGroqNotConfiguredRow); // WhisperOnDevice selected by default.

        vm.SetSpeechEngine(SpeechEngineChoice.GroqCloud);
        Assert.True(vm.ShowGroqNotConfiguredRow);
        Assert.False(vm.IsGroqConfigured);
    }

    [Fact]
    public void WhisperStatusText_ReflectsModelCacheState()
    {
        var whisperDir = Path.Combine(Path.GetTempPath(), $"volar-settingsvm-tests-{Guid.NewGuid():N}");
        Directory.CreateDirectory(whisperDir);
        var fixture = new Fixture(whisperModelDirectory: whisperDir);
        var vm = fixture.BuildViewModel();

        Assert.Equal("Not downloaded", vm.WhisperStatusText);

        File.WriteAllBytes(Path.Combine(whisperDir, "ggml-base.bin"), new byte[] { 1 });
        Assert.Equal("Ready", vm.WhisperStatusText);
    }

    [Fact]
    public void ParseEnginePreference_DefaultsOnDevice_AndSetParseEngine_PersistsThroughSharedConsentKey()
    {
        var fixture = new Fixture();
        var vm = fixture.BuildViewModel();

        Assert.Equal(ParseEnginePreference.OnDevice, vm.ParseEnginePreference);

        vm.SetParseEngine(ParseEnginePreference.Cloud);

        Assert.Equal(ParseEnginePreference.Cloud, vm.ParseEnginePreference);
        // Same bit DefaultCloudParseGate/ParseEnginePreferenceStore read — single source of truth.
        Assert.True(fixture.Settings.GetBool(ParseEnginePreferenceStore.CloudParseConsentKey, false));
    }

    [Fact]
    public void ShowCloudParseNotConfiguredRow_TrueOnlyWhenCloudSelectedAndCredentialMissing()
    {
        var fixture = new Fixture();
        var vm = fixture.BuildViewModel();

        vm.SetParseEngine(ParseEnginePreference.Cloud);
        Assert.True(vm.ShowCloudParseNotConfiguredRow);

        fixture.Settings.SetString(ConfigParseCredentialProvider.BaseUrlSettingsKey, "https://example.invalid");
        fixture.Settings.SetString(ConfigParseCredentialProvider.TokenSettingsKey, "token");
        Assert.False(vm.ShowCloudParseNotConfiguredRow);
        Assert.True(vm.IsCloudParseConfigured);
    }

    [Fact]
    public void CosmeticGeneralSettings_AreLocalAndEphemeral_NotPersisted()
    {
        var fixture = new Fixture();
        var vm = fixture.BuildViewModel();

        Assert.True(vm.LaunchAtLogin);
        vm.SetLaunchAtLogin(false);
        Assert.False(vm.LaunchAtLogin);

        vm.SetDefaultTaskDurationMinutes(60);
        Assert.Equal(60, vm.DefaultTaskDurationMinutes);

        // Nothing was written to the settings store — matches SettingsView.swift's own un-backed
        // `@State` for this cluster of rows (see SettingsViewModel.cs header note).
        var second = fixture.BuildViewModel();
        Assert.True(second.LaunchAtLogin);
        Assert.Equal(30, second.DefaultTaskDurationMinutes);
    }

    // ------------------------------------------------------------------------------------------
    // MARK: Notifications tab
    // ------------------------------------------------------------------------------------------

    [Fact]
    public void VoiceDeliveryMode_And_GlobalReminderPolicyPreset_RoundTripThroughRealService()
    {
        var fixture = new Fixture();
        var vm = fixture.BuildViewModel();

        Assert.Equal(VoiceDeliveryMode.VisualPlusVoice, vm.VoiceDeliveryMode);
        Assert.Equal(ReminderPolicyPreset.DayHourAt, vm.GlobalReminderPolicyPreset);

        vm.SetVoiceDeliveryMode(VoiceDeliveryMode.VoiceOnly);
        Assert.Equal(VoiceDeliveryMode.VoiceOnly, vm.VoiceDeliveryMode);
        Assert.Equal(VoiceDeliveryMode.VoiceOnly, fixture.ReminderSettings.CurrentVoiceDeliveryMode);

        vm.SetGlobalReminderPolicyPreset(ReminderPolicyPreset.AtOnly);
        Assert.Equal(ReminderPolicyPreset.AtOnly, vm.GlobalReminderPolicyPreset);
        Assert.Single(fixture.ReminderSettings.CurrentGlobalReminderPolicy.Offsets);
    }

    [Theory]
    [InlineData(ReminderPolicyPreset.DayHourAt)]
    [InlineData(ReminderPolicyPreset.HourAt)]
    [InlineData(ReminderPolicyPreset.AtOnly)]
    [InlineData(ReminderPolicyPreset.None)]
    public void ReminderPolicyPreset_RoundTrips_ToPolicy_ThenFromPolicy(ReminderPolicyPreset preset)
    {
        var policy = preset.ToPolicy();
        Assert.Equal(preset, ReminderPolicyPresetExtensions.FromPolicy(policy));
    }

    [Fact]
    public void ReminderPolicyPreset_FromPolicy_FallsBackToDayHourAt_ForUnrecognizedShape()
    {
        var oddPolicy = new ReminderPolicy(new[] { TimeSpan.FromMinutes(-17) }, null);
        Assert.Equal(ReminderPolicyPreset.DayHourAt, ReminderPolicyPresetExtensions.FromPolicy(oddPolicy));
    }

    // ------------------------------------------------------------------------------------------
    // MARK: Appearance tab — accent/density/ambient all proxy ThemeState; theme.Changed propagates.
    // ------------------------------------------------------------------------------------------

    [Fact]
    public void SetAccent_UpdatesThemeState_AndRaisesViewModelPropertyChanged()
    {
        var fixture = new Fixture();
        var vm = fixture.BuildViewModel();
        var raised = new List<string>();
        vm.PropertyChanged += (_, e) => raised.Add(e.PropertyName!);

        vm.SetAccent(VolarAccent.Teal);

        Assert.Equal(VolarAccent.Teal, vm.Accent);
        Assert.Equal(VolarAccent.Teal, fixture.Theme.Accent);
        Assert.Contains(nameof(SettingsViewModel.Accent), raised);
    }

    [Fact]
    public void SetDensity_And_SetAmbient_ProxyThemeState()
    {
        var fixture = new Fixture();
        var vm = fixture.BuildViewModel();

        vm.SetDensity(Density.Roomy);
        Assert.Equal(Density.Roomy, vm.Density);

        vm.SetAmbient(AmbientMode.Rain);
        Assert.Equal(AmbientMode.Rain, vm.Ambient);
        Assert.False(vm.ShowCustomImageRow);

        vm.SetAmbient(AmbientMode.Custom);
        Assert.True(vm.ShowCustomImageRow);
    }

    [Fact]
    public void SetCustomImage_And_RemoveCustomImage_ProxyThemeState_MatchingAsymmetricContract()
    {
        var fixture = new Fixture();
        var vm = fixture.BuildViewModel();

        vm.SetCustomImage(@"C:\pictures\bg.png");
        Assert.Equal(@"C:\pictures\bg.png", vm.CustomImagePath);
        Assert.Equal(AmbientMode.Custom, vm.Ambient);

        vm.RemoveCustomImage();
        Assert.Null(vm.CustomImagePath);
        // Ambient is left at .Custom — SettingsView.swift:397-400's own asymmetry, ported verbatim.
        Assert.Equal(AmbientMode.Custom, vm.Ambient);
    }

    // ------------------------------------------------------------------------------------------
    // MARK: Integrations tab
    // ------------------------------------------------------------------------------------------

    [Fact]
    public void InitializeIntegrationsTab_DetectsAgainstTheKnownPath_WhenAlreadyConnected()
    {
        var fixture = new Fixture();
        var claudeDir = Path.Combine(fixture.EditorTransport.HomeDirectory, ".claude");
        Directory.CreateDirectory(claudeDir);
        var vm = fixture.BuildViewModel();

        vm.ConnectClaudeCode(claudeDir);
        Assert.True(vm.ClaudeConnected);

        var second = fixture.BuildViewModel(); // simulates re-opening Settings.
        second.InitializeIntegrationsTab();
        Assert.True(second.ClaudeDetected);
        Assert.True(second.ClaudeConnected);
    }

    [Fact]
    public void ConnectClaudeCode_Then_DisconnectClaudeCode_RoundTrips()
    {
        var fixture = new Fixture();
        var claudeDir = Path.Combine(fixture.EditorTransport.HomeDirectory, ".claude");
        Directory.CreateDirectory(claudeDir);
        var vm = fixture.BuildViewModel();

        vm.ConnectClaudeCode(claudeDir);
        Assert.True(vm.ClaudeConnected);
        Assert.Null(vm.ClaudeConnectError);
        Assert.True(File.Exists(Path.Combine(claudeDir, "settings.json")));

        vm.DisconnectClaudeCode();
        Assert.False(vm.ClaudeConnected);
        Assert.Null(vm.ClaudeConnectError);
    }

    [Fact]
    public void ConnectClaudeCode_OutsideUserProfile_SurfacesConnectorErrorInsteadOfThrowing()
    {
        var fixture = new Fixture();
        var outsidePath = Path.Combine(Path.GetTempPath(), $"volar-outside-{Guid.NewGuid():N}");
        Directory.CreateDirectory(outsidePath);
        var vm = fixture.BuildViewModel();

        vm.ConnectClaudeCode(outsidePath);

        Assert.False(vm.ClaudeConnected);
        Assert.NotNull(vm.ClaudeConnectError);
    }

    [Fact]
    public void ClaudeTestSignalSafe_GatesOnWipCount()
    {
        var fixture = new Fixture();
        var vm = fixture.BuildViewModel();

        // No DelegationTracker wired -> WipCount() always 0 -> always safe (matches
        // DelegationOrchestratorService.WipCount()'s own `?? 0` fallback).
        Assert.True(vm.ClaudeTestSignalSafe);
    }

    [Fact]
    public async Task SendClaudeTestSignal_Then_PollAppLinkReceipt_FlipsToReceived_OnceLastAppLinkAtAdvances()
    {
        var fixture = new Fixture();
        var claudeDir = Path.Combine(fixture.EditorTransport.HomeDirectory, ".claude");
        Directory.CreateDirectory(claudeDir);
        var vm = fixture.BuildViewModel();
        vm.ConnectClaudeCode(claudeDir);

        vm.SendClaudeTestSignal();
        Assert.True(vm.TestSignalAwaitingReceipt);
        Assert.False(vm.TestSignalReceived);
        Assert.Single(fixture.EditorTransport.OpenedUris);

        // No receipt yet -> polling is a no-op.
        vm.PollAppLinkReceipt();
        Assert.True(vm.TestSignalAwaitingReceipt);

        // Simulate the real round trip: AppLinkHandler.Handle -> AppState.onAppLinkHandled's C#
        // equivalent, DelegationOrchestratorService.OnAppLinkHandledAsync, stamping LastAppLinkAt.
        await fixture.Delegation.OnAppLinkHandledAsync(fixture.Clock.Now.AddSeconds(1));

        vm.PollAppLinkReceipt();
        Assert.False(vm.TestSignalAwaitingReceipt);
        Assert.True(vm.TestSignalReceived);
    }

    // ------------------------------------------------------------------------------------------
    // MARK: About tab — static content sanity.
    // ------------------------------------------------------------------------------------------

    [Fact]
    public void AboutTabConstants_AreNonEmpty()
    {
        Assert.False(string.IsNullOrWhiteSpace(SettingsViewModel.AppDisplayName));
        Assert.False(string.IsNullOrWhiteSpace(SettingsViewModel.AppVersion));
        Assert.False(string.IsNullOrWhiteSpace(SettingsViewModel.AppTagline));
    }
}
