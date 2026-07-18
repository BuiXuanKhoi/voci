// Sources/Parsing/DeviceCheckProvider.swift — free-tier device attestation token generation
// (T023) for the `X-Device-Token` header consumed by `CloudParser`.
//
// NAMING NOTE: the task brief and parse-proxy.md call this "DeviceCheck", but the ALREADY-BUILT
// server (`supabase/functions/_shared/auth.ts`, `supabase/README.md` "Free: App Attest") is more
// precise and implements **App Attest** (`DCAppAttestService`), not raw DeviceCheck
// (`DCDevice.generateToken`) — this file follows the server, which is the actual thing on the
// other end of the wire. Rationale (from the server's own doc comment, restated here so this
// file's choice isn't a mystery in isolation): a raw `DCDevice` token is a bearer credential Apple
// validates but carries NO stable per-device identifier — two tokens from the same physical
// device are unlinkable, which makes "N free parses per device per day" impossible to enforce
// with DeviceCheck alone. App Attest's `keyId` (from a one-time `generateKey()`) *is* stable per
// device+app-install, so `SHA-256(keyId)` is what the server uses as its quota counter key.
//
// Wire format this file MUST produce for `X-Device-Token` (verified against
// `_shared/auth.ts`'s `parseDeviceToken`): base64url, no padding, of the JSON object
//   { "keyId": "<base64 Data from generateKey>",
//     "assertion": "<base64 Data from generateAssertion>",
//     "clientDataHashB64": "<base64 SHA-256 digest the assertion was computed over>" }
//
// STATUS (matches the server's own documented status — see `_shared/auth.ts` module doc comment):
// the server currently fails closed with 503 `config_missing` for EVERY well-formed free-tier
// token, because the public-key registry a real assertion-signature check needs
// (`/attest/register` + a storage table) doesn't exist yet — that is explicitly out of scope here
// too (backlog, `backlog.md` 2026-07-16 "Supabase free-tier cloud parse chưa hoạt động"). This
// file's job is ONLY to produce a structurally-correct client token; `IntentRouter` already falls
// through to Heuristic on any Cloud non-200 (including this 503), so a stubbed server is a
// harmless, expected, already-handled condition — not a bug in this file.
//
// Every DeviceCheck/App Attest API call below is `// UNVERIFIED: DeviceCheck/App Attest API —
// confirm on macOS 26 SDK / real device` — this Windows machine has no `DeviceCheck` framework to
// compile against; shapes are a best-faith mirror of Apple's public `DCAppAttestService` surface.
import Foundation
import Security
#if canImport(DeviceCheck)
import DeviceCheck
#endif
import CryptoKit

// MARK: - DeviceAttestationProvider protocol

/// Produces the fully-encoded `X-Device-Token` header value. A concrete composite
/// `ParseCredentialProvider` (StoreKit/entitlement owner's work, NOT built in this file) calls
/// this when the user is on the free tier and wraps a non-nil result in
/// `ParseAuthHeader.freeDeviceToken(_:)`.
protocol DeviceAttestationProvider: Sendable {
    /// `nil` = App Attest unsupported (simulator, disabled Secure Enclave) or any step of key
    /// generation/attestation/assertion failed — the caller MUST treat `nil` as "no free-tier
    /// credential available right now" and let `CloudParser`/`IntentRouter` fall through to
    /// Heuristic. Never throws; every failure path is caught and folded into `nil` so a
    /// DeviceCheck hiccup can never crash a parse attempt.
    func deviceToken() async -> String?
}

// MARK: - AppAttestDeviceCheckProvider (T023)

