// Views/SettingsView.xaml.cs — see SettingsView.xaml header. Port of
// Volar/Sources/Views/SettingsView.swift (958 lines).
//
// FileOpenPicker/FolderPicker live HERE (not the VM) per wave4-contract.md's VM rule — both need a
// window handle, so this code-behind exposes <see cref="OwnerWindowHandle"/> for whoever mounts
// this view (Stage C) to set once, mirroring the same seam every Wave-4 view needing a picker uses.
using System.ComponentModel;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Shapes;
using Volar.App.Services.Account;
using Volar.App.Services.State;
using Volar.App.ViewModels;
using Volar.Reminders;
using Volar.Speech.Ambient;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace Volar.App.Views;

public sealed partial class SettingsView : UserControl
{
    private enum Tab
    {
        General,
        Hotkeys,
        Notifications,
        Appearance,
        Integrations,
        Account,
        About,
    }

    private sealed record TabDef(Tab Tab, string Label, Controls.VolarIconName Icon, Func<FrameworkElement> Builder);

    private SettingsViewModel? _viewModel;
    private AccountViewModel? _accountViewModel;
    private Tab _selectedTab = Tab.General;
    private readonly List<(Tab Tab, Button Button)> _tabButtons = new();
    private DispatcherQueueTimer? _receiptTimer;
    private TabDef[] _tabs = Array.Empty<TabDef>();

    public SettingsView()
    {
        InitializeComponent();
        Unloaded += OnUnloaded;
    }

    /// <summary>Set by whoever mounts this overlay (Stage C) before any picker can be used —
    /// <see cref="Windows.Storage.Pickers.FileOpenPicker"/>/<see cref="FolderPicker"/> both require
    /// <c>IInitializeWithWindow</c> in an unpackaged desktop app.</summary>
    public nint OwnerWindowHandle { get; set; }

    /// <summary>Port of Swift's implicit "Settings window closes" affordance (a real macOS window
    /// has its own close box) — this overlay has none, so <see cref="CloseButton"/>/the scrim tap
    /// raise this for Stage C to hide the overlay.</summary>
    public event EventHandler? CloseRequested;

    public void Attach(SettingsViewModel viewModel)
    {
        if (_viewModel is not null)
        {
            _viewModel.PropertyChanged -= OnViewModelPropertyChanged;
        }
        _viewModel = viewModel ?? throw new ArgumentNullException(nameof(viewModel));
        _viewModel.PropertyChanged += OnViewModelPropertyChanged;

        // Account tab (2026-07-26 account-auth contract): resolved off the app-wide DI container
        // rather than threaded through SettingsViewModel's own constructor — MainWindow.xaml.cs
        // constructs SettingsViewModel with a fixed positional argument list outside this task's
        // file-ownership scope, so App.Services (already the seam every other Wave-3-C service is
        // resolved through post-construction, e.g. App.xaml.cs's WireHotkey/WireTray) is used here
        // instead. Constructed once per Attach() call (mirrors _viewModel's own one-per-Attach
        // lifetime) and reuses THIS view's own DispatcherQueue for UI-thread marshaling, same as
        // every other Wave-4 VM.
        if (_accountViewModel is not null)
        {
            _accountViewModel.PropertyChanged -= OnViewModelPropertyChanged;
        }
        var accountService = Volar.App.App.Services.GetRequiredService<IAccountService>();
        _accountViewModel = new AccountViewModel(accountService, DispatcherQueue);
        _accountViewModel.PropertyChanged += OnViewModelPropertyChanged;

        _tabs = new[]
        {
            new TabDef(Tab.General, "General", Controls.VolarIconName.Settings, BuildGeneralTab),
            new TabDef(Tab.Hotkeys, "Hotkeys", Controls.VolarIconName.Cmd, BuildHotkeysTab),
            new TabDef(Tab.Notifications, "Notifications", Controls.VolarIconName.Bell, BuildNotificationsTab),
            new TabDef(Tab.Appearance, "Appearance", Controls.VolarIconName.Sparkle, BuildAppearanceTab),
            new TabDef(Tab.Integrations, "Integrations", Controls.VolarIconName.Bolt, BuildIntegrationsTab),
            // VolarIconName has no dedicated "account/person" case (frozen 28-case 1:1 port of the
            // Swift enum, views-inventory.md — adding a new case is out of this task's scope) —
            // Flag reused as the closest available stand-in; purely cosmetic.
            new TabDef(Tab.Account, "Account", Controls.VolarIconName.Flag, BuildAccountTab),
            new TabDef(Tab.About, "About", Controls.VolarIconName.Project, BuildAboutTab),
        };
        BuildTabStrip();
        SelectTab(Tab.General);

        // Decision 12: timer-driven state (the test-signal receipt poll) owned by the VM's HOST —
        // this view. PollAppLinkReceipt() is a cheap no-op whenever nothing is awaiting receipt.
        _receiptTimer = DispatcherQueue.CreateTimer();
        _receiptTimer.Interval = TimeSpan.FromMilliseconds(500);
        _receiptTimer.Tick += (_, _) => _viewModel?.PollAppLinkReceipt();
        _receiptTimer.Start();
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        _receiptTimer?.Stop();
        if (_viewModel is not null)
        {
            _viewModel.PropertyChanged -= OnViewModelPropertyChanged;
        }
        if (_accountViewModel is not null)
        {
            _accountViewModel.PropertyChanged -= OnViewModelPropertyChanged;
        }
    }

    private void OnViewModelPropertyChanged(object? sender, PropertyChangedEventArgs e) =>
        DispatcherQueue.TryEnqueue(() => RebuildCurrentTab());

