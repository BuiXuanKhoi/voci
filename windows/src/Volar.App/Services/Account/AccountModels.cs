// Services/Account/AccountModels.cs — wire-adjacent DTOs and small value types for the account-auth
// feature (specs/002-workflow-command-center/contracts/account-auth.md, "CHỐT bởi anh Khôi
// 2026-07-26" — the SAME contract the macOS client and the Supabase edge functions implement in
// parallel; this file only mirrors it, never redesigns it).
//
// Layering note: every type here lives in Volar.App (not Volar.Domain) because it is consumed ONLY
// by Volar.App code (AccountService, AccountViewModel, SettingsViewModel, SettingsView.xaml.cs).
// The two lower-layer consumers that DO need a sliver of this — Volar.Parsing's
// ConfigParseCredentialProvider and Volar.Speech.Groq's AccountGroqCredentialProvider — cannot
// reference Volar.App at all (Volar.Parsing.csproj/Volar.Speech.csproj only reference
// Volar.Core/Volar.Domain or nothing; adding a reference is a csproj change outside this task's
// file-ownership scope). Those two are wired via plain `Func<...>` delegates instead (see their own
// files' doc comments) — the same "stay project-reference-free" pattern
// EnvironmentGroqCredentialProvider already established for Volar.Speech.
using System.Text.Json.Serialization;

namespace Volar.App.Services.Account;

/// <summary>Whether <see cref="AccountService"/> currently holds a usable (possibly expired-but-
/// refreshable) session. Mirrors the contract's "(chưa login)" vs account row — deliberately just
/// two states; tier (free/pro) is a SEPARATE axis carried by <see cref="SubscriptionStatusSnapshot"/>,
/// not folded into this enum, because tier can change (webhook/renewal) without ever signing out.</summary>
public enum AccountSessionState
{
    SignedOut,
    SignedIn,
}

/// <summary>The signed-in user's identity — just enough for the Settings UI to show "signed in as
/// ...". Never anything more (no PII beyond what GoTrue itself already returns).</summary>
public sealed record AccountUser(string Id, string? Email);

/// <summary>Persisted, DPAPI-encrypted session state (see <see cref="TokenStore"/>). Kept as a
/// record purely for value-equality in tests — the encrypted-at-rest guarantee comes from
/// <see cref="DpapiTokenStore"/>, not from anything about this type itself, so this type is free to
/// carry the access token in memory/JSON exactly like any other DTO.</summary>
public sealed record StoredSession(
    string AccessToken,
    string RefreshToken,
    DateTimeOffset ExpiresAt,
    string UserId,
    string? Email);

/// <summary>Cached snapshot of <c>GET /functions/v1/subscription/status</c> (contract §3) plus the
/// instant it was fetched, so callers (the Groq pre-record gate, the Settings quota line) can judge
/// staleness themselves rather than this type silently going stale in the background.</summary>
public sealed record SubscriptionStatusSnapshot(
    string Tier,
    DateTimeOffset? ExpiresAt,
    int ParseUsedToday,
    int ParseLimit,
    int SpeechUsedToday,
    int SpeechLimit,
    DateTimeOffset FetchedAt)
{
    public bool IsPro => Tier == "pro";
}

// MARK: - Outcome types for the auth-flow entry points (VM-facing, richer than a plain bool so the
// UI can show a useful inline message per the contract's opaque {"error":"<code>"} error shape).

public enum OtpSendOutcome
{
    Sent,
    InvalidEmail,
    NetworkError,
    ServerError,
}

public sealed record OtpSendResult(OtpSendOutcome Outcome, string? ErrorMessage = null)
{
    public static OtpSendResult Ok() => new(OtpSendOutcome.Sent);
}

public enum VerifyOtpOutcome
{
    SignedIn,
    InvalidCode,
    NetworkError,
    ServerError,
}

public sealed record VerifyOtpResult(VerifyOtpOutcome Outcome, string? ErrorMessage = null);

public enum DeleteAccountOutcome
{
    Deleted,
    NetworkError,
    ServerError,
    NotSignedIn,
}

public sealed record DeleteAccountResult(DeleteAccountOutcome Outcome, string? ErrorMessage = null);

// MARK: - Wire DTOs (System.Text.Json + [JsonPropertyName], same style CloudParser/
// GroqTranscriptionClient already use for their own response types).

/// <summary>Supabase GoTrue's user object, as embedded in a session response.</summary>
internal sealed class GoTrueUserWire
{
    [JsonPropertyName("id")]
    public string? Id { get; set; }

    [JsonPropertyName("email")]
    public string? Email { get; set; }
}

/// <summary>Supabase GoTrue's session response — contract §2: "Session trả về: {access_token,
/// refresh_token, expires_at (epoch giây), token_type, user:{id, email}}". Used for both the
/// verify-OTP response and the refresh-token response (identical shape).</summary>
internal sealed class GoTrueSessionWire
{
    [JsonPropertyName("access_token")]
    public string? AccessToken { get; set; }

    [JsonPropertyName("refresh_token")]
    public string? RefreshToken { get; set; }

    /// <summary>Epoch SECONDS per the contract ("expires_at (epoch giây)") — NOT milliseconds.</summary>
    [JsonPropertyName("expires_at")]
    public long? ExpiresAt { get; set; }

    [JsonPropertyName("user")]
    public GoTrueUserWire? User { get; set; }
}

/// <summary>Wire shape of <c>GET /functions/v1/subscription/status</c> (contract §3) —
/// genuinely camelCase on the wire, unlike GoTrue's own snake_case.</summary>
internal sealed class SubscriptionStatusWire
{
    [JsonPropertyName("tier")]
    public string? Tier { get; set; }

    [JsonPropertyName("expiresAt")]
    public string? ExpiresAt { get; set; }

    [JsonPropertyName("parseUsedToday")]
    public int ParseUsedToday { get; set; }

    [JsonPropertyName("parseLimit")]
    public int ParseLimit { get; set; }

    [JsonPropertyName("speechUsedToday")]
    public int SpeechUsedToday { get; set; }

    [JsonPropertyName("speechLimit")]
    public int SpeechLimit { get; set; }
}
