// Groq/GroqCredentialProvider.cs — ported from Sources/Speech/GroqTranscriptionClient.swift
namespace Volar.Speech.Groq;

/// <summary>Supplies the transcription endpoint + authorization. Injected so the real Groq key
/// NEVER lives in the app binary: in production this should return the Volar **proxy** base URL +
/// a short-lived app/user token (the proxy holds the Groq key and gates by paid tier); for local
/// dev it can point straight at <c>https://api.groq.com/openai/v1</c> with a developer key. The
/// client (<see cref="GroqTranscriptionClient"/>) is agnostic to which.</summary>
public interface IGroqCredentialProvider
{
    /// <summary>Base URL exposing an OpenAI-compatible API. The client appends
    /// <c>audio/transcriptions</c>.</summary>
    Task<Uri> GetBaseUrlAsync(CancellationToken cancellationToken = default);

    /// <summary>Value for the <c>Authorization</c> header (e.g. <c>"Bearer …"</c>), or
    /// <c>null</c> if none is needed. Throws <see cref="GroqTranscriptionException"/>
    /// (<see cref="GroqTranscriptionErrorKind.MissingCredentials"/>) when no credential is
    /// available.</summary>
    Task<string?> GetAuthorizationAsync(CancellationToken cancellationToken = default);

    /// <summary>
    /// <see langword="true"/> when a bearer token is configured — lets a caller (e.g. a future
    /// speech-engine-selection policy, ported from Swift's <c>AppState.selectedEngine</c>) fall
    /// back to on-device transcription BEFORE recording, instead of hard-erroring only at upload
    /// time. New in Wave 3-B (A3: Local&lt;-&gt;Cloud switch, macOS commit f88d5e5 — Swift's
    /// <c>GroqEngine.isConfigured</c> / <c>EnvironmentGroqCredentialProvider.isConfigured</c>).
    /// Declared as an INSTANCE member (not <see langword="static"/>, unlike Swift's
    /// <c>static var</c>) so a caller never needs a global/ambient credential source — it always
    /// asks the exact provider instance it was given, matching this port's DI-first convention and
    /// this project's "reference-free" rule (see <see cref="EnvironmentGroqCredentialProvider"/>'s
    /// header comment: settings reach this type ONLY through the injected environment reader, so
    /// this member must be implementable without a <c>Volar.Domain</c>/<c>Volar.Data</c> reference).
    /// Implementations MUST read the exact same sources <see cref="GetAuthorizationAsync"/> reads,
    /// so the two can never disagree (mirrors Swift's own doc comment on this point verbatim).
    /// </summary>
    bool IsConfigured { get; }
}

/// <summary>
/// Dev-only default provider. Reads the base URL + bearer token from environment variables and
/// NEVER hardcodes a key (SECURITY: do not add a fallback literal key here — see the W1-D brief's
/// "giữ bí mật" requirement). Production should replace this with a proxy-backed provider that
/// returns the Volar proxy URL + a per-user token instead of a raw Groq key.
///
/// - Base URL: <c>GROQ_BASE_URL</c> env var, then the <c>volar.groqBaseURL</c> settings key (read
///   through the SAME injected reader — see below); falls back to Groq direct
///   (<c>https://api.groq.com/openai/v1</c>) so a developer can smoke-test without a proxy. Ports
///   Swift's <c>EnvironmentGroqCredentialProvider.baseURL()</c> fallback chain exactly
///   (<c>ProcessInfo.environment["GROQ_BASE_URL"] ?? UserDefaults.standard.string(forKey:
///   "volar.groqBaseURL")</c>).
/// - Token: <c>GROQ_PROXY_TOKEN</c>, then <c>GROQ_API_KEY</c>, then the <c>volar.groqToken</c>
///   settings key (same injected reader). Absent -&gt; throws
///   <see cref="GroqTranscriptionErrorKind.MissingCredentials"/>. Ports Swift's
///   <c>env["GROQ_PROXY_TOKEN"] ?? env["GROQ_API_KEY"] ?? UserDefaults.standard.string(forKey:
///   "volar.groqToken")</c> exactly.
///
/// The reader is injected as a single <c>Func&lt;string, string?&gt;</c> (defaults to
/// <see cref="Environment.GetEnvironmentVariable(string)"/>) so unit tests can supply fake values
/// without mutating real process-wide environment state, AND so this project stays
/// project-reference-free: Wave 3-C wires a composite reader that checks a
/// <c>Volar.Domain.ISettingsStore</c> first (for the <c>volar.groq*</c> keys, which only a settings
/// store would ever have) and falls back to <see cref="Environment.GetEnvironmentVariable(string)"/>
/// (for the <c>GROQ_*</c> keys, which only the environment would ever have) — a single function of
/// shape <c>key =&gt; settings.GetString(key) ?? Environment.GetEnvironmentVariable(key)</c> is
/// sufficient; this type never needs to know which source actually answered.
/// </summary>
public sealed class EnvironmentGroqCredentialProvider : IGroqCredentialProvider
{
    public static readonly Uri GroqDirectBaseUrl = new("https://api.groq.com/openai/v1");

