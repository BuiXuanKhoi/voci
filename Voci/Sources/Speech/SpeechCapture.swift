// Sources/Speech/SpeechCapture.swift — on-device speech-to-text: SFSpeechRecognizer + AVAudioEngine
import Foundation
import Speech
import AVFoundation

/// Errors specific to `SpeechCapture` (as opposed to whatever `Error` the Speech framework itself
/// throws/reports).
enum SpeechCaptureError: Error, Sendable {
    case recognizerUnavailable
    case authorizationDenied
}

/// Bridges Apple's on-device Speech framework into a plain start/stop + callback API. Fully
/// on-device (`requiresOnDeviceRecognition = true`); no audio or transcript ever leaves the
/// machine, no network calls (constitution I).
///
/// ## Ownership & bridging (for Phase 2C `HotkeyManager` / Phase 3 `VociApp` wiring)
/// `HotkeyManager` should own exactly one `SpeechCapture` for the app's lifetime (creating a new
/// `SFSpeechRecognizer` + `AVAudioEngine` pair per keypress is wasteful and can hit rate limits).
/// This type intentionally has **no dependency on `AppState`** — per the Phase 2 split in
/// `docs/app-architecture.md`, `Speech/` stays decoupled from `App/`; the caller bridges partials
/// and completion into `AppState`. Intended wiring, once the ⌃⌥Space hold-to-talk hotkey fires:
///
/// ```swift
/// // once, at HotkeyManager init:
/// speechCapture.onFinal = { final in appState.finishRecording(transcript: final) }
/// speechCapture.onError = { _ in appState.captureState = .error }
///
/// // keyDown:
/// appState.startCapture()                       // -> .recording; clears liveTranscript/parsed
/// Task {
///     guard await speechCapture.requestAuthorization() else {
///         appState.captureState = .error
///         return
///     }
///     speechCapture.start(onPartial: { partial in appState.liveTranscript = partial })
/// }
///
/// // keyUp:
/// speechCapture.stop()   // triggers one last final result -> onFinal -> finishRecording(transcript:)
/// ```
///
/// ## Concurrency bridging (UNVERIFIED — please double-check on the Mac/Xcode 26 toolchain)
/// This type is `@MainActor` (all its stored state — engine/request/task refs, `isRunning` — is
/// only ever touched from the main actor). Two system callbacks do NOT run on the main actor and
/// must not touch `self` or MainActor-isolated state directly:
///   1. `AVAudioNode.installTap` block runs on a realtime audio thread. It must stay
///      allocation-light and non-blocking, so it captures only the local `SFSpeechAudioBufferRecognitionRequest`
///      (via `nonisolated(unsafe) let`, since that system class isn't `Sendable` but
///      `append(_:)` is documented safe to call from any thread while streaming) and calls only
///      `append(buffer:)` — it never reaches back into `self`.
///   2. `SFSpeechRecognizer.recognitionTask`'s result handler is invoked on an arbitrary
///      non-main queue. It captures `self` weakly (`nonisolated(unsafe) weak var` boxing avoided by
///      hopping immediately) and re-enters the main actor via `Task { @MainActor in ... }` before
///      touching `self` or invoking the caller-supplied `onPartial`/`onFinal`/`onError` closures —
///      those are expected to feed `AppState`, a `@MainActor` type.
/// If the Xcode 26 SDK has tightened `AVAudioNodeTapBlock` / the recognition-task closure to
/// require full `Sendable` closures (or `@Sendable` capture lists), the `nonisolated(unsafe)`
/// local-let workaround below is the intended escape hatch — narrow it further (e.g. wrap in a
/// dedicated `@unchecked Sendable` box type) if the compiler still objects on Mac.
@MainActor
final class SpeechCapture {
    private let audioEngine = AVAudioEngine()
    private let recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private(set) var isRunning = false

