// Audio/AudioCaptureService.cs — microphone recording lifecycle (NAudio / WASAPI)
//
// Windows analog of the recording half of Sources/Speech/SpeechCapture.swift (315 lines) plus the
// AVAudioRecorder setup duplicated in WhisperKitEngine.swift/GroqEngine.swift. Unlike the mac
// version — which is engine-specific (SpeechCapture wraps SFSpeechRecognizer directly; WhisperKit/
// Groq each open their own AVAudioRecorder) — this is factored out as one shared service used by
// both WhisperNetEngine and GroqEngine, since neither Windows STT path streams: both need
// "record whole utterance to a file, then hand the file to the engine" and there is no reason to
// duplicate that plumbing per engine the way the Swift originals do.
//
// ## Format decision (per W1-D brief: report any resampling)
// Whisper wants 16 kHz mono 16-bit PCM. The mac original recorded straight to 16 kHz mono AAC
// (`AVAudioRecorder` with `AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1`) — same rate/channel
// count as the encoder target, just compressed, so no resample was needed there. On Windows,
// `WasapiCapture` in *shared* mode (the only mode NAudio makes easy and the only one that doesn't
// require exclusive control of the device) captures at the endpoint's **mix format** — typically
// 44.1/48 kHz, 32-bit IEEE float, 1-8 channels, entirely device-dependent and NOT configurable to
// "16 kHz mono" up front. So this service DOES resample+downmix after capture: raw bytes are
// buffered in the mix format while recording, then on `StopAsync` converted through
// Downmix-to-mono -> `WdlResamplingSampleProvider` (16 kHz) -> `WaveFileWriter.CreateWaveFile16`
// (16-bit PCM WAV). This is an unavoidable divergence from the mac source, called out explicitly
// per the brief.
using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace Volar.Speech.Audio;

/// <summary>
/// Owns exactly one microphone recording at a time: opens the default capture device, buffers raw
/// audio while running, and on <see cref="StopAsync"/> converts the buffered audio into a 16 kHz
/// mono 16-bit PCM WAV temp file ready for Whisper.net or a Groq upload. Not thread-safe for
/// concurrent Start/Stop/Cancel calls from multiple threads — callers are expected to serialize
/// through the engine that owns this instance (mirrors the mac originals, which are all
/// <c>@MainActor</c>).
/// </summary>
public sealed class AudioCaptureService : IAudioCaptureService
{
    public const int TargetSampleRate = 16_000;
    public const int TargetChannels = 1;
    public const int TargetBitsPerSample = 16;

    private WasapiCapture? _capture;
    private MemoryStream? _rawBuffer;
    private WaveFormat? _captureFormat;
    private System.Threading.Timer? _maxDurationTimer;

    /// <summary>Bumped on every <see cref="Start"/> and <see cref="Cancel"/>; the capture-thread
    /// callbacks and the async conversion in <see cref="StopAsync"/> only act if the session token
    /// they captured still matches. Mirrors the `session`/`captureSession` guard used throughout
    /// the Swift originals (SpeechCapture.session, WhisperKitEngine.session, GroqEngine.session) to
    /// stop a stale callback from a superseded/cancelled capture reaching the current one.</summary>
    private int _session;

    public bool IsRunning { get; private set; }

    /// <summary>Optional recording-duration safety cap. The mac source (SpeechCapture/
    /// WhisperKitEngine/GroqEngine) has NO hard duration limit — this is an addition on top of the
    /// port, not a 1:1 translation, so it defaults to <c>null</c> (unlimited) to match mac
    /// behavior exactly unless a caller opts in.</summary>
    public TimeSpan? MaxDuration { get; set; }

    /// <summary>Fires when recording fails to start, fails mid-flight, or the max-duration guard
    /// trips. Not raised for a clean <see cref="Cancel"/>.</summary>
    public event Action<Exception>? OnError;

