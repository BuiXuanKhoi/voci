// Sources/Speech/GroqEngine.swift — Groq (cloud, paid tier) batch transcription engine
import Foundation
import AVFoundation

/// Cloud transcription via Groq Speech-to-Text — the paid tier of the freemium speech design
/// (backlog: on-device WhisperKit = free, Groq = paid). A **batch** `SpeechEngine`: it records the
/// whole utterance to a temp AAC file, then on `stop()` uploads it and delivers a single final
/// transcript through `onFinal`. No interim results (`supportsPartialResults == false`).
///
/// Model strategy (backlog "★ KIẾN TRÚC CHỐT"): `whisper-large-v3` primary for best vi↔en
/// code-switching; on a *server-side (5xx) or transport* failure it falls back once to
/// `whisper-large-v3-turbo` (cheaper/faster) rather than failing the capture outright. Language is
/// auto-detected (the client sends no `language`).
///
/// Scope note: NOT yet wired into `AppState`/`PopoverView` (that's the tier-routing + StoreKit
/// epic). It conforms to `SpeechEngine` so the capture flow can route to it later exactly as it
/// does the on-device engine.
@MainActor
final class GroqEngine: SpeechEngine {
    let supportsPartialResults = false
    private(set) var isRunning = false

    var onFinal: ((String) -> Void)?
    var onError: ((Error) -> Void)?

    private let client: GroqTranscriptionClient
    private let primaryModel: GroqModel
    private let fallbackModel: GroqModel

    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    /// Guards the async upload against a stop/restart race (mirrors `AppState.captureSession`).
    private var session = 0

    init(
        client: GroqTranscriptionClient = GroqTranscriptionClient(credentials: EnvironmentGroqCredentialProvider()),
        primaryModel: GroqModel = .largeV3,
        fallbackModel: GroqModel = .largeV3Turbo
    ) {
        self.client = client
        self.primaryModel = primaryModel
        self.fallbackModel = fallbackModel
    }

    /// Groq only needs the microphone (no Speech-framework authorization). Matches
    /// `SpeechCapture`'s mic path so both engines authorize identically.
    func requestAuthorization() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start(onPartial: @escaping (String) -> Void) {
        guard !isRunning else { return }
        // `onPartial` is intentionally ignored — a batch engine emits no interim results.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("volar-groq-\(UUID().uuidString).m4a")
        // 16 kHz mono AAC: ideal for Whisper, keeps the upload small.
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]
        do {
            let rec = try AVAudioRecorder(url: url, settings: settings)
            guard rec.record() else {
                onError?(GroqTranscriptionError.network("Recorder failed to start"))
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
            defer { try? FileManager.default.removeItem(at: url) }
            let audio: Data
            do {
                audio = try Data(contentsOf: url)
            } catch {
                if self.session == token { self.onError?(GroqTranscriptionError.network("Couldn't read recording")) }
                return
            }
            do {
                let text = try await self.transcribeWithFallback(audio: audio, filename: url.lastPathComponent)
                guard self.session == token else { return }
                self.onFinal?(text)
            } catch {
                guard self.session == token else { return }
                self.onError?(error)
            }
        }
    }

    /// Tries the primary (large-v3) model; on a server-side (5xx) or transport failure only, retries
    /// once with the turbo fallback. Client-side failures (missing creds, 4xx, too-large, empty,
    /// decoding) are NOT retried — a different model wouldn't help.
    private func transcribeWithFallback(audio: Data, filename: String) async throws -> String {
        do {
            return try await client.transcribe(audio: audio, filename: filename, model: primaryModel)
        } catch let error as GroqTranscriptionError {
            guard Self.isRetriable(error) else { throw error }
            return try await client.transcribe(audio: audio, filename: filename, model: fallbackModel)
        }
    }

    private static func isRetriable(_ error: GroqTranscriptionError) -> Bool {
        switch error {
        case .network: return true
        case .http(let status, _): return (500..<600).contains(status)
        case .missingCredentials, .audioTooLarge, .decoding, .emptyTranscript: return false
        }
    }
}