    private readonly Func<string, string?> _getEnv;

    public EnvironmentGroqCredentialProvider(Func<string, string?>? environmentReader = null)
    {
        _getEnv = environmentReader ?? Environment.GetEnvironmentVariable;
    }

    public Task<Uri> GetBaseUrlAsync(CancellationToken cancellationToken = default)
    {
        var configured = _getEnv("GROQ_BASE_URL");
        if (string.IsNullOrEmpty(configured))
        {
            configured = _getEnv("volar.groqBaseURL");
        }
        if (!string.IsNullOrEmpty(configured) && Uri.TryCreate(configured, UriKind.Absolute, out var uri))
        {
            return Task.FromResult(uri);
        }
        return Task.FromResult(GroqDirectBaseUrl);
    }

    public Task<string?> GetAuthorizationAsync(CancellationToken cancellationToken = default)
    {
        var token = ResolveToken();
        if (string.IsNullOrEmpty(token))
        {
            throw GroqTranscriptionException.MissingCredentials();
        }
        return Task.FromResult<string?>($"Bearer {token}");
    }

    /// <summary>
    /// Reads the SAME sources <see cref="GetAuthorizationAsync"/> reads, in the same order — so
    /// <see cref="IsConfigured"/> and <see cref="GetAuthorizationAsync"/> can never disagree (ports
    /// Swift's <c>EnvironmentGroqCredentialProvider.isConfigured</c> doc comment's own stated
    /// invariant verbatim).
    /// </summary>
    private string? ResolveToken()
    {
        var token = _getEnv("GROQ_PROXY_TOKEN");
        if (string.IsNullOrEmpty(token))
        {
            token = _getEnv("GROQ_API_KEY");
        }
        if (string.IsNullOrEmpty(token))
        {
            token = _getEnv("volar.groqToken");
        }
        return token;
    }

    public bool IsConfigured => !string.IsNullOrEmpty(ResolveToken());
}

// MARK: - AccountGroqCredentialProvider (2026-07-26 account-auth contract)

