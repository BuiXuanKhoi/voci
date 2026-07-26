// Services/TrayIconService.cs — the tray icon + flyout menu, mirroring
// Sources/App/VolarApp.swift's MenuBarMenuContent: "Open Volar", "New task (Ctrl+Alt+M)",
// "Settings…", "Preview reminder", "Quit Volar".
//
// APPROACH: raw Win32 Shell_NotifyIcon P/Invoke, NOT H.NotifyIcon.WinUI. H.NotifyIcon.WinUI 2.3.0
// was evaluated (its NuGet package restores fine against this project's net10.0-windows10.0.19041.0
// TFM — the package itself targets net8.0-windows10.0.17763, which is binary-compatible) but its
// "windowless"/code-behind-only usage pattern for an unpackaged unpackaged app (no XAML tree to
// host the control, no MSIX identity) is under-documented and adds a third-party dependency to the
// single highest-risk part of this task (must actually launch on this machine). A raw
// Shell_NotifyIcon + hidden native window + native popup menu is more code but every piece is a
// well-documented, deterministic Win32 API — same risk trade-off HotkeyManager already made for
// RegisterHotKey vs. a hook. Runs on its own dedicated pump thread (same shape as
// Volar.Speech.Hotkey.HotkeyManager) so it never depends on WinUI's own dispatcher/message loop.
using System.Diagnostics;
using System.Runtime.InteropServices;
using static Volar.App.Services.TrayNativeMethods;

namespace Volar.App.Services;

/// <summary>The 3 tray icon states — wave4-contract.md frozen decision 4 ("MenuBarLabel analog =
/// tray icon state swap (idle/listening/focus-lock icons) + dynamic tooltip"). Mirrors
/// MenuBarLabel.swift's 3-state switch (idle / `captureState == .recording` / `focusActive`)
/// 1:1 — Windows has no menu-bar surface to render MenuBarLabel's rich text into (task title, WIP
/// badge, mono countdown all live in the tooltip string instead, via <see cref="TrayIconService.UpdateState"/>'s
/// <c>tooltip</c> parameter), so only the 3 STATE identities carry over as icon glyphs; the rest of
/// MenuBarLabel's content becomes the tooltip text, composed by whichever caller wires this up
/// (Stage C — this class stays passive, see <see cref="TrayIconService.UpdateState"/>'s own doc comment).</summary>
public enum TrayState
{
    Idle,
    Listening,
    Focus,
}

public sealed class TrayIconService : IDisposable
{
    private const string ClassName = "VolarTrayIconWindow";
    private const int TrayIconId = 1;

    private const int CmdOpen = 1;
    private const int CmdNewTask = 2;
    private const int CmdSettings = 3;
    private const int CmdPreviewReminder = 4;
    private const int CmdQuit = 5;

    private readonly Action _onOpen;
    private readonly Action _onNewTask;
    private readonly Action _onSettings;
    private readonly Action _onPreviewReminder;
    private readonly Action _onQuit;

    /// <summary>Fires (off the native pump thread — dispatched the same way <see cref="Dispatch"/>
    /// dispatches menu commands, so subscribers must marshal onto their own UI thread themselves)
    /// on power resume (WM_POWERBROADCAST/PBT_APMRESUMESUSPEND/PBT_APMRESUMEAUTOMATIC) or session
    /// unlock (WM_WTSSESSION_CHANGE/WTS_SESSION_UNLOCK). App.xaml.cs subscribes this to
    /// <c>ReminderScheduler.RebuildFromStorage</c> — the Windows equivalent of macOS's
    /// <c>NSWorkspace.didWakeNotification</c> observer (appstate-inventory.md §5.2): a reminder due
    /// while the app was asleep/the session was locked must still fire via this path. Handled on
    /// this class's existing hidden window/message pump rather than standing up a second native
    /// window solely for power/session notifications.</summary>
    public event Action? SystemResumedOrUnlocked;

    // Kept alive for the process lifetime: native code (RegisterClassEx/window proc dispatch)
    // holds an unmanaged function pointer into this delegate — if it were GC'd, the next WM_* call
    // would crash into freed memory.
    private readonly WndProcDelegate _wndProc;

    private Thread? _pumpThread;
    private nint _hwnd;
    private bool _disposed;

    // Lazily built, cached for the process lifetime — DestroyIcon'd in Dispose(). See
    // EnsureIcons()/CreateDotIcon() below.
    private nint _iconIdle;
    private nint _iconListening;
    private nint _iconFocus;

