// ConfigParseCredentialProvider.cs — port of Sources/Parsing/ConfigParseCredentialProvider.swift.
//
// Wires the Cloud parse tier (CloudParser/IntentRouter) so the Local<->Cloud Settings switch
// (macOS commit f88d5e5) is functional NOW, before the real StoreKit-equivalent paid-entitlement +
// device-attestation composite credential provider exists. "Code first, key later": reads an
// optional proxy base URL + bearer token from an injected ISettingsStore; while either is missing
// it returns no usable credential, so CloudParser reports Unavailable and IntentRouter falls back
// to on-device parsing — never sending an unauthenticated request. Once both keys are set (e.g.
// by a future Settings field, or Wave 3-C seeding them for local dev) the Cloud tier activates.
using Volar.Domain;

namespace Volar.Parsing;

/// <summary>Thrown by <see cref="ConfigParseCredentialProvider.GetBaseUrlAsync"/> when no valid
/// base URL is configured. Port of Swift's <c>ParseCredentialError.notConfigured</c>. Callers
/// (<see cref="CloudParser"/>) catch this and treat it identically to any other endpoint-resolution
/// failure — it must never propagate past <see cref="CloudParser"/> as a user-visible error.</summary>
public sealed class ParseCredentialNotConfiguredException : Exception
{
    public ParseCredentialNotConfiguredException() : base("Cloud parse proxy is not configured.") { }
}

public sealed class ConfigParseCredentialProvider : IParseCredentialProvider
{
    /// <summary>Settings key for the Supabase parse-proxy base URL, e.g.
    /// <c>https://&lt;ref&gt;.supabase.co</c>. Identical string to macOS's UserDefaults key.</summary>
    public const string BaseUrlSettingsKey = "volar.parseProxyBaseURL";

    /// <summary>Settings key for the bearer token sent as <c>Authorization: Bearer &lt;token&gt;</c>.
    /// Placeholder for the real paid-entitlement JWS — sent as <see cref="ParseAuthHeader.PaidJws"/>
    /// purely so the wire shape is Bearer auth; a future composite credential provider replaces this
    /// entirely. Identical string to macOS's UserDefaults key.</summary>
    public const string TokenSettingsKey = "volar.parseProxyToken";

    private readonly ISettingsStore _settings;

    public ConfigParseCredentialProvider(ISettingsStore settings)
    {
        _settings = settings ?? throw new ArgumentNullException(nameof(settings));
    }

    /// <summary>
    /// <see langword="true"/> only when BOTH a non-empty base URL (that parses as an absolute
    /// <see cref="Uri"/>) AND a non-empty token are configured — drives a future Settings "Not
    /// configured" hint without duplicating the key-reading logic. Port of Swift's
    /// <c>ConfigParseCredentialProvider.isConfigured</c> static property, as an instance member
    /// instead (this provider is constructed with an injected <see cref="ISettingsStore"/> rather
    /// than reaching into a global `UserDefaults.standard`, so there is no ambient static to hang
    /// this off of — see this wave's self-review "behaviour drift" note).
    /// </summary>
    public bool IsConfigured
    {
        get
        {
            var baseUrl = _settings.GetString(BaseUrlSettingsKey);
            if (string.IsNullOrEmpty(baseUrl) || !Uri.TryCreate(baseUrl, UriKind.Absolute, out _))
            {
                return false;
            }
            var token = _settings.GetString(TokenSettingsKey);
            return !string.IsNullOrEmpty(token);
        }
    }

    public Task<Uri> GetBaseUrlAsync(CancellationToken cancellationToken = default)
    {
        var raw = _settings.GetString(BaseUrlSettingsKey);
        if (string.IsNullOrEmpty(raw) || !Uri.TryCreate(raw, UriKind.Absolute, out var uri))
        {
            throw new ParseCredentialNotConfiguredException();
        }
        return Task.FromResult(uri);
    }

    public Task<ParseAuthHeader?> GetAuthHeaderAsync(CancellationToken cancellationToken = default)
    {
        var token = _settings.GetString(TokenSettingsKey);
        if (string.IsNullOrEmpty(token))
        {
            // No credential available right now -> CloudParser must treat this as "Cloud
            // unavailable" and NEVER send an unauthenticated request (see IParseCredentialProvider's
            // own doc comment in CloudParser.cs — this is the ONLY signal it uses for that state).
            return Task.FromResult<ParseAuthHeader?>(null);
        }
        return Task.FromResult<ParseAuthHeader?>(new ParseAuthHeader.PaidJws(token));
    }
}
