// Whisper/WhisperNetEngine.cs — ported from Sources/Speech/WhisperKitEngine.swift
//
// On-device transcription — the FREE, unlimited tier of the freemium speech design. A **batch**
// ISpeechEngine, structured like GroqEngine: records the whole utterance via AudioCaptureService,
// then on Stop() runs it through the local Whisper.net (whisper.cpp) pipeline and delivers a
// single final transcript through OnFinal. No interim results.
//
// ## Why one engine covers what mac splits into SpeechCapture + WhisperKitEngine
// mac has TWO on-device paths: `SpeechCapture` (SFSpeechRecognizer, streaming, Apple's OS-level
// speech framework) and `WhisperKitEngine` (WhisperKit/CoreML, batch, Apple-Silicon-only, opt-in
// for better vi/en accuracy). Windows has no OS-level streaming STT framework this port can lean
// on the way SFSpeechRecognizer is leaned on for free on every Mac. Per plan.md's platform mapping
// ("STT tier 1: SFSpeechRecognizer / WhisperKit -> Whisper.net"), both mac paths collapse into this
// single Whisper.net-based batch engine on Windows — there is no separate "OS dictation" tier here.
// This is a deliberate, plan-approved simplification, not an oversight; flagged again in the final
// report per the brief's "ghi rõ lý do" instruction.
//
// ## Hardware gate
// mac's WhisperKitEngine gates on Apple Silicon (Neural Engine) via `WhisperKitEngine.isSupported`.
// whisper.cpp runs on any x64/ARM64 CPU (no hardware gate needed); Whisper.net.Runtime ships CPU
// inference by default, so there is no Windows equivalent of that gate — `IsSupported` is omitted.
using System.Text;
using Volar.Speech.Audio;

namespace Volar.Speech.Whisper;

public sealed class WhisperNetEngine : ISpeechEngine, IDisposable
{
    public bool SupportsPartialResults => false;
    public bool IsRunning { get; private set; }

    public event Action<string>? OnFinal;
    public event Action<Exception>? OnError;

    /// <summary>Model-download/load lifecycle, surfaced to Settings — mirrors
    /// `WhisperKitEngine.State` (notReady/preparing/ready/failed) exactly.</summary>
    public enum EngineState { NotReady, Preparing, Ready, Failed }

    public EngineState State { get; private set; } = EngineState.NotReady;
    public string? FailureReason { get; private set; }
    public bool IsModelReady => State == EngineState.Ready;

    private readonly WhisperModelManager _modelManager;
    private readonly WhisperModelSize _modelSize;
    private readonly IAudioCaptureService _capture;
    private global::Whisper.net.WhisperFactory? _factory;

    /// <summary>Guards the async transcription against a stop/restart/cancel race — mirrors
    /// `WhisperKitEngine.session`.</summary>
    private int _session;

    public WhisperNetEngine(
        WhisperModelManager modelManager,
        WhisperModelSize modelSize = WhisperModelSize.Base,
        IAudioCaptureService? captureService = null)
    {
        _modelManager = modelManager;
        _modelSize = modelSize;
        _capture = captureService ?? new AudioCaptureService();
        _capture.OnError += ex =>
        {
            if (IsRunning)
            {
                IsRunning = false;
                OnError?.Invoke(ex);
            }
        };
    }

    /// <summary>Downloads (first run only — cached after) and loads the Whisper.net model.
    /// Idempotent: a second call while <see cref="EngineState.Preparing"/> or once
    /// <see cref="EngineState.Ready"/> is a no-op — exactly mirrors `WhisperKitEngine.prepare()`.
    /// Call this eagerly (e.g. when the user picks the on-device engine in Settings) so the model
    /// is ready well before the next capture.</summary>
    public async Task PrepareAsync(IProgress<WhisperModelDownloadProgress>? downloadProgress = null, CancellationToken cancellationToken = default)
    {
        switch (State)
        {
            case EngineState.Preparing:
            case EngineState.Ready:
                return;
        }
        State = EngineState.Preparing;
        try
        {
            var modelPath = await _modelManager.EnsureModelAsync(_modelSize, downloadProgress, cancellationToken).ConfigureAwait(false);
            _factory = global::Whisper.net.WhisperFactory.FromPath(modelPath);
            State = EngineState.Ready;
        }
        catch (Exception ex)
        {
            FailureReason = ex.Message;
            State = EngineState.Failed;
        }
    }

    /// <summary>Whisper.net only needs the microphone — no OS speech-framework authorization,
    /// everything stays on-device. Matches GroqEngine's mic-only path.</summary>
    public Task<bool> RequestAuthorizationAsync(CancellationToken cancellationToken = default) =>
        _capture.RequestAuthorizationAsync(cancellationToken);

    public void Start(Action<string>? onPartial = null)
    {
        if (IsRunning) return;
        // onPartial is intentionally ignored — a batch engine emits no interim results.
        _session++;
        _capture.Start();
        IsRunning = _capture.IsRunning;
    }

    // `async void` is intentional here (not a mistake) — it mirrors the Swift original's
    // fire-and-forget `Task { @MainActor in ... }` kicked off from a synchronous `stop()`. The
    // ISpeechEngine.Stop() contract is synchronous-looking with results delivered later via
    // OnFinal/OnError; every branch below is wrapped so no exception can escape this method.
    public async void Stop()
    {
        if (!IsRunning) return;
        IsRunning = false;
        _session++;
        var token = _session;

        string wavPath;
        try
        {
            wavPath = await _capture.StopAsync().ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            if (_session == token) OnError?.Invoke(ex);
            return;
        }

        try
        {
            if (_factory is null)
            {
                if (_session == token)
                {
                    OnError?.Invoke(new InvalidOperationException(
                        "Whisper model is not loaded yet — call PrepareAsync() before starting a capture."));
                }
                return;
            }

            var text = await TranscribeAsync(_factory, wavPath).ConfigureAwait(false);
            if (_session != token) return;
            if (string.IsNullOrWhiteSpace(text))
            {
                OnError?.Invoke(new InvalidOperationException("Nothing recognized."));
            }
            else
            {
                OnFinal?.Invoke(text);
            }
        }
        catch (Exception ex)
        {
            if (_session == token) OnError?.Invoke(ex);
        }
        finally
        {
            TryDelete(wavPath);
        }
    }

    /// <summary>No `language:` is fixed on purpose — language auto-detection, mirroring the Swift
    /// original's `DecodingOptions(task: .transcribe, detectLanguage: true)` so vi/en are
    /// auto-detected rather than forced to a single language.</summary>
    private static async Task<string> TranscribeAsync(global::Whisper.net.WhisperFactory factory, string wavPath)
    {
        await using var processor = factory.CreateBuilder()
            .WithLanguageDetection()
            .Build();
        await using var fileStream = File.OpenRead(wavPath);
        var builder = new StringBuilder();
        await foreach (var segment in processor.ProcessAsync(fileStream).ConfigureAwait(false))
        {
            builder.Append(segment.Text);
        }
        return builder.ToString().Trim();
    }

    /// <summary>Immediately abandons the in-flight capture — mirrors `WhisperKitEngine.cancel()`:
    /// bumps `_session` first so an already-running transcription's session check discards its
    /// result, then tears down the recording.</summary>
    public void Cancel()
    {
        _session++;
        IsRunning = false;
        _capture.Cancel();
    }

    private static void TryDelete(string path)
    {
        try { File.Delete(path); } catch { /* best-effort cleanup, mirrors Swift's `try?` */ }
    }

    public void Dispose()
    {
        _capture.Dispose();
        _factory?.Dispose();
    }
}
