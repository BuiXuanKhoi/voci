// CaptureWindow.xaml.cs — see CaptureWindow.xaml header for the bug this fixes, why this file lives
// at the project root next to MainWindow.xaml.cs rather than under Views/, and the overall design.
// This file owns: presenter setup (borderless/always-on-top/switcher-hidden),
// DPI-correct sizing+positioning on the monitor under the cursor, and the Esc/Enter keyboard
// routing CapturePopover.xaml's own header says used to live on MainWindow's root accelerators.
//
// LIFECYCLE CONTRACT (self-review item 3 — "created once, reused; does closing it kill the app?"):
//   - Constructed exactly once, by MainWindow.xaml.cs's ComposeCapturePopover, and stored in a field
//     for MainWindow's own lifetime (which is the app's lifetime — MainWindow never really closes
//     either, see its own OnAppWindowClosing). Never constructed per-capture.
//   - Shown/hidden via ShowNearCursor()/HideWindow() (AppWindow.Show/Hide) — the underlying HWND is
//     never destroyed by normal capture start/stop, so there is nothing to leak or re-flicker.
//   - OnAppWindowClosing below cancels any close attempt and hides instead, mirroring MainWindow's
//     own "X hides, doesn't exit" contract. This matters here specifically because this window CAN
//     receive keyboard focus (Esc/Enter routing needs it to) and is briefly the foreground window
//     while visible, so Alt+F4 landing on it is a real (if unlikely) path — without this guard that
//     would destroy the HWND and, per WinUI3's default "exit when the last window closes" behavior,
//     could plausibly take the whole process down with it (MainWindow is hidden, not gone, so it
//     would likely survive as "the last window" either way — this guard removes the need to rely on
//     that ordering at all).
using System;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Input;
using Volar.App.ViewModels;
using Volar.App.Views;
using Windows.Graphics;
using WinRT.Interop;

namespace Volar.App;

public sealed partial class CaptureWindow : Window
{
    // Fallback content size before the popover's own SizeChanged has fired even once — matches
    // CapturePopover.xaml's own GlassPanel Width="380" plus a little slack for its Border padding
    // (14/14/14/12, CapturePopover.xaml's own header) so the very first ShowNearCursor() never
    // flashes at 0x0 for a frame.
    private const double FallbackWidthDip = 380;
    private const double FallbackHeightDip = 120;

    // "upper third vertically" (this task's brief): the window's own vertical CENTER lands 1/3 of
    // the way down the current monitor's work area, clamped so it never clips above the work area
    // top on a short/narrow display.
    private const double VerticalCenterFraction = 1.0 / 3.0;
    private const int MinTopMarginPx = 16;

    private readonly AppWindow _appWindow;
    private CapturePopoverViewModel? _viewModel;

    public CaptureWindow()
    {
        InitializeComponent();

        var hWnd = WindowNative.GetWindowHandle(this);
        var windowId = Win32Interop.GetWindowIdFromWindow(hWnd);
        _appWindow = AppWindow.GetFromWindowId(windowId);

        // CreateForContextMenu() is WinUI's own built-in factory for exactly this shape of window
        // (non-resizable, non-maximizable/minimizable, no border/title bar, always-on-top) — the
        // explicit calls below restate the two properties this task's brief calls out by name so
        // the intent survives even if a future Windows App SDK version changes that factory's
        // defaults.
        var presenter = OverlappedPresenter.CreateForContextMenu();
        presenter.IsAlwaysOnTop = true;
        presenter.SetBorderAndTitleBar(false, false);
        _appWindow.SetPresenter(presenter);

        // Never in the taskbar or Alt-Tab — this task's brief, and consistent with this being a
        // transient input surface, not a real window a user would ever want to switch to directly.
        _appWindow.IsShownInSwitchers = false;

        // No window-level backdrop material (see CaptureWindow.xaml's header comment for why —
        // GlassPanel already supplies the one translucent surface this design wants).
        SystemBackdrop = null;

        _appWindow.Closing += OnAppWindowClosing;
    }

