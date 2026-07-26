// Views/Controls/VolarToggle.xaml.cs — see VolarToggle.xaml header. Port of SettingsView.swift's
// private VolarToggle (lines 787-808).
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Windows.UI;

namespace Volar.App.Views.Controls;

public sealed partial class VolarToggle : UserControl
{
    // Color.white.opacity(0.12) -> alpha = round(0.12*255) = 30.6 -> 31 = 0x1F (SettingsView.swift:795,
    // the off-state track fill).
    private static readonly SolidColorBrush OffTrackBrush = new(Color.FromArgb(0x1F, 255, 255, 255));

    // The thumb's travel distance: track width (38) - thumb width (18) - left/right margin (2*2) = 16.
    private const double ThumbTravel = 16;

    public static readonly DependencyProperty IsOnProperty = DependencyProperty.Register(
        nameof(IsOn), typeof(bool), typeof(VolarToggle), new PropertyMetadata(false, OnIsOnChanged));

    public VolarToggle()
    {
        InitializeComponent();
        UpdateVisual(animate: false);
    }

    public bool IsOn
    {
        get => (bool)GetValue(IsOnProperty);
        set => SetValue(IsOnProperty, value);
    }

    /// <summary>Mirrors Swift's plain `@Binding var isOn: Bool` + `.onTapGesture { isOn.toggle() }`
    /// (SettingsView.swift:806) — fires whenever the user taps the control, carrying the NEW value.
    /// Same "dumb control" convention as <see cref="Segmented.SelectionChanged"/>.</summary>
    public event EventHandler<bool>? Toggled;

    private static void OnIsOnChanged(DependencyObject d, DependencyPropertyChangedEventArgs e) =>
        ((VolarToggle)d).UpdateVisual(animate: true);

    private void OnPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        var next = !IsOn;
        IsOn = next; // triggers UpdateVisual via OnIsOnChanged.
        Toggled?.Invoke(this, next);
    }

    private void UpdateVisual(bool animate)
    {
        var appResources = Application.Current.Resources;
        TrackBorder.Background = IsOn ? (Brush)appResources["AccentSolidBrush"] : OffTrackBrush;

        var targetX = IsOn ? ThumbTravel : 0;
        if (!animate)
        {
            ThumbTransform.X = targetX;
            return;
        }

        // A short, one-shot (non-looping) position transition — the "repeat-forever animations only
        // in full-window surfaces" gotcha applies to LOOPING animations; this fires once per toggle
        // and completes, so it needs no UISettings.AnimationsEnabled gate (mirrors Swift's
        // `.animation(VolarMotion.hover, value: isOn)`, itself a single settle-to-value spring, not
        // a loop).
        var animation = new DoubleAnimation
        {
            To = targetX,
            Duration = new Duration(TimeSpan.FromMilliseconds(150)),
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut },
        };
        Storyboard.SetTarget(animation, ThumbTransform);
        Storyboard.SetTargetProperty(animation, "X");
        var storyboard = new Storyboard();
        storyboard.Children.Add(animation);
        storyboard.Begin();
    }
}