/// Real implementation backed by `DCAppAttestService`. Persists only the (non-secret) `keyId` —
/// the actual signing key never leaves the Secure Enclave and is never touched by this code
/// directly, matching Apple's App Attest model.
final class AppAttestDeviceCheckProvider: DeviceAttestationProvider {
    /// Non-secret: this is a public key REFERENCE (the server hashes it into an opaque counter
    /// key), not signing material — UserDefaults is an appropriate store, same tier of data as
    /// `EnvironmentGroqCredentialProvider`'s config keys, not a Keychain-grade secret.
    private static let keyIdDefaultsKey = "volar.appAttest.keyId"
    private static let attestedDefaultsKey = "volar.appAttest.attested"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func deviceToken() async -> String? {
        #if canImport(DeviceCheck)
        // UNVERIFIED: DeviceCheck API — confirm `DCAppAttestService.shared.isSupported` exists
        // with this exact spelling on macOS 26 SDK. Simulator / no Secure Enclave -> false.
        guard DCAppAttestService.shared.isSupported else { return nil }

        do {
            let keyId = try await currentOrNewKeyId()

            // Freshness "nonce" the assertion is computed over. UNVERIFIED / DESIGN NOTE for the
            // reviewer: real App Attest usage typically binds `clientDataHash` to the specific
            // request being protected (e.g. a hash of the outgoing request body) so a captured
            // assertion can't be replayed against a different request. Binding it to the exact
            // `/parse` JSON body here would require this provider to be called AFTER the request
            // body is built (a `ParseCredentialProvider`/`CloudParser` wiring concern, not this
            // protocol's). Since the server's assertion-signature verification is not implemented
            // yet either (see module doc comment — every well-formed token 503s today regardless
            // of what's inside `clientDataHash`), this generates a per-call random nonce instead:
            // it is STILL cryptographically fresh per call (never reused, so it is not a static
            // replayable secret) but is NOT bound to the request payload. Flagged as a follow-up:
            // once the server's registration/verification ceremony lands, reconcile this with
            // whatever canonical "hash of the request" the server ends up expecting.
            guard let nonce = Self.randomBytes(count: 32) else { return nil }
            let clientDataHash = Data(SHA256.hash(data: nonce))

            let assertion: Data
            do {
                // UNVERIFIED: DeviceCheck API — confirm `generateAssertion(_:clientDataHash:)`'s
                // exact async/throws signature on macOS 26 SDK (real Apple surface takes
                // `keyId: String`, returns raw `Data`).
                assertion = try await DCAppAttestService.shared.generateAssertion(keyId, clientDataHash: clientDataHash)
            } catch let dcError as DCError where dcError.code == .invalidKey || dcError.code == .invalidInput {
                // A persisted `keyId` whose Secure Enclave key was lost (reinstall, OS-level
                // invalidation, etc.) makes `generateAssertion` fail with `.invalidKey` FOREVER —
                // nothing else ever clears the stored id, so every future call would silently
                // fail this same way. `.invalidKey`/`.invalidInput` specifically mean the keyId
                // itself is unusable (not a transient network/server issue), so clear BOTH the
                // stored keyId and the attested flag here: the NEXT call's `currentOrNewKeyId()`
                // then regenerates + re-attests from scratch. This call still returns `nil` (no
                // token this round) — never retried inline, per this protocol's "never throws,
                // nil means try again next time" contract.
                // UNVERIFIED: `DCError.code` / `DCError.Code.invalidKey` / `.invalidInput` exact
                // spelling — confirm against the real DeviceCheck framework on macOS 26 SDK.
                defaults.removeObject(forKey: Self.keyIdDefaultsKey)
                defaults.removeObject(forKey: Self.attestedDefaultsKey)
                return nil
            }

            // `keyId` is already the base64 `String` `generateKey()` returns (see
            // `currentOrNewKeyId` doc comment) — sent as-is, not re-encoded.
            let wire = DeviceTokenWire(
                keyId: keyId,
                assertion: assertion.base64EncodedString(),
                clientDataHashB64: clientDataHash.base64EncodedString()
            )
            guard let json = try? JSONEncoder().encode(wire) else { return nil }
            return Self.base64URLNoPadding(json)
        } catch {
            // Any other failure (key generation, keychain/UserDefaults I/O, or the attestation
            // path's rethrown `.invalidKey`/`.invalidInput` from `currentOrNewKeyId` below, which
            // has already cleared the stored keyId itself) -> graceful nil, never a crash, never a
            // partially-built token sent to the network.
            return nil
        }
        #else
        return nil
        #endif
    }

    #if canImport(DeviceCheck)
    /// Returns the persisted `keyId` if one exists, else performs the one-time
    /// `generateKey()` + best-effort `attestKey()` ceremony and persists the new `keyId`.
    ///
    /// UNVERIFIED / API SHAPE NOTE: the real `DCAppAttestService.generateKey()` returns a
    /// `String` (an already-base64-encoded key identifier), not `Data` — `attestKey`/
    /// `generateAssertion` likewise take `keyId: String`. This is why `keyId` is stored and sent
    /// as a plain `String` throughout this file rather than round-tripped through `Data`; the
    /// server's `auth.ts` comment phrase "base64 Data from generateKey" describes exactly this —
    /// the string IS already base64.
    ///
    /// `attestKey()` failing is NOT treated as fatal here: today there is no `/attest/register`
    /// endpoint to hand the attestation object to anyway (see module doc comment), so a
    /// locally-generated-but-not-yet-attested key still produces a structurally valid token; the
    /// server currently 503s regardless of attestation state. Once the registration ceremony
    /// exists, this is the spot that would also POST the attestation object to it.
    private func currentOrNewKeyId() async throws -> String {
        if let stored = defaults.string(forKey: Self.keyIdDefaultsKey), !stored.isEmpty {
            return stored
        }
        // UNVERIFIED: DeviceCheck API — confirm `generateKey()`'s exact async/throws signature.
        let keyId = try await DCAppAttestService.shared.generateKey()
        defaults.set(keyId, forKey: Self.keyIdDefaultsKey)

        // Best-effort one-time attestation (see doc comment above for why failure isn't fatal).
        // The flag must only be set on an actual success: `try?` alone would swallow the
        // throw and still mark this key as attested, so a real failure (network blip, Apple
        // service hiccup) would never be retried on a later call.
        if !defaults.bool(forKey: Self.attestedDefaultsKey) {
            if let challenge = Self.randomBytes(count: 32) {
                let challengeHash = Data(SHA256.hash(data: challenge))
                do {
                    // UNVERIFIED: DeviceCheck API — `attestKey(_:clientDataHash:)` signature.
                    _ = try await DCAppAttestService.shared.attestKey(keyId, clientDataHash: challengeHash)
                    defaults.set(true, forKey: Self.attestedDefaultsKey)
                } catch {
                    // Leave the flag unset so a future call retries attestation.
                }
            }
        }
        return keyId
    }
    #endif

    private struct DeviceTokenWire: Encodable {
        var keyId: String
        var assertion: String
        var clientDataHashB64: String
    }

    /// Cryptographically random bytes via `SecRandomCopyBytes` — `nil` on any failure (never a
    /// force-unwrap: `baseAddress` can theoretically be nil, and `SecRandomCopyBytes` can
    /// theoretically fail; both degrade to "no token this call" rather than crashing).
    private static func randomBytes(count: Int) -> Data? {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { ptr -> OSStatus in
            guard let base = ptr.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        return status == errSecSuccess ? bytes : nil
    }

    /// base64url, no padding — matches `_shared/auth.ts`'s `parseDeviceToken` decode
    /// (`.replace(/-/g, "+").replace(/_/g, "/")` before `atob`) and `supabase/README.md`'s curl
    /// example encoding.
    private static func base64URLNoPadding(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