/// <summary>
/// Production Groq credential provider under the account-auth contract
/// (specs/002-workflow-command-center/contracts/account-auth.md): cloud speech is Pro-only, gated
/// on a signed-in account whose cached tier/quota say "pro" with remaining daily speech quota.
/// Replaces <see cref="EnvironmentGroqCredentialProvider"/> in production wiring
/// (<c>Volar.App.Services.CompositionRoot</c>) — that type is left in place unchanged (still used
/// by anything that constructs it directly, e.g. existing tests/dev-token flows), this is an
/// ADDITIONAL implementation, not a replacement of it.
/// </summary>
/// <remarks>
/// LAYERING: <c>Volar.Speech.csproj</c> carries ZERO project references (this project's own
/// long-standing "project-reference-free" design goal — see
/// <see cref="EnvironmentGroqCredentialProvider"/>'s own header comment above), so this type cannot
/// hold a direct reference to <c>Volar.App.Services.Account.IAccountService</c> (adding a reference
/// is a csproj change outside this task's scope regardless). It takes two plain delegates instead —
/// <c>Volar.App.Services.CompositionRoot</c> is the one place that can see both sides and supplies
/// them as simple lambdas/method-group conversions over the real
/// <c>Volar.App.Services.Account.AccountService</c> instance.
/// </remarks>
public sealed class AccountGroqCredentialProvider : IGroqCredentialProvider
{
    /// <summary>Supabase edge-function base for the Groq proxy (contract §3:
    /// <c>POST /functions/v1/groq/audio/transcriptions</c>). TRAILING SLASH is required — this
    /// class's own <see cref="GetBaseUrlAsync"/> return value is combined via
    /// <c>new Uri(baseUrl, "audio/transcriptions")</c> inside <see cref="GroqTranscriptionClient"/>,
    /// and without the trailing slash that combine would REPLACE the last path segment
    /// ("/groq") instead of appending under it.</summary>
    public static readonly Uri ProxyBaseUrl = new("https://nuzrpipwacravfgsiacv.supabase.co/functions/v1/groq/");

    private readonly Func<CancellationToken, Task<string?>> _getValidAccessToken;
    private readonly Func<bool> _isConfigured;
    private readonly Uri _baseUrl;

    /// <param name="getValidAccessToken">Typically
    /// <c>Volar.App.Services.Account.AccountService.GetValidAccessTokenAsync</c> as a method-group
    /// conversion.</param>
    /// <param name="isConfigured">
    /// Fail-closed pre-record gate, checked by <c>SpeechEngineService.SelectedEngine</c> BEFORE a
    /// recording even starts: must return <see langword="true"/> ONLY when there is POSITIVE, cached
    /// evidence the signed-in account is Pro tier with remaining daily speech quota (e.g.
    /// <c>() =&gt; accountService.CachedStatus is { IsPro: true, SpeechUsedToday: var used,
    /// SpeechLimit: var limit } &amp;&amp; used &lt; limit</c>). Absent/stale/unknown status (never
    /// fetched yet, fetch failed, or free tier) must all resolve to <see langword="false"/> — this
    /// is what makes a free user's speech-engine selection degrade SILENTLY to Whisper on-device
    /// before a recording ever starts, rather than failing only at upload time with a 403. A genuine
    /// race (tier/quota changes mid-recording, after this gate already passed) is the one scenario
    /// this cannot prevent from this file alone — see this feature's final report, "failure modes."
    /// </param>
    public AccountGroqCredentialProvider(
        Func<CancellationToken, Task<string?>> getValidAccessToken,
        Func<bool> isConfigured,
        Uri? baseUrl = null)
    {
        _getValidAccessToken = getValidAccessToken ?? throw new ArgumentNullException(nameof(getValidAccessToken));
        _isConfigured = isConfigured ?? throw new ArgumentNullException(nameof(isConfigured));
        _baseUrl = baseUrl ?? ProxyBaseUrl;
    }

    public Task<Uri> GetBaseUrlAsync(CancellationToken cancellationToken = default) => Task.FromResult(_baseUrl);

    public bool IsConfigured => _isConfigured();

    public async Task<string?> GetAuthorizationAsync(CancellationToken cancellationToken = default)
    {
        var token = await _getValidAccessToken(cancellationToken).ConfigureAwait(false);
        if (token is null)
        {
            // Mirrors EnvironmentGroqCredentialProvider's own contract: GetAuthorizationAsync throws
            // MissingCredentials when no credential is available. In practice SpeechEngineService
            // never reaches this call with Groq selected unless IsConfigured was already true
            // moments earlier (see IsConfigured's own remarks) — this only fires on a genuine race
            // (session expired/signed-out between the pre-record check and upload time).
            throw GroqTranscriptionException.MissingCredentials();
        }
        return $"Bearer {token}";
    }
}
