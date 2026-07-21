// Sources/Speech/GroqTranscriptionClient.swift — Groq Speech-to-Text network layer (OpenAI-compatible)
import Foundation

/// Groq Whisper models exposed at the OpenAI-compatible `/audio/transcriptions` route.
/// `largeV3` is the accuracy primary (best vi↔en code-switching per backlog); `largeV3Turbo` is
/// the cheaper/faster fallback (~$0.04/hr audio, ~216x realtime).
enum GroqModel: String, Sendable, CaseIterable {
    case largeV3 = "whisper-large-v3"
    case largeV3Turbo = "whisper-large-v3-turbo"
}

/// Failures from the Groq transcription network layer.
enum GroqTranscriptionError: Error, Sendable {
    /// No endpoint credential available (proxy token / dev key). The engine surfaces this instead
    /// of sending an unauthenticated request.
    case missingCredentials
    /// Recording exceeds Groq's per-request size limit — rejected before upload to avoid a certain 413.
    case audioTooLarge(bytes: Int)
    /// Non-2xx HTTP response. `body` is the (truncated) server message for logging/diagnosis.
    case http(status: Int, body: String)
    /// 2xx but the JSON body couldn't be decoded into a transcript.
    case decoding
    /// Transport-level failure (offline, DNS, TLS, timeout…).
    case network(String)
    /// Server returned an empty transcript (nothing recognized).
    case emptyTranscript
}

extension GroqTranscriptionError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "No Groq credentials are configured."
        case .audioTooLarge(let bytes):
            return "Recording is too large to upload (\(bytes) bytes)."
        case .http(let status, _):
            return "Groq request failed (HTTP \(status))."
        case .decoding:
            return "Couldn't read Groq's transcription response."
        case .network(let message):
            return "Network error talking to Groq: \(message)"
        case .emptyTranscript:
            return "Nothing was recognized in the recording."
        }
    }
}

/// Supplies the transcription endpoint + authorization. Injected so the real Groq key NEVER lives
/// in the app binary: in production this returns the Volar **proxy** base URL + a short-lived
/// app/user token (the proxy holds the Groq key and gates by paid tier); for local dev it can be
/// swapped for one pointing straight at `https://api.groq.com/openai/v1` with a developer key. The
/// client is agnostic to which.
protocol GroqCredentialProvider: Sendable {
    /// Base URL exposing an OpenAI-compatible API (proxy in prod, Groq directly in dev). The client
    /// appends `audio/transcriptions`.
    func baseURL() async throws -> URL
    /// Value for the `Authorization` header (e.g. `"Bearer …"`), or `nil` if none is needed. Throw
    /// `GroqTranscriptionError.missingCredentials` when no credential is available.
    func authorization() async throws -> String?
}

/// Dev-only default provider. Reads the base URL + bearer token from the environment (or
/// `UserDefaults` as a convenience) and NEVER hardcodes a key. Production should replace this with a
/// Keychain/StoreKit-backed provider returning the Volar proxy URL + a per-user token.
///
/// - Base URL: `GROQ_BASE_URL` env or `volar.groqBaseURL` default; falls back to Groq direct
///   (`https://api.groq.com/openai/v1`) so a developer can smoke-test without a proxy.
/// - Token: `GROQ_PROXY_TOKEN` or `GROQ_API_KEY` env, or `volar.groqToken` default. Absent → throws
///   `.missingCredentials`.
struct EnvironmentGroqCredentialProvider: GroqCredentialProvider {
    static let groqDirectBaseURL = URL(string: "https://api.groq.com/openai/v1")!

    /// True when a bearer token is configured (env `GROQ_PROXY_TOKEN`/`GROQ_API_KEY`, or
    /// `volar.groqToken`) — lets the app fall back to on-device BEFORE recording (like WhisperKit's
    /// readiness gate) instead of hard-erroring only at upload time. Reads the SAME sources as
    /// `authorization()` below so the two can't disagree. Mirrors `ConfigParseCredentialProvider.isConfigured`.
    static var isConfigured: Bool {
        let env = ProcessInfo.processInfo.environment
        let token = env["GROQ_PROXY_TOKEN"] ?? env["GROQ_API_KEY"]
            ?? UserDefaults.standard.string(forKey: "volar.groqToken")
        return !(token ?? "").isEmpty
    }

    func baseURL() async throws -> URL {
        if let s = ProcessInfo.processInfo.environment["GROQ_BASE_URL"]
            ?? UserDefaults.standard.string(forKey: "volar.groqBaseURL"),
           let url = URL(string: s) {
            return url
        }
        return Self.groqDirectBaseURL
    }

    func authorization() async throws -> String? {
        let env = ProcessInfo.processInfo.environment
        guard let token = env["GROQ_PROXY_TOKEN"] ?? env["GROQ_API_KEY"]
                ?? UserDefaults.standard.string(forKey: "volar.groqToken"),
              !token.isEmpty else {
            throw GroqTranscriptionError.missingCredentials
        }
        return "Bearer \(token)"
    }
}

/// Pure network layer for Groq Speech-to-Text: builds a multipart `/audio/transcriptions` request
/// and returns the transcript. No AVFoundation, no app state — unit-testable by injecting a
/// `URLSession`. Language is deliberately omitted from the request so Groq auto-detects the spoken
/// language (required for vi↔en code-switching — see backlog).
struct GroqTranscriptionClient: Sendable {
    let credentials: GroqCredentialProvider
    var session: URLSession = .shared
    /// Reject recordings past Groq's documented free-tier limit (25 MB) before uploading.
    var maxAudioBytes = 25 * 1024 * 1024

    func transcribe(audio: Data, filename: String, model: GroqModel) async throws -> String {
        guard audio.count <= maxAudioBytes else {
            throw GroqTranscriptionError.audioTooLarge(bytes: audio.count)
        }
        let base = try await credentials.baseURL()
        let auth = try await credentials.authorization()

        let url = base.appendingPathComponent("audio/transcriptions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if let auth { request.setValue(auth, forHTTPHeaderField: "Authorization") }
        let boundary = "volar-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let body = Self.multipartBody(audio: audio, filename: filename, model: model.rawValue, boundary: boundary)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(for: request, from: body)
        } catch {
            throw GroqTranscriptionError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw GroqTranscriptionError.network("Non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data.prefix(2000), encoding: .utf8) ?? ""
            throw GroqTranscriptionError.http(status: http.statusCode, body: bodyText)
        }
        guard let decoded = try? JSONDecoder().decode(GroqTranscriptionResponse.self, from: data) else {
            throw GroqTranscriptionError.decoding
        }
        let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw GroqTranscriptionError.emptyTranscript }
        return text
    }

    private struct GroqTranscriptionResponse: Decodable { let text: String }

    private static func multipartBody(audio: Data, filename: String, model: String, boundary: String) -> Data {
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        field("model", model)
        field("response_format", "json")
        // NO "language" field on purpose → Groq auto-detects (vi↔en code-switching, backlog).
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(audio)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }
}
