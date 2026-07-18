// Hotkey/HotkeyManager.cs — global toggle-to-talk hotkey via RegisterHotKey (Windows analog of
// Sources/Speech/HotkeyManager.swift's Carbon-based ⌃⌥M toggle hotkey).
//
// ============================================================================================
// ## RegisterHotKey, not WH_KEYBOARD_LL — anh Khôi's decision, 2026-07-19 (supersedes W1-D)
// ============================================================================================
// A previous revision of this file installed a WH_KEYBOARD_LL global low-level keyboard hook,
// because the original W1-D brief said the app needed genuine push-to-talk (hold to speak,
// release to stop) "đúng như bản mac". That premise was WRONG, and the same agent who built the
// hook version caught the discrepancy: the actual mac source
// (Sources/Speech/HotkeyManager.swift) is TOGGLE-based — "toggle: press to start, press again to
// stop+parse" — and explicitly documents that key-up is never used ("onKeyUp intentionally not
// invoked — toggle mode has no use for key-up"). Genuine hold-to-talk has never existed in the
// shipping mac app.
//
// Since real hold-to-talk isn't needed, `RegisterHotKey` — which only ever delivers a key-DOWN-
// shaped `WM_HOTKEY` and has no key-up signal at all — is no longer a structural blocker, and
// anh Khôi chose it over the hook deliberately: it is a small, purpose-built API (register a
// combo, get a message when it's pressed) rather than a firehose of every keystroke system-wide.
// Concretely, versus WH_KEYBOARD_LL, `RegisterHotKey`:
//   - is not flagged by antivirus/EDR products the way a low-level keyboard hook can be (hooks
//     share their primitive with keyloggers; RegisterHotKey does not);
//   - does not draw extra Microsoft Store certification scrutiny;
//   - cannot freeze system-wide keyboard input if buggy — a slow/wedged WH_KEYBOARD_LL callback
//     is a well-known cause of "my whole keyboard stopped responding" system hangs; a slow
//     WM_HOTKEY handler just delays that one message, nothing else;
//   - cannot strand the microphone "stuck on" from a missed key-up (there's no key-up to miss —
//     toggle mode's whole state machine is now just "one message = flip capture on/off").
//
// ## Thread-affinity requirement this design still has to satisfy (same shape as the old hook)
// `RegisterHotKey(hWnd: NULL, ...)` posts `WM_HOTKEY` to the CALLING THREAD's message queue, not
// to any window — so, exactly like the old WH_KEYBOARD_LL hook, this only works if a dedicated
// thread actively pumps `GetMessage`/`DispatchMessage`, and the SAME thread that registered the
// hotkey must be the one that unregisters it (hotkeys registered with a NULL window handle are
// associated with the registering thread, not the process). See `RunMessageLoop` below.
using System.Runtime.InteropServices;

namespace Volar.Speech.Hotkey;

public sealed class HotkeyManager : IDisposable
{
    /// <summary>Arbitrary per-thread hotkey identifier passed to RegisterHotKey/UnregisterHotKey.
    /// Only needs to be unique among hotkeys registered by THIS thread (hotkeys registered with a
    /// NULL window handle are scoped to the registering thread) — this app only ever registers one
    /// combo, so any constant works.</summary>
    private const int HotkeyId = 1;

    private readonly HotkeyOptions _options;
    private readonly ManualResetEventSlim _ready = new(initialState: false);

    private Thread? _pumpThread;
    private uint _pumpThreadId;

    /// <summary>Written on the pump thread only, read from <see cref="IsRunning"/> on any thread.
    /// Not lock-guarded — the only consumer is the `IsRunning`/`Start`/`Stop` idempotency check,
    /// where a stale read costs at worst one redundant/skipped call, never a correctness or safety
    /// issue (the pump thread's own state — whether RegisterHotKey actually succeeded — is always
    /// authoritative).</summary>
    private bool _registered;

    private Exception? _startException;
    private bool _disposed;

    /// <summary>Fires (on a thread-pool thread, NOT the pump thread) once per qualifying
    /// WM_HOTKEY — i.e. once per physical key-down of the configured combo, thanks to
    /// <see cref="NativeMethods.MOD_NOREPEAT"/> suppressing OS auto-repeat re-delivery. Mirrors the
    /// mac source's single `toggleCapture()` call on `kEventHotKeyPressed`.</summary>
    public event Action? OnToggle;

