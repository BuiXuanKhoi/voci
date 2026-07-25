// Services/HotkeyService.cs — thin wrapper around Volar.Speech.Hotkey.HotkeyManager for this
// shell's needs: register Ctrl+Alt+M, log the toggle, and surface it as an event MainWindow/App
// can subscribe to. Real capture-flow wiring (start/stop ISpeechEngine on toggle) is Wave 3-B —
// this only proves the global hotkey registers and fires end-to-end.
using System.Diagnostics;
using Volar.Speech.Hotkey;

namespace Volar.App.Services;

public sealed class HotkeyService : IDisposable
{
    private readonly HotkeyManager _manager = new(HotkeyOptions.Default);

    /// <summary>Fires (already marshalled by <see cref="App"/> back to the UI thread) once per
    /// Ctrl+Alt+M press.</summary>
    public event Action? OnToggle;

    public HotkeyService()
    {
        _manager.OnToggle += () =>
        {
            LogStubToggle();
            OnToggle?.Invoke();
        };
    }

    public void LogStubToggle() => Debug.WriteLine("[HotkeyService] capture toggled (stub — Wave 3-B wires ISpeechEngine)");

    /// <summary>Best-effort start: a failure (e.g. another app already owns Ctrl+Alt+M) is logged,
    /// not thrown — this shell must still boot and show its window even if the hotkey can't be
    /// registered on this machine.</summary>
    public void TryStart()
    {
        try
        {
            _manager.Start();
            Debug.WriteLine("[HotkeyService] Ctrl+Alt+M registered.");
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[HotkeyService] Failed to register Ctrl+Alt+M: {ex.Message}");
        }
    }

    public void Stop() => _manager.Stop();

    public void Dispose() => _manager.Dispose();
}
