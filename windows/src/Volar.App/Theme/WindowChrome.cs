// Theme/WindowChrome.cs — paints the OS-drawn window frame (border, caption bar, caption text) in
// Volar Twilight tokens.
//
// WHY THIS EXISTS: this app does NOT extend content into the title bar, so the caption bar and the
// 1px window border are drawn by DWM, not by XAML — Colors.xaml can't reach them. With only
// `RequestedTheme="Dark"` set (App.xaml) Windows still draws that border in its own default, which
// on Windows 11 reads as a bright near-white hairline around a very dark window: the one white line
// on an otherwise night-blue app. The fix is DwmSetWindowAttribute, which is also the only
// supported way to colour the border at all.
//
// Values are the Twilight tokens, converted to Win32 COLORREF (0x00BBGGRR — byte order is the
// REVERSE of the #RRGGBB the XAML uses; getting this backwards silently yields a plausible-looking
// wrong colour, so each constant below documents both forms).
//
// Every call is best-effort: DWMWA_BORDER_COLOR/CAPTION_COLOR/TEXT_COLOR need Windows 11 build
// 22000+, and DwmSetWindowAttribute simply returns a failure HRESULT on Windows 10 (this app's
// floor) rather than throwing. A machine that doesn't support them keeps the system default frame,
// which is exactly the pre-existing behaviour — so the return codes are deliberately ignored.
using System.Runtime.InteropServices;

namespace Volar.App.Theme;

internal static class WindowChrome
{
    private const int DwmwaUseImmersiveDarkMode = 20;
    private const int DwmwaBorderColor = 34;
    private const int DwmwaCaptionColor = 35;
    private const int DwmwaTextColor = 36;

    /// <summary>VolarBorder over VolarBg, flattened to an opaque colour — DWM takes no alpha.
    /// #1B2434 (a Twilight edge tone) -> COLORREF 0x0034241B.</summary>
    private const int BorderColorRef = 0x0034241B;

    /// <summary>VolarBg #07090E -> COLORREF 0x000E0907.</summary>
    private const int CaptionColorRef = 0x000E0907;

    /// <summary>VolarTextSec #9AA7BC -> COLORREF 0x00BCA79A.</summary>
    private const int CaptionTextColorRef = 0x00BCA79A;

    [DllImport("dwmapi.dll", ExactSpelling = true)]
    private static extern int DwmSetWindowAttribute(nint hwnd, int attribute, ref int value, int size);

    /// <summary>Applies the Twilight frame to <paramref name="hwnd"/>. Safe to call on any OS
    /// version and safe to call more than once.</summary>
    public static void Apply(nint hwnd)
    {
        if (hwnd == 0)
        {
            return;
        }

        // Dark mode first: it drives the caption BUTTON glyphs (minimise/maximise/close), which the
        // colour attributes below do not cover — without it those stay dark-on-dark.
        var darkMode = 1;
        _ = DwmSetWindowAttribute(hwnd, DwmwaUseImmersiveDarkMode, ref darkMode, sizeof(int));

        var border = BorderColorRef;
        _ = DwmSetWindowAttribute(hwnd, DwmwaBorderColor, ref border, sizeof(int));

        var caption = CaptionColorRef;
        _ = DwmSetWindowAttribute(hwnd, DwmwaCaptionColor, ref caption, sizeof(int));

        var text = CaptionTextColorRef;
        _ = DwmSetWindowAttribute(hwnd, DwmwaTextColor, ref text, sizeof(int));
    }
}
