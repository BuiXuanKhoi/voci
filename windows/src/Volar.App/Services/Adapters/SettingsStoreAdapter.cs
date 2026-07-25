// Services/Adapters/SettingsStoreAdapter.cs — trivial ISettingsStore forwarding wrapper over
// Volar.Data.JsonFileSettingsStore, per that file's own header comment's explicit "Wave 3-C must
// do one of (a)/(b)" ask. This is option (b) ("write a trivial SettingsStoreAdapter : ISettingsStore
// in Volar.App that forwards every member to an injected JsonFileSettingsStore instance") — chosen
// over option (a) (adding a Volar.Data -> Volar.Domain project reference) because this agent's
// file-ownership rule for this wave does not include any .csproj, and this forwarding wrapper is a
// few lines that changes no behavior in JsonFileSettingsStore itself, exactly as that file's
// comment anticipates.
//
// Not itself one of this agent's seven named files, but squarely infrastructure/no-AppState-logic
// under this agent's owned folder (Services/Adapters/) — flagged explicitly in this agent's final
// report as an addition beyond the named list, with the reasoning above.
using Volar.Data;
using Volar.Domain;

namespace Volar.App.Services.Adapters;

public sealed class SettingsStoreAdapter : ISettingsStore
{
    private readonly JsonFileSettingsStore _inner;

    public SettingsStoreAdapter(JsonFileSettingsStore inner)
    {
        _inner = inner ?? throw new ArgumentNullException(nameof(inner));
    }

    public string? GetString(string key) => _inner.GetString(key);

    public void SetString(string key, string? value) => _inner.SetString(key, value);

    public bool GetBool(string key, bool defaultValue) => _inner.GetBool(key, defaultValue);

    public void SetBool(string key, bool value) => _inner.SetBool(key, value);
}
