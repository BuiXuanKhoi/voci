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
