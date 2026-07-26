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

/// Production provider (UPDATED per specs/002-workflow-command-center/contracts/account-auth.md,
/// 2026-07-26): Groq is **Pro-only** (contract §1 — free tier has a 0 speech quota server-side
/// too, but this client gates BEFORE ever sending a request, same "code first, key later" spirit
/// as before). Returns the account's Supabase access token as the bearer credential ONLY when (a)
/// an account session exists in the Keychain AND (b) the cached entitlement tier says Pro.
///
/// Previously this read a hand-typed dev token from `GROQ_PROXY_TOKEN`/`GROQ_API_KEY` env vars or
/// `volar.groqToken` UserDefaults — that whole mechanism is REMOVED (mirrors the contract's own
/// removal of `PARSE_DEV_TOKEN`: "không còn cần, vì tạo account free/pro là test được ngay"). A
/// local smoke-test now needs a real signed-in Pro account, same as production; there is no more
/// direct-Groq-with-a-raw-key escape hatch. (Flagged to `backlog.md` as a possible follow-up if a
/// dev-only override is wanted back for offline testing.)
///
/// Kept as the SAME type name (`EnvironmentGroqCredentialProvider`) as before this change —
/// `GroqEngine.swift` (NOT in this task's owned files) references this type by name as its default
/// credential-provider parameter and reads `EnvironmentGroqCredentialProvider.isConfigured`
/// directly; renaming it would require editing that out-of-scope file. The name is now a slight
/// misnomer (nothing here reads the environment anymore except the base-URL smoke-testing override
/// below) — flagged for whoever next owns `GroqEngine.swift` to rename together.
struct EnvironmentGroqCredentialProvider: GroqCredentialProvider {
    /// Direct Groq endpoint — kept only as a documented opt-in for local smoke-testing via
    /// `volar.groqBaseURL`; NOT the default anymore (see doc comment above). Note this path STILL
    /// requires `isConfigured`/`authorization()` below to pass (signed in + Pro) — there is no
    /// longer any way to bypass the account/entitlement check even when pointing at Groq directly.
    static let groqDirectBaseURLForSmokeTesting = URL(string: "https://api.groq.com/openai/v1")!
    /// Default: Volar's Supabase edge-function proxy for Groq Speech-to-Text (holds the real Groq
    /// key server-side; see `supabase/functions/groq/index.ts`). Force-unwrap is safe: fixed,
    /// hand-verified literal, never user input.
    static let groqProxyBaseURL = URL(string: "https://nuzrpipwacravfgsiacv.supabase.co/functions/v1/groq")!

    /// `true` iff signed in AND the cached tier is Pro. `Entitlements.cachedIsPro` is a
    /// UserDefaults SNAPSHOT (NOT a secret — just the string "free"/"pro", see
    /// `Sources/Model/Entitlements.swift`) kept fresh by `refreshStatus()`/`purchase()`/
    /// `relinkCurrentEntitlements()`; reading it here (rather than awaiting the network) is what
    /// lets `AppState.selectedEngine` gate Groq SYNCHRONOUSLY before a capture even starts — the
    /// same "pick on-device before a key/entitlement exists" fallback this codebase already had,
    /// now driven by account/entitlement state instead of an env token. Mirrors
    /// `ConfigParseCredentialProvider.isConfigured`'s Keychain-read shape.
    static var isConfigured: Bool {
        KeychainStore.loadSession() != nil && Entitlements.cachedIsPro
    }

    func baseURL() async throws -> URL {
        if let s = ProcessInfo.processInfo.environment["GROQ_BASE_URL"]
            ?? UserDefaults.standard.string(forKey: "volar.groqBaseURL"),
           let url = URL(string: s) {
            return url
        }
        return Self.groqProxyBaseURL
    }

    /// Re-checks the same two conditions as `isConfigured` (does not just trust it) — a session
    /// that expired or failed to refresh, or a tier that dropped back to free, BETWEEN engine
    /// selection (`AppState.selectedEngine`, evaluated once at `startCapture()`) and this
    /// upload-time call must also degrade to `.missingCredentials` here, never send a stale/
    /// unauthorized request.
    ///
    /// KNOWN RESIDUAL GAP (self-review, flagged rather than fixed): this method is the client's
    /// only pre-flight gate. If the CACHED tier is stale (e.g. a subscription just expired and
    /// `Entitlements.refreshStatus()` hasn't run since) this can still return a bearer token the
    /// server rejects with `403 upgrade_required` mid-flight. `GroqEngine.swift` (NOT in this
    /// task's owned files) is what decides how a thrown `GroqTranscriptionError.http(403, _)`
    /// surfaces from there (today: `onError`, a visible capture error) — this file has no path to
    /// convert that into a silent on-device fallback without editing that out-of-scope file.
    /// Logged to `backlog.md`.
    func authorization() async throws -> String? {
        guard Entitlements.cachedIsPro else { throw GroqTranscriptionError.missingCredentials }
        guard let token = try? await AccountService.shared.validAccessToken() else {
            throw GroqTranscriptionError.missingCredentials
        }
        return "Bearer \(token)"
    }
}

/// Pure network layer for Groq Speech-to-Text: builds a multipart `/audio/transcriptions` request
/// and returns the transcript. No AVFoundation, no app state — unit-testable by injecting a
/// `URLSession`. The `language` hint (ISO-639-1, e.g. "vi") is forwarded only when the caller has
/// one — i.e. the user picked a specific locale in Settings' Recognition-language picker; the
/// picker's "Automatic (multilingual)" choice resolves to `nil` here, which omits the field
/// entirely so Groq auto-detects the spoken language (needed for vi↔en code-switching — see
/// backlog). Short 2-5s clips auto-detect poorly (Whisper reasons over a 30s window padded with
/// silence), so a known locale should always be forwarded when the user has one set.
struct GroqTranscriptionClient: Sendable {
    let credentials: GroqCredentialProvider
    var session: URLSession = .shared
    /// Reject recordings past Groq's documented free-tier limit (25 MB) before uploading.
    var maxAudioBytes = 25 * 1024 * 1024

    /// - Parameter language: ISO-639-1 code (e.g. "vi", "en") to hint Groq's language detection,
    ///   or `nil` to let Groq auto-detect (sends no `language` field at all).
    func transcribe(audio: Data, filename: String, model: GroqModel, language: String? = nil) async throws -> String {
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
        let body = Self.multipartBody(audio: audio, filename: filename, model: model.rawValue, language: language, boundary: boundary)

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

    private static func multipartBody(audio: Data, filename: String, model: String, language: String?, boundary: String) -> Data {
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        field("model", model)
        field("response_format", "json")
        // "language" is sent only when the caller has a concrete ISO-639-1 hint (user picked a
        // specific locale in Settings); the "Automatic (multilingual)" choice passes `nil` here so
        // the field is omitted entirely and Groq auto-detects (vi↔en code-switching, backlog).
        if let language, !language.isEmpty {
            field("language", language)
        }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(audio)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }
}
