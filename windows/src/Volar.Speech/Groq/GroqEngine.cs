// Groq/GroqEngine.cs — ported from Sources/Speech/GroqEngine.swift
//
// Cloud transcription via Groq Speech-to-Text — the paid tier of the freemium speech design. A
// **batch** ISpeechEngine: records the whole utterance via AudioCaptureService, then on Stop()
// uploads it and delivers a single final transcript through OnFinal. No interim results.
//
// Model strategy (unchanged from Swift): whisper-large-v3 primary for best vi/en code-switching;
// on a server-side (5xx) or transport failure it falls back once to whisper-large-v3-turbo rather
// than failing the capture outright. Language is auto-detected.
using Volar.Speech.Audio;

namespace Volar.Speech.Groq;

public sealed class GroqEngine : ISpeechEngine, IDisposable
{
    public bool SupportsPartialResults => false;
    public bool IsRunning { get; private set; }

    public event Action<string>? OnFinal;
    public event Action<Exception>? OnError;

    private readonly GroqTranscriptionClient _client;
    private readonly GroqModel _primaryModel;
    private readonly GroqModel _fallbackModel;
    private readonly IAudioCaptureService _capture;
    private readonly IGroqCredentialProvider _credentialProvider;

    /// <summary>Guards the async upload against a stop/restart/cancel race — same role as
    /// `AppState.captureSession`/`GroqEngine.session` in the Swift original.</summary>
    private int _session;

    /// <summary>
    /// <see langword="true"/> when a Groq credential is available — new in Wave 3-B (A3:
    /// Local&lt;-&gt;Cloud switch, macOS commit f88d5e5). Port of Swift's
    /// <c>nonisolated static var GroqEngine.isConfigured: Bool { EnvironmentGroqCredentialProvider.isConfigured }</c>,
    /// drives the pre-record fallback a future speech-engine-selection policy (ported from
    /// <c>AppState.selectedEngine</c>, Wave 3-C) needs: choosing Groq before a credential exists
    /// must degrade quietly to on-device instead of failing only at upload time.
    /// </summary>
    /// <remarks>
    /// BEHAVIOUR NOTE for the self-review "parity"/"behaviour drift" points: Swift's
    /// <c>GroqEngine.isConfigured</c> queries the ambient
    /// <c>EnvironmentGroqCredentialProvider.isConfigured</c> STATIC directly — completely
    /// independent of whatever credential provider the engine's OWN
    /// <c>GroqTranscriptionClient</c> was actually constructed with (a pre-existing coupling
    /// quirk in the Swift source, not introduced by this port). This port preserves that exact
    /// shape rather than "fixing" it: <see cref="IsConfigured"/> reads a SEPARATE, independently
    /// injected <see cref="IGroqCredentialProvider"/> (defaulting to a fresh
    /// <see cref="EnvironmentGroqCredentialProvider"/>), not the credential provider hidden inside
    /// <paramref name="client"/> — because <c>Volar.Speech.Groq.GroqTranscriptionClient</c> is not
    /// in this wave's file-ownership list and could not be edited to expose its private provider.
    /// A caller that constructs both with visibly DIFFERENT providers could see them disagree;
    /// Wave 3-C's composition root should construct both from the SAME
    /// <see cref="IGroqCredentialProvider"/> instance to avoid that (see this wave's handoff note).
    /// </remarks>
    public bool IsConfigured => _credentialProvider.IsConfigured;

    public GroqEngine(
        GroqTranscriptionClient client,
        GroqModel primaryModel = GroqModel.LargeV3,
        GroqModel fallbackModel = GroqModel.LargeV3Turbo,
        IAudioCaptureService? captureService = null,
        IGroqCredentialProvider? credentialProvider = null)
    {
        _client = client;
        _primaryModel = primaryModel;
        _fallbackModel = fallbackModel;
        _capture = captureService ?? new AudioCaptureService();
        _credentialProvider = credentialProvider ?? new EnvironmentGroqCredentialProvider();
        _capture.OnError += ex =>
        {
            if (IsRunning)
            {
                IsRunning = false;
                OnError?.Invoke(ex);
            }
        };
    }

    /// <summary>Groq only needs the microphone (no speech-framework-equivalent authorization).</summary>
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
            byte[] audio;
            try
            {
                audio = await File.ReadAllBytesAsync(wavPath).ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                if (_session == token) OnError?.Invoke(GroqTranscriptionException.Network($"Couldn't read recording: {ex.Message}"));
                return;
            }

            try
            {
                var text = await TranscribeWithFallbackAsync(audio, Path.GetFileName(wavPath)).ConfigureAwait(false);
                if (_session == token) OnFinal?.Invoke(text);
            }
            catch (Exception ex)
            {
                if (_session == token) OnError?.Invoke(ex);
            }
        }
        finally
        {
            TryDelete(wavPath);
        }
    }

    /// <summary>Tries the primary (large-v3) model; on a server-side (5xx) or transport failure
    /// only, retries once with the turbo fallback. Client-side failures (missing creds, 4xx,
    /// too-large, decoding, empty) are NOT retried — a different model wouldn't help.</summary>
    private async Task<string> TranscribeWithFallbackAsync(byte[] audio, string filename)
    {
        try
        {
            return await _client.TranscribeAsync(audio, filename, _primaryModel).ConfigureAwait(false);
        }
        catch (GroqTranscriptionException ex) when (IsRetriable(ex))
        {
            return await _client.TranscribeAsync(audio, filename, _fallbackModel).ConfigureAwait(false);
        }
    }

    private static bool IsRetriable(GroqTranscriptionException ex) => ex.Kind switch
    {
        GroqTranscriptionErrorKind.Network => true,
        GroqTranscriptionErrorKind.Http => ex.HttpStatus is >= 500 and < 600,
        _ => false,
    };

    /// <summary>Immediately abandons the in-flight capture. Bumps `_session` first so any
    /// in-flight upload's result can never reach the app once it resolves (the network request
    /// itself may still complete in the background — Groq isn't told to abort — but its transcript
    /// is discarded), matching the Swift `cancel()` contract exactly.</summary>
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

    public void Dispose() => _capture.Dispose();
}