    /// <summary>Test-only seam standing in for the real <c>RegisterHotKey</c> P/Invoke call.
    /// Defaults to the genuine Win32 call; Volar.Speech.Tests overrides it to simulate success or a
    /// specific failure (e.g. <see cref="NativeMethods.ERROR_HOTKEY_ALREADY_REGISTERED"/>) without
    /// ever registering a real system-wide hotkey — mirrors how the previous hook-based
    /// implementation let tests fake `KeyStateProbe` instead of touching real hardware.</summary>
    internal Func<uint, uint, (bool Success, int Win32Error)> RegisterHotKeyFunc { get; set; } = DefaultRegisterHotKey;

    /// <summary>Test-only seam standing in for the real <c>UnregisterHotKey</c> P/Invoke call. See
    /// <see cref="RegisterHotKeyFunc"/>.</summary>
    internal Action UnregisterHotKeyFunc { get; set; } = DefaultUnregisterHotKey;

    public HotkeyManager(HotkeyOptions? options = null)
    {
        _options = options ?? HotkeyOptions.Default;
    }

    public bool IsRunning => _registered;

    /// <summary>Registers the global hotkey on a fresh dedicated thread and blocks until it's
    /// confirmed registered or failed. Safe to call again after a prior <see cref="Stop"/>; throws
    /// if the underlying `RegisterHotKey` call fails — notably
    /// <see cref="HotkeyAlreadyRegisteredException"/> if another application already owns the
    /// combo — rather than silently no-op'ing, so callers (and eventually a Settings UI) know
    /// capture won't work and why.</summary>
    public void Start()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (IsRunning) return;

        _ready.Reset();
        _startException = null;

        var thread = new Thread(RunMessageLoop)
        {
            IsBackground = true,
            Name = "Volar.HotkeyManager.Pump",
        };
        _pumpThread = thread;
        thread.Start();
        _ready.Wait();

