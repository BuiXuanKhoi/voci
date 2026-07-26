// Sources/Account/AccountService.swift — Supabase Auth over plain URLSession.
//
// WHY NO supabase-swift SPM PACKAGE: this app has never once been compiled (Windows dev machine,
// no Swift/Xcode toolchain here — see repo convention). Adding a large dependency tree with its
// own Swift 6 concurrency surface is a risk this session cannot evaluate at all (we'd be trusting
// that package's actor/Sendable story compiles clean on a toolchain we can't run). We need exactly
// 5 endpoints (contract §2) — hand-rolling them with `URLSession`, matching the existing
// `GroqTranscriptionClient.swift`/`CloudParser.swift` pattern (struct/actor, injected session,
// typed error enum, no hardcoded secrets), keeps the risk surface to "did I call 5 URLs right"
// instead of "does a third-party package's whole concurrency model compile."
//
// specs/002-workflow-command-center/contracts/account-auth.md is the CHỐT design — every endpoint,
// header, and status code below matches it exactly.
import Foundation
import AppKit
import AuthenticationServices
import CryptoKit

/// Supabase Auth (GoTrue) + the two account-lifecycle edge functions (`subscription/status` is
/// `Entitlements`'s concern; `subscription/link` too — this file owns identity + session only,
/// plus `delete-account` since that's account lifecycle, not subscription state).
///
/// A plain `actor` (NOT `@MainActor`): all state here (`cachedSession`, `refreshTask`) is mutated
/// only through actor-isolated methods, and every method does real networking, which per this
/// task's constraints must stay off the main actor. `AppState` (a `@MainActor @Observable` type)
/// awaits into this actor and mirrors the bits of state its views need into its own `@Observable`
/// properties — see `AppState`'s "Account & Entitlements" section.
actor AccountService {
    /// `nonisolated` is spelled out even though a plain (non-`@MainActor`) actor's `static let` is
    /// nonisolated by default — this repo has been bitten specifically by `@MainActor` TYPES'
    /// `static let`s inheriting that isolation (a different situation from this plain `actor`),
    /// so this is written explicitly rather than relying on a reader to remember the distinction.
    /// A single shared instance because the credential providers below (`ConfigParseCredentialProvider`,
    /// `EnvironmentGroqCredentialProvider` in `GroqTranscriptionClient.swift`) are constructed
    /// fresh, with no-argument inits, at call sites this task does not own (`AppState.swift`'s
    /// `router` default parameter is one; `GroqEngine.swift`'s default parameter — NOT an owned
    /// file — is another) — they all need to reach the SAME session state, so it can't be a
    /// per-instance dependency threaded through every one of those call sites.
    nonisolated static let shared = AccountService()

    private static let baseURL = URL(string: "https://nuzrpipwacravfgsiacv.supabase.co")!
    /// Publishable key, contract §2 — NOT a secret (same reasoning as
    /// `ConfigParseCredentialProvider.defaultBaseURL`'s doc comment: every client of a Supabase
    /// project embeds its project's public anon/publishable key; only the service-role key is
    /// secret, and that never leaves the server). Required as the `apikey` header on every GoTrue
    /// call (contract §2: "mọi request kèm header apikey").
    private static let apiKey = "sb_publishable_pz2_mJTispHtuvcYWTpE6g_SDHmpRUI"

    private let session: URLSession
    private var cachedSession: AccountSession?
    /// Serializes concurrent `validAccessToken()` refreshes into ONE in-flight request — see that
    /// method's doc comment for the exact serialization argument.
    private var refreshTask: Task<String, Error>?

    init(session: URLSession = .shared) {
        self.session = session
        self.cachedSession = KeychainStore.loadSession()
    }

    // MARK: - Observable-ish state (read by `AppState` to mirror into its own `@Observable` props)

    var isSignedIn: Bool { cachedSession != nil }
    var currentEmail: String? { cachedSession?.user.email }
    var currentUserID: String? { cachedSession?.user.id }

    // MARK: - Sign in with Apple

    /// Contract §2 Apple nonce dance: generate a random raw nonce, send its SHA-256 hash to Apple
    /// (`ASAuthorizationAppleIDRequest.nonce`), then send the RAW nonce (not the hash) to Supabase
    /// alongside the identity token. Getting this backwards is the classic Sign In with Apple +
    /// Supabase failure mode — Supabase re-hashes whatever nonce it receives and compares that
    /// against the hash embedded inside Apple's identity token JWT; sending the hash to Apple and
    /// the raw value to Supabase (i.e. this direction, correct) is what lets those match. Sending
    /// them the other way around means Supabase hashes an already-hashed value and rejects the
    /// token as `auth_invalid` every time.
    ///
    /// Email: deliberately NEVER read from `ASAuthorizationAppleIDCredential.email` here (contract
    /// §2: "Apple chỉ trả email lần đăng nhập ĐẦU TIÊN... lấy email từ session.user.email") — this
    /// method returns whatever `AccountUser` the Supabase session carries, which is the single
    /// source of truth on every login, first or not.
    func signInWithApple() async throws -> AccountUser {
        let coordinator = await AppleSignInCoordinator()
        let (identityToken, rawNonce) = try await coordinator.signIn()
        let body: [String: Any] = [
            "provider": "apple",
            "id_token": identityToken,
            "nonce": rawNonce,
        ]
        let session = try await tokenRequest(query: "grant_type=id_token", body: body)
        return store(session)
    }

    // MARK: - Email OTP

    func sendEmailOTP(email: String) async throws {
        _ = try await authRequest(path: "auth/v1/otp", body: ["email": email, "create_user": true])
    }

    func verifyEmailOTP(email: String, code: String) async throws -> AccountUser {
        let data = try await authRequest(path: "auth/v1/verify", body: ["email": email, "token": code, "type": "email"])
        let session = try Self.decodeSession(data)
        return store(session)
    }

    // MARK: - Refresh

    /// Returns a valid access token, transparently refreshing when within ~60s of expiry (or
    /// already expired). Returns `nil` — never throws — when there's simply no session at all
    /// (signed out); DOES throw if a session exists but the refresh attempt itself fails, so
    /// callers that need to distinguish "never signed in" from "session died" can (the credential
    /// providers in `ConfigParseCredentialProvider`/`GroqTranscriptionClient` swallow either case
    /// to "no credential" via `try?`, per their own contract).
    ///
    /// Concurrency: serializes concurrent callers onto ONE in-flight refresh `Task`, stored in
    /// `refreshTask`. This works BECAUSE actor isolation means the synchronous "is a refresh
    /// already running?" check-and-set below runs atomically up to the first `await` — a second
    /// caller's call to this same actor method can only start running once the first caller has
    /// already reached (and thus already executed) its own check-and-set, so the second caller
    /// always observes `refreshTask` either still nil (and starts the one real task) or already
    /// set (and just awaits that same task's `.value`) — ten simultaneous callers (e.g. a parse
    /// request and a Groq request firing at once) can never race into ten separate refreshes.
    func validAccessToken() async throws -> String? {
        guard let current = cachedSession else { return nil }
        if current.expiresAtDate.timeIntervalSinceNow > 60 {
            return current.accessToken
        }
        if let inFlight = refreshTask {
            return try await inFlight.value
        }
        let refreshToken = current.refreshToken
        let task = Task<String, Error> {
            try await self.performRefresh(refreshToken: refreshToken)
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    /// On 400/401 (contract §2's refresh endpoint failing means the refresh token itself is dead)
    /// — clear the Keychain and drop the cached session so the app falls back to signed-out
    /// instead of retrying the same dead refresh token forever. Any other failure (network,
    /// decode) is NOT treated as "sign out"; it's transient and the next call may succeed.
    private func performRefresh(refreshToken: String) async throws -> String {
        do {
            let session = try await tokenRequest(query: "grant_type=refresh_token", body: ["refresh_token": refreshToken])
            _ = store(session)
            return session.accessToken
        } catch let error as AccountError {
            if case .http(let status, _) = error, status == 400 || status == 401 {
                cachedSession = nil
                KeychainStore.clearSession()
            }
            throw error
        }
    }

    // MARK: - Sign out / delete

    /// Best-effort server-side logout (contract §2), then ALWAYS clears local state regardless of
    /// whether the network call succeeded — a signed-out UI state must never depend on the logout
    /// request actually reaching the server (e.g. offline sign-out must still work locally).
    func signOut() async {
        if let token = cachedSession?.accessToken {
            _ = try? await authRequest(path: "auth/v1/logout", body: [:], bearer: token)
        }
        cachedSession = nil
        KeychainStore.clearSession()
    }

    /// Contract §3 `POST /functions/v1/subscription/delete-account` — Apple Guideline 5.1.1(v).
    /// Clears local state ONLY after the server confirms deletion (unlike `signOut()` above,
    /// which clears regardless) — a failed delete-account call must leave the user's session
    /// intact so they can retry, not silently sign them out of an account that still exists.
    func deleteAccount() async throws {
        guard let token = try await validAccessToken() else { throw AccountError.signedOut }
        _ = try await functionsRequest(path: "functions/v1/subscription/delete-account", body: [:], bearer: token)
        cachedSession = nil
        KeychainStore.clearSession()
    }

    // MARK: - Networking helpers

    private func tokenRequest(query: String, body: [String: Any]) async throws -> AccountSession {
        let (status, data) = try await send(path: "auth/v1/token", query: query, body: body)
        guard (200..<300).contains(status) else { throw Self.mapError(status: status, data: data) }
        return try Self.decodeSession(data)
    }

    /// GoTrue endpoints (contract §2) — always send `apikey` (default `includeApiKey: true`).
    private func authRequest(path: String, body: [String: Any], bearer: String? = nil) async throws -> Data {
        let (status, data) = try await send(path: path, body: body, bearer: bearer)
        guard (200..<300).contains(status) else { throw Self.mapError(status: status, data: data) }
        return data
    }

    /// Edge functions (contract §3) authenticate purely via `Authorization: Bearer <access_token>`
    /// — no `apikey` header, matching the existing `CloudParser`/`GroqTranscriptionClient`
    /// convention of sending Authorization only (config.toml's `verify_jwt = false`, see contract
    /// §7 — the function verifies the account token itself via `auth.getUser()`).
    private func functionsRequest(path: String, body: [String: Any], bearer: String) async throws -> Data {
        let (status, data) = try await send(path: path, body: body, bearer: bearer, includeApiKey: false)
        guard (200..<300).contains(status) else { throw Self.mapError(status: status, data: data) }
        return data
    }

    private func send(
        path: String,
        query: String? = nil,
        body: [String: Any],
        bearer: String? = nil,
        includeApiKey: Bool = true
    ) async throws -> (status: Int, data: Data) {
        var components = URLComponents(url: Self.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if let query { components?.percentEncodedQuery = query }
        guard let url = components?.url else { throw AccountError.network("Couldn't build request URL") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if includeApiKey { request.setValue(Self.apiKey, forHTTPHeaderField: "apikey") }
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { throw AccountError.decoding }
        request.httpBody = httpBody

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // Never log `error.localizedDescription` here — on some platforms transport errors
            // can echo request details, and this subsystem's privacy contract (never log tokens/
            // email) errs on the side of logging nothing at the network-failure boundary either.
            throw AccountError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw AccountError.network("Non-HTTP response") }
        return (http.statusCode, data)
    }

    private static func decodeSession(_ data: Data) throws -> AccountSession {
        guard let session = try? JSONDecoder().decode(AccountSession.self, from: data) else {
            throw AccountError.decoding
        }
        return session
    }

    private static func mapError(status: Int, data: Data) -> AccountError {
        let body = try? JSONDecoder().decode(AccountErrorBody.self, from: data)
        return .http(status: status, code: body?.error)
    }

    @discardableResult
    private func store(_ session: AccountSession) -> AccountUser {
        cachedSession = session
        KeychainStore.saveSession(session)
        return session.user
    }
}

// MARK: - Apple Sign In bridging

/// Bridges `ASAuthorizationController`'s delegate-based API to `async`/`await`. Mirrors the idea
/// in `Sources/Speech/SpeechCapture.swift`'s `ContinuationOnce` (an `NSLock`-guarded box that drops
/// every resume after the first) — reimplemented here as a THROWING variant, since Apple's
/// delegate has both a success and an error callback, either of which — plus a user cancellation,
/// which arrives through the SAME error callback with `ASAuthorizationError.canceled` — must
/// resume the continuation EXACTLY once. Not the literal same type because `SpeechCapture`'s
/// `ContinuationOnce` is `private` to that file and wraps a non-throwing continuation.
private final class ThrowingContinuationOnce<T>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    /// `sending` (both here and on `resume(throwing:)`) matches `SpeechCapture`'s `ContinuationOnce`
    /// and, more importantly, `CheckedContinuation.resume(returning:)`'s own Swift 6 signature
    /// (`sending T`, SE-0430). Without it the compiler rejects the forward below with "sending
    /// 'value' risks causing data races": a plain parameter is task-isolated, so handing it to a
    /// `sending` parameter would let this task keep a reference to a value the continuation's
    /// resumed task now also owns. Declaring it `sending` pushes that obligation out to the call
    /// sites, which all pass freshly-constructed (and in fact `Sendable`) values.
    func resume(returning value: sending T) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }

    func resume(throwing error: sending Error) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(throwing: error)
    }
}