    public TrayIconService(
        Action onOpen,
        Action onNewTask,
        Action onSettings,
        Action onPreviewReminder,
        Action onQuit)
    {
        _onOpen = onOpen;
        _onNewTask = onNewTask;
        _onSettings = onSettings;
        _onPreviewReminder = onPreviewReminder;
        _onQuit = onQuit;
        _wndProc = WndProc;
    }

    public void Initialize()
    {
        var thread = new Thread(RunMessageLoop)
        {
            IsBackground = true,
            Name = "Volar.TrayIconService.Pump",
        };
        _pumpThread = thread;
        thread.Start();
    }

    private void RunMessageLoop()
    {
        try
        {
            var hInstance = GetModuleHandle(null);

            var wndClass = new WNDCLASSEX
            {
                cbSize = Marshal.SizeOf<WNDCLASSEX>(),
                lpfnWndProc = _wndProc,
                hInstance = hInstance,
                lpszClassName = ClassName,
            };
            RegisterClassEx(ref wndClass);

            _hwnd = CreateWindowEx(0, ClassName, "Volar Tray", 0, 0, 0, 0, 0, 0, 0, hInstance, 0);
            if (_hwnd == 0)
            {
                Debug.WriteLine("[TrayIconService] CreateWindowEx failed — tray icon unavailable.");
                return;
            }

            AddIcon();

            // Best-effort: a failure here just means session lock/unlock never triggers
            // RebuildFromStorage on THIS machine — power-resume (WM_POWERBROADCAST) still does, and
            // RebuildFromStorage also always runs once at every launch, so this is a nice-to-have
            // catch-up, never the only recovery path.
            WTSRegisterSessionNotification(_hwnd, NOTIFY_FOR_THIS_SESSION);

            while (GetMessageW(out var msg, 0, 0, 0) > 0)
            {
                TranslateMessage(ref msg);
                DispatchMessageW(ref msg);
            }
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[TrayIconService] Pump thread failed: {ex}");
        }
    }

    private void AddIcon()
    {
        var data = new NOTIFYICONDATA
        {
            cbSize = Marshal.SizeOf<NOTIFYICONDATA>(),
            hWnd = _hwnd,
            uID = TrayIconId,
            uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP,
            uCallbackMessage = WM_TRAYICON,
            hIcon = IconFor(TrayState.Idle),
            szTip = "Volar",
        };
        Shell_NotifyIcon(NIM_ADD, ref data);
    }

    /// <summary>Swaps the tray icon glyph for <paramref name="state"/> and, when
    /// <paramref name="tooltip"/> is supplied, replaces the hover tooltip (<c>NIM_MODIFY</c>'s
    /// <c>szTip</c>, truncated to <c>NOTIFYICONDATA</c>'s 127-char/128-byte-with-null-terminator
    /// limit — wave4-contract.md frozen decision 4). PASSIVE by design (this task's brief): this
    /// class does not subscribe to any service itself, throttle call frequency, or decide WHEN a
    /// state changed — Stage C is expected to wire <see cref="CaptureFlowService.State"/>/
    /// <c>FocusSessionService.FocusActive</c>/the 1s focus-countdown tick to this method, including
    /// the "update the focus tooltip at most 1/s" constraint (a caller-side throttling
    /// responsibility, not enforced here). Safe to call from any thread — <c>Shell_NotifyIcon</c>
    /// itself has no thread affinity to the window it targets; a no-op before <see cref="Initialize"/>
    /// has created the tray icon (or after <see cref="Dispose"/>).</summary>
    public void UpdateState(TrayState state, string? tooltip)
    {
        if (_disposed || _hwnd == 0)
        {
            return;
        }

        var tip = string.IsNullOrEmpty(tooltip) ? "Volar" : tooltip;
        if (tip.Length > 127)
        {
            tip = tip[..127];
        }

        var data = new NOTIFYICONDATA
        {
            cbSize = Marshal.SizeOf<NOTIFYICONDATA>(),
            hWnd = _hwnd,
            uID = TrayIconId,
            uFlags = NIF_ICON | NIF_TIP,
            hIcon = IconFor(state),
            szTip = tip,
        };
        Shell_NotifyIcon(NIM_MODIFY, ref data);
    }