    /// <summary>Set once by MainWindow.xaml.cs's ComposeCapturePopover, to the SAME
    /// <see cref="CapturePopoverViewModel"/> instance MainWindow's shell composition already builds
    /// — this window is a second mount point for that one VM, never a second VM (no capture-logic
    /// duplication, per this task's brief).</summary>
    public CapturePopoverViewModel? ViewModel
    {
        get => _viewModel;
        set
        {
            _viewModel = value;
            Popover.ViewModel = value;
        }
    }

    /// <summary>Sizes+positions against whichever monitor currently has the cursor, THEN shows and
    /// activates (so Esc/Enter reach this window's own accelerators immediately) — called every time
    /// <see cref="Services.State.CaptureFlowService.CaptureChanged"/> transitions away from Idle, so
    /// a hotkey pressed on a different monitor/DPI than last time always re-resolves both.</summary>
    public void ShowNearCursor()
    {
        PositionAndSize();
        _appWindow.Show(true);
    }

    /// <summary>Hides (AppWindow.Hide — does NOT destroy the HWND) whenever CaptureFlowService
    /// returns to Idle. See this file's header for why this window is never Close()'d as part of
    /// normal show/hide.</summary>
    public void HideWindow() => _appWindow.Hide();

    /// <summary>CapturePopover.xaml.cs's Render() rebuilds its whole child tree on every VM
    /// PropertyChanged (that file's own header) — height changes constantly as capture moves through
    /// its states (listening -&gt; transcript -&gt; parsed card -&gt; actions, etc.). Re-run the same
    /// DPI-correct sizing/positioning math on every one of those changes, but only while actually
    /// visible (avoids fighting the initial ShowNearCursor() sizing pass with a redundant SizeChanged
    /// that can fire from the very first layout pass before Show).</summary>
    private void OnPopoverSizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (_appWindow.IsVisible)
        {
            PositionAndSize();
        }
    }

    /// <summary>The DPI-correctness core of this task. <see cref="AppWindow.ResizeClient"/>/
    /// <see cref="AppWindow.Move"/> both operate in RAW PHYSICAL pixels — NOT the DIP/effective-pixel
    /// units every XAML Width/Height/Margin in this codebase is authored in — so a window shown on a
    /// monitor at anything other than 100% scaling needs its DIP-measured content size explicitly
    /// multiplied by that monitor's own scale factor before calling either API; skipping this step is
    /// exactly the classic Windows multi-monitor/mixed-DPI bug this task warns about (a window that
    /// is the wrong physical size, or centered against the wrong monitor's bounds, the moment a
    /// second display at a different scale factor is involved). <see cref="DisplayArea.WorkArea"/> is
    /// itself already in physical pixels (Windows' own <c>DisplayArea</c> API surface), so it is used
    /// as-is with no conversion once resolved for the monitor under the cursor.</summary>
    private void PositionAndSize()
    {
        NativeMethods.GetCursorPos(out var cursor);
        var displayArea = DisplayArea.GetFromPoint(new PointInt32(cursor.X, cursor.Y), DisplayAreaFallback.Nearest);
        var workArea = displayArea.WorkArea;

        // DPI is deliberately queried for the TARGET monitor (the one under the cursor, via
        // MonitorFromPoint), NOT via GetDpiForWindow(thisWindow'sOwnHwnd) — this window may currently
        // still be sitting on a DIFFERENT, differently-scaled monitor from the last time it was shown
        // (e.g. the user pressed the hotkey on Monitor B this time, having last captured on Monitor A
        // at a different scale factor). GetDpiForWindow reports the CURRENT monitor's DPI, which is
        // only correct AFTER a move — querying it before Move/ResizeClient below would size this
        // window using the WRONG monitor's scale for this one call (the classic mixed-DPI bug this
        // task warns about). MonitorFromPoint + GetDpiForMonitor resolve the correct DPI up front,
        // independent of where the HWND happens to be sitting right now.
        var monitor = NativeMethods.MonitorFromPoint(cursor, NativeMethods.MONITOR_DEFAULTTONEAREST);
        NativeMethods.GetDpiForMonitor(monitor, NativeMethods.MDT_EFFECTIVE_DPI, out var dpiX, out _);
        var scale = dpiX / 96.0;

        var contentWidthDip = Popover.ActualWidth > 0 ? Popover.ActualWidth : FallbackWidthDip;
        var contentHeightDip = Popover.ActualHeight > 0 ? Popover.ActualHeight : FallbackHeightDip;
        var widthPx = (int)Math.Ceiling(contentWidthDip * scale);
        var heightPx = (int)Math.Ceiling(contentHeightDip * scale);

        _appWindow.ResizeClient(new SizeInt32(widthPx, heightPx));

        var x = workArea.X + ((workArea.Width - widthPx) / 2);
        var y = workArea.Y + (int)(workArea.Height * VerticalCenterFraction) - (heightPx / 2);
        y = Math.Max(workArea.Y + MinTopMarginPx, y);
        _appWindow.Move(new PointInt32(x, y));
    }

    /// <summary>Port of MainWindow.xaml.cs's old CaptureScrimHost-gated OnEscapeAccelerator branch —
    /// unconditional here since this window is only ever visible while a capture is in progress (see
    /// MainWindow.xaml.cs's UpdateCaptureWindowVisibility), so there is no "is the scrim showing"
    /// check left to make.</summary>
    private void OnEscapeAccelerator(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        _viewModel?.HandleEscape();
    }

    /// <summary>Port of MainWindow.xaml.cs's old CaptureScrimHost-gated OnEnterAccelerator branch —
    /// see OnEscapeAccelerator's doc comment for why the guard is gone.</summary>
    private void OnEnterAccelerator(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        _viewModel?.HandlePrimaryEnter();
    }

    /// <summary>Never actually destroys this window — mirrors MainWindow.xaml.cs's own
    /// OnAppWindowClosing exactly (same "X hides, doesn't exit" contract). See this file's header
    /// for why a stray close reaching this window at all is worth guarding against even though
    /// nothing in this task's own code ever calls Close() on it.</summary>
    private void OnAppWindowClosing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        args.Cancel = true;
        _appWindow.Hide();
    }

    /// <summary>Tiny private P/Invoke surface, kept local to this file rather than added to the
    /// existing Services/TrayNativeMethods.cs (out of this task's file-ownership list) or duplicated
    /// against it — reuses that file's own <c>GetCursorPos</c>/<c>POINT</c> (same assembly, already
    /// internal-visible) instead of redeclaring them, and adds only the two extra P/Invokes
    /// (<c>MonitorFromPoint</c>/<c>GetDpiForMonitor</c>) this file actually needs that
    /// TrayNativeMethods does not already have — see PositionAndSize's own doc comment for why DPI is
    /// resolved this way instead of via <c>GetDpiForWindow</c>.</summary>
    private static class NativeMethods
    {
        public const uint MONITOR_DEFAULTTONEAREST = 2;
        public const int MDT_EFFECTIVE_DPI = 0;

        [System.Runtime.InteropServices.DllImport("user32.dll")]
        public static extern nint MonitorFromPoint(Services.TrayNativeMethods.POINT pt, uint dwFlags);

        [System.Runtime.InteropServices.DllImport("shcore.dll")]
        public static extern int GetDpiForMonitor(nint hmonitor, int dpiType, out uint dpiX, out uint dpiY);

        public static bool GetCursorPos(out Services.TrayNativeMethods.POINT point) =>
            Services.TrayNativeMethods.GetCursorPos(out point);
    }
}
