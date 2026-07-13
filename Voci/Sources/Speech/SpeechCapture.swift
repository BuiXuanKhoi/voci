// Sources/Speech/SpeechCapture.swift — on-device speech-to-text: SFSpeechRecognizer + AVAudioEngine
import Foundation
import Speech
import AVFoundation

/// Errors specific to `SpeechCapture` (as opposed to whatever `Error` the Speech framework itself
/// throws/reports).
enum SpeechCaptureError: Error, Sendable {
    case recognizerUnavailable
    case authorizationDenied
    case recognitionFailed(String)
    /// On-device recognition couldn't run (Dictation is off on this Mac). Distinct from
    /// `recognitionFailed` so the caller can offer "enable Dictation" / "use Apple's servers"
    /// instead of a generic error.
    case onDeviceUnavailable
}

/// Bridges Apple's Speech framework into a plain start/stop + callback API. Prefers on-device
/// recognition (`requiresOnDeviceRecognition = true`, no audio/transcript ever leaves the
/// machine — constitution I); falls back to Apple's server-based recognition only when the
/// caller has explicitly set `allowServerFallback = true` (user consent, e.g. Dictation is off).
///
/// ## Ownership & bridging (for Phase 2C `HotkeyManager` / Phase 3 `VociApp` wiring)
/// `HotkeyManager` should own exactly one `SpeechCapture` for the app's lifetime (creating a new
/// `SFSpeechRecognizer` + `AVAudioEngine` pair per keypress is wasteful and can hit rate limits).
/// This type intentionally has **no dependency on `AppState`** — per the Phase 2 split in
/// `docs/app-architecture.md`, `Speech/` stays decoupled from `App/`; the caller bridges partials
/// and completion into `AppState`. Intended wiring, once the ⌃⌥M toggle-capture hotkey fires:
///
/// ```swift
/// // once, at HotkeyManager init:
/// speechCapture.onFinal = { final in appState.finishRecording(transcript: final) }
/// speechCapture.onError = { _ in appState.captureState = .error }
///
/// // first press (toggle -> start):
/// appState.startCapture()                       // -> .recording; clears liveTranscript/parsed
/// Task {
///     guard await speechCapture.requestAuthorization() else {
///         appState.captureState = .error
///         return
///     }
///     speechCapture.start(onPartial: { partial in appState.liveTranscript = partial })
/// }
///
/// // second press (toggle -> stop):
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

    /// Interim-result handler, stored (not just a `start` parameter) so the recognition-task
    /// callback can reach it via `self` on the main actor instead of capturing a non-Sendable
    /// closure into the `@MainActor` hop.
    private var onPartialHandler: ((String) -> Void)?

    /// When false (default): force on-device recognition (private, needs Dictation enabled).
    /// When true (user consented): allow Apple's server recognition (audio leaves the Mac).
    var allowServerFallback = false

    /// Tracks whether the in-flight attempt is on-device, so the `recognitionTask` error handler
    /// can tell a Dictation-disabled failure apart from any other recognition failure.
    private var isOnDeviceAttempt = false

    init(locale: Locale = Locale(identifier: "en-US")) {
        self.recognizer = SFSpeechRecognizer(locale: locale)
        print("[Voci.Speech] recognizer == nil: \(self.recognizer == nil)")
    }

    // MARK: - Authorization

    /// Requests both Speech-recognition and microphone authorization; returns `true` only if both
    /// are granted (recording is pointless with just one). Safe to call every time before
    /// `start(...)` — the system only prompts the user once and returns the cached decision after.
    ///
    /// IMPORTANT (Swift 6 dynamic isolation): this method lives on a `@MainActor` type, so any
    /// non-`@Sendable` closure literal formed here is INFERRED to be MainActor-isolated. The
    /// Speech framework's completion handler isn't `@Sendable` in the SDK and is invoked on a
    /// background queue (`com.apple.root.default-qos`) — Swift 6 inserts a runtime
    /// `dispatch_assert_queue(main)` check at the entry of MainActor-isolated closures, which
    /// traps with EXC_BREAKPOINT *before the closure body even runs* (this is why the
    /// `ContinuationOnce` double-resume guard alone could not stop the crash). The explicit
    /// `@Sendable` below opts the closure out of MainActor inference so it may legally run on
    /// any queue.
    func requestAuthorization() async -> Bool {
        let speechStatus = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            // `@Sendable` is load-bearing — see the isolation note in the doc comment above.
            // ContinuationOnce additionally guards against the handler firing more than once
            // (a second resume of a checked continuation also traps).
            let once = ContinuationOnce(continuation)
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                once.resume(status)
            }
        }
        print("[Voci.Speech] speech auth = \(speechStatus.rawValue)")
        guard speechStatus == .authorized else { return false }

        // Native async variant (macOS 14+) — no completion handler, no continuation, and
        // therefore no isolation-inference hazard at all for the mic half.
        let micGranted = await AVAudioApplication.requestRecordPermission()
        print("[Voci.Speech] mic granted = \(micGranted)")
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
        print("[Voci.Speech] recognizer.isAvailable=\(recognizer.isAvailable) supportsOnDevice=\(recognizer.supportsOnDeviceRecognition)")

        onPartialHandler = onPartial

        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        // Prefer on-device (private). Only use Apple's servers when the user has explicitly
        // consented (allowServerFallback) — audio leaves the Mac in that mode.
        let useOnDevice = !allowServerFallback
        newRequest.requiresOnDeviceRecognition = useOnDevice
        isOnDeviceAttempt = useOnDevice
        request = newRequest

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        print("[Voci.Speech] input format sampleRate=\(format.sampleRate) channels=\(format.channelCount)")

        // With no usable input device (or the mic TCC grant not yet effective) the hardware
        // format comes back as 0 Hz / 0 channels — `installTap` then raises an ObjC exception
        // ("IsFormatSampleRateAndChannelCountValid(format)") and CoreAudio aborts the process.
        // Fail soft through `onError` instead.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            print("[Voci.Speech] aborting start: input format is 0 Hz / 0 channels (no usable audio input device)")
            request = nil
            onError?(SpeechCaptureError.recognitionFailed("No usable audio input device"))
            return
        }

        // Realtime audio thread from here down: capture only the request (thread-safe `append`),
        // never `self`. `@Sendable` is load-bearing: without it this closure literal, formed in a
        // `@MainActor` method, is inferred MainActor-isolated and Swift 6's runtime isolation
        // check traps (EXC_BREAKPOINT) when the audio thread invokes it — same failure mode as
        // the authorization callback (see `requestAuthorization`).
        nonisolated(unsafe) let tapRequest = newRequest
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in
            tapRequest.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            print("[Voci.Speech] audioEngine.start FAILED: \(error.localizedDescription)")
            inputNode.removeTap(onBus: 0)
            request = nil
            onError?(error)
            return
        }

        isRunning = true

        // `@Sendable` again load-bearing (arbitrary-queue callback; prevents MainActor inference
        // + the Swift 6 runtime isolation trap). Capturing `self` weakly is fine — a @MainActor
        // class is implicitly Sendable.
        task = recognizer.recognitionTask(with: newRequest) { @Sendable [weak self] result, error in
            // This handler runs on an arbitrary queue, and `result`/`error` are non-Sendable.
            // Pull only Sendable primitives out here, then hop to the main actor with just those
            // (never send SFSpeechRecognitionResult across the actor boundary). Mirrors the
            // Sendable-primitive extraction pattern in HotkeyManager.
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let errorMessage = error?.localizedDescription
            print("[Voci.Speech] recognitionTask error: \(errorMessage ?? "nil")")
            print("[Voci.Speech] partial/final text len=\(text?.count ?? -1) isFinal=\(isFinal)")
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let text {
                    if isFinal {
                        self.teardown()
                        self.onFinal?(text)
                    } else {
                        self.onPartialHandler?(text)
                    }
                }
                if let errorMessage {
                    self.teardown()
                    let lower = errorMessage.lowercased()
                    if self.isOnDeviceAttempt, lower.contains("dictation") || lower.contains("siri") {
                        self.onError?(SpeechCaptureError.onDeviceUnavailable)
                    } else {
                        self.onError?(SpeechCaptureError.recognitionFailed(errorMessage))
                    }
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

    func resume(_ value: sending T) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}