    private nint IconFor(TrayState state)
    {
        EnsureIcons();
        return state switch
        {
            TrayState.Listening => _iconListening != 0 ? _iconListening : LoadIcon(0, IDI_APPLICATION),
            TrayState.Focus => _iconFocus != 0 ? _iconFocus : LoadIcon(0, IDI_APPLICATION),
            _ => _iconIdle != 0 ? _iconIdle : LoadIcon(0, IDI_APPLICATION),
        };
    }

    /// <summary>Builds the 3 state icons once. GDI-drawn simple glyph variants, per this task's
    /// brief ("dot/red dot/ring"): idle = a small muted-grey dot (Colors.xaml <c>VolarTextSec</c>
    /// #9BA3AE), listening = a small solid red dot (a plain "recording" convention — deliberately
    /// NOT drawn from the app's anti-shame no-red-for-status palette rule, since a tray REC glyph is
    /// an activity indicator under normal OS iconography conventions, not an in-app task-status
    /// color; flagged in this task's final report), focus-lock = a ring in the reserved warm NOW
    /// spotlight tone (Colors.xaml <c>VolarNowAccent</c> #E8B25A — mirrors MenuBarLabel.swift's own
    /// choice to badge focus-lock with the NOW-spotlight family, MenuBarLabel.swift:103-113).
    /// Falls back to <c>LoadIcon(0, IDI_APPLICATION)</c> per-state if generation fails for any
    /// reason (never let a tray icon glyph failure take down the tray).</summary>
    private void EnsureIcons()
    {
        if (_iconIdle != 0 || _iconListening != 0 || _iconFocus != 0)
        {
            return;
        }
        _iconIdle = CreateDotIcon(0x9BA3AE, ringOnly: false);
        _iconListening = CreateDotIcon(0xE0524F, ringOnly: false);
        _iconFocus = CreateDotIcon(0xE8B25A, ringOnly: true);
    }

    private static nint CreateDotIcon(uint rgb, bool ringOnly)
    {
        const int size = 32;
        var pixels = new byte[size * size * 4]; // top-down BGRA, opaque where drawn, else 0 = fully transparent.
        var b = (byte)(rgb & 0xFF);
        var g = (byte)((rgb >> 8) & 0xFF);
        var r = (byte)((rgb >> 16) & 0xFF);
        var center = (size - 1) / 2.0;
        var outerRadius = size * 0.30;
        var innerRadius = ringOnly ? outerRadius * 0.55 : 0.0;

        for (var y = 0; y < size; y++)
        {
            for (var x = 0; x < size; x++)
            {
                var dx = x - center;
                var dy = y - center;
                var dist = Math.Sqrt((dx * dx) + (dy * dy));
                if (dist > outerRadius || dist < innerRadius)
                {
                    continue;
                }
                var offset = ((y * size) + x) * 4;
                pixels[offset + 0] = b;
                pixels[offset + 1] = g;
                pixels[offset + 2] = r;
                pixels[offset + 3] = 255;
            }
        }

        return BuildHIconFromBgra(pixels, size, size);
    }

    private static nint BuildHIconFromBgra(byte[] bgraTopDown, int width, int height)
    {
        var bmi = new BITMAPINFO
        {
            bmiHeader = new BITMAPINFOHEADER
            {
                biSize = Marshal.SizeOf<BITMAPINFOHEADER>(),
                biWidth = width,
                biHeight = -height, // negative = top-down DIB, matching bgraTopDown's row order.
                biPlanes = 1,
                biBitCount = 32,
                biCompression = BI_RGB,
            },
        };

        var screenDC = GetDC(0);
        if (screenDC == 0)
        {
            return 0;
        }
        try
        {
            var colorBitmap = CreateDIBSection(screenDC, ref bmi, DIB_RGB_COLORS, out var bits, 0, 0);
            if (colorBitmap == 0 || bits == 0)
            {
                return 0;
            }
            try
            {
                Marshal.Copy(bgraTopDown, 0, bits, bgraTopDown.Length);

                // AND mask — irrelevant with a true-per-pixel-alpha 32bpp color bitmap (supported by
                // every Windows version this app targets), but ICONINFO still requires one the same
                // size.
                var maskBitmap = CreateBitmap(width, height, 1, 1, 0);
                try
                {
                    var iconInfo = new ICONINFO { fIcon = true, hbmColor = colorBitmap, hbmMask = maskBitmap };
                    return CreateIconIndirect(ref iconInfo);
                }
                finally
                {
                    if (maskBitmap != 0)
                    {
                        DeleteObject(maskBitmap);
                    }
                }
            }
            finally
            {
                DeleteObject(colorBitmap);
            }
        }
        finally
        {
            ReleaseDC(0, screenDC);
        }
    }

