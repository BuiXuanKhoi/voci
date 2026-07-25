// ParseEnginePreference.cs — port of the `ParseEnginePreference` enum added to
// Volar/Sources/App/AppState.swift by macOS commit f88d5e5 ("add Local/Cloud switch for both task
// parsing and speech"). Local (on-device) vs Cloud task-parsing preference — the Settings switch
// that feature adds.
//
// PARITY NOTE (state explicitly per this wave's self-review requirement): on macOS this is a thin
// bridge OVER the existing one-time `cloudParseConsent` bool (`AppState.parseEnginePreference` /
// `setParseEngine`) — Swift does NOT persist a separate "volar.parseEngine" UserDefaults key
// anywhere (grep confirms: only `volar.cloudParseConsent`/`volar.speechEngine` are real keys).
// `ParseEnginePreferenceStore` below reproduces that exact bridge (single source of truth, no
// second key) so this port cannot drift from the real mechanism. `ToRawValue`/`TryParse` exist
// only so a FUTURE literal "volar.parseEngine" string key (if Wave 3-C's Settings UI ever wants
// one, e.g. for a picker binding) round-trips using the same wire format Swift's `RawValue`
// synthesis would produce ("onDevice"/"cloud") — they are not wired to any settings key by this
// file itself.
using Volar.Domain;

namespace Volar.Parsing;

/// <summary>Local (on-device) vs Cloud task-parsing preference. Port of Swift's
/// <c>enum ParseEnginePreference: String, CaseIterable, Identifiable { case onDevice, cloud }</c>.</summary>
public enum ParseEnginePreference
{
    OnDevice,
    Cloud,
}

public static class ParseEnginePreferenceExtensions
{
    /// <summary>Swift's synthesized <c>rawValue</c> strings ("onDevice"/"cloud") — kept identical
    /// here for wire-format parity, per this file's header note.</summary>
    public static string ToRawValue(this ParseEnginePreference preference) => preference switch
    {
        ParseEnginePreference.OnDevice => "onDevice",
        ParseEnginePreference.Cloud => "cloud",
        _ => throw new ArgumentOutOfRangeException(nameof(preference), preference, "Unknown ParseEnginePreference."),
    };

    /// <summary>Inverse of <see cref="ToRawValue"/>. Returns <see langword="false"/> (and sets
    /// <paramref name="preference"/> to <see cref="ParseEnginePreference.OnDevice"/>, the safe
    /// default) for any unrecognized raw value — never throws.</summary>
    public static bool TryParse(string? raw, out ParseEnginePreference preference)
    {
        switch (raw)
        {
            case "onDevice":
                preference = ParseEnginePreference.OnDevice;
                return true;
            case "cloud":
                preference = ParseEnginePreference.Cloud;
                return true;
            default:
                preference = ParseEnginePreference.OnDevice;
                return false;
        }
    }

    /// <summary>Port of <c>AppState.parseEnginePreference</c>'s getter: a `null`/absent/false
    /// consent reads as <see cref="ParseEnginePreference.OnDevice"/> — the privacy-first default
    /// ("decline ⇒ never cloud"), matching <see cref="DefaultCloudParseGate"/>'s own
    /// false-when-absent read of the same bit.</summary>
    public static ParseEnginePreference FromCloudConsent(bool cloudConsent) =>
        cloudConsent ? ParseEnginePreference.Cloud : ParseEnginePreference.OnDevice;

    /// <summary>Port of <c>AppState.setParseEngine(_:)</c>'s write side: what to persist to the
    /// <c>cloudParseConsent</c> bit when the user changes the Settings picker. Picking
    /// <see cref="ParseEnginePreference.Cloud"/> IS the informed one-time opt-in — the Settings
    /// row's hint (Wave 4) must state that cloud parsing sends only the TEXT of the utterance,
    /// never audio, exactly like the Swift `SettingsView` hint this ports.</summary>
    public static bool ToCloudConsent(this ParseEnginePreference preference) =>
        preference == ParseEnginePreference.Cloud;
}

/// <summary>
/// Reads/writes the Local↔Cloud preference against an <see cref="ISettingsStore"/> by bridging the
/// SAME <c>volar.cloudParseConsent</c> bit <see cref="DefaultCloudParseGate"/> gates
/// <see cref="IntentRouter"/>'s Cloud tier on — never a second source of truth. Exists so Wave 3-C's
/// Settings UI (and any other future caller) gets this bridge pre-built and pre-tested instead of
/// re-deriving it slightly differently from <c>AppState.swift</c>'s prose.
/// </summary>
public static class ParseEnginePreferenceStore
{
    /// <summary>Same string Swift's <c>AppState.cloudParseConsentKey</c> writes to, and the same
    /// key <see cref="DefaultCloudParseGate.IsOptedInAsync"/> reads — the single source of truth
    /// for both the one-time voice-capture consent popover (Wave 3-C/4) and this Settings picker.</summary>
    public const string CloudParseConsentKey = "volar.cloudParseConsent";

    public static ParseEnginePreference Get(ISettingsStore settings) =>
        ParseEnginePreferenceExtensions.FromCloudConsent(settings.GetBool(CloudParseConsentKey, false));

    public static void Set(ISettingsStore settings, ParseEnginePreference preference) =>
        settings.SetBool(CloudParseConsentKey, preference.ToCloudConsent());
}
