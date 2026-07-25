// Sources/Parsing/ConfigParseCredentialProvider.swift — placeholder cloud-parse credentials.
//
// Wires the Cloud parse tier (`CloudParser`/`IntentRouter`) so the Local↔Cloud Settings switch is
// functional NOW, before the real StoreKit paid-JWS + DeviceCheck free-token composite (the
// intended concrete `ParseCredentialProvider`, Phase 8/T051) exists. "Code first, key later":
// reads an optional proxy base URL + bearer token from UserDefaults; while either is missing it
// returns no credential, so `CloudParser` reports `.unavailable` and `IntentRouter` falls back to
// on-device parsing — never sending an unauthenticated request. Once both keys are set (e.g. via
// `defaults write` on the Mac, or a future Settings field) the Cloud tier activates.
import Foundation

struct ConfigParseCredentialProvider: ParseCredentialProvider {
    /// UserDefaults key for the Supabase parse-proxy base URL, e.g. `https://<ref>.supabase.co`.
    static let baseURLKey = "volar.parseProxyBaseURL"
    /// UserDefaults key for the bearer token sent as `Authorization: Bearer <token>`. Placeholder
    /// for the real StoreKit JWS — sent as `.paidJWS` purely so the wire shape is Bearer auth; the
    /// Phase 8 composite replaces this with a proper entitlement/attestation-derived credential.
    static let tokenKey = "volar.parseProxyToken"

    /// True only when BOTH a non-empty base URL (that parses as a `URL`) and token are configured —
    /// drives the Settings "Not configured" hint without duplicating the key-reading logic.
    static var isConfigured: Bool {
        guard let base = UserDefaults.standard.string(forKey: baseURLKey), !base.isEmpty,
              URL(string: base) != nil,
              let token = UserDefaults.standard.string(forKey: tokenKey), !token.isEmpty else {
            return false
        }
        return true
    }

    func baseURL() async throws -> URL {
        guard let raw = UserDefaults.standard.string(forKey: Self.baseURLKey),
              let url = URL(string: raw) else {
            throw ParseCredentialError.notConfigured
        }
        return url
    }

    func authHeader() async -> ParseAuthHeader? {
        guard let token = UserDefaults.standard.string(forKey: Self.tokenKey), !token.isEmpty else {
            return nil
        }
        return .paidJWS(token)
    }
}

enum ParseCredentialError: Error { case notConfigured }
