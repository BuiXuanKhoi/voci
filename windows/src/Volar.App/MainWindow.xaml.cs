// MainWindow.xaml.cs — the single top-level window ("Volar"), hosting a placeholder Today view.
// Menu-bar-app behavior (mirrors Sources/App/VolarApp.swift's LSUIElement Window group): closing
// this window via the title-bar X does NOT exit the process — it hides the window instead. Only
// the tray "Quit Volar" command (TrayIconService) actually terminates the app. Real TodayView
// content is Wave 4 — this hosts only a placeholder per this task's brief.
using System;
using System.Diagnostics;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Volar.App.Services;
using Volar.App.Services.State;
using WinRT.Interop;

namespace Volar.App;

public sealed partial class MainWindow : Window
{
    private const int MinWidth = 820;
    private const int MinHeight = 560;

    private readonly AppWindow _appWindow;
    private readonly CaptureFlowService _captureFlow;
    private bool _allowClose;

    public MainWindow()
    {
        InitializeComponent();
        Title = "Volar";

        var hWnd = WindowNative.GetWindowHandle(this);
        var windowId = Win32Interop.GetWindowIdFromWindow(hWnd);
        _appWindow = AppWindow.GetFromWindowId(windowId);

        // Reasonable default/min size — real TodayView layout constraints are Wave 4's concern.
        _appWindow.Resize(new Windows.Graphics.SizeInt32(MinWidth, MinHeight));

        _appWindow.Closing += OnAppWindowClosing;
        FooterText.Text = $"PID {Environment.ProcessId} — DI graph resolved OK";

        // Real wiring (Wave 3-C, C5) — a placeholder button, but a real service call. The full Today
        // view binding (task list, live capture state, etc.) is Wave 4's job; this only proves the
        // one interactive control this shell has actually reaches CaptureFlowService end to end.
        _captureFlow = App.Services.GetRequiredService<CaptureFlowService>();
        _captureFlow.CaptureChanged += OnCaptureChanged;
        UpdateStatusText();
    }

    /// <summary>CaptureFlowService.CaptureChanged carries no thread guarantee of its own (that
    /// class's own doc comment: "may run on whichever thread an ISpeechEngine.OnFinal/OnError
    /// callback happens to fire on") — marshal before touching any XAML element, per this wave's
    /// UI-thread-discipline rule.</summary>
    private void OnCaptureChanged() => DispatcherQueue.TryEnqueue(UpdateStatusText);

    private void UpdateStatusText()
    {
        StatusText.Text = _captureFlow.State switch
        {
            CaptureState.Recording => "Listening…",
            CaptureState.Parsing => "Parsing…",
            CaptureState.Parsed => $"{_captureFlow.ConfirmDrafts.Count} draft(s) ready — full review is Wave 4.",
            CaptureState.Saving => "Saving…",
            CaptureState.Done => "Saved.",
            CaptureState.Error => _captureFlow.CaptureErrorDetail ?? "Something went wrong.",
            _ => "Shell OK. Wave 4 will replace this with the real Today view.",
        };
    }

    /// <summary>
    /// Menu-bar-style close: hides the window instead of letting the OS destroy it, unless
    /// <see cref="AllowRealClose"/> was called first (the tray "Quit Volar" path).
    /// </summary>
    private void OnAppWindowClosing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (_allowClose)
        {
            return;
        }

        args.Cancel = true;
        _appWindow.Hide();
    }

    /// <summary>Called by TrayIconService's "Quit Volar" handler before actually exiting.</summary>
    public void AllowRealClose() => _allowClose = true;

    public void ShowAndActivate()
    {
        _appWindow.Show();
        Activate();
    }

    private void CaptureButton_Click(object sender, RoutedEventArgs e)
    {
        _ = ToggleCaptureSafeAsync();
        ShowAndActivate();
    }

    private async Task ToggleCaptureSafeAsync()
    {
        try
        {
            await _captureFlow.ToggleCaptureAsync().ConfigureAwait(true);
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[Volar.App.MainWindow] ToggleCaptureAsync failed: {ex.GetType().Name}");
        }
    }
}
