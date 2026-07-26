// ConfigParseCredentialProvider.cs — port of Sources/Parsing/ConfigParseCredentialProvider.swift.
//
// REWRITTEN 2026-07-26 for the account-auth contract
// (specs/002-workflow-command-center/contracts/account-auth.md, "CHỐT bởi anh Khôi 2026-07-26"):
// cloud parsing now requires a signed-in Supabase account, and the bearer is the account's OWN
// access token (refreshed transparently) rather than a hand-configured settings-store token. Signed
// out is STILL not an error — it is just on-device mode, exactly as before this rewrite; only the
// SOURCE of the credential changed.
//
// LAYERING: Volar.Parsing.csproj references only Volar.Core/Volar.Domain — it must never reference
// Volar.App (where the real account service lives; see Services/Account/AccountModels.cs's own
// header comment for the full explanation), and adding that reference is a csproj change outside
// this task's scope. So this class takes two plain delegates instead of an account-service
// interface — the SAME "stay project-reference-free, inject a Func instead of a project reference"
// pattern `Volar.Speech.Groq.EnvironmentGroqCredentialProvider` already established for the
// identical problem on the speech side. `Volar.App.Services.CompositionRoot` is the one place that
// CAN see both `Volar.App.Services.Account.AccountService` and this type, so it supplies the two
// delegates as simple method-group conversions of the real service's own members.

namespace Volar.Parsing;

/// <summary>Thrown by <see cref="ConfigParseCredentialProvider.GetBaseUrlAsync"/> when no valid
/// base URL is configured. Port of Swift's <c>ParseCredentialError.notConfigured</c>. Callers
/// (<see cref="CloudParser"/>) catch this and treat it identically to any other endpoint-resolution
/// failure — it must never propagate past <see cref="CloudParser"/> as a user-visible error.
/// Retained for parity with the Swift error surface even though this class's own
/// <see cref="ConfigParseCredentialProvider.GetBaseUrlAsync"/> no longer has an "unconfigured" state
/// (the base URL is now a fixed, baked-in Supabase project URL, not something a user configures) —
/// kept in case a future caller still wants to distinguish "endpoint resolution failed" from "no
/// credential."</summary>
public sealed class ParseCredentialNotConfiguredException : Exception
{
    public ParseCredentialNotConfiguredException() : base("Cloud parse proxy is not configured.") { }
}

public sealed class ConfigParseCredentialProvider : IParseCredentialProvider
{
    /// <summary>Contract §2: the Supabase project base URL; <see cref="CloudParser"/> appends
    /// <c>functions/v1/parse</c> onto this itself.</summary>
    public static readonly Uri DefaultBaseUrl = new("https://nuzrpipwacravfgsiacv.supabase.co");

    private readonly Func<CancellationToken, Task<string?>> _getValidAccessToken;
    private readonly Func<bool> _isSignedIn;
    private readonly Uri _baseUrl;

    /// <param name="getValidAccessToken">Typically
    /// <c>Volar.App.Services.Account.AccountService.GetValidAccessTokenAsync</c> as a method-group
    /// conversion — returns <see langword="null"/> whenever no usable token is available right now
    /// (signed out, or a refresh attempt failed/was rejected).</param>
    /// <param name="isSignedIn">Typically
    /// <c>() =&gt; accountService.State == AccountSessionState.SignedIn</c> — drives
    /// <see cref="IsConfigured"/> (a future Settings "not signed in" hint) without this class needing
    /// to know anything about the account service's own shape.</param>
    public ConfigParseCredentialProvider(
        Func<CancellationToken, Task<string?>> getValidAccessToken,
        Func<bool> isSignedIn,
        Uri? baseUrl = null)
    {
        _getValidAccessToken = getValidAccessToken ?? throw new ArgumentNullException(nameof(getValidAccessToken));
        _isSignedIn = isSignedIn ?? throw new ArgumentNullException(nameof(isSignedIn));
        _baseUrl = baseUrl ?? DefaultBaseUrl;
    }

    /// <summary>
    /// <see langword="true"/> only when the account is currently signed in — drives a future
    /// Settings "Not signed in" hint without duplicating the sign-in-state logic. Note this is
    /// deliberately NOT "signed in AND a valid token could be fetched right now" — a transient
    /// refresh failure while signed in should still read as "configured" in the UI (the NEXT parse
    /// attempt just falls back silently to on-device that one time, per
    /// <see cref="GetAuthHeaderAsync"/>'s own contract), not flip the Settings row to "not
    /// configured."
    /// </summary>
    public bool IsConfigured => _isSignedIn();

    public Task<Uri> GetBaseUrlAsync(CancellationToken cancellationToken = default) => Task.FromResult(_baseUrl);

    public async Task<ParseAuthHeader?> GetAuthHeaderAsync(CancellationToken cancellationToken = default)
    {
        var token = await _getValidAccessToken(cancellationToken).ConfigureAwait(false);
        if (token is null)
        {
            // Signed out, or a refresh attempt just failed/was rejected -> CloudParser must treat
            // this as "Cloud unavailable" and NEVER send an unauthenticated request (see
            // IParseCredentialProvider's own doc comment in CloudParser.cs — this is the ONLY signal
            // it uses for that state). Never a user-visible error, never a dialog, never breaks
            // capture — IntentRouter falls through to the heuristic on-device tier exactly as it
            // already does for "not configured."
            return null;
        }
        // The wire shape is Bearer auth either way (contract §3: "Mọi request cloud mang
        // Authorization: Bearer <supabase access_token>" regardless of tier) — PaidJws is reused
        // purely because it is the ParseAuthHeader case that maps onto an Authorization: Bearer
        // header; it does NOT imply the user is on the paid/pro tier (rate limiting by tier happens
        // server-side per contract §1/§4, keyed on user_id either way).
        return new ParseAuthHeader.PaidJws(token);
    }
}
