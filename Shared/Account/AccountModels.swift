// Sources/Account/AccountModels.swift — wire types for Supabase Auth + entitlements/quota.
// specs/002-workflow-command-center/contracts/account-auth.md §2 (auth), §3 (edge functions), §6.
//
// Plain Codable/Sendable value types only — no networking, no Keychain, no StoreKit here (see
// `AccountService.swift`/`Entitlements.swift`/`KeychainStore.swift` for those). Kept in one file
// so every collaborator shares exactly one decode shape per wire response.
import Foundation

/// A Supabase Auth session — the exact shape every GoTrue endpoint this app calls returns
/// (`/auth/v1/token`, `/auth/v1/verify`), per contract §2: "Session trả về: {access_token,
/// refresh_token, expires_at (epoch giây), token_type, user:{id, email}}".
///
/// This is BOTH the wire-decode shape AND the Keychain-persisted shape (same `Codable`, JSON-
/// encoded as one blob) — see `KeychainStore.swift`'s doc comment for why one item is enough.
struct AccountSession: Codable, Sendable, Equatable {
    var accessToken: String
    var refreshToken: String
    /// Epoch SECONDS (contract: "expires_at (epoch giây)") — GoTrue sends a raw JSON number, not
    /// an ISO8601 string, so this decodes as `Double` rather than through a date strategy that
    /// would apply to every field in this struct. Use `expiresAtDate` below to work with `Date`.
    var expiresAt: Double
    var tokenType: String
    var user: AccountUser

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
        case tokenType = "token_type"
        case user
    }

    var expiresAtDate: Date { Date(timeIntervalSince1970: expiresAt) }
}

struct AccountUser: Codable, Sendable, Equatable {
    var id: String
    /// Contract §2: "Apple chỉ trả email lần đăng nhập ĐẦU TIÊN" — Apple's identity token only
    /// carries an email claim on first authorization, but Supabase persists it into `auth.users`
    /// server-side, so every session response (first login or not) is expected to still carry it
    /// here. Modeled optional anyway to be defensive against a GoTrue response that omits it
    /// (e.g. an email-less account edge case) rather than force-unwrapping.
    var email: String?
}

/// `GET /functions/v1/subscription/status` 200 body — contract §3.
struct SubscriptionStatus: Codable, Sendable, Equatable {
    var tier: AccountTier
    var expiresAt: String?
    var parseUsedToday: Int
    var parseLimit: Int
    var speechUsedToday: Int
    var speechLimit: Int
}

/// `POST /functions/v1/subscription/link` 200 body — contract §3.
struct SubscriptionLinkResponse: Codable, Sendable, Equatable {
    var tier: AccountTier
    var expiresAt: String?
    var productId: String?
}

enum AccountTier: String, Codable, Sendable, Equatable {
    case free, pro
}

/// Opaque server error body, contract §5: `{"error":"<code>"}` (+ `resetAt` on 429, unused by
/// this subsystem — quota 429s are `CloudParser`'s/`GroqTranscriptionClient`'s concern, not
/// account auth's).
struct AccountErrorBody: Codable, Sendable {
    var error: String
    var resetAt: String?
}

/// Every failure `AccountService`/`Entitlements` can produce — ONE enum (not split per file) so
/// `SettingsView` has a single error type to switch/display. Mirrors the error-enum convention of
/// `GroqTranscriptionError`/`ParseCredentialError` elsewhere in this codebase.
enum AccountError: Error, Sendable, Equatable {
    /// No session, or a refresh attempt failed — the "please sign in" state. IMPORTANT: this must
    /// NEVER reach `ConfigParseCredentialProvider`/`GroqTranscriptionClient`'s credential
    /// providers as a surfaced error — they treat "no valid token" as "return nil credential" and
    /// fall back on-device silently (contract §1: "Chưa login → ... Không hiện lỗi"). Only
    /// `SettingsView`'s explicit sign-in flow shows this to the user.
    case signedOut
    /// User dismissed/cancelled the Apple Sign-In sheet — not a real failure.
    case cancelled
    /// Non-2xx HTTP response. `code` is the decoded `{"error":"…"}` body when present (contract
    /// §5's opaque error codes), `nil` if the body didn't decode.
    case http(status: Int, code: String?)
    case decoding
    case network(String)
}

extension AccountError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .signedOut: return "Not signed in."
        case .cancelled: return "Sign-in was cancelled."
        case .http(let status, let code): return "Request failed (\(code ?? "http_\(status)"))."
        case .decoding: return "Couldn't read the server's response."
        case .network(let message): return "Network error: \(message)"
        }
    }
}
