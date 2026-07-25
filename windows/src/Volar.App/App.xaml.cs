// App.xaml.cs — composition root. Builds the DI ServiceProvider (exposed as App.Services) with
// every Wave 2 seam registered per this task's brief, then creates the single MainWindow, the
// tray icon, and the global Ctrl+Alt+M hotkey.
using System;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Volar.App.Services;

namespace Volar.App;

public partial class App : Application
{
    /// <summary>The composition root's resolved provider — exposed statically per this task's
    /// brief so any part of the shell can resolve a Wave-2 seam without threading a provider
    /// reference through every constructor. TODO(W3-B): once a real DI-aware navigation/view-model
    /// layer exists (Wave 4+), prefer constructor injection over this static access.</summary>
    public static IServiceProvider Services { get; private set; } = null!;

    private MainWindow? _mainWindow;
    private TrayIconService? _tray;
    private HotkeyService? _hotkey;

    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        Services = CompositionRoot.Build();

        _mainWindow = new MainWindow();

        _hotkey = Services.GetRequiredService<HotkeyService>();
        _hotkey.OnToggle += () =>
        {
            // Marshal back to the UI thread — HotkeyManager.OnToggle fires on a thread-pool thread
            // (see Volar.Speech.Hotkey.HotkeyManager's doc comment).
            _mainWindow.DispatcherQueue.TryEnqueue(() =>
            {
                _mainWindow.ShowAndActivate();
            });
        };
        _hotkey.TryStart();

        _tray = new TrayIconService(
            onOpen: () => _mainWindow.DispatcherQueue.TryEnqueue(_mainWindow.ShowAndActivate),
            onNewTask: () => _mainWindow.DispatcherQueue.TryEnqueue(() =>
            {
                _mainWindow.ShowAndActivate();
                _hotkey?.LogStubToggle();
            }),
            onSettings: () => _mainWindow.DispatcherQueue.TryEnqueue(_mainWindow.ShowAndActivate),
            onPreviewReminder: () => _mainWindow.DispatcherQueue.TryEnqueue(_mainWindow.ShowAndActivate),
            onQuit: () =>
            {
                _hotkey?.Stop();
                _mainWindow?.AllowRealClose();
                _mainWindow?.Close();
                Exit();
            });
        _tray.Initialize();

        _mainWindow.ShowAndActivate();
    }
}
