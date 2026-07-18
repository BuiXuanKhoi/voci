// Audio/AudioCaptureException.cs — errors specific to AudioCaptureService.
namespace Volar.Speech.Audio;

/// <summary>Failures from <see cref="AudioCaptureService"/> — the Windows analog of the parts of
/// Sources/Speech/SpeechCaptureError (Swift) that concern the microphone/recording pipeline itself
/// rather than a specific STT engine (Whisper/Groq have their own error types below).</summary>
public sealed class AudioCaptureException : Exception
{
    public AudioCaptureException(string message, Exception? inner = null) : base(message, inner) { }

    /// <summary>No default capture device / the device format couldn't be opened. Mirrors the
    /// mac guard in SpeechCapture.swift ("input format is 0 Hz / 0 channels") that fails soft
    /// through <c>onError</c> instead of letting CoreAudio abort the process — same intent here:
    /// never let a missing microphone crash the app.</summary>
    public static AudioCaptureException NoInputDevice(Exception? inner = null) =>
        new("No usable audio input device.", inner);

    /// <summary>Windows Settings ▸ Privacy &amp; security ▸ Microphone is off for this app (or
    /// system-wide). There is no in-app permission prompt to trigger on Windows the way
    /// AVAudioApplication.requestRecordPermission() prompts on macOS — the caller must send the
    /// user to Settings themselves.</summary>
    public static AudioCaptureException AccessDenied(Exception? inner = null) =>
        new("Microphone access is denied. Enable it in Windows Settings > Privacy & security > Microphone.", inner);

    public static AudioCaptureException EmptyRecording() =>
        new("Nothing was recorded.");
}