    private void RemoveIcon()
    {
        var data = new NOTIFYICONDATA
        {
            cbSize = Marshal.SizeOf<NOTIFYICONDATA>(),
            hWnd = _hwnd,
            uID = TrayIconId,
        };
        Shell_NotifyIcon(NIM_DELETE, ref data);
    }

    private nint WndProc(nint hWnd, uint msg, nint wParam, nint lParam)
    {
        switch (msg)
        {
            case WM_TRAYICON:
                if (lParam is WM_LBUTTONUP or WM_RBUTTONUP)
                {
                    ShowMenu(hWnd);
                }
                return 0;

            case WM_COMMAND:
                Dispatch((int)(wParam.ToInt64() & 0xFFFF));
                return 0;

            case WM_POWERBROADCAST:
                if (wParam == PBT_APMRESUMESUSPEND || wParam == PBT_APMRESUMEAUTOMATIC)
                {
                    RaiseSystemResumedOrUnlocked();
                }
                return 1; // TRUE — required return value for WM_POWERBROADCAST handlers.

            case WM_WTSSESSION_CHANGE:
                if (wParam == WTS_SESSION_UNLOCK)
                {
                    RaiseSystemResumedOrUnlocked();
                }
                return 0;

            case WM_DESTROY:
                PostQuitMessage(0);
                return 0;

            default:
                return DefWindowProc(hWnd, msg, wParam, lParam);
        }
    }

    private void ShowMenu(nint hWnd)
    {
        var menu = CreatePopupMenu();
        if (menu == 0)
        {
            return;
        }
        try
        {
            AppendMenu(menu, MF_STRING, (nuint)CmdOpen, "Open Volar");
            AppendMenu(menu, MF_STRING, (nuint)CmdNewTask, "New task (Ctrl+Alt+M)");
            AppendMenu(menu, MF_STRING, (nuint)CmdSettings, "Settings…");
            AppendMenu(menu, MF_STRING, (nuint)CmdPreviewReminder, "Preview reminder");
            AppendMenu(menu, MF_SEPARATOR, 0, null);
            AppendMenu(menu, MF_STRING, (nuint)CmdQuit, "Quit Volar");

            GetCursorPos(out var pt);
            // Required for the native popup menu to dismiss correctly when it loses focus (the
            // documented Win32 idiom for a tray-triggered TrackPopupMenuEx call).
            SetForegroundWindow(hWnd);
            var selected = TrackPopupMenuEx(menu, TPM_RIGHTBUTTON | TPM_RETURNCMD, pt.X, pt.Y, hWnd, 0);
            if (selected != 0)
            {
                Dispatch(selected);
            }
        }
        finally
        {
            DestroyMenu(menu);
        }
    }

    private void Dispatch(int commandId)
    {
        // Fire-and-forget onto the thread pool — mirrors HotkeyManager.Dispatch: handlers must
        // never run on this native pump thread (they touch WinUI's DispatcherQueue themselves).
        Action? action = commandId switch
        {
            CmdOpen => _onOpen,
            CmdNewTask => _onNewTask,
            CmdSettings => _onSettings,
            CmdPreviewReminder => _onPreviewReminder,
            CmdQuit => _onQuit,
            _ => null,
        };
        if (action is not null)
        {
            ThreadPool.QueueUserWorkItem(_ => action());
        }
    }

    // Fire-and-forget onto the thread pool — same rationale as Dispatch above: never run a
    // subscriber's handler on this native pump thread.
    private void RaiseSystemResumedOrUnlocked()
    {
        var handler = SystemResumedOrUnlocked;
        if (handler is not null)
        {
            ThreadPool.QueueUserWorkItem(_ => handler());
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;

        if (_hwnd != 0)
        {
            WTSUnRegisterSessionNotification(_hwnd);
            RemoveIcon();
            DestroyWindow(_hwnd);
        }

        if (_iconIdle != 0)
        {
            DestroyIcon(_iconIdle);
            _iconIdle = 0;
        }
        if (_iconListening != 0)
        {
            DestroyIcon(_iconListening);
            _iconListening = 0;
        }
        if (_iconFocus != 0)
        {
            DestroyIcon(_iconFocus);
            _iconFocus = 0;
        }
    }
}
