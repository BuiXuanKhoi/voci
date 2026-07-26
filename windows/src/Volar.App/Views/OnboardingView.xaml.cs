// Views/OnboardingView.xaml.cs — see OnboardingView.xaml header. Port of
// Volar/Sources/Views/OnboardingView.swift (302 lines).
using System.ComponentModel;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Shapes;
using Volar.App.ViewModels;
using Windows.System;

namespace Volar.App.Views;

public sealed partial class OnboardingView : UserControl
{
    private OnboardingViewModel? _viewModel;
    private readonly List<Border> _stepDots = new();
    private int _renderedStep;

    public OnboardingView()
    {
        InitializeComponent();
    }

    /// <summary>Fired once the user finishes/skips step 3 — the SAME moment
    /// <see cref="OnboardingViewModel.Completed"/> fires, re-raised here so Stage C's host doesn't
    /// need a second reference to the VM just to know when to swap this overlay out.</summary>
    public event EventHandler? Finished;

    public void Attach(OnboardingViewModel viewModel)
    {
        if (_viewModel is not null)
        {
            _viewModel.PropertyChanged -= OnViewModelPropertyChanged;
            _viewModel.Completed -= OnViewModelCompleted;
        }
        _viewModel = viewModel ?? throw new ArgumentNullException(nameof(viewModel));
        _viewModel.PropertyChanged += OnViewModelPropertyChanged;
        _viewModel.Completed += OnViewModelCompleted;

        BuildStepDots();
        _renderedStep = _viewModel.Step;
        StepHost.Content = PanelForStep(_renderedStep);
        StepHost.Opacity = 1;
        UpdateStepDots();
        UpdateFooter();
    }

    private void OnViewModelCompleted(object? sender, EventArgs e) =>
        DispatcherQueue.TryEnqueue(() => Finished?.Invoke(this, EventArgs.Empty));

    private void OnViewModelPropertyChanged(object? sender, PropertyChangedEventArgs e) =>
        DispatcherQueue.TryEnqueue(() =>
        {
            if (_viewModel is null || _viewModel.Step == _renderedStep)
            {
                return;
            }
            AnimateToStep(_viewModel.Step);
        });

    // ============================================================================================
    // MARK: - Step dots (OnboardingView.swift:40-49) — animated width 6->18 on the active dot.
    // ============================================================================================

    private void BuildStepDots()
    {
        StepDotsPanel.Children.Clear();
        _stepDots.Clear();
        for (var i = 1; i <= OnboardingViewModel.TotalSteps; i++)
        {
            var dot = new Border { Height = 6, CornerRadius = new CornerRadius(3), Width = 6 };
            _stepDots.Add(dot);
            StepDotsPanel.Children.Add(dot);
        }
    }