    /// <summary>Probes microphone availability. Windows has no equivalent of
    /// AVAudioApplication.requestRecordPermission()'s modal prompt for a Win32/unpackaged desktop
    /// app — access is governed entirely by the system Microphone privacy toggle, which the app
    /// can only detect (by trying to open the device), never prompt for. Returns <c>false</c> on
    /// any failure to open the default capture device (no device, exclusive lock, OR privacy
    /// toggle off) rather than throwing, so callers can show one consistent "no microphone access"
    /// message regardless of the underlying cause.</summary>
    public async Task<bool> RequestAuthorizationAsync(CancellationToken cancellationToken = default)
    {
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            using var device = enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Console);
            using var probe = new WasapiCapture(device);
            var stopped = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            probe.DataAvailable += (_, _) => { /* subscribed so the capture actually runs */ };
            probe.RecordingStopped += (_, e) => stopped.TrySetResult(e.Exception is null);
            probe.StartRecording();
            try
            {
                await Task.Delay(30, cancellationToken).ConfigureAwait(false);
            }
            finally
            {
                probe.StopRecording();
            }
            return await stopped.Task.ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            return false;
        }
    }

    /// <summary>Starts buffering microphone audio. No-op if already running (mirrors
    /// `guard !isRunning else { return }` in every mac engine's `start`).</summary>
    public void Start()
    {
        if (IsRunning) return;
        _session++;
        var token = _session;

        MMDeviceEnumerator? enumerator = null;
        MMDevice? device = null;
        try
        {
            enumerator = new MMDeviceEnumerator();
            device = enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Console);
        }
        catch (Exception ex)
        {
            device?.Dispose();
            enumerator?.Dispose();
            RaiseError(AudioCaptureException.NoInputDevice(ex));
            return;
        }

        var capture = new WasapiCapture(device);
        var buffer = new MemoryStream();
        _captureFormat = capture.WaveFormat;
        _rawBuffer = buffer;

        // Capture-thread callback: append-only, no locks, no I/O beyond the in-memory buffer —
        // kept intentionally light since this runs on NAudio's dedicated capture thread.
        capture.DataAvailable += (_, e) =>
        {
            if (_session == token)
            {
                buffer.Write(e.Buffer, 0, e.BytesRecorded);
            }
        };
        capture.RecordingStopped += (_, e) =>
        {
            if (e.Exception is not null && _session == token)
            {
                RaiseError(new AudioCaptureException("Recording stopped unexpectedly.", e.Exception));
            }
            capture.Dispose();
            device.Dispose();
            enumerator.Dispose();
        };

        try
        {
            capture.StartRecording();
        }
        catch (Exception ex)
        {
            capture.Dispose();
            device.Dispose();
            enumerator.Dispose();
            _rawBuffer = null;
            _captureFormat = null;
            RaiseError(TranslateStartFailure(ex));
            return;
        }

        _capture = capture;
        IsRunning = true;

        if (MaxDuration is { } max)
        {
            _maxDurationTimer = new System.Threading.Timer(_ =>
            {
                if (_session != token) return;
                RaiseError(new AudioCaptureException($"Recording exceeded the {max} maximum duration."));
                Cancel();
            }, null, max, Timeout.InfiniteTimeSpan);
        }
    }

    /// <summary>Ends recording and converts the buffered audio into a 16 kHz mono 16-bit PCM WAV
    /// temp file. Throws <see cref="AudioCaptureException"/> if nothing was recorded. Safe to await
    /// off the calling thread — the actual resample/write runs on a background task.</summary>
    public async Task<string> StopAsync(CancellationToken cancellationToken = default)
    {
        if (!IsRunning || _capture is null || _rawBuffer is null || _captureFormat is null)
        {
            throw new InvalidOperationException("AudioCaptureService.StopAsync called while not recording.");
        }

        IsRunning = false;
        DisarmMaxDurationTimer();

        var capture = _capture;
        var buffer = _rawBuffer;
        var format = _captureFormat;
        _capture = null;
        _rawBuffer = null;
        _captureFormat = null;

        capture.StopRecording(); // async under the hood; RecordingStopped disposes `capture`/device

        var rawBytes = buffer.ToArray();
        await buffer.DisposeAsync().ConfigureAwait(false);
        if (rawBytes.Length == 0)
        {
            throw AudioCaptureException.EmptyRecording();
        }

        return await Task.Run(() => ConvertToWavFile(rawBytes, format), cancellationToken).ConfigureAwait(false);
    }

    /// <summary>Immediately abandons the in-flight recording: bumps <c>_session</c> FIRST (so the
    /// capture-thread callback and any in-flight <see cref="StopAsync"/> conversion drop their
    /// work), stops the device, and discards the buffer. Mirrors `cancel()` in every mac engine.</summary>
    public void Cancel()
    {
        _session++;
        DisarmMaxDurationTimer();
        IsRunning = false;
        try
        {
            _capture?.StopRecording();
        }
        catch
        {
            // Best-effort: the device may already be tearing down (RecordingStopped fires async
            // and disposes it); cancellation must never throw into the caller.
        }
        _capture = null;
        _rawBuffer?.Dispose();
        _rawBuffer = null;
        _captureFormat = null;
    }

    public void Dispose() => Cancel();

    private void DisarmMaxDurationTimer()
    {
        _maxDurationTimer?.Dispose();
        _maxDurationTimer = null;
    }

    private void RaiseError(Exception ex) => OnError?.Invoke(ex);

    /// <summary>Maps a WASAPI start failure to a friendly, non-crashing error. The Windows
    /// microphone-privacy-toggle denial surfaces as an HRESULT E_ACCESSDENIED (0x80070005) COM
    /// exception from `IAudioClient.Initialize`/`Start` — detected here so callers can show
    /// "enable microphone access in Settings" instead of a raw COM error string.</summary>
    private static AudioCaptureException TranslateStartFailure(Exception ex)
    {
        if (ex is System.Runtime.InteropServices.COMException com &&
            (unchecked((uint)com.HResult) == 0x80070005u ||
             com.Message.Contains("Access is denied", StringComparison.OrdinalIgnoreCase)))
        {
            return AudioCaptureException.AccessDenied(ex);
        }
        return AudioCaptureException.NoInputDevice(ex);
    }

    /// <summary>Runs off the capture thread (invoked via <c>Task.Run</c> from
    /// <see cref="StopAsync"/>). Downmixes to mono (any channel count, not just stereo) and
    /// resamples to 16 kHz, then writes 16-bit PCM WAV via NAudio's `WaveFileWriter.CreateWaveFile16`.
    /// Internal (not private) + `InternalsVisibleTo("Volar.Speech.Tests")` so
    /// Volar.Speech.Tests can exercise the format-conversion path directly with synthetic byte
    /// buffers — this is the one piece of "hits hardware" code that can actually run without a
    /// real microphone, since it only operates on already-captured bytes.</summary>
    internal static string ConvertToWavFile(byte[] rawBytes, WaveFormat captureFormat)
    {
        using var rawStream = new MemoryStream(rawBytes);
        using var rawSource = new RawSourceWaveStream(rawStream, captureFormat);
        ISampleProvider samples = rawSource.ToSampleProvider();

        if (captureFormat.Channels > 1)
        {
            samples = new DownmixToMonoSampleProvider(samples);
        }
        if (samples.WaveFormat.SampleRate != TargetSampleRate)
        {
            samples = new WdlResamplingSampleProvider(samples, TargetSampleRate);
        }

        var path = Path.Combine(Path.GetTempPath(), $"volar-capture-{Guid.NewGuid():N}.wav");
        WaveFileWriter.CreateWaveFile16(path, samples);
        return path;
    }

    /// <summary>Averages all input channels down to one. NAudio ships `StereoToMonoSampleProvider`
    /// for the 2-channel case only; WASAPI mix formats can legally report more channels (e.g. a
    /// 5.1 device), so this is written generically rather than assuming stereo.</summary>
    internal sealed class DownmixToMonoSampleProvider : ISampleProvider
    {
        private readonly ISampleProvider _source;
        private readonly int _sourceChannels;
        private float[] _scratch = [];

        public DownmixToMonoSampleProvider(ISampleProvider source)
        {
            _source = source;
            _sourceChannels = source.WaveFormat.Channels;
            WaveFormat = WaveFormat.CreateIeeeFloatWaveFormat(source.WaveFormat.SampleRate, 1);
        }

        public WaveFormat WaveFormat { get; }

        public int Read(float[] buffer, int offset, int count)
        {
            var needed = count * _sourceChannels;
            if (_scratch.Length < needed)
            {
                _scratch = new float[needed];
            }
            var sourceRead = _source.Read(_scratch, 0, needed);
            var framesRead = sourceRead / _sourceChannels;
            for (var frame = 0; frame < framesRead; frame++)
            {
                float sum = 0;
                var baseIndex = frame * _sourceChannels;
                for (var ch = 0; ch < _sourceChannels; ch++)
                {
                    sum += _scratch[baseIndex + ch];
                }
                buffer[offset + frame] = sum / _sourceChannels;
            }
            return framesRead;
        }
    }
}
