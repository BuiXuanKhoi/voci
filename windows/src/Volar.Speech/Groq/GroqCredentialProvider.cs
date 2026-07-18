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
}

/// <summary>
/// Dev-only default provider. Reads the base URL + bearer token from environment variables and
/// NEVER hardcodes a key (SECURITY: do not add a fallback literal key here — see the W1-D brief's
/// "giữ bí mật" requirement). Production should replace this with a proxy-backed provider that
/// returns the Volar proxy URL + a per-user token instead of a raw Groq key.
///
/// - Base URL: <c>GROQ_BASE_URL</c> env var; falls back to Groq direct
///   (<c>https://api.groq.com/openai/v1</c>) so a developer can smoke-test without a proxy.
/// - Token: <c>GROQ_PROXY_TOKEN</c> or <c>GROQ_API_KEY</c> env var. Absent -&gt; throws
///   <see cref="GroqTranscriptionErrorKind.MissingCredentials"/>.
///
/// The environment reader is injected (defaults to <see cref="Environment.GetEnvironmentVariable(string)"/>)
/// so unit tests can supply fake values without mutating real process-wide environment state.
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
        if (!string.IsNullOrEmpty(configured) && Uri.TryCreate(configured, UriKind.Absolute, out var uri))
        {
            return Task.FromResult(uri);
        }
        return Task.FromResult(GroqDirectBaseUrl);
    }

    public Task<string?> GetAuthorizationAsync(CancellationToken cancellationToken = default)
    {
        var token = _getEnv("GROQ_PROXY_TOKEN");
        if (string.IsNullOrEmpty(token))
        {
            token = _getEnv("GROQ_API_KEY");
        }
        if (string.IsNullOrEmpty(token))
        {
            throw GroqTranscriptionException.MissingCredentials();
        }
        return Task.FromResult<string?>($"Bearer {token}");
    }
}
