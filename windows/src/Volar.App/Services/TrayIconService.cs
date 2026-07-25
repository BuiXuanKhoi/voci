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

    // Kept alive for the process lifetime: native code (RegisterClassEx/window proc dispatch)
    // holds an unmanaged function pointer into this delegate — if it were GC'd, the next WM_* call
    // would crash into freed memory.
    private readonly WndProcDelegate _wndProc;

    private Thread? _pumpThread;
    private nint _hwnd;
    private bool _disposed;

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
        var icon = LoadIcon(0, IDI_APPLICATION);
        var data = new NOTIFYICONDATA
        {
            cbSize = Marshal.SizeOf<NOTIFYICONDATA>(),
            hWnd = _hwnd,
            uID = TrayIconId,
            uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP,
            uCallbackMessage = WM_TRAYICON,
            hIcon = icon,
            szTip = "Volar",
        };
        Shell_NotifyIcon(NIM_ADD, ref data);
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

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;

        if (_hwnd != 0)
        {
            RemoveIcon();
            DestroyWindow(_hwnd);
        }
    }
}