    private void OnScrimTapped(object sender, TappedRoutedEventArgs e) => CloseRequested?.Invoke(this, EventArgs.Empty);

    private void OnCloseButtonClick(object sender, RoutedEventArgs e) => CloseRequested?.Invoke(this, EventArgs.Empty);

    // ============================================================================================
    // MARK: - Tab strip (SettingsView.swift:86-116)
    // ============================================================================================

    private void BuildTabStrip()
    {
        TabStripPanel.Children.Clear();
        _tabButtons.Clear();

        foreach (var tab in _tabs)
        {
            var stack = new StackPanel { Spacing = 4, HorizontalAlignment = HorizontalAlignment.Center };
            var icon = new Controls.VolarIcon { IconName = tab.Icon, IconSize = 18 };
            var label = new TextBlock
            {
                Text = tab.Label,
                FontSize = 11,
                FontWeight = FontWeights.Medium,
                HorizontalAlignment = HorizontalAlignment.Center,
            };
            stack.Children.Add(icon);
            stack.Children.Add(label);

            var button = new Button
            {
                Content = stack,
                Padding = new Thickness(14, 6, 14, 6),
                MinWidth = 72,
                CornerRadius = new CornerRadius(8), // one-off literal, SettingsView.swift:103.
                BorderThickness = new Thickness(0),
                Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
                Tag = tab.Tab,
            };
            SuppressStockButtonChrome(button);
            button.Click += (_, _) => SelectTab((Tab)((Button)button).Tag);

            _tabButtons.Add((tab.Tab, button));
            TabStripPanel.Children.Add(button);
        }
    }

    private void SelectTab(Tab tab)
    {
        _selectedTab = tab;
        UpdateTabStripVisuals();

        if (tab == Tab.Integrations)
        {
            // Port of the `.task` modifier (SettingsView.swift:528-531) — re-checked every time the
            // tab is (re)shown, same "picks up an install without relaunching" intent Swift's own
            // comment calls out.
            _viewModel?.InitializeIntegrationsTab();
        }
        RebuildCurrentTab();
    }

    private void RebuildCurrentTab()
    {
        if (_viewModel is null)
        {
            return;
        }
        var def = Array.Find(_tabs, t => t.Tab == _selectedTab);
        ContentHost.Content = def?.Builder();
    }

    private void UpdateTabStripVisuals()
    {
        var appResources = Application.Current.Resources;
        var accentSolid = (Brush)appResources["AccentSolidBrush"];
        var accentSurface = (Brush)appResources["AccentSurfaceBrush"];
        var textSec = (Brush)appResources["VolarTextSecBrush"];
        var transparent = new SolidColorBrush(Microsoft.UI.Colors.Transparent);

        foreach (var (tab, button) in _tabButtons)
        {
            var selected = tab == _selectedTab;
            button.Background = selected ? accentSurface : transparent;
            var stack = (StackPanel)button.Content;
            var icon = (Controls.VolarIcon)stack.Children[0];
            var label = (TextBlock)stack.Children[1];
            icon.IconBrush = selected ? accentSolid : textSec;
            label.Foreground = selected ? accentSolid : textSec;
        }
    }

    // ============================================================================================
    // MARK: - Row builder (SettingsView.swift's private SettingsRow, lines 756-783)
    // ============================================================================================

    private static FrameworkElement BuildRow(string label, string? hint, FrameworkElement control)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var textStack = new StackPanel { Spacing = 3, VerticalAlignment = VerticalAlignment.Center };
        textStack.Children.Add(new TextBlock
        {
            Text = label,
            FontSize = 13.5,
            FontWeight = FontWeights.Medium,
            Foreground = (Brush)Application.Current.Resources["VolarTextPriBrush"],
            TextWrapping = TextWrapping.Wrap,
        });
        if (hint is not null)
        {
            textStack.Children.Add(new TextBlock
            {
                Text = hint,
                FontSize = 12,
                Foreground = (Brush)Application.Current.Resources["VolarTextSecBrush"],
                TextWrapping = TextWrapping.Wrap,
                LineHeight = 16,
            });
        }
        Grid.SetColumn(textStack, 0);
        grid.Children.Add(textStack);

        control.HorizontalAlignment = HorizontalAlignment.Right;
        control.VerticalAlignment = VerticalAlignment.Center;
        control.Margin = new Thickness(12, 0, 0, 0);
        Grid.SetColumn(control, 1);
        grid.Children.Add(control);

