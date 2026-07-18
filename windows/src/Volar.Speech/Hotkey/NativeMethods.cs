// Hotkey/NativeMethods.cs — raw Win32 P/Invoke surface for the RegisterHotKey global hotkey.
//
// Kept in its own file, deliberately minimal: only the exact functions/constants HotkeyManager
// needs for RegisterHotKey/UnregisterHotKey + the message loop that has to pump WM_HOTKEY.
//
// ## RegisterHotKey, not WH_KEYBOARD_LL — anh Khôi's decision, 2026-07-19 (supersedes W1-D)
// An earlier revision of this file installed a WH_KEYBOARD_LL global low-level keyboard hook,
// because the original W1-D brief asked for genuine push-to-talk (hold to speak, release to
// stop), which is structurally impossible on RegisterHotKey (it only ever delivers a key-DOWN-
// shaped WM_HOTKEY, never a key-up). That brief was based on a wrong premise: the actual mac
// source (Sources/Speech/HotkeyManager.swift) is TOGGLE-only — press once to start capture, press
// again to stop+parse; key-up is never used. Since real hold-to-talk was never needed, the
// heavier, riskier mechanism it required is not needed either. anh Khôi ordered the hook removed
// in favor of RegisterHotKey because it is a clean, purpose-built API (no antivirus/EDR flags —
// unlike WH_KEYBOARD_LL, which shares its primitive with keyloggers — no Microsoft Store
// certification friction, no ability to freeze system-wide keyboard input if buggy, and no risk of
// a stuck-open microphone from a missed key-up event, since there is no key-up to miss).
using System.Runtime.InteropServices;

namespace Volar.Speech.Hotkey;

internal static class NativeMethods
{
    public const uint WM_QUIT = 0x0012;
    public const uint WM_HOTKEY = 0x0312;

    // RegisterHotKey fsModifiers flags (winuser.h).
    public const uint MOD_ALT = 0x0001;
    public const uint MOD_CONTROL = 0x0002;
    public const uint MOD_SHIFT = 0x0004;
    public const uint MOD_WIN = 0x0008;
    /// <summary>Tells the OS to suppress repeat WM_HOTKEY delivery while the key is held down —
    /// the RegisterHotKey-native replacement for the previous hook-based implementation's manual
    /// `_isDown` auto-repeat guard. Requires Windows 7+ (no compatibility concern — this app has no
    /// older target).</summary>
    public const uint MOD_NOREPEAT = 0x4000;

    /// <summary>Win32 error code returned by <c>GetLastError()</c> when <see cref="RegisterHotKey"/>
    /// fails because another application already owns the exact same key combination.</summary>
    public const int ERROR_HOTKEY_ALREADY_REGISTERED = 1409;

    [StructLayout(LayoutKind.Sequential)]
    public struct MSG
    {
        public IntPtr hwnd;
        public uint message;
        public IntPtr wParam;
        public IntPtr lParam;
        public uint time;
        public int ptX;
        public int ptY;
    }

    /// <summary>Registers a system-wide hotkey. With <paramref name="hWnd"/> = <see cref="IntPtr.Zero"/>,
    /// the resulting WM_HOTKEY messages are posted to the CALLING THREAD's message queue (not any
    /// window's), so the thread that calls this must be actively pumping messages, and must be the
    /// same thread that later calls <see cref="UnregisterHotKey"/> — hotkeys registered this way are
    /// associated with the registering thread, not the process. Returns <c>false</c> on failure;
    /// call <c>Marshal.GetLastWin32Error()</c> immediately after for the reason (notably
    /// <see cref="ERROR_HOTKEY_ALREADY_REGISTERED"/> when another app already owns the combo).</summary>
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern int GetMessageW(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax);

    /// <summary>PM_NOREMOVE — used with <see cref="PeekMessageW"/> purely to force creation of the
    /// calling thread's message queue without consuming any pending message. See
    /// <c>HotkeyManager.RunMessageLoop</c>'s call site for why this matters.</summary>
    public const uint PM_NOREMOVE = 0x0000;

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool PeekMessageW(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax, uint wRemoveMsg);

    [DllImport("user32.dll")]
    public static extern bool TranslateMessage(ref MSG lpMsg);

    [DllImport("user32.dll")]
    public static extern IntPtr DispatchMessageW(ref MSG lpMsg);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool PostThreadMessageW(uint idThread, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll")]
    public static extern uint GetCurrentThreadId();
}