/// One-shot coordinator for a single Sign In with Apple attempt: construct, call `signIn()` once,
/// discard. A fresh instance per attempt means there is no reentrancy to worry about (unlike
/// `SpeechCapture`, which is long-lived and reused across many capture sessions).
///
/// `@MainActor` — // UNVERIFIED: `ASAuthorizationControllerDelegate`'s callbacks are not annotated
/// with any particular isolation by the SDK, and this repo's `SpeechCapture.swift` documents in
/// detail how a similar system callback (`SFSpeechRecognizer.requestAuthorization`) can arrive on
/// a background queue and TRAP (EXC_BREAKPOINT) if the receiving closure/method is MainActor-
/// isolated. `ASAuthorizationController`'s delegate + `presentationAnchor(for:)` are widely
/// documented/observed (Apple sample code, common third-party usage) to be invoked on the main
/// thread — presenting the Sign In with Apple sheet requires it — so `@MainActor` here should be
/// safe in practice, but this has NOT been exercised on a real Mac. If it traps, the fix mirrors
/// `SpeechCapture`'s: make the delegate methods `nonisolated`, extract only `Sendable` primitives,
/// and hop to `@MainActor` explicitly before touching `self`.
@MainActor
private final class AppleSignInCoordinator: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var box: ThrowingContinuationOnce<(identityToken: String, rawNonce: String)>?
    private var rawNonce = ""

    func signIn() async throws -> (identityToken: String, rawNonce: String) {
        let nonce = try Self.randomNonce()
        rawNonce = nonce

        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.email]
        // See `AccountService.signInWithApple`'s doc comment: HASHED nonce to Apple, RAW nonce to
        // Supabase. This line is the "hashed to Apple" half.
        request.nonce = Self.sha256Hex(nonce)

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self

        return try await withCheckedThrowingContinuation { continuation in
            self.box = ThrowingContinuationOnce(continuation)
            controller.performRequests()
        }
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let identityToken = String(data: tokenData, encoding: .utf8) else {
            box?.resume(throwing: AccountError.decoding)
            return
        }
        // Deliberately never reads `credential.email` — see this type's doc comment and
        // `AccountService.signInWithApple`'s.
        box?.resume(returning: (identityToken, rawNonce))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        if let authError = error as? ASAuthorizationError, authError.code == .canceled {
            box?.resume(throwing: AccountError.cancelled)
        } else {
            box?.resume(throwing: AccountError.network(error.localizedDescription))
        }
    }

    private static func randomNonce(length: Int = 32) throws -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw AccountError.network("Secure random generation failed") }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256Hex(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
