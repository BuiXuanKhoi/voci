// ISpeechEngine.cs — transcription-engine abstraction (interface + shared surface)
//
// Ported from Sources/Speech/SpeechEngine.swift (56 lines). Read that file first — this is a
// near-literal translation of its protocol into a C# interface with the same start/stop/cancel +
// callback surface, so the app can swap between on-device (Whisper.net — free tier) and cloud
// (Groq — paid tier) transcription without the capture flow knowing which engine is live.
namespace Volar.Speech;

/// <summary>
/// A speech-to-text engine behind a uniform start/stop + callback surface.
///
/// ## Streaming vs batch — why <see cref="OnPartial"/> is best-effort
/// The macOS original had a genuine streaming engine (SFSpeechRecognizer) that emits interim
/// results continuously. Windows has no equivalent always-available streaming on-device engine
/// wired up here (see WhisperNetEngine's doc comment for why Whisper.net is batch-only in this
/// port) — every engine implementing this interface today is a **batch** engine: it records the
/// whole utterance locally and, only on <see cref="Stop"/>, produces a single final transcript.
/// <see cref="SupportsPartialResults"/> is <c>false</c> for all current implementations and
/// <see cref="OnPartial"/> is never invoked. The parameter/event is kept on the interface (rather
/// than deleted) so a future streaming engine can conform without an interface-shape change, and
/// so callers already coded against "best-effort partials, authoritative final" continue to work
/// unchanged.
/// </summary>
public interface ISpeechEngine
{
    /// <summary>Whether this engine emits interim results while recording. <c>false</c> for every
    /// batch engine in this port (Whisper.net, Groq).</summary>
    bool SupportsPartialResults { get; }

    /// <summary>True between a successful <see cref="Start"/> and the terminal
    /// <see cref="OnFinal"/>/<see cref="OnError"/> (or <see cref="Stop"/>/<see cref="Cancel"/>).</summary>
    bool IsRunning { get; }

    /// <summary>Fires once with the authoritative transcript when recognition ends (for batch
    /// engines: after the upload/transcription resolves). Set before calling <see cref="Start"/>.
    /// Invoked on a thread-pool thread — NOT the UI thread; callers touching UI state must
    /// marshal back themselves (mirrors the Swift original's explicit "hop to MainActor" step,
    /// which has no equivalent single global actor in .NET).</summary>
    event Action<string>? OnFinal;

    /// <summary>Fires if recognition can't start or fails mid-flight. Set before calling
    /// <see cref="Start"/>. Same threading caveat as <see cref="OnFinal"/>.</summary>
    event Action<Exception>? OnError;

    /// <summary>Requests any authorization/permission the engine needs (microphone at minimum).
    /// Returns <c>true</c> only if fully granted. Safe to call before every <see cref="Start"/>.</summary>
    Task<bool> RequestAuthorizationAsync(CancellationToken cancellationToken = default);

    /// <summary>Begins capturing. <paramref name="onPartial"/> fires for interim results on
    /// streaming engines; batch engines ignore it. Terminal results flow through
    /// <see cref="OnFinal"/>/<see cref="OnError"/>.</summary>
    void Start(Action<string>? onPartial = null);

    /// <summary>Ends capture. Streaming engines flush a final result; batch engines begin
    /// transcription/upload and deliver the transcript through <see cref="OnFinal"/> when it
    /// completes.</summary>
    void Stop();

    /// <summary>Immediately abandons the in-flight capture: stops recording, discards
    /// buffered/recorded audio (deleting any temp file), and guarantees neither
    /// <see cref="OnFinal"/> nor <see cref="OnError"/> fires for this session.</summary>
    void Cancel();
}
