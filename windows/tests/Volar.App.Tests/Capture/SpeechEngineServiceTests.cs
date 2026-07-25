// Capture/SpeechEngineServiceTests.cs — Wave 3-C stage 2, agent C3. Cluster F: the two-tier
// speech-engine picker. Covers persistence and, most importantly, the "GroqCloud gates on
// IsConfigured and falls back silently to on-device when unconfigured" acceptance criterion
// wave3c-services.md calls out explicitly as "do not regress it" (Wave 3-B, A3).
using Volar.App.Services.State;
using Volar.Domain;
using Volar.Speech;
using Volar.Speech.Groq;
using Volar.Speech.Whisper;
using Xunit;

namespace Volar.App.Tests.Capture;

public sealed class SpeechEngineServiceTests
{
    /// <summary>Pre-seeds a dummy (empty) model file at the exact path
    /// <see cref="WhisperModelManager.EnsureModelAsync"/> would otherwise download to, so any
    /// fire-and-forget <c>PrepareAsync</c> this test suite triggers (via
    /// <see cref="SpeechEngineService.SetChoice"/>) resolves near-instantly and never attempts a
    /// real network call — this test file cares about engine SELECTION, not about Whisper.net's own
    /// (separately tested, in Volar.Speech.Tests) model-loading behavior. The dummy file is not a
    /// valid GGML model, so <c>WhisperFactory.FromPath</c> will fail to parse it — caught internally
    /// by <c>PrepareAsync</c> (sets <c>EngineState.Failed</c>, never throws) — which is exactly as
    /// harmless here as an offline network failure would have been, just deterministic and fast.</summary>
    private static WhisperNetEngine NewWhisper()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"volar-speech-tests-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        File.WriteAllBytes(Path.Combine(directory, "ggml-base.bin"), Array.Empty<byte>());
        return new WhisperNetEngine(new WhisperModelManager(directory), captureService: new FakeAudioCaptureService());
    }

    private static GroqEngine NewGroq(bool configured) =>
        new(
            new GroqTranscriptionClient(new FakeGroqCredentialProvider { IsConfigured = configured }),
            captureService: new FakeAudioCaptureService(),
            credentialProvider: new FakeGroqCredentialProvider { IsConfigured = configured });

    [Fact]
    public void Choice_DefaultsToWhisperOnDevice_OnFreshSettings()
    {
        var service = new SpeechEngineService(NewWhisper(), NewGroq(configured: false), new InMemorySettingsStore());
        Assert.Equal(SpeechEngineChoice.WhisperOnDevice, service.Choice);
    }

    [Fact]
    public void SetChoice_Persists_AcrossServiceInstances()
    {
        var settings = new InMemorySettingsStore();
        var first = new SpeechEngineService(NewWhisper(), NewGroq(configured: true), settings);
        first.SetChoice(SpeechEngineChoice.GroqCloud);

        var second = new SpeechEngineService(NewWhisper(), NewGroq(configured: true), settings);
        Assert.Equal(SpeechEngineChoice.GroqCloud, second.Choice);
    }

    [Fact]
    public void SelectedEngine_WhisperOnDeviceChoice_AlwaysReturnsWhisper()
    {
        var whisper = NewWhisper();
        var service = new SpeechEngineService(whisper, NewGroq(configured: true), new InMemorySettingsStore());
        Assert.Same(whisper, service.SelectedEngine);
    }

    [Fact]
    public void SelectedEngine_GroqChoice_Configured_ReturnsGroq()
    {
        var groq = NewGroq(configured: true);
        var service = new SpeechEngineService(NewWhisper(), groq, new InMemorySettingsStore());
        service.SetChoice(SpeechEngineChoice.GroqCloud);
        Assert.Same(groq, service.SelectedEngine);
    }

    /// <summary>THE acceptance criterion this wave's brief calls out by name: picking Groq before a
    /// credential exists must degrade quietly to on-device, never a hard error at upload time.
    /// Carried over unbroken from Wave 3-B (A3) — this test exists specifically so a future edit
    /// cannot regress it silently.</summary>
    [Fact]
    public void SelectedEngine_GroqChoice_Unconfigured_FallsBackToWhisperSilently()
    {
        var whisper = NewWhisper();
        var groq = NewGroq(configured: false);
        var service = new SpeechEngineService(whisper, groq, new InMemorySettingsStore());
        service.SetChoice(SpeechEngineChoice.GroqCloud);

        Assert.Equal(SpeechEngineChoice.GroqCloud, service.Choice); // the CHOICE is still recorded...
        Assert.Same(whisper, service.SelectedEngine); // ...but the ENGINE quietly falls back.
    }

    [Fact]
    public void SelectedEngine_ReevaluatesLive_WhenCredentialBecomesAvailable()
    {
        // Not cached — mirrors decision 5's "read-through, never cache" spirit extended to this
        // cluster: SelectedEngine must reflect IsConfigured's CURRENT value, not a snapshot taken at
        // SetChoice time (a real credential can arrive later, e.g. after a Settings sign-in flow).
        var whisper = NewWhisper();
        var credentialProvider = new FakeGroqCredentialProvider { IsConfigured = false };
        var groq = new GroqEngine(
            new GroqTranscriptionClient(credentialProvider),
            captureService: new FakeAudioCaptureService(),
            credentialProvider: credentialProvider);
        var service = new SpeechEngineService(whisper, groq, new InMemorySettingsStore());
        service.SetChoice(SpeechEngineChoice.GroqCloud);
        Assert.Same(whisper, service.SelectedEngine);

        credentialProvider.IsConfigured = true;

        Assert.Same(groq, service.SelectedEngine);
    }
}
