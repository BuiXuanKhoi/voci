// Stubs/StubSpeechAdapters.cs — minimal Wave-2 seam adapter for the ISpeechEngine tier.
//
// HotkeyManager and IAudioCaptureService both already have real, hardware-touching Windows
// implementations in Volar.Speech (HotkeyManager itself; AudioCaptureService via NAudio) — those
// are wired up directly in CompositionRoot/HotkeyService, not stubbed. ISpeechEngine's real
// implementations (WhisperNetEngine, GroqEngine) need model files / credentials this shell
// deliberately does not provision, so ONLY that seam is stubbed here.
//
// TODO(W3-B): register the real engine (WhisperNetEngine for the free/on-device tier, GroqEngine
// for the paid/cloud tier) behind a tier-selection policy, once Settings/credentials exist.
using System.Diagnostics;
using Volar.Speech;

namespace Volar.App.Stubs;

public sealed class StubSpeechEngine : ISpeechEngine
{
    public bool SupportsPartialResults => false;

    public bool IsRunning { get; private set; }

    public event Action<string>? OnFinal;

    // Required by ISpeechEngine but never raised by this stub (no real capture ever fails here) —
    // suppressed narrowly rather than solution-wide, matching Volar.App.csproj's own NoWarn policy.
#pragma warning disable CS0067
    public event Action<Exception>? OnError;
#pragma warning restore CS0067

    public Task<bool> RequestAuthorizationAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult(true);

    public void Start(Action<string>? onPartial = null)
    {
        IsRunning = true;
        Debug.WriteLine("[StubSpeechEngine] Start (no real capture — Wave 3-B wires WhisperNetEngine/GroqEngine).");
    }

    public void Stop()
    {
        if (!IsRunning)
        {
            return;
        }
        IsRunning = false;
        Debug.WriteLine("[StubSpeechEngine] Stop -> OnFinal(\"\")");
        OnFinal?.Invoke(string.Empty);
    }

    public void Cancel()
    {
        IsRunning = false;
        Debug.WriteLine("[StubSpeechEngine] Cancel (no OnFinal/OnError fired, per contract).");
    }
}
