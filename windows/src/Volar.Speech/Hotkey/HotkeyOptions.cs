// Hotkey/HotkeyOptions.cs — configurable hotkey combo for the global toggle-to-talk hotkey.
//
// Everything HotkeyManager needs to identify "the" combo lives here, in ONE place, so nothing in
// HotkeyManager/NativeMethods hardcodes a specific key or modifier outside of the Default below.
//
// ## Toggle-only (no PushToTalk) — anh Khôi's decision, 2026-07-19
// An earlier revision of this file had a `HotkeyCaptureMode` enum (Toggle vs. PushToTalk) because
// the original W1-D brief asked for genuine hold-to-talk. That brief was wrong: the actual mac
// source (Sources/Speech/HotkeyManager.swift) is toggle-only — press once to start capture, press
// again to stop+parse; key-up is never used ("onKeyUp intentionally not invoked — toggle mode has
// no use for key-up"). anh Khôi confirmed toggle-only is correct and ordered PushToTalk mode
// removed, along with the WH_KEYBOARD_LL hook that mode required (see NativeMethods.cs's header
// for the full rationale — RegisterHotKey has no key-up signal at all, so PushToTalk was never
// buildable on it anyway; removing the enum just makes that structural fact visible in the type
// system instead of leaving a dead mode nothing could implement).
namespace Volar.Speech.Hotkey;

/// <summary>Immutable hotkey configuration. <see cref="Default"/> reproduces the mac combo
/// (Control+Option+M, i.e. <c>kVK_ANSI_M</c> = 46 with the Carbon <c>controlKey|optionKey</c>
/// modifier mask) mapped to its literal Windows equivalent: Ctrl+Alt+M.</summary>
public sealed class HotkeyOptions
{
    /// <summary>Virtual-key code of the trigger key. Default <c>0x4D</c> ('M') — same physical key
    /// as mac's ⌃⌥M.</summary>
    public int VirtualKeyCode { get; init; } = 0x4D;

    public bool RequireControl { get; init; } = true;
    public bool RequireAlt { get; init; } = true;
    public bool RequireShift { get; init; }
    public bool RequireWindows { get; init; }

    /// <summary>Ctrl+Alt+M — the Windows mapping of the mac ⌃⌥M combo (see class doc comment).
    /// Toggle is the ONLY interaction mode this package implements (see file header), so unlike the
    /// previous revision this default is now interaction-identical to the mac source, not merely
    /// key-identical.</summary>
    public static HotkeyOptions Default => new();

    /// <summary>Converts this combo into the <c>(fsModifiers, vk)</c> pair that
    /// <c>RegisterHotKey</c>/<c>UnregisterHotKey</c> expect. Always OR's in
    /// <see cref="NativeMethods.MOD_NOREPEAT"/> so the OS itself suppresses WM_HOTKEY re-delivery
    /// while the key is held down — the RegisterHotKey-native replacement for the previous
    /// hook-based implementation's manual `_isDown` auto-repeat guard. This is correct parity, not
    /// a behavior change: the mac source also reacts once per physical press, never once per OS
    /// auto-repeat tick.</summary>
    internal (uint fsModifiers, uint vk) ToRegisterHotKeyArgs()
    {
        var fsModifiers = NativeMethods.MOD_NOREPEAT;
        if (RequireAlt) fsModifiers |= NativeMethods.MOD_ALT;
        if (RequireControl) fsModifiers |= NativeMethods.MOD_CONTROL;
        if (RequireShift) fsModifiers |= NativeMethods.MOD_SHIFT;
        if (RequireWindows) fsModifiers |= NativeMethods.MOD_WIN;
        return (fsModifiers, unchecked((uint)VirtualKeyCode));
    }

    /// <summary>Human-readable combo description for error messages (e.g. <c>"Ctrl+Alt+M"</c>) —
    /// used by <see cref="HotkeyManager"/> when <c>RegisterHotKey</c> fails, so the resulting
    /// exception names the exact combo that's unavailable rather than just a raw VK code. Only maps
    /// the common '0'-'9' / 'A'-'Z' trigger-key range to a literal character; anything else falls
    /// back to a "VK 0xNN" label rather than guessing wrong.</summary>
    internal string DescribeCombo()
    {
        var parts = new List<string>(5);
        if (RequireControl) parts.Add("Ctrl");
        if (RequireAlt) parts.Add("Alt");
        if (RequireShift) parts.Add("Shift");
        if (RequireWindows) parts.Add("Win");
        parts.Add(DescribeVirtualKey(VirtualKeyCode));
        return string.Join("+", parts);
    }

    private static string DescribeVirtualKey(int vk) => vk switch
    {
        >= 0x30 and <= 0x39 => ((char)vk).ToString(), // '0'-'9'
        >= 0x41 and <= 0x5A => ((char)vk).ToString(), // 'A'-'Z'
        _ => $"VK 0x{vk:X2}",
    };
}
