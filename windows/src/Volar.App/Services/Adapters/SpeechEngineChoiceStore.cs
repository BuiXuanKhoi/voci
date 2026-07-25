// Services/Adapters/SpeechEngineChoiceStore.cs — persists Volar.Speech.SpeechEngineChoice under
// "volar.speechEngine", shaped like Volar.Parsing.ParseEnginePreferenceStore (same static
// Get(ISettingsStore)/Set(ISettingsStore, value) shape, same "own the key constant, own the
// raw-value round trip" convention) — per specs/003-windows-port/wave3c-services.md's explicit ask.
//
// RAW VALUE PARITY NOTE: Swift's `AppState.swift` persists this key with its OWN enum's rawValue
// strings ("appleOnDevice"/"whisperKit"/"groq" — see appstate-inventory.md §0). Windows's
// SpeechEngineChoice (Volar.Speech/SpeechEngineChoice.cs) deliberately has only two cases
// (WhisperOnDevice/GroqCloud, per that file's own "PARITY NOTE" — no Windows analog for
// `.appleOnDevice`), and there is no cross-platform settings file to stay wire-compatible with
// (this is a fresh Windows install, no migration in scope — mirrors TaskRepository.cs's own
// "migration note"). So this file mints its OWN raw strings ("whisperOnDevice"/"groqCloud") rather
// than reusing Swift's, matching this port's naming rather than a platform it will never read a
// settings file from.
using Volar.Domain;
using Volar.Speech;

namespace Volar.App.Services.Adapters;

public static class SpeechEngineChoiceStore
{
    /// <summary>Same string Swift's <c>AppState.speechEngineKey</c> writes to
    /// (<c>"volar.speechEngine"</c>) — kept identical purely for naming-convention consistency
    /// across the port; there is no shared settings file for this key to actually round-trip
    /// through (see file header).</summary>
    public const string SpeechEngineKey = "volar.speechEngine";

    private const string WhisperOnDeviceRawValue = "whisperOnDevice";
    private const string GroqCloudRawValue = "groqCloud";

    /// <summary>Absent or unrecognized (e.g. a stale/foreign value) reads back as
    /// <see cref="SpeechEngineChoiceDefaults.Default"/> — never throws, matching every other
    /// enum-backed settings read in this port (<c>ParseEnginePreferenceExtensions.TryParse</c>,
    /// <c>TaskEntity.Status</c>'s fail-closed accessor).</summary>
    public static SpeechEngineChoice Get(ISettingsStore settings)
    {
        var raw = settings.GetString(SpeechEngineKey);
        return raw switch
        {
            WhisperOnDeviceRawValue => SpeechEngineChoice.WhisperOnDevice,
            GroqCloudRawValue => SpeechEngineChoice.GroqCloud,
            _ => SpeechEngineChoiceDefaults.Default,
        };
    }

    public static void Set(ISettingsStore settings, SpeechEngineChoice choice)
    {
        var raw = choice switch
        {
            SpeechEngineChoice.GroqCloud => GroqCloudRawValue,
            _ => WhisperOnDeviceRawValue,
        };
        settings.SetString(SpeechEngineKey, raw);
    }
}