        return new Border
        {
            Padding = new Thickness(18, 14, 18, 14), // SettingsView.swift:777-778.
            CornerRadius = new CornerRadius(11), // one-off literal recurring 3x, views-inventory.md SS1.15 point 4.
            BorderThickness = new Thickness(0.5),
            Background = (Brush)Application.Current.Resources["VolarCardBrush"],
            BorderBrush = (Brush)Application.Current.Resources["VolarGlassBorderBrush"],
            Child = grid,
        };
    }

    private static ComboBox BuildComboBox<T>(IReadOnlyList<T> items, Func<T, string> label, T selected, Action<T> onSelected)
        where T : notnull
    {
        var box = new ComboBox { Width = 220 };
        foreach (var item in items)
        {
            box.Items.Add(new ComboBoxItem { Content = label(item), Tag = item });
        }
        box.SelectedIndex = items.ToList().IndexOf(selected);
        box.SelectionChanged += (_, _) =>
        {
            if (box.SelectedItem is ComboBoxItem { Tag: T value })
            {
                onSelected(value);
            }
        };
        return box;
    }

    private static TextBlock BuildStatusText(string text) => new()
    {
        Text = text,
        FontSize = 12,
        FontWeight = FontWeights.Medium,
        Foreground = (Brush)Application.Current.Resources["VolarTextSecBrush"],
    };

    /// <summary>Same stock-chrome-suppression trick as Segmented/other plain buttons in this wave —
    /// see Segmented.xaml.cs's own doc comment for why.</summary>
    private static void SuppressStockButtonChrome(Button button)
    {
        var transparent = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        button.Resources["ButtonBackgroundPointerOver"] = transparent;
        button.Resources["ButtonBackgroundPressed"] = transparent;
        button.Resources["ButtonBorderBrushPointerOver"] = transparent;
        button.Resources["ButtonBorderBrushPressed"] = transparent;
    }

    private static Button BuildPillButton(string text, bool solid, RoutedEventHandler onClick)
    {
        var appResources = Application.Current.Resources;
        var button = new Button
        {
            Content = new TextBlock { Text = text, FontSize = 12.5, FontWeight = FontWeights.Medium },
            Padding = new Thickness(14, 0, 14, 0),
            Height = 30,
            CornerRadius = new CornerRadius(8),
            BorderThickness = new Thickness(0.5),
            Background = solid ? (Brush)appResources["AccentSolidBrush"] : (Brush)appResources["VolarSurfaceHiBrush"],
            BorderBrush = solid ? new SolidColorBrush(Windows.UI.Color.FromArgb(0x2E, 255, 255, 255)) : (Brush)appResources["VolarBorderHiBrush"],
            Foreground = solid ? new SolidColorBrush(Microsoft.UI.Colors.White) : (Brush)appResources["VolarTextPriBrush"],
        };
        SuppressStockButtonChrome(button);
        button.Click += onClick;
        return button;
    }

    // ============================================================================================
    // MARK: - General tab
    // ============================================================================================

    private FrameworkElement BuildGeneralTab()
    {
        var vm = _viewModel!;
        var stack = new StackPanel { Spacing = 12 };

        stack.Children.Add(BuildRow(
            "Speech engine",
            "On-device (Whisper.net) stays private and free. Groq is cloud — it sends your audio for the best multilingual/Vietnamese accuracy.",
            BuildComboBox(SettingsViewModel.SpeechEngineChoices, SettingsViewModel.Label, vm.SpeechEngineChoice, vm.SetSpeechEngine)));

        if (vm.ShowWhisperStatusRow)
        {
            stack.Children.Add(BuildRow(
                "Whisper model",
                "First use downloads a small on-device model (~148MB, Whisper.net) and caches it locally.",
                BuildStatusText(vm.WhisperStatusText)));
        }
        if (vm.ShowGroqNotConfiguredRow)
        {
            stack.Children.Add(BuildRow(
                "Groq status",
                "Groq cloud transcription is a Pro feature — sign in and upgrade in the Account tab to enable it. Until then Volar uses the on-device engine.",
                BuildStatusText("Not configured — using on-device")));
        }

        stack.Children.Add(BuildRow(
            "Task parsing",
            "On-device stays private and free. Cloud AI sends only the TEXT of what you said (never audio) to our proxy for higher-quality parsing of trickier phrasing.",
            BuildComboBox(SettingsViewModel.ParseEnginePreferences, SettingsViewModel.Label, vm.ParseEnginePreference, vm.SetParseEngine)));

        if (vm.ShowCloudParseNotConfiguredRow)
        {
            stack.Children.Add(BuildRow(
                "Cloud parsing status",
                "Sign in (Account tab) to enable cloud parsing — every signed-in account gets a daily quota, free or Pro. Until you sign in, Volar quietly uses on-device parsing.",
                BuildStatusText("Not configured — using on-device")));
        }

        stack.Children.Add(BuildRow(
            "Launch at login",
            "Volar starts in the background and lives in your system tray.",
            BuildToggle(vm.LaunchAtLogin, vm.SetLaunchAtLogin)));

        stack.Children.Add(BuildRow(
            "Default task duration",
            "Block this much time when a task has no explicit length.",
            BuildIntSegmented(new[] { (15, "15"), (30, "30"), (60, "60 min") }, vm.DefaultTaskDurationMinutes, vm.SetDefaultTaskDurationMinutes)));

        stack.Children.Add(BuildRow(
            "Hyperfocus interrupt after",
            "Volar checks in if you've been deep on one task this long.",
            BuildIntSegmented(new[] { (60, "60"), (90, "90"), (120, "120 min") }, vm.HyperfocusInterruptMinutes, vm.SetHyperfocusInterruptMinutes)));

        stack.Children.Add(BuildRow(
            "Show morning frog prompt",
            "A daily question at first launch: what's the ONE task that matters most?",
            BuildToggle(vm.ShowMorningFrogPrompt, vm.SetShowMorningFrogPrompt)));

        stack.Children.Add(BuildRow(
            "Capture foreground app context",
            "Tags new tasks with the app you were in when you captured them.",
            BuildToggle(vm.CaptureAppContext, vm.SetCaptureAppContext)));

        var calendarRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        calendarRow.Children.Add(BuildToggle(vm.CalendarIntegration, vm.SetCalendarIntegration));
        calendarRow.Children.Add(BuildPillButton("Open in Calendar", solid: false, (_, _) => { })); // decorative no-op, matches SettingsView.swift:238 (`Button("Open in Calendar") {}`).
        stack.Children.Add(BuildRow("Calendar integration", "Mirror tasks with scheduled times into your calendar.", calendarRow));

        return new ScrollViewer { Content = stack, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled };
    }

    private static Controls.VolarToggle BuildToggle(bool isOn, Action<bool> onToggled)
    {
        var toggle = new Controls.VolarToggle { IsOn = isOn };
        toggle.Toggled += (_, value) => onToggled(value);
        return toggle;
    }

    private static Controls.Segmented BuildIntSegmented(IReadOnlyList<(int Id, string Label)> options, int selected, Action<int> onSelected)
    {
        var segmented = new Controls.Segmented
        {
            Options = options.Select(o => new Controls.SegmentOption(o.Id, o.Label)).ToList(),
            SelectedId = selected,
        };
        segmented.SelectionChanged += (_, id) => onSelected((int)id);
        return segmented;
    }

    // ============================================================================================
    // MARK: - Hotkeys tab (SettingsView.swift:254-284) — display-only, see KeyRecorder.xaml header.
    // ============================================================================================

    private FrameworkElement BuildHotkeysTab()
    {
        var stack = new StackPanel { Spacing = 12 };

        stack.Children.Add(BuildRow(
            "Quick capture",
            "Press this combo from anywhere to toggle recording — press to start, press again to stop.",
            new Controls.KeyRecorder { Keys = new[] { "Ctrl", "Alt", "M" } }));

        var longPressRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        longPressRow.Children.Add(new TextBlock
        {
            Text = "Long-press",
            FontSize = 11,
            Foreground = (Brush)Application.Current.Resources["VolarTextSecBrush"],
            VerticalAlignment = VerticalAlignment.Center,
        });
        longPressRow.Children.Add(new Controls.KeyBadge { Text = "Ctrl" });
        longPressRow.Children.Add(new Controls.KeyBadge { Text = "Alt" });
        longPressRow.Children.Add(new Controls.KeyBadge { Text = "M" });
        var longPressChip = new Border
        {
            Padding = new Thickness(10, 0, 10, 0),
            Height = 28,
            CornerRadius = new CornerRadius(8),
            BorderThickness = new Thickness(0.5),
            Background = new SolidColorBrush(Windows.UI.Color.FromArgb(0x40, 0, 0, 0)),
            BorderBrush = (Brush)Application.Current.Resources["VolarGlassBorderBrush"],
            Child = longPressRow,
        };
        stack.Children.Add(BuildRow("Task breakdown (long press)", "Hold the same hotkey ≥1.5s to have AI split the task into steps.", longPressChip));

        stack.Children.Add(BuildRow("Show Volar window", "Bring the main window to the front.", new Controls.KeyRecorder { Keys = new[] { "Ctrl", "Alt", "V" } }));
        stack.Children.Add(BuildRow("Toggle Focus Lock", "Lock the current task as your only focus — Volar will gently interrupt if you drift.", new Controls.KeyRecorder { Keys = new[] { "Ctrl", "Alt", "F" } }));
        stack.Children.Add(BuildRow("Complete current task", "When Focus Lock is active, mark the current task done without opening the window.", new Controls.KeyRecorder { Keys = new[] { "Ctrl", "Alt", "↩" } }));

        return new ScrollViewer { Content = stack, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled };
    }

    // ============================================================================================
    // MARK: - Notifications tab (SettingsView.swift:288-326)
    // ============================================================================================

    private FrameworkElement BuildNotificationsTab()
    {
        var vm = _viewModel!;
        var stack = new StackPanel { Spacing = 16 };

        stack.Children.Add(BuildRow("Show reminders", "Send a notification before each task.", BuildToggle(vm.ShowReminders, vm.SetShowReminders)));
        stack.Children.Add(BuildRow("Sound", "Subtle chime when a task is captured.", BuildToggle(vm.NotificationSound, vm.SetNotificationSound)));
        stack.Children.Add(BuildRow("Focus mode aware", "Stay silent while Windows Focus is on.", BuildToggle(vm.FocusModeAware, vm.SetFocusModeAware)));

        var reminderPresets = Enum.GetValues<ReminderPolicyPreset>();
        var reminderSegmented = new Controls.Segmented
        {
            Options = reminderPresets.Select(p => new Controls.SegmentOption(p, p.Label())).ToList(),
            SelectedId = vm.GlobalReminderPolicyPreset,
        };
        reminderSegmented.SelectionChanged += (_, id) => vm.SetGlobalReminderPolicyPreset((ReminderPolicyPreset)id);
        stack.Children.Add(BuildRow(
            "Default reminders before deadline",
            "Applies to any task without its own custom reminder.",
            reminderSegmented));

        var voiceModes = new[] { VoiceDeliveryMode.VisualOnly, VoiceDeliveryMode.VisualPlusVoice, VoiceDeliveryMode.VoiceOnly };
        var voiceSegmented = new Controls.Segmented
        {
            Options = voiceModes.Select(m => new Controls.SegmentOption(m, SettingsViewModel.Label(m))).ToList(),
            SelectedId = vm.VoiceDeliveryMode,
        };
        voiceSegmented.SelectionChanged += (_, id) => vm.SetVoiceDeliveryMode((VoiceDeliveryMode)id);
        stack.Children.Add(BuildRow(
            "Voice delivery",
            "Visual notifications always show. Voice is an extra, on-device-spoken nudge for urgent or unacknowledged reminders.",
            voiceSegmented));

        return new ScrollViewer { Content = stack, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled };
    }

    // ============================================================================================
    // MARK: - Appearance tab (SettingsView.swift:363-487)
    // ============================================================================================

    private string _cosmeticThemeChoice = "dark"; // SettingsView.swift:54's own un-persisted @State — cosmetic only.

    private FrameworkElement BuildAppearanceTab()
    {
        var vm = _viewModel!;
        var stack = new StackPanel { Spacing = 16 };

        var themeSegmented = new Controls.Segmented
        {
            Options = new List<Controls.SegmentOption>
            {
                new("dark", "Dark"),
                new("system", "Match system", disabled: true),
            },
            SelectedId = _cosmeticThemeChoice,
        };
        themeSegmented.SelectionChanged += (_, id) => _cosmeticThemeChoice = (string)id;
        stack.Children.Add(BuildRow("Theme", "Volar is dark-only.", themeSegmented));

        var ambientSegmented = new Controls.Segmented
        {
            Options = SettingsViewModel.AmbientModes.Select(m => new Controls.SegmentOption(m, SettingsViewModel.Label(m))).ToList(),
            SelectedId = vm.Ambient,
        };
        ambientSegmented.SelectionChanged += (_, id) => vm.SetAmbient((AmbientMode)id);
        stack.Children.Add(BuildRow(
            "Background",
            "A live scene or your own image behind the glass. Task list and panels stay readable on top.",
            ambientSegmented));

        if (vm.ShowCustomImageRow)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, VerticalAlignment = VerticalAlignment.Center };
            row.Children.Add(BuildCustomImageThumbnail(vm.CustomImagePath));
            row.Children.Add(BuildPillButton("Choose image…", solid: false, async (_, _) => await ChooseCustomImageAsync()));
            if (vm.CustomImagePath is not null)
            {
                var removeButton = new Button
                {
                    Content = new TextBlock { Text = "Remove", FontSize = 12, FontWeight = FontWeights.Medium, Foreground = (Brush)Application.Current.Resources["VolarTextSecBrush"] },
                    Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
                    BorderThickness = new Thickness(0),
                };
                SuppressStockButtonChrome(removeButton);
                removeButton.Click += (_, _) => vm.RemoveCustomImage();
                row.Children.Add(removeButton);
            }
            stack.Children.Add(BuildRow("Custom image", "Choose a photo or wallpaper from this PC.", row));
        }

        stack.Children.Add(BuildRow("Accent color", "Used for active states and the capture button.", BuildAccentSwatchRow(vm)));

        var densities = new[] { Density.Cozy, Density.Comfy, Density.Roomy };
        var densitySegmented = new Controls.Segmented
        {
            Options = densities.Select(d => new Controls.SegmentOption(d, SettingsViewModel.Label(d))).ToList(),
            SelectedId = vm.Density,
        };
        densitySegmented.SelectionChanged += (_, id) => vm.SetDensity((Density)id);
        stack.Children.Add(BuildRow("Density", "How tight the rows pack.", densitySegmented));

        return new ScrollViewer { Content = stack, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled };
    }

    private static FrameworkElement BuildCustomImageThumbnail(string? path)
    {
        var border = new Border
        {
            Width = 44,
            Height = 30,
            CornerRadius = new CornerRadius(6), // VolarCornerRadiusSmall's value — literal per the gotcha.
            Background = new SolidColorBrush(Windows.UI.Color.FromArgb(0x0F, 255, 255, 255)),
        };
        if (!string.IsNullOrEmpty(path) && File.Exists(path))
        {
            try
            {
                var image = new Image
                {
                    Source = new BitmapImage(new Uri(path)),
                    Stretch = Stretch.UniformToFill,
                };
                border.Child = image;
            }
            catch (Exception ex) when (ex is UriFormatException or IOException)
            {
                // Corrupt/unreadable path — keep the empty placeholder rather than crash the tab.
            }
        }
        return border;
    }

    /// <summary>Circle swatches for the 4 selectable <see cref="VolarAccent"/> families (the ONLY
    /// exerciser of live accent switching, views-inventory.md SS1.15 point 2) — each circle's fill
    /// is one of Accents.xaml's STATIC per-family brushes (VolarIndigoSolidBrush/...), distinct from
    /// the shared, in-place-mutated AccentSolidBrush every other view reads (decision 9) — these 4
    /// never change color themselves; only which one has the "selected" ring changes.</summary>
    private FrameworkElement BuildAccentSwatchRow(SettingsViewModel vm)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        var appResources = Application.Current.Resources;
        var families = new (VolarAccent Accent, string BrushKey)[]
        {
            (VolarAccent.Indigo, "VolarIndigoSolidBrush"),
            (VolarAccent.Teal, "VolarTealSolidBrush"),
            (VolarAccent.Amber, "VolarAccentAmberSolidBrush"),
            (VolarAccent.Magenta, "VolarMagentaSolidBrush"),
        };

        foreach (var (accent, brushKey) in families)
        {
            var selected = accent == vm.Accent;
            var ellipse = new Ellipse
            {
                Width = 22,
                Height = 22,
                Fill = (Brush)appResources[brushKey],
                Stroke = selected ? (Brush)appResources[brushKey] : new SolidColorBrush(Windows.UI.Color.FromArgb(0x33, 255, 255, 255)),
                StrokeThickness = selected ? 1.5 : 0.5,
            };
            var wrapper = new Grid
            {
                Width = 27,
                Height = 27,
                Children = { ellipse },
                Tag = accent,
            };
            wrapper.PointerPressed += (sender, _) => vm.SetAccent((VolarAccent)((Grid)sender!).Tag);
            row.Children.Add(wrapper);
        }
        return row;
    }

    private async Task ChooseCustomImageAsync()
    {
        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.PicturesLibrary };
        picker.FileTypeFilter.Add(".png");
        picker.FileTypeFilter.Add(".jpg");
        picker.FileTypeFilter.Add(".jpeg");
        picker.FileTypeFilter.Add(".bmp");
        picker.FileTypeFilter.Add(".gif");
        InitializeWithWindow.Initialize(picker, OwnerWindowHandle);

        var file = await picker.PickSingleFileAsync();
        if (file is not null)
        {
            _viewModel?.SetCustomImage(file.Path);
        }
    }

    // ============================================================================================
    // MARK: - Integrations tab (SettingsView.swift:489-706)
    // ============================================================================================

    private FrameworkElement BuildIntegrationsTab()
    {
        var vm = _viewModel!;
        var appResources = Application.Current.Resources;

        var card = new StackPanel { Spacing = 12 };

        var titleStack = new StackPanel { Spacing = 3 };
        titleStack.Children.Add(new TextBlock { Text = "Connect Claude Code", FontSize = 13.5, FontWeight = FontWeights.Medium, Foreground = (Brush)appResources["VolarTextPriBrush"] });
        titleStack.Children.Add(new TextBlock { Text = vm.ClaudeConnectHint, FontSize = 12, Foreground = (Brush)appResources["VolarTextSecBrush"], TextWrapping = TextWrapping.Wrap });
        card.Children.Add(titleStack);

        card.Children.Add(new Border
        {
            Padding = new Thickness(10),
            CornerRadius = new CornerRadius(8),
            BorderThickness = new Thickness(0.5),
            Background = new SolidColorBrush(Windows.UI.Color.FromArgb(0x40, 0, 0, 0)),
            BorderBrush = (Brush)appResources["VolarGlassBorderBrush"],
            Child = new TextBlock
            {
                Text = vm.ClaudeHookPreview,
                FontFamily = (FontFamily)appResources["VolarMonoFontFamily"],
                FontSize = 11,
                Foreground = (Brush)appResources["VolarInstrumentBrush"],
                IsTextSelectionEnabled = true,
                TextWrapping = TextWrapping.Wrap,
            },
        });

        if (vm.ClaudeConnectError is { } error)
        {
            card.Children.Add(new TextBlock { Text = error, FontSize = 11.5, Foreground = (Brush)appResources["VolarRescheduleBrush"], TextWrapping = TextWrapping.Wrap, MaxLines = 3 });
        }

        var buttonsRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        if (vm.ClaudeConnected)
        {
            if (vm.ClaudeTestSignalSafe)
            {
                buttonsRow.Children.Add(BuildPillButton("Send test signal", solid: true, (_, _) => vm.SendClaudeTestSignal()));
            }
            buttonsRow.Children.Add(BuildPillButton("Disconnect", solid: false, (_, _) => vm.DisconnectClaudeCode()));
        }
        else
        {
            buttonsRow.Children.Add(BuildPillButton("Connect…", solid: true, async (_, _) => await ConnectClaudeCodeAsync()));
        }
        card.Children.Add(buttonsRow);

        if (vm.ClaudeConnected && !vm.ClaudeTestSignalSafe)
        {
            card.Children.Add(new TextBlock
            {
                Text = "Test signal hidden while a delegation is waiting — sending it now could mark a real task reviewed instead of just testing the connection.",
                FontSize = 11.5,
                Foreground = (Brush)appResources["VolarTextMutBrush"],
                TextWrapping = TextWrapping.Wrap,
                MaxLines = 3,
            });
        }

        if (vm.TestSignalAwaitingReceipt)
        {
            card.Children.Add(new TextBlock { Text = "Signal sent — waiting…", FontSize = 11.5, Foreground = (Brush)appResources["VolarTextMutBrush"] });
        }
        else if (vm.TestSignalReceived)
        {
            card.Children.Add(new TextBlock { Text = "✓ received", FontSize = 11.5, FontWeight = FontWeights.Medium, Foreground = (Brush)appResources["VolarDoneBrush"] });
        }

        var cardBorder = new Border
        {
            Padding = new Thickness(16),
            CornerRadius = new CornerRadius(11), // one-off literal, SettingsView.swift:622.
            BorderThickness = new Thickness(0.5),
            Background = (Brush)appResources["VolarCardBrush"],
            BorderBrush = (Brush)appResources["VolarGlassBorderBrush"],
            Child = card,
        };

        return new ScrollViewer { Content = cardBorder, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled };
    }

    private async Task ConnectClaudeCodeAsync()
    {
        // PickerLocationId has no "home directory" member — Desktop is the closest stock starting
        // point; ConnectClaudeCode's own VM-side EditorConnector.Connect still validates the final
        // choice resolves under the real user profile (EnsureWithinUserProfile), so a wrong initial
        // location here is a UX nit, never a correctness concern.
        var picker = new FolderPicker { SuggestedStartLocation = PickerLocationId.Desktop };
        picker.FileTypeFilter.Add("*");
        InitializeWithWindow.Initialize(picker, OwnerWindowHandle);

        var folder = await picker.PickSingleFolderAsync();
        if (folder is not null)
        {
            _viewModel?.ConnectClaudeCode(folder.Path);
        }
    }

    // ============================================================================================
    // MARK: - Account tab (new, 2026-07-26 account-auth contract — no macOS equivalent existed
    // before this; the whole tab is new surface, not a port). Cloud parse/Groq speech gating and
    // the actual auth network calls all live in AccountViewModel/AccountService — this method and
    // its helpers are pure layout, following the same programmatic-row pattern every other tab in
    // this file uses.
    // ============================================================================================

    private FrameworkElement BuildAccountTab()
    {
        var vm = _accountViewModel!;
        var appResources = Application.Current.Resources;
        var stack = new StackPanel { Spacing = 16 };

        stack.Children.Add(vm.IsSignedIn ? BuildSignedInAccountCard(vm, appResources) : BuildSignedOutAccountCard(vm, appResources));

        return new ScrollViewer { Content = stack, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled };
    }

    private FrameworkElement BuildSignedOutAccountCard(AccountViewModel vm, ResourceDictionary appResources)
    {
        var card = new StackPanel { Spacing = 12 };

        card.Children.Add(new TextBlock
        {
            Text = "Sign in",
            FontSize = 13.5,
            FontWeight = FontWeights.Medium,
            Foreground = (Brush)appResources["VolarTextPriBrush"],
        });
        card.Children.Add(new TextBlock
        {
            Text = "Sign in with your email to unlock Cloud AI parsing and Groq cloud transcription. Volar's core capture, tasks, and reminders never require an account.",
            FontSize = 12,
            Foreground = (Brush)appResources["VolarTextSecBrush"],
            TextWrapping = TextWrapping.Wrap,
        });

        var emailBox = new TextBox
        {
            PlaceholderText = "you@example.com",
            Width = 260,
            IsEnabled = !vm.Busy && !vm.CodeSent,
            Text = vm.EmailInput,
        };
        emailBox.TextChanged += (_, _) => vm.EmailInput = emailBox.Text;
        card.Children.Add(BuildRow("Email", null, emailBox));

        if (!vm.CodeSent)
        {
            card.Children.Add(BuildPillButton(vm.Busy ? "Sending…" : "Send code", solid: true, async (_, _) => await vm.SendCodeAsync()));
        }
        else
        {
            var codeBox = new TextBox
            {
                PlaceholderText = "6-digit code",
                Width = 160,
                IsEnabled = !vm.Busy,
                Text = vm.CodeInput,
            };
            codeBox.TextChanged += (_, _) => vm.CodeInput = codeBox.Text;
            card.Children.Add(BuildRow("Code", "Check your email for a 6-digit code.", codeBox));

            var buttonsRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            buttonsRow.Children.Add(BuildPillButton(vm.Busy ? "Verifying…" : "Verify", solid: true, async (_, _) => await vm.VerifyCodeAsync()));
            buttonsRow.Children.Add(BuildPillButton("Resend code", solid: false, async (_, _) => await vm.SendCodeAsync()));
            card.Children.Add(buttonsRow);
        }

        if (vm.ErrorMessage is { } error)
        {
            card.Children.Add(new TextBlock { Text = error, FontSize = 11.5, Foreground = (Brush)appResources["VolarRescheduleBrush"], TextWrapping = TextWrapping.Wrap });
        }

        card.Children.Add(new TextBlock
        {
            Text = AccountViewModel.AppleSignInLimitationNote,
            FontSize = 11,
            Foreground = (Brush)appResources["VolarTextMutBrush"],
            TextWrapping = TextWrapping.Wrap,
        });

        return WrapInCard(card, appResources);
    }

    private FrameworkElement BuildSignedInAccountCard(AccountViewModel vm, ResourceDictionary appResources)
    {
        var card = new StackPanel { Spacing = 12 };

        var header = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, VerticalAlignment = VerticalAlignment.Center };
        header.Children.Add(new TextBlock
        {
            Text = vm.Email ?? "Signed in",
            FontSize = 13.5,
            FontWeight = FontWeights.Medium,
            Foreground = (Brush)appResources["VolarTextPriBrush"],
        });
        header.Children.Add(new Border
        {
            Padding = new Thickness(8, 2, 8, 2),
            CornerRadius = new CornerRadius(999), // Capsule — same convention as BuildPill's badge.
            Background = vm.IsPro ? (Brush)appResources["AccentSurfaceBrush"] : new SolidColorBrush(Windows.UI.Color.FromArgb(0x1F, 255, 255, 255)),
            Child = new TextBlock
            {
                Text = vm.TierLabel,
                FontSize = 11,
                FontWeight = FontWeights.Medium,
                Foreground = vm.IsPro ? (Brush)appResources["AccentSolidBrush"] : (Brush)appResources["VolarTextSecBrush"],
            },
        });
        card.Children.Add(header);

        card.Children.Add(new TextBlock { Text = vm.QuotaLine, FontSize = 12, Foreground = (Brush)appResources["VolarTextSecBrush"] });

        if (vm.CanUpgrade)
        {
            card.Children.Add(BuildRow("Upgrade to Pro", AccountViewModel.UpgradeHint, BuildStatusText("Mac app only")));
        }

        var buttonsRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        buttonsRow.Children.Add(BuildPillButton(vm.Busy ? "Signing out…" : "Sign out", solid: false, async (_, _) => await vm.SignOutAsync()));
        card.Children.Add(buttonsRow);

        if (vm.ErrorMessage is { } error)
        {
            card.Children.Add(new TextBlock { Text = error, FontSize = 11.5, Foreground = (Brush)appResources["VolarRescheduleBrush"], TextWrapping = TextWrapping.Wrap });
        }

        card.Children.Add(new Rectangle { Height = 0.5, Fill = (Brush)appResources["VolarBorderBrush"], Margin = new Thickness(0, 4, 0, 4) });

        if (!vm.DeleteConfirmationPending)
        {
            var deleteRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            deleteRow.Children.Add(BuildDestructiveButton("Delete account", (_, _) => vm.RequestDeleteAccount()));
            card.Children.Add(BuildRow("Delete account", "Permanently deletes your Volar account and cloud usage history. This cannot be undone.", deleteRow));
        }
        else
        {
            card.Children.Add(new TextBlock
            {
                Text = "Are you sure? This permanently deletes your account and cannot be undone.",
                FontSize = 12,
                FontWeight = FontWeights.Medium,
                Foreground = (Brush)appResources["VolarRescheduleBrush"],
                TextWrapping = TextWrapping.Wrap,
            });
            var confirmRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            confirmRow.Children.Add(BuildDestructiveButton(vm.Busy ? "Deleting…" : "Yes, delete permanently", async (_, _) => await vm.ConfirmDeleteAccountAsync()));
            confirmRow.Children.Add(BuildPillButton("Cancel", solid: false, (_, _) => vm.CancelDeleteAccount()));
            card.Children.Add(confirmRow);
        }

        return WrapInCard(card, appResources);
    }

    private static Button BuildDestructiveButton(string text, RoutedEventHandler onClick)
    {
        var button = new Button
        {
            Content = new TextBlock { Text = text, FontSize = 12.5, FontWeight = FontWeights.Medium, Foreground = new SolidColorBrush(Microsoft.UI.Colors.White) },
            Padding = new Thickness(14, 0, 14, 0),
            Height = 30,
            CornerRadius = new CornerRadius(8),
            BorderThickness = new Thickness(0),
            Background = (Brush)Application.Current.Resources["VolarRescheduleBrush"],
        };
        SuppressStockButtonChrome(button);
        button.Click += onClick;
        return button;
    }

    private static Border WrapInCard(FrameworkElement content, ResourceDictionary appResources) => new()
    {
        Padding = new Thickness(16),
        CornerRadius = new CornerRadius(11), // one-off literal, same recurring 11 as every other card border in this file.
        BorderThickness = new Thickness(0.5),
        Background = (Brush)appResources["VolarCardBrush"],
        BorderBrush = (Brush)appResources["VolarGlassBorderBrush"],
        Child = content,
    };

    // ============================================================================================
    // MARK: - About tab (SettingsView.swift:708-749)
    // ============================================================================================

    private FrameworkElement BuildAboutTab()
    {
        var appResources = Application.Current.Resources;
        var stack = new StackPanel { Spacing = 14, HorizontalAlignment = HorizontalAlignment.Center };

        // The real app icon replaces this port's stand-in tile (an accent gradient with a mic
        // glyph). The mark IS the squircle — night-blue ground, mint cone, lit dot — so it replaces
        // both layers rather than sitting inside them, and the accent-gradient binding that used to
        // paint the tile is gone with it: it tracked ThemeState.SetAccent, which the brand mark must
        // NOT do (the icon is fixed identity, not a themeable surface).
        var tile = new Image
        {
            Width = 64,
            Height = 64,
            HorizontalAlignment = HorizontalAlignment.Center,
            Source = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage(new Uri("ms-appx:///Assets/volar-app-icon-128.png")),
        };
        stack.Children.Add(tile);

        // Wordmark image + version, instead of the app name set in the UI font: the wordmark is
        // Bricolage Grotesque 600 with -0.03em tracking and a mint dot inside the "o" (design zip ->
        // export-wordmark/README.txt), none of which the system font stack can reproduce — and the
        // font is not bundled in this app (deferred, see backlog.md), so the raster IS the only
        // faithful way to render it today. AppDisplayName still drives the version row's accessible
        // name so screen readers keep hearing the product name.
        var nameRow = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 10,
            HorizontalAlignment = HorizontalAlignment.Center,
        };
        nameRow.Children.Add(new Image
        {
            Height = 22,
            Stretch = Microsoft.UI.Xaml.Media.Stretch.Uniform,
            VerticalAlignment = VerticalAlignment.Center,
            Source = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage(new Uri("ms-appx:///Assets/volar-wordmark.png")),
        });
        nameRow.Children.Add(new TextBlock
        {
            Text = SettingsViewModel.AppVersion,
            FontSize = 17,
            FontWeight = FontWeights.Medium,
            Foreground = (Brush)appResources["VolarTextSecBrush"],
            VerticalAlignment = VerticalAlignment.Center,
        });
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(
            nameRow, $"{SettingsViewModel.AppDisplayName} {SettingsViewModel.AppVersion}");
        stack.Children.Add(nameRow);
        stack.Children.Add(new TextBlock
        {
            Text = SettingsViewModel.AppTagline,
            FontSize = 13,
            Foreground = (Brush)appResources["VolarTextSecBrush"],
            HorizontalAlignment = HorizontalAlignment.Center,
        });

        var pillsRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center };
        pillsRow.Children.Add(BuildPill("What's new", (Brush)appResources["AccentSolidBrush"], (Brush)appResources["AccentSurfaceBrush"]));
        pillsRow.Children.Add(BuildPill("Acknowledgements", (Brush)appResources["VolarTextSecBrush"], new SolidColorBrush(Windows.UI.Color.FromArgb(0x0F, 255, 255, 255))));
        stack.Children.Add(pillsRow);

        return new ScrollViewer { Content = stack, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled, HorizontalContentAlignment = HorizontalAlignment.Center };
    }

    private static Border BuildPill(string text, Brush foreground, Brush background) => new()
    {
        Padding = new Thickness(10, 4, 10, 4),
        CornerRadius = new CornerRadius(999), // Capsule -> a radius >= half the pill's height renders fully rounded.
        Background = background,
        Child = new TextBlock { Text = text, FontSize = 11, FontWeight = FontWeights.Medium, Foreground = foreground },
    };
}
