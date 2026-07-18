// Playback/VoicePlayback.cs — ported from Sources/Speech/VoicePlayback.swift
//
// ## TTS engine choice: System.Speech.Synthesis (SAPI5), not Windows.Media.SpeechSynthesis
// The brief asks to pick one and record why. `Windows.Media.SpeechSynthesis` (WinRT) has better,
// more natural voices, but: (1) it requires an `IAsyncOperation`-based, effectively-STA activation
// pattern and works most reliably in a packaged (MSIX) app with a package identity — Volar.Speech
// is a plain class library with no guarantee of running inside a packaged host; (2) it hands back
// an in-memory audio *stream* that must then be routed through a SEPARATE playback API (e.g.
// `Windows.Media.Playback.MediaPlayer`), doubling the moving parts for what is, in the mac
// original, a single `AVSpeechSynthesizer.speak(...)` call. `System.Speech.Synthesis` is a plain
// synchronous SAPI5 wrapper: no packaging requirement, no WinRT activation edge cases, and
// `SpeechSynthesizer.SpeakAsync`/`.Speak` plays audio directly — a much closer structural match to
// `AVSpeechSynthesizer`. Trade-off recorded: SAPI5 voices sound noticeably more robotic than
// AVSpeechSynthesizer's or WinRT's neural voices; revisit if voice quality becomes a product
// priority (Settings could offer WinRT synthesis as an opt-in upgrade path later).
using System.Speech.Synthesis;

namespace Volar.Speech.Playback;

/// <summary>Wraps <see cref="SpeechSynthesizer"/> for spoken feedback — mirrors mac's
/// `VoicePlayback` (`AVSpeechSynthesizer` wrapper).</summary>
public sealed class VoicePlayback : IDisposable
{
    private readonly SpeechSynthesizer _synthesizer = new();

    public VoicePlayback()
    {
        _synthesizer.SetOutputToDefaultAudioDevice();
    }

    /// <summary>`volarSpeak(text)` / mac `VoicePlayback.speak(_:)`. The Swift original carries over
    /// the original JS prototype's "+3% over the platform's normal rate" — `AVSpeechUtterance.rate`
    /// uses a 0...1 scale where ~0.5 is "normal", so it computes
    /// `AVSpeechUtteranceDefaultSpeechRate * 1.03`. `SpeechSynthesizer.Rate` uses a very different
    /// integer scale: -10 (slowest) to +10 (fastest), 0 = normal, roughly logarithmic/perceptual
    /// rather than linear. There is no exact numeric equivalent of "+3% of normal" on that scale —
    /// the smallest possible adjustment (±1) already reads as a much bigger perceptual change than
    /// 3%. Rather than fabricate a precision this scale can't express, this keeps `Rate = 0`
    /// (platform-normal), which is the closest honest match; flagged here instead of silently
    /// picking an arbitrary non-zero value.</summary>
    public void Speak(string text)
    {
        if (string.IsNullOrEmpty(text)) return;
        _synthesizer.SpeakAsyncCancelAll();
        var prompt = new PromptBuilder();
        prompt.AppendText(text);
        _synthesizer.Rate = 0;
        _synthesizer.SpeakAsync(prompt);
    }

    /// <summary>`volarStopSpeak()`.</summary>
    public void Stop() => _synthesizer.SpeakAsyncCancelAll();

    /// <summary>Mirrors mac's `VoicePlayback.readDay(_:)`: announces the open-task count and up to
    /// the first 3 titles, or "All clear" when there is nothing open.
    ///
    /// Deliberately takes a plain title list instead of an `AppState`/`TaskSnapshot` reference —
    /// Volar.Speech has no dependency on Volar.Domain or any app-shell type (see the W1-D scope
    /// note: "Speech/ stays decoupled from App/", carried over from the mac architecture doc).
    /// Whatever Wave-3 service replaces `AppState` should call this with its own open-task titles,
    /// exactly like the mac doc comment describes `AppState`/`PopoverView` bridging into
    /// `SpeechCapture` without either owning the other.</summary>
    public void ReadDay(IReadOnlyList<string> openTaskTitles)
    {
        if (openTaskTitles.Count == 0)
        {
            Speak("All clear. Nothing scheduled.");
            return;
        }
        var upNext = string.Join(", ", openTaskTitles.Take(3));
        var taskWord = openTaskTitles.Count == 1 ? "task" : "tasks";
        Speak($"You have {openTaskTitles.Count} open {taskWord}. Up next: {upNext}.");
    }

    public void Dispose()
    {
        _synthesizer.Dispose();
    }
}
