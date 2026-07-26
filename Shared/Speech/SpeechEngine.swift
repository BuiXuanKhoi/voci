// Sources/Speech/SpeechEngine.swift — transcription-engine abstraction (protocol + shared surface)
import Foundation

/// A speech-to-text engine behind a uniform start/stop + callback surface, so the app can swap
/// between on-device (SFSpeechRecognizer / WhisperKit — free tier) and cloud (Groq — paid tier)
/// transcription without the capture flow (`AppState`/`PopoverView`) knowing which is live.
/// Mirrors the `NLParser` "protocol + swappable impl" convention (see `Sources/Model/NLParser.swift`).
///
/// ## Streaming vs batch — why `onPartial` is best-effort
/// Engines differ in *when* they can produce text:
///   - **Streaming** (`SFSpeechRecognizer`): emits interim results continuously via `onPartial`
///     while recording, then a final result on `stop()`.
///   - **Batch** (Groq, or any upload-then-transcribe cloud API): records the whole utterance
///     locally and, only on `stop()`, uploads it to produce a single final transcript. It emits NO
///     partials — `supportsPartialResults` is `false` and `onPartial` is never called.
/// Callers must treat `onPartial` as best-effort (drive live captions from it when present, show an
/// indeterminate "listening…" state otherwise) and always rely on `onFinal` for the authoritative
/// transcript.
///
/// The surface deliberately matches the existing `SpeechCapture` (`onFinal`/`onError`/
/// `requestAuthorization`/`start(onPartial:)`/`stop()`/`isRunning`) so `SpeechCapture` can later
/// conform with a one-line `: SpeechEngine` + `supportsPartialResults { true }` — not done here to
/// keep this change off the working (never-compiled) capture path.
@MainActor
protocol SpeechEngine: AnyObject {
    /// Whether this engine emits interim (`onPartial`) results while recording. `false` for batch
    /// engines like Groq.
    var supportsPartialResults: Bool { get }

    /// True between a successful `start(...)` and the terminal `onFinal`/`onError` (or `stop()`).
    var isRunning: Bool { get }

    /// Fires once, on the main actor, with the authoritative transcript when recognition ends (for
    /// batch engines: after the upload resolves). Set before calling `start`.
    var onFinal: ((String) -> Void)? { get set }

    /// Fires on the main actor if recognition can't start or fails. Set before calling `start`.
    var onError: ((Error) -> Void)? { get set }

    /// Requests any authorization the engine needs (mic, and speech for on-device). Returns `true`
    /// only if fully granted. Safe to call before every `start`.
    func requestAuthorization() async -> Bool

    /// Begins capturing. `onPartial` fires on the main actor for interim results on streaming
    /// engines; batch engines ignore it. Terminal results flow through `onFinal`/`onError`.
    func start(onPartial: @escaping (String) -> Void)

    /// Ends capture. Streaming engines flush a final result; batch engines begin the upload and
    /// deliver the transcript through `onFinal` when it returns.
    func stop()

    /// Immediately abandons the in-flight capture: stops recording, discards buffered/recorded
    /// audio (deleting any temp file), and guarantees neither `onFinal` nor `onError` fires for
    /// this session.
    func cancel()
}