        if (_startException is { } ex)
        {
            _pumpThread = null;
            throw ex;
        }
    }

    /// <summary>Entry point for the dedicated pump thread. Wrapped in try/finally so `_ready.Set()`
    /// always fires — a bug here must never hang the calling thread's <see cref="Start"/> forever.
    /// Deliberately does NOT let any exception propagate out of a background `Thread` body: an
    /// unhandled exception on ANY managed thread terminates the whole process by default in .NET,
    /// and a registration failure must never crash the app — it's surfaced back to
    /// <see cref="Start"/>'s caller via <see cref="_startException"/> instead.</summary>
    private void RunMessageLoop()
    {
        try
        {
            _pumpThreadId = NativeMethods.GetCurrentThreadId();

            // Force this thread's Win32 message queue to exist RIGHT NOW, before anything else.
            // Windows creates a thread's message queue lazily, on its first user32/GDI call. The
            // real RegisterHotKey (itself a user32 call) would normally trigger that as a side
            // effect, but relying on that implicitly is fragile — it silently breaks whenever
            // RegisterHotKeyFunc is swapped for a pure-managed test fake that never touches user32
            // (see Volar.Speech.Tests), leaving a window where Stop()'s PostThreadMessageW below
            // can be posted before the queue exists and get silently dropped (ERROR_INVALID_THREAD_ID),
            // wedging the pump thread in GetMessageW until Stop()'s Join times out. A no-op
            // PeekMessageW/PM_NOREMOVE call makes queue creation explicit and immediate instead of
            // an implicit side effect of a different call.
            NativeMethods.PeekMessageW(out _, IntPtr.Zero, 0, 0, NativeMethods.PM_NOREMOVE);

            var (fsModifiers, vk) = _options.ToRegisterHotKeyArgs();
            var (success, win32Error) = RegisterHotKeyFunc(fsModifiers, vk);

            if (!success)
            {
                _startException = CreateRegistrationFailureException(_options, win32Error);
                return; // `finally` below still signals `_ready` and exits the thread cleanly.
            }

            _registered = true;
            _ready.Set();

            // Standard Win32 message pump. Required because RegisterHotKey(hWnd: NULL, ...) posts
            // WM_HOTKEY to the INSTALLING THREAD's own message queue — without an actively pumping
            // GetMessage/DispatchMessage loop on this exact thread, WM_HOTKEY simply never arrives.
            // This is also why registration cannot happen "fire and forget" from an arbitrary
            // thread-pool thread, and why Stop() below must post WM_QUIT to THIS thread specifically.
            while (NativeMethods.GetMessageW(out var msg, IntPtr.Zero, 0, 0) > 0)
            {
                if (msg.message == NativeMethods.WM_HOTKEY && msg.wParam.ToInt32() == HotkeyId)
                {
                    Dispatch();
                }

                NativeMethods.TranslateMessage(ref msg);
                NativeMethods.DispatchMessageW(ref msg);
            }
        }
        catch (Exception ex)
        {
            _startException ??= ex;
        }
        finally
        {
            if (_registered)
            {
                // Must run on this same thread — hotkeys registered with a NULL window handle are
                // associated with the registering thread, and UnregisterHotKey is documented to be
                // called by that thread. See the file header's "thread-affinity requirement" note.
                UnregisterHotKeyFunc();
                _registered = false;
            }
            _ready.Set();
        }
    }

    /// <summary>Unregisters the hotkey and stops the pump thread. Posts WM_QUIT to the pump
    /// thread's own message queue (the standard, only-correct way to unblock a `GetMessage` loop
    /// from another thread) and joins with a bounded timeout so a wedged pump thread can never hang
    /// the caller forever. Idempotent.</summary>
    public void Stop()
    {
        if (!IsRunning || _pumpThread is not { } thread) return;
        NativeMethods.PostThreadMessageW(_pumpThreadId, NativeMethods.WM_QUIT, IntPtr.Zero, IntPtr.Zero);
        thread.Join(TimeSpan.FromSeconds(2));
        _pumpThread = null;
    }

    /// <summary>No finalizer, deliberately (unlike the previous hook-based revision of this class).
    /// A `SetWindowsHookEx` handle could be released from any thread, so a finalizer safety net
    /// made sense; `UnregisterHotKey` cannot — it must run on the same thread that registered the
    /// hotkey, which a finalizer thread never is, so attempting the call there would be at best a
    /// no-op and at worst misleading. If <see cref="Dispose"/>/<see cref="Stop"/> is never called,
    /// no leak results anyway: the pump thread is a background thread (<c>IsBackground = true</c>),
    /// so it does not block process exit, and the OS releases the thread-scoped hotkey registration
    /// automatically the moment that thread (and therefore the process) terminates.</summary>
    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        Stop();
        _ready.Dispose();
    }

    /// <summary>
    /// Runs on the pump thread for the qualifying WM_HOTKEY message. Extracted as its own
    /// `internal` method (rather than inlined in the loop above) specifically so
    /// Volar.Speech.Tests can exercise the dispatch-threading contract — "handlers never run on the
    /// pump thread" — directly, without ever routing a real message through
    /// PostThreadMessageW/GetMessageW.
    /// </summary>
    internal void Dispatch()
    {
        // Fire-and-forget onto the thread pool — this method must not block the pump thread.
        // Handlers registered on OnToggle therefore run on an arbitrary thread-pool thread, never
        // the pump thread and never a UI thread; callers that touch UI state must marshal back
        // themselves (mirrors ISpeechEngine's OnFinal/OnError threading note).
        var handler = OnToggle;
        if (handler is not null)
        {
            ThreadPool.QueueUserWorkItem(_ => handler());
        }
    }

    /// <summary>Builds a descriptive, UI-presentable exception for a failed `RegisterHotKey` call.
    /// Pulled out as its own pure, static, `internal` function — independent of any P/Invoke or
    /// threading — specifically so Volar.Speech.Tests can exercise the "combo already taken by
    /// another app" error path without ever calling the real Win32 API or spinning up the pump
    /// thread. <see cref="NativeMethods.ERROR_HOTKEY_ALREADY_REGISTERED"/> gets its own exception
    /// type (<see cref="HotkeyAlreadyRegisteredException"/>) so a future Settings UI can catch it
    /// specifically and prompt the user to pick a different combo, rather than pattern-matching on
    /// exception message text; any other failure surfaces as a plain
    /// <see cref="InvalidOperationException"/> carrying the raw Win32 error code.</summary>
    internal static Exception CreateRegistrationFailureException(HotkeyOptions options, int win32Error)
    {
        var combo = options.DescribeCombo();
        return win32Error == NativeMethods.ERROR_HOTKEY_ALREADY_REGISTERED
            ? new HotkeyAlreadyRegisteredException(
                $"The hotkey {combo} is already registered by another application. Please choose a different combination in Settings.",
                win32Error)
            : new InvalidOperationException(
                $"RegisterHotKey failed for {combo} (Win32 error {win32Error}).");
    }

    private static (bool Success, int Win32Error) DefaultRegisterHotKey(uint fsModifiers, uint vk)
    {
        var success = NativeMethods.RegisterHotKey(IntPtr.Zero, HotkeyId, fsModifiers, vk);
        return success ? (true, 0) : (false, Marshal.GetLastWin32Error());
    }

    private static void DefaultUnregisterHotKey() => NativeMethods.UnregisterHotKey(IntPtr.Zero, HotkeyId);
}