    /// Fires once, on the main actor, with the last transcript when recognition ends (normally
    /// right after `stop()` flushes the request and the recognizer reports `isFinal`). Set this
    /// before calling `start(onPartial:)`. The CALLER is responsible for then calling
    /// `appState.finishRecording(transcript:)` — kept as a settable property rather than a
    /// `start(...)` parameter so `start`'s signature stays exactly `(onPartial:)`.
    var onFinal: ((String) -> Void)?

    /// Fires on the main actor if recognition can't start (e.g. recognizer unavailable) or fails
    /// mid-stream. Set this before calling `start(onPartial:)`. The caller is expected to set
    /// `appState.captureState = .error` from it.
    var onError: ((Error) -> Void)?

    init(locale: Locale = Locale(identifier: "en-US")) {
        self.recognizer = SFSpeechRecognizer(locale: locale)
    }

    // MARK: - Authorization

    /// Requests both Speech-recognition and microphone authorization; returns `true` only if both
    /// are granted (recording is pointless with just one). Safe to call every time before
    /// `start(...)` — the system only prompts the user once and returns the cached decision after.
    func requestAuthorization() async -> Bool {
        let speechStatus = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            // Some macOS builds invoke this completion handler more than once; a second resume
            // of a checked continuation traps (EXC_BREAKPOINT). Guard so it resumes exactly once.
            let once = ContinuationOnce(continuation)
            SFSpeechRecognizer.requestAuthorization { status in
                once.resume(status)
            }
        }
        guard speechStatus == .authorized else { return false }

        let micGranted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = ContinuationOnce(continuation)
            AVAudioApplication.requestRecordPermission { granted in
                once.resume(granted)
            }
        }
        return micGranted
    }

    // MARK: - Start / stop

    /// Starts on-device recognition and taps the default input. `onPartial` fires on the main
    /// actor with the transcript-so-far for every interim result (live captions while
    /// `.recording`). Final-transcript and error notifications go through the `onFinal`/`onError`
    /// properties above (set them before calling `start`) rather than extra parameters here, so
    /// this method's signature matches `start(onPartial: @escaping (String) -> Void)` exactly.
    func start(onPartial: @escaping (String) -> Void) {
        guard !isRunning else { return }
        guard let recognizer, recognizer.isAvailable else {
            onError?(SpeechCaptureError.recognizerUnavailable)
            return
        }

        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        // On-device only — audio/transcript never leaves the machine (constitution I).
        newRequest.requiresOnDeviceRecognition = true
        request = newRequest

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        // Realtime audio thread from here down: capture only the request (thread-safe `append`),
        // never `self`. See the concurrency note in the type doc comment above.
        nonisolated(unsafe) let tapRequest = newRequest
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            tapRequest.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            request = nil
            onError?(error)
            return
        }

        isRunning = true

        task = recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
            // Not guaranteed to run on the main actor — hop before touching `self` or invoking
            // any of the AppState-bound closures.
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.teardown()
                        self.onFinal?(text)
                    } else {
                        onPartial(text)
                    }
                }
                if let error {
                    self.teardown()
                    self.onError?(error)
                }
            }
        }
    }

    /// Ends the audio input and signals end-of-utterance to the recognition request, which causes
    /// the recognizer to deliver one last final result on the in-flight task (routed through the
    /// `onFinal` property, if set). Safe to call even if recognition already finished on its own.
    func stop() {
        guard isRunning else { return }
        request?.endAudio()
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        isRunning = false
    }

    /// Internal cleanup shared by the "recognizer finished/errored on its own" and `stop()` paths.
    private func teardown() {
        task?.cancel()
        task = nil
        request = nil
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        isRunning = false
    }
}

/// Guards a `CheckedContinuation` so it is resumed at most once. Some system authorization
/// callbacks (notably `SFSpeechRecognizer.requestAuthorization` on some macOS builds) invoke
/// their completion handler more than once; a second resume of a checked continuation traps
/// (EXC_BREAKPOINT). This box drops every resume after the first.
private final class ContinuationOnce<T>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, Never>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}
