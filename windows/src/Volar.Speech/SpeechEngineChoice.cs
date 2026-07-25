// SpeechEngineChoice.cs — new in Wave 3-B (A3: Local<->Cloud switch, macOS commit f88d5e5). Port
// of Swift's `enum SpeechEngineChoice: String, Sendable, Equatable, CaseIterable, Identifiable`
// (Volar/Sources/App/AppState.swift) — the user-facing speech-engine picker's backing type.
//
// PARITY NOTE (per anh Khôi's decision 2026-07-25, specs/003-windows-port/wave3b-parity.md "A3"):
// Windows has only TWO cases, not Swift's three. Swift's `.appleOnDevice` (live, streaming
// on-device transcription via the Speech framework, `supportsPartialResults == true`) has NO
// Windows equivalent — there is no OS-level streaming speech API this port targets, and Windows
// accepts BATCH-ONLY capture (no live caption) for both its on-device tier (Whisper.net,
// `WhisperNetEngine`) and its cloud tier (Groq, `GroqEngine`). This is a deliberate, permanent
// platform difference, not a placeholder to fill in later.
namespace Volar.Speech;

/// <summary>The two speech-to-text engines Windows offers, in order of the freemium tier they
/// belong to (free/on-device first, paid/cloud second) — mirrors <c>ParseEnginePreference</c>'s
/// naming convention (<c>OnDevice</c>/<c>Cloud</c>) for a consistent Local↔Cloud vocabulary across
/// both the parsing and speech switches.</summary>
public enum SpeechEngineChoice
{
    /// <summary>Free, unlimited tier: on-device batch transcription via Whisper.net
    /// (<see cref="Volar.Speech.Whisper.WhisperNetEngine"/>). The default.</summary>
    WhisperOnDevice,

    /// <summary>Paid tier: cloud batch transcription via Groq
    /// (<see cref="Volar.Speech.Groq.GroqEngine"/>). Selecting this WITHOUT a configured
    /// credential (<see cref="Groq.IGroqCredentialProvider.IsConfigured"/> false) must degrade
    /// silently to <see cref="WhisperOnDevice"/> before recording starts — never a hard error at
    /// upload time. That routing decision itself belongs to a future speech-engine-selection
    /// policy (ported from Swift's <c>AppState.selectedEngine</c>, Wave 3-C) — this enum only
    /// names the choice.</summary>
    GroqCloud,
}

/// <summary>Convenience default so callers don't hardcode <see cref="SpeechEngineChoice.WhisperOnDevice"/>
/// in multiple places (composition root default parameter, Settings UI initial selection, ...).</summary>
public static class SpeechEngineChoiceDefaults
{
    public const SpeechEngineChoice Default = SpeechEngineChoice.WhisperOnDevice;
}