    private void UpdateStepDots()
    {
        var appResources = Application.Current.Resources;
        var accentSolid = (Brush)appResources["AccentSolidBrush"];
        var inactive = new SolidColorBrush(Windows.UI.Color.FromArgb(0x26, 255, 255, 255)); // white@0.15.

        for (var i = 0; i < _stepDots.Count; i++)
        {
            var isActive = i + 1 == (_viewModel?.Step ?? _renderedStep);
            var dot = _stepDots[i];
            dot.Background = isActive ? accentSolid : inactive;

            var targetWidth = isActive ? 18.0 : 6.0;
            if (Math.Abs(dot.Width - targetWidth) < 0.01)
            {
                continue;
            }
            var animation = new DoubleAnimation
            {
                To = targetWidth,
                Duration = new Duration(TimeSpan.FromMilliseconds(150)),
                EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut },
            };
            Storyboard.SetTarget(animation, dot);
            Storyboard.SetTargetProperty(animation, "Width");
            var storyboard = new Storyboard();
            storyboard.Children.Add(animation);
            storyboard.Begin();
        }
    }

    private void UpdateFooter() => FooterStepText.Text = $"Step {_viewModel?.Step ?? _renderedStep} of {OnboardingViewModel.TotalSteps}";

    // ============================================================================================
    // MARK: - Step crossfade (OnboardingView.swift's `withAnimation { step = N }`)
    // ============================================================================================

    private void AnimateToStep(int step)
    {
        var fadeOut = new DoubleAnimation { To = 0, Duration = new Duration(TimeSpan.FromMilliseconds(120)) };
        Storyboard.SetTarget(fadeOut, StepHost);
        Storyboard.SetTargetProperty(fadeOut, "Opacity");
        var fadeOutStoryboard = new Storyboard();
        fadeOutStoryboard.Children.Add(fadeOut);
        fadeOutStoryboard.Completed += (_, _) =>
        {
            _renderedStep = step;
            StepHost.Content = PanelForStep(step);
            UpdateStepDots();
            UpdateFooter();

            var fadeIn = new DoubleAnimation { To = 1, Duration = new Duration(TimeSpan.FromMilliseconds(180)) };
            Storyboard.SetTarget(fadeIn, StepHost);
            Storyboard.SetTargetProperty(fadeIn, "Opacity");
            var fadeInStoryboard = new Storyboard();
            fadeInStoryboard.Children.Add(fadeIn);
            fadeInStoryboard.Begin();
        };
        fadeOutStoryboard.Begin();
    }

    private FrameworkElement PanelForStep(int step) => step switch
    {
        1 => BuildStepOne(),
        2 => BuildStepTwo(),
        _ => BuildStepThree(),
    };

    // ============================================================================================
    // MARK: - Shared helpers
    // ============================================================================================

    private static LinearGradientBrush BuildAccentGradientBrush()
    {
        var appResources = Application.Current.Resources;
        var gradient = new LinearGradientBrush { StartPoint = new Windows.Foundation.Point(0, 0), EndPoint = new Windows.Foundation.Point(1, 1) };
        var solidStop = new GradientStop { Offset = 0 };
        Microsoft.UI.Xaml.Data.BindingOperations.SetBinding(
            solidStop, GradientStop.ColorProperty,
            new Microsoft.UI.Xaml.Data.Binding { Source = appResources["AccentSolidBrush"], Path = new PropertyPath("Color") });
        var hoverStop = new GradientStop { Offset = 1 };
        Microsoft.UI.Xaml.Data.BindingOperations.SetBinding(
            hoverStop, GradientStop.ColorProperty,
            new Microsoft.UI.Xaml.Data.Binding { Source = appResources["AccentHoverBrush"], Path = new PropertyPath("Color") });
        gradient.GradientStops.Add(solidStop);
        gradient.GradientStops.Add(hoverStop);
        return gradient;
    }

    private static TextBlock BuildTitle(string text) => new()
    {
        Text = text,
        FontSize = 32,
        FontWeight = FontWeights.Medium,
        Foreground = (Brush)Application.Current.Resources["VolarTextPriBrush"],
        TextWrapping = TextWrapping.Wrap,
        Margin = new Thickness(0, 0, 0, 14),
    };

    private static TextBlock BuildSubtitle(string text) => new()
    {
        Text = text,
        FontSize = 15,
        Foreground = (Brush)Application.Current.Resources["VolarTextSecBrush"],
        TextWrapping = TextWrapping.Wrap,
        MaxWidth = 420,
        Margin = new Thickness(0, 0, 0, 30),
    };

    private static Button BuildPrimaryButton(string text, RoutedEventHandler onClick)
    {
        var appResources = Application.Current.Resources;
        var button = new Button
        {
            Content = new TextBlock { Text = text, FontSize = 14, FontWeight = FontWeights.Medium, Foreground = new SolidColorBrush(Microsoft.UI.Colors.White) },
            Padding = new Thickness(22, 0, 22, 0),
            Height = 44,
            CornerRadius = new CornerRadius(11), // one-off literal, OnboardingView.swift:141/189/271.
            BorderThickness = new Thickness(0),
            Background = (Brush)appResources["AccentSolidBrush"],
        };
        SuppressStockButtonChrome(button);
        button.Click += onClick;
        return button;
    }

    private static Button BuildSecondaryButton(string text, RoutedEventHandler onClick)
    {
        var appResources = Application.Current.Resources;
        var button = new Button
        {
            Content = new TextBlock { Text = text, FontSize = 14, FontWeight = FontWeights.Medium, Foreground = (Brush)appResources["VolarTextSecBrush"] },
            Padding = new Thickness(18, 0, 18, 0),
            Height = 44,
            CornerRadius = new CornerRadius(11),
            BorderThickness = new Thickness(0.5),
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderBrush = (Brush)appResources["VolarGlassBorderBrush"],
        };
        SuppressStockButtonChrome(button);
        button.Click += onClick;
        return button;
    }

    private static void SuppressStockButtonChrome(Button button)
    {
        var transparent = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        button.Resources["ButtonBackgroundPointerOver"] = transparent;
        button.Resources["ButtonBackgroundPressed"] = transparent;
        button.Resources["ButtonBorderBrushPointerOver"] = transparent;
        button.Resources["ButtonBorderBrushPressed"] = transparent;
    }

    // ============================================================================================
    // MARK: - Step 1: hotkey intro (OnboardingView.swift:99-144)
    // ============================================================================================

    private FrameworkElement BuildStepOne()
    {
        var stack = new StackPanel();

        stack.Children.Add(new Border
        {
            Width = 84,
            Height = 84,
            CornerRadius = new CornerRadius(22), // one-off literal, OnboardingView.swift:101.
            Background = BuildAccentGradientBrush(),
            Margin = new Thickness(0, 0, 0, 28),
            HorizontalAlignment = HorizontalAlignment.Left,
            Child = new Controls.VolarIcon { IconName = Controls.VolarIconName.Mic, IconSize = 42, IconBrush = new SolidColorBrush(Microsoft.UI.Colors.White) },
        });

        var pressRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(0, 0, 0, 2) };
        pressRow.Children.Add(new TextBlock { Text = "Press", FontSize = 32, FontWeight = FontWeights.Medium, Foreground = (Brush)Application.Current.Resources["VolarTextPriBrush"] });
        pressRow.Children.Add(new Controls.KeyBadge { Text = "Ctrl", Accent = true, VerticalAlignment = VerticalAlignment.Center });
        pressRow.Children.Add(new Controls.KeyBadge { Text = "Alt", Accent = true, VerticalAlignment = VerticalAlignment.Center });
        pressRow.Children.Add(new Controls.KeyBadge { Text = "M", Accent = true, VerticalAlignment = VerticalAlignment.Center });
        pressRow.Children.Add(new TextBlock { Text = ".", FontSize = 32, FontWeight = FontWeights.Medium, Foreground = (Brush)Application.Current.Resources["VolarTextPriBrush"] });
        stack.Children.Add(pressRow);

        stack.Children.Add(BuildTitle("Speak. Done."));
        stack.Children.Add(BuildSubtitle("Volar is a voice-first task manager. No typing, no menus — just press the hotkey from anywhere on your PC and say what you need to do."));

        var getStarted = BuildPrimaryButton("Get started  →", (_, _) => _viewModel?.Advance());
        getStarted.HorizontalAlignment = HorizontalAlignment.Left;
        stack.Children.Add(getStarted);

        return stack;
    }

    // ============================================================================================
    // MARK: - Step 2: mic permission (OnboardingView.swift:148-213; wave4-contract.md decision 8)
    // ============================================================================================

    private FrameworkElement BuildStepTwo()
    {
        var appResources = Application.Current.Resources;
        var accentSolid = (Brush)appResources["AccentSolidBrush"];
        var stack = new StackPanel();

        // Reads the CURRENT accent family's Color (not a hardcoded indigo) so a previously
        // persisted non-default accent (Settings' accent swatch row) renders correctly here too —
        // a one-time read at build time, not a live binding: onboarding is a first-run, single-pass
        // surface with no Settings access mid-flow, so it does not need SettingsViewModel-style live
        // accent-switch tracking (unlike the center tile's fill/border below, which already reuses
        // the live AccentSolidBrush/AccentSurfaceBrush resources directly).
        var accentColor = ((SolidColorBrush)accentSolid).Color;
        var ringsGrid = new Grid { Width = 84, Height = 84, Margin = new Thickness(0, 0, 0, 28), HorizontalAlignment = HorizontalAlignment.Left };
        for (var i = 1; i < 4; i++)
        {
            var size = 84 + i * 12;
            var alpha = (byte)Math.Round(0.15 / i * 255);
            ringsGrid.Children.Add(new Ellipse
            {
                Width = size,
                Height = size,
                Stroke = new SolidColorBrush(Windows.UI.Color.FromArgb(alpha, accentColor.R, accentColor.G, accentColor.B)),
                StrokeThickness = 1,
            });
        }
        var centerTile = new Border
        {
            Width = 84,
            Height = 84,
            CornerRadius = new CornerRadius(22),
            Background = (Brush)appResources["AccentSurfaceBrush"],
            BorderThickness = new Thickness(0.5),
            BorderBrush = accentSolid,
            Child = new Controls.VolarIcon { IconName = Controls.VolarIconName.Mic, IconSize = 42, IconBrush = accentSolid },
        };
        ringsGrid.Children.Add(centerTile);
        stack.Children.Add(ringsGrid);

        stack.Children.Add(BuildTitle("Volar needs your microphone."));
        stack.Children.Add(BuildSubtitle("Audio is processed by whichever speech engine you've chosen in Settings — on-device (Whisper) by default, never uploaded unless you opt into Cloud. The waveform stays on this PC."));

        var buttonsRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Margin = new Thickness(0, 0, 0, 22) };
        buttonsRow.Children.Add(BuildPrimaryButton("Allow microphone", async (_, _) => await OnAllowMicrophoneAsync()));
        buttonsRow.Children.Add(BuildSecondaryButton("Not now", (_, _) => _viewModel?.Advance()));
        stack.Children.Add(buttonsRow);

        var hintRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        hintRow.Children.Add(new Ellipse { Width = 6, Height = 6, Fill = (Brush)appResources["VolarDoneBrush"], VerticalAlignment = VerticalAlignment.Center });
        hintRow.Children.Add(new TextBlock { Text = "On-device · No network calls (default engine)", FontSize = 12, Foreground = (Brush)appResources["VolarTextMutBrush"] });
        stack.Children.Add(hintRow);

        return stack;
    }

    /// <summary>Decision 8: informational only — opens the Windows privacy settings page for the
    /// microphone (no direct permission-request API call: unpackaged desktop apps get mic access
    /// unless the user has blocked it at the OS level; the first real capture is the actual test),
    /// then advances exactly like Swift's `Task { await requestAuthorization(); step = 3 }` does
    /// after its own (macOS-only) permission prompt completes.</summary>
    private async Task OnAllowMicrophoneAsync()
    {
        try
        {
            await Launcher.LaunchUriAsync(new Uri("ms-settings:privacy-microphone"));
        }
        catch (Exception ex)
        {
            // Best-effort — a failed settings-page launch must never block onboarding from advancing.
            System.Diagnostics.Debug.WriteLine($"[Volar.App.Views.OnboardingView] ms-settings:privacy-microphone launch failed: {ex.GetType().Name}");
        }
        _viewModel?.Advance();
    }

    // ============================================================================================
    // MARK: - Step 3: try it (OnboardingView.swift:217-286)
    // ============================================================================================

    private FrameworkElement BuildStepThree()
    {
        var appResources = Application.Current.Resources;
        // One-time read of the CURRENT accent Color — see BuildStepTwo's identical comment on why
        // this is a build-time read, not a live binding.
        var accentColor = ((SolidColorBrush)appResources["AccentSolidBrush"]).Color;
        var stack = new StackPanel();

        var chipRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        chipRow.Children.Add(new Controls.KeyBadge { Text = "Ctrl", Accent = true });
        chipRow.Children.Add(new Controls.KeyBadge { Text = "Alt", Accent = true });
        chipRow.Children.Add(new Controls.KeyBadge { Text = "M", Accent = true });
        stack.Children.Add(new Border
        {
            Padding = new Thickness(18, 14, 18, 14),
            CornerRadius = new CornerRadius(14), // one-off literal, OnboardingView.swift:227.
            BorderThickness = new Thickness(0.5),
            Background = (Brush)appResources["AccentSurfaceBrush"],
            // accentColors.solid.opacity(0.27) (OnboardingView.swift:230) -> alpha round(0.27*255)=69=0x45.
            BorderBrush = new SolidColorBrush(Windows.UI.Color.FromArgb(0x45, accentColor.R, accentColor.G, accentColor.B)),
            Child = chipRow,
            Margin = new Thickness(0, 0, 0, 32),
            HorizontalAlignment = HorizontalAlignment.Left,
        });

        stack.Children.Add(BuildTitle("Try it now."));
        stack.Children.Add(BuildSubtitle("Press the hotkey and say your first task. We'll parse the time, priority, and project for you."));

        var trySayingStack = new StackPanel { Spacing = 4 };
        trySayingStack.Children.Add(new TextBlock { Text = "TRY SAYING", FontSize = 11, FontWeight = FontWeights.Medium, CharacterSpacing = 70, Foreground = (Brush)appResources["VolarTextMutBrush"] });
        trySayingStack.Children.Add(new TextBlock { Text = "“Call John tomorrow at 3pm, high priority”", FontSize = 14, Foreground = (Brush)appResources["VolarTextPriBrush"], TextWrapping = TextWrapping.Wrap });
        stack.Children.Add(new Border
        {
            Padding = new Thickness(16, 12, 16, 12),
            CornerRadius = new CornerRadius(12), // one-off literal, OnboardingView.swift:253.
            BorderThickness = new Thickness(0.5),
            Background = new SolidColorBrush(Windows.UI.Color.FromArgb(0x0A, 255, 255, 255)), // white@0.04.
            BorderBrush = (Brush)appResources["VolarGlassBorderBrush"],
            Child = trySayingStack,
            Margin = new Thickness(0, 0, 0, 22),
            MaxWidth = 460,
        });

        stack.Children.Add(BuildPrimaryButtonWithMargin("Start using Volar  →", (_, _) => _viewModel?.Complete()));
        stack.Children.Add(BuildSecondaryTextButton("Skip for now", (_, _) => _viewModel?.Complete()));

        return stack;
    }

    private static Button BuildPrimaryButtonWithMargin(string text, RoutedEventHandler onClick)
    {
        var button = BuildPrimaryButton(text, onClick);
        button.Margin = new Thickness(0, 0, 0, 10);
        button.HorizontalAlignment = HorizontalAlignment.Left;
        return button;
    }

    private static Button BuildSecondaryTextButton(string text, RoutedEventHandler onClick)
    {
        var button = new Button
        {
            Content = new TextBlock { Text = text, FontSize = 13, FontWeight = FontWeights.Medium, Foreground = (Brush)Application.Current.Resources["VolarTextSecBrush"] },
            Height = 36,
            Padding = new Thickness(14, 0, 14, 0),
            BorderThickness = new Thickness(0),
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        SuppressStockButtonChrome(button);
        button.Click += onClick;
        return button;
    }
}
