// Services/Adapters/SettingsThenEnvironmentReader.cs — the ONE reader
// specs/003-windows-port/wave3c-services.md's C1 section asks for: `key => settings.GetString(key)
// ?? Environment.GetEnvironmentVariable(key)`, exactly the composite
// `Volar.Speech.Groq.GroqCredentialProvider.EnvironmentGroqCredentialProvider`'s own doc comment
// describes as "Wave 3-C wires a composite reader that checks a Volar.Domain.ISettingsStore first
// ... and falls back to Environment.GetEnvironmentVariable".
//
// SINGLE-INSTANCE CONTRACT (this file's whole reason for existing): C5's composition root must
// construct exactly ONE instance of this reader and pass its <see cref="Read"/> method (or an
// equivalently bound delegate) as the `environmentReader` argument to BOTH
// `EnvironmentGroqCredentialProvider` instances it builds for `GroqTranscriptionClient` and
// `GroqEngine` (see `GroqEngine.IsConfigured`'s remarks — the two credential providers those two
// types hold are independently constructed and can silently disagree if built from different
// readers/settings stores). This type itself never assumes anything about that wiring; it is
// deliberately provider-agnostic — nothing here is Groq-specific — so any FUTURE composite
// settings-then-environment credential could reuse the same instance.
//
// SECURITY: never logs anything. `Read` returns whatever value it finds (which, for the keys this
// reader is used for, are the Groq bearer token / base URL) directly to the caller and touches no
// logging/telemetry path — a caller that logs the RESULT of `Read` would be the one introducing a
// leak, not this file, and no caller in this codebase does that today.
using Volar.Domain;

namespace Volar.App.Services.Adapters;

public sealed class SettingsThenEnvironmentReader
{
    private readonly ISettingsStore _settings;
    private readonly Func<string, string?> _getEnvironmentVariable;

    /// <param name="settings">Checked FIRST — matches the frozen shape's declared precedence
    /// (settings, then environment), so a value the user set in Settings always wins over a
    /// same-named environment variable left over from a dev shell.</param>
    /// <param name="getEnvironmentVariable">Defaults to <see cref="Environment.GetEnvironmentVariable(string)"/>;
    /// overridable so tests never need to mutate real process-wide environment state (mirrors
    /// <c>EnvironmentGroqCredentialProvider</c>'s own constructor parameter for the identical
    /// reason).</param>
    public SettingsThenEnvironmentReader(ISettingsStore settings, Func<string, string?>? getEnvironmentVariable = null)
    {
        _settings = settings ?? throw new ArgumentNullException(nameof(settings));
        _getEnvironmentVariable = getEnvironmentVariable ?? Environment.GetEnvironmentVariable;
    }

    /// <summary>The frozen shape: <c>settings.GetString(key) ?? Environment.GetEnvironmentVariable(key)</c>.
    /// An empty string in settings is treated as "present" (returned as-is, not treated as absent)
    /// — identical to <see cref="ISettingsStore.GetString"/>'s own "null only when the key is truly
    /// absent" contract; callers that want to treat blank as unconfigured (as every current caller
    /// of this reader's target types already does via `string.IsNullOrEmpty` checks) do that
    /// downstream, not here.</summary>
    public string? Read(string key) => _settings.GetString(key) ?? _getEnvironmentVariable(key);

    /// <summary>Convenience for call sites that want a bound <c>Func&lt;string, string?&gt;</c>
    /// (e.g. <c>EnvironmentGroqCredentialProvider</c>'s constructor parameter) without spelling out
    /// a method-group conversion at every call site.</summary>
    public Func<string, string?> AsFunc() => Read;
}
