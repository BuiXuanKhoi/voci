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

/// `POST /functions/v1/subscription/redeem` 200 body — promo-code redemption (backlog: "1 free
/// month of Pro" codes the product owner hands out; one code shared by many people, each may
/// redeem it exactly once). Field names already match the wire JSON exactly (no `CodingKeys`
/// needed), same as `SubscriptionStatus`/`SubscriptionLinkResponse` right above.
///
/// `expiresAt` is a raw ISO8601 `String`, NOT `Date` — deliberately mirrors those two structs'
/// own `expiresAt: String?` rather than inventing a `Date`-typed field: every `JSONDecoder()` this
/// file's callers use is a plain `JSONDecoder()` with no `dateDecodingStrategy` set (see
/// `AccountSession.expiresAt`'s doc comment for the same underlying reason, there solved by
/// decoding as `Double` instead), so a `Date` field here would silently fail to decode against
/// the exact same decoder every other model in this file goes through. Any `Date` parsing for
/// display happens at the call site (`AppState.redeemPromoCode`), not here.
struct RedeemResult: Codable, Sendable, Equatable {
    var tier: AccountTier
    var expiresAt: String?
    var grantedDays: Int
    var source: String
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
    /// Non-2xx HTTP response. `code` is the decoded `{"error":"…"}` body when present (contract
    /// §5's opaque error codes), `nil` if the body didn't decode.
    case http(status: Int, code: String?)
    case decoding
    case network(String)
    /// `POST subscription/redeem` 404 (`code_invalid`) — the server DELIBERATELY collapses
    /// "unknown code", "expired code", and "deactivated code" into this one opaque outcome (a
    /// distinguishable error would let someone brute-forcing codes learn which guesses are
    /// "close"). Do NOT split this back into more specific wording client-side — that would leak
    /// exactly the distinction the server withholds on purpose.
    case promoCodeInvalid
    /// `POST subscription/redeem` 409 (`already_redeemed`) — THIS signed-in user already redeemed
    /// THIS code. A different user redeeming the same code, or this user redeeming a DIFFERENT
    /// code, doesn't hit this case.
    case promoCodeAlreadyRedeemed
    /// `POST subscription/redeem` 410 (`code_exhausted`) — the code hit its total-redemptions cap
    /// (a many-people-share-one-code promo running out), independent of whether THIS user
    /// personally redeemed it before.
    case promoCodeExhausted
    /// `POST subscription/redeem` 429 (`too_many_attempts`) — too many wrong tries TODAY (contract
    /// wording is per-day, not a fixed lockout window), so the message says "tomorrow" rather than
    /// implying a retry-after countdown this app doesn't have.
    case promoCodeTooManyAttempts
}

extension AccountError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .signedOut: return "Not signed in."
        case .http(let status, let code): return "Request failed (\(code ?? "http_\(status)"))."
        case .decoding: return "Couldn't read the server's response."
        case .network(let message): return "Network error: \(message)"
        case .promoCodeInvalid: return "That code isn't valid."
        case .promoCodeAlreadyRedeemed: return "You've already used this code."
        case .promoCodeExhausted: return "This code has been fully claimed."
        case .promoCodeTooManyAttempts: return "Too many attempts. Try again tomorrow."
        }
    }
}
