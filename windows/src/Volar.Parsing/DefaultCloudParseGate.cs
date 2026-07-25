// DefaultCloudParseGate.cs — port of the `DefaultCloudParseGate` at the bottom of
// Volar/Sources/App/AppState.swift: the real ICloudParseGate wiring the one-time consent decision
// (and a best-effort reachability check) into IntentRouter's Cloud tier.
//
// isOptedIn(): reads the exact key AppState.resolveCloudConsent(allow:)/setParseEngine(_:) write
// (AppState.cloudParseConsentKey == "volar.cloudParseConsent") — false (never opted in, or
// declined, or key absent) is the safe default, matching "decline => never cloud."
//
// isOnline(): Swift uses an NWPathMonitor background subscription (defaults `true` until its
// first callback lands). Windows has no equivalent lightweight push-based reachability API in the
// BCL without pulling in a new package, so this ports the SAME semantics — "true when
// unknown/unable to determine, this is an optimization not a security gate" (the protocol's own
// doc comment sanctions exactly this) — via a synchronous, on-demand
// NetworkInterface.GetIsNetworkAvailable() check instead of a persistent monitor. Behaviour drift
// noted in this wave's self-review: Swift's answer can lag a real connectivity change by however
// long NWPathMonitor takes to fire; this port's answer is always current at the moment it's asked,
// which is strictly more accurate, not less — the only way this could surprise a caller is a
// (harmless) extra Cloud attempt during the exact instant a connection drops, which CloudParser's
// own transport-failure -> Unavailable fallback already handles silently.
using System.Net.NetworkInformation;
using Volar.Domain;

namespace Volar.Parsing;

public sealed class DefaultCloudParseGate : ICloudParseGate
{
    private readonly ISettingsStore _settings;
    private readonly Func<bool> _isNetworkAvailable;

    /// <param name="settings">Backing store for the one-time consent bit.</param>
    /// <param name="isNetworkAvailable">Injected for testability; defaults to
    /// <see cref="NetworkInterface.GetIsNetworkAvailable"/>. Any exception from this delegate is
    /// treated as "unknown" -> <see langword="true"/>, per the protocol's own contract.</param>
    public DefaultCloudParseGate(ISettingsStore settings, Func<bool>? isNetworkAvailable = null)
    {
        _settings = settings ?? throw new ArgumentNullException(nameof(settings));
        _isNetworkAvailable = isNetworkAvailable ?? DefaultIsNetworkAvailable;
    }

    public Task<bool> IsOptedInAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult(_settings.GetBool(ParseEnginePreferenceStore.CloudParseConsentKey, false));

    public Task<bool> IsOnlineAsync(CancellationToken cancellationToken = default)
    {
        bool online;
        try
        {
            online = _isNetworkAvailable();
        }
        catch
        {
            online = true; // unknown/unable to determine -> optimistic true, not a security gate.
        }
        return Task.FromResult(online);
    }

    private static bool DefaultIsNetworkAvailable()
    {
        try
        {
            return NetworkInterface.GetIsNetworkAvailable();
        }
        catch
        {
            return true;
        }
    }
}
