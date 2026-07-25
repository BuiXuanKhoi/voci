// MainWindow.xaml.cs — the single top-level window ("Volar"), hosting a placeholder Today view.
// Menu-bar-app behavior (mirrors Sources/App/VolarApp.swift's LSUIElement Window group): closing
// this window via the title-bar X does NOT exit the process — it hides the window instead. Only
// the tray "Quit Volar" command (TrayIconService) actually terminates the app. Real TodayView
// content is Wave 4 — this hosts only a placeholder per this task's brief.
using System;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Volar.App.Services;
using WinRT.Interop;

namespace Volar.App;

public sealed partial class MainWindow : Window
{
    private const int MinWidth = 820;
    private const int MinHeight = 560;

    private readonly AppWindow _appWindow;
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
        // TODO(W3-B): wire to the real capture flow (ISpeechEngine.Start -> IntentRouter.ParseAsync
        // -> TaskRepository). For this shell, mirror the hotkey toggle's stub behavior.
        StatusText.Text = "Capture toggled (stub) — real pipeline is Wave 3-B/4.";
        ShowAndActivate();
    }
}
