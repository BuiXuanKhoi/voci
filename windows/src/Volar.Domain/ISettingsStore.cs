// ISettingsStore.cs — plain key/value settings seam, new in Wave 3-B (macOS commit f88d5e5's
// Local<->Cloud parse/speech switch). macOS reads/writes this data straight through
// `UserDefaults.standard` from wherever it's needed (`ConfigParseCredentialProvider`,
// `DefaultCloudParseGate`, `EnvironmentGroqCredentialProvider`, `AppState`) — there is no Swift
// protocol for it because `UserDefaults` IS the ambient, globally-reachable store. Windows has no
// equivalent ambient singleton that every project can safely reach into (and several of this
// port's projects are deliberately NOT allowed to reference `Environment`/AppData directly, or to
// reference each other beyond the fixed layering in `specs/003-windows-port/wave3b-parity.md`), so
// this interface exists purely to give those consumers an injectable seam instead of a global.
//
// Lives in Volar.Domain (not Volar.Core) per this wave's file ownership — Volar.Parsing already
// references Volar.Domain, so `ConfigParseCredentialProvider`/`DefaultCloudParseGate` can depend on
// this abstraction without a new project reference. The REAL, disk-backed implementation
// (`Volar.Data.JsonFileSettingsStore`) intentionally does NOT implement this interface directly —
// see that file's header comment for why (Volar.Data -> Volar.Domain is not an allowed reference
// this wave) and the handoff note for what Wave 3-C must do to bridge the two.
namespace Volar.Domain;

/// <summary>
/// A minimal, synchronous key/value store for app settings — string and bool values only, which is
/// all this feature needs (proxy URL, proxy token, one-time consent flag, engine-choice strings).
/// Mirrors the two accessor shapes `UserDefaults` exposes for these types:
/// <c>string?(forKey:)</c> (nil when absent, never a default substitution) and
/// <c>bool(forKey:)</c> (defaults to a caller-supplied value when absent, matching
/// <c>UserDefaults.bool(forKey:)</c>'s own "false when absent" convention generalized to any
/// default).
/// </summary>
public interface ISettingsStore
{
    /// <summary>The stored string, or <see langword="null"/> if the key is absent or was last
    /// stored as a non-string value.</summary>
    string? GetString(string key);

    /// <summary>Stores <paramref name="value"/> under <paramref name="key"/>. Passing
    /// <see langword="null"/> REMOVES the key (mirrors <c>UserDefaults.set(nil, forKey:)</c>),
    /// rather than storing a literal null.</summary>
    void SetString(string key, string? value);

    /// <summary>The stored bool, or <paramref name="defaultValue"/> if the key is absent or was
    /// last stored as a non-bool value.</summary>
    bool GetBool(string key, bool defaultValue);

    /// <summary>Stores <paramref name="value"/> under <paramref name="key"/>.</summary>
    void SetBool(string key, bool value);
}

/// <summary>
/// Volatile, process-lifetime-only <see cref="ISettingsStore"/> — the safe default for unit tests
/// and for any composition root that hasn't wired up <c>Volar.Data.JsonFileSettingsStore</c> yet.
/// Never touches disk; guarded by a lock so it is safe to share across threads (settings reads/
/// writes are rare and cheap, so a single lock is not a contention concern).
/// </summary>
public sealed class InMemorySettingsStore : ISettingsStore
{
    private readonly object _gate = new();
    private readonly Dictionary<string, object?> _values = new();

    public string? GetString(string key)
    {
        lock (_gate)
        {
            return _values.TryGetValue(key, out var value) && value is string s ? s : null;
        }
    }

    public void SetString(string key, string? value)
    {
        lock (_gate)
        {
            if (value is null)
            {
                _values.Remove(key);
            }
            else
            {
                _values[key] = value;
            }
        }
    }

    public bool GetBool(string key, bool defaultValue)
    {
        lock (_gate)
        {
            return _values.TryGetValue(key, out var value) && value is bool b ? b : defaultValue;
        }
    }

    public void SetBool(string key, bool value)
    {
        lock (_gate)
        {
            _values[key] = value;
        }
    }
}
