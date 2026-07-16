// Sources/Speech/WhisperKitEngine.swift — WhisperKit (on-device, FREE tier) batch transcription engine
import Foundation
import AVFoundation
import WhisperKit

/// On-device transcription via WhisperKit (argmaxinc, MIT — Whisper on CoreML/Neural Engine) — the
/// **free** tier of the freemium speech design (backlog "★ KIẾN TRÚC CHỐT"): private, offline,
/// no per-minute cost, in exchange for weaker accuracy than the Groq paid tier — especially on
/// Vietnamese and vi↔en code-switching, which is pushed to Groq by design (see backlog). A
/// **batch** `SpeechEngine`, structured exactly like `GroqEngine`: records the whole utterance to a
/// temp AAC file, then on `stop()` runs it through the local WhisperKit pipeline and delivers a
/// single final transcript through `onFinal`. No interim results (`supportsPartialResults == false`).
///
/// ## Model
/// Defaults to `"base"` (~145MB) rather than `"small"` (~480MB) to honor the backlog's "keep the
/// free tier light" call. `"small"` is a meaningfully better English-accuracy option if that
/// tradeoff is ever revisited — change `modelName`'s default (or pass one into `init`) to switch.
///
/// ## Hardware gate
/// WhisperKit needs Apple Silicon (Neural Engine). `isSupported` gates this at the type level so
/// `AppState` can fall back to `SpeechCapture` on Intel Macs without ever constructing a pipeline
/// that can't run. `prepare()` also self-guards and reports `.failed` on unsupported hardware, in
/// case something calls it directly.
///
/// ## Model download / readiness
/// WhisperKit's initializer downloads the named model from Hugging Face on first run and caches it
/// under Application Support — that network fetch (and subsequent CoreML compile) is what `.preparing`
/// covers. `state` is exposed so Settings can show "Downloading model…" / "Ready" / an error, and so
/// `AppState` can decide whether to route a capture to this engine or fall back to Apple's on-device
/// recognizer while the model isn't ready yet.
///
/// ## Concurrency
/// `@MainActor`, matching every other engine (`SpeechCapture`, `GroqEngine`) and the `SpeechEngine`
/// protocol itself. `session` mirrors `GroqEngine`'s token pattern to guard the async transcription
/// against a stop/restart race.
@MainActor
final class WhisperKitEngine: SpeechEngine {
    let supportsPartialResults = false
    private(set) var isRunning = false

    var onFinal: ((String) -> Void)?
    var onError: ((Error) -> Void)?

    /// Whether this Mac's hardware can run WhisperKit at all (Neural Engine / Apple Silicon).
    /// `AppState` checks this before ever routing a capture here.
    static var isSupported: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    /// The WhisperKit model identifier to load. Defaults to `"base"` — see the type-level doc
    /// comment for the `"small"` tradeoff.
    private let modelName: String

    /// Model-download/load lifecycle, surfaced to Settings (and used by `AppState` to decide
    /// whether to route captures here vs. falling back to `SpeechCapture`).
    enum State: Equatable {
        case notReady
        case preparing
        case ready
        case failed(String)
    }
    private(set) var state: State = .notReady
    var isModelReady: Bool { state == .ready }

    private var whisperKit: WhisperKit?

    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    /// Guards the async transcription against a stop/restart race (mirrors `GroqEngine.session` /
    /// `AppState.captureSession`).
    private var session = 0

    init(modelName: String = "base") {
        self.modelName = modelName
    }

    /// Downloads (first run only — cached after) and loads the WhisperKit model. Idempotent: a
    /// second call while `.preparing` or once `.ready` is a no-op. Call this eagerly (e.g. when the
    /// user picks WhisperKit in Settings) so the model is ready well before the next capture.
    func prepare() async {
        guard Self.isSupported else {
            state = .failed("Requires Apple Silicon")
            return
        }
        switch state {
        case .preparing, .ready:
            return
        case .notReady, .failed:
            break
        }
        state = .preparing
        do {
            // UNVERIFIED (Mac/Xcode) — confirm WhisperKitConfig(model:) and the WhisperKit(_:)
            // async-throwing initializer signature against the installed WhisperKit version;
            // this is the documented pattern as of WhisperKit 0.9.x.
            let pipe = try await WhisperKit(WhisperKitConfig(model: modelName))
            self.whisperKit = pipe
            self.state = .ready
        } catch {
            self.state = .failed(error.localizedDescription)
        }
    }

    /// WhisperKit only needs the microphone (no Speech-framework authorization, no server
    /// consent — everything stays on-device). Matches `GroqEngine`'s mic-only path.
    func requestAuthorization() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start(onPartial: @escaping (String) -> Void) {
        guard !isRunning else { return }
        // `onPartial` is intentionally ignored — a batch engine emits no interim results.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("volar-whisper-\(UUID().uuidString).m4a")
        // 16 kHz mono AAC — matches GroqEngine's format; ideal for Whisper.
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]
        do {
            let rec = try AVAudioRecorder(url: url, settings: settings)
            guard rec.record() else {
                onError?(NSError(domain: "Volar.WhisperKit", code: 0, userInfo: [NSLocalizedDescriptionKey: "Recorder failed to start"]))
                return
            }
            recorder = rec
            fileURL = url
            isRunning = true
            session += 1
        } catch {
            onError?(error)
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        recorder?.stop()
        recorder = nil
        guard let url = fileURL else { return }
        fileURL = nil
        session += 1
        let token = session

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let pipe = self.whisperKit else {
                if self.session == token {
                    self.onError?(NSError(domain: "Volar.WhisperKit", code: 1, userInfo: [NSLocalizedDescriptionKey: "Model not loaded"]))
                }
                try? FileManager.default.removeItem(at: url)
                return
            }
            do {
                // UNVERIFIED (Mac/Xcode) — confirm DecodingOptions' field names (`task`,
                // `detectLanguage`) and `WhisperKit.transcribe(audioPath:decodeOptions:)`'s
                // signature/return type ([TranscriptionResult]) against the installed WhisperKit
                // version. No `language:` is passed on purpose so vi/en are auto-detected.
                let options = DecodingOptions(task: .transcribe, detectLanguage: true)
                let results = try await pipe.transcribe(audioPath: url.path, decodeOptions: options)
                let text = results.map { $0.text }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
                try? FileManager.default.removeItem(at: url)
                guard self.session == token else { return }
                if text.isEmpty {
                    self.onError?(NSError(domain: "Volar.WhisperKit", code: 2, userInfo: [NSLocalizedDescriptionKey: "Nothing recognized"]))
                } else {
                    self.onFinal?(text)
                }
            } catch {
                try? FileManager.default.removeItem(at: url)
                guard self.session == token else { return }
                self.onError?(error)
            }
        }
    }
}
