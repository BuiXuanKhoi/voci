// Views/Controls/Spinner.cs — port of Components.swift's `Spinner` (lines 101-129): rotating
// trimmed-arc ring spinner. wave4-contract.md Stage A deliverable 2 + frozen decision 2 (hand-rolled
// rotate Storyboard, no Win2D/toolkit dependency).
//
// Hand-rolled per the contract's own call: "Spinner may use stock ProgressRing only if restyled to
// match; otherwise hand-rolled rotate Storyboard." WinUI's stock ProgressRing's indeterminate visual
// (a ring of animated dots) doesn't match Swift's single quarter-arc rotation without rebuilding
// most of its template anyway, so this ports the arc directly: a full low-opacity "track" Ellipse
// (Swift: `color.opacity(0.2)`) plus a second Ellipse whose `StrokeDashArray` is computed so only
// 25% of its circumference draws (Swift: `.trim(from: 0, to: 0.25)`), continuously rotated by a
// `RotateTransform` + linear, non-easing, forever-repeating `Storyboard` (Swift:
// `.linear(duration: 0.7).repeatForever(autoreverses: false)`).
//
// Contract's explicit visual spec ("size 14, line width 2, accent color") takes the 2px line width
// over Swift's literal `lineWidth: 1.6` (Components.swift:115/119) — a deliberate, contract-directed
// deviation, not a porting slip.
//
// Gotcha compliance: this is one of the handful of surfaces the contract's gotcha list explicitly
// allows to loop forever (MorningFrog pulse / Spinner / Popover PulsingDot &c.), but that same
// gotcha also says "Gate loops on UISettings.AnimationsEnabled where the Swift checks
// reduce-motion" — Swift's own `Spinner` doesn't check reduce-motion (no
// `@Environment(\.accessibilityReduceMotion)` in this file), but this port gates anyway, applying
// the general Windows accessibility convention defensively: when animations are disabled system-wide
// the arc renders statically at its start angle instead of spinning.
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;
using Windows.UI.ViewManagement;

namespace Volar.App.Views.Controls;

/// <summary>`&lt;controls:Spinner SpinnerColor="{StaticResource AccentSolidBrush}"/&gt;`.</summary>
public sealed class Spinner : Grid
{
    /// <summary>Contract's explicit spec overrides Swift's literal 1.6 (Components.swift:115/119)
    /// — see file header.</summary>
    private const double LineWidth = 2.0;

    /// <summary>`color.opacity(0.2)` (Components.swift:115) — applied as the track Ellipse's own
    /// `Opacity`, not a derived brush, so the track always tracks whatever brush `SpinnerColor`
    /// currently is (including live accent-family mutation) without needing a second bound brush.</summary>
    private const double TrackOpacity = 0.2;

    /// <summary>`.trim(from: 0, to: 0.25)` (Components.swift:118).</summary>
    private const double ArcFraction = 0.25;

    public static readonly DependencyProperty SpinnerColorProperty = DependencyProperty.Register(
        nameof(SpinnerColor), typeof(Brush), typeof(Spinner), new PropertyMetadata(null, OnColorChanged));

    /// <summary>Mirrors Swift's `size: CGFloat = 14` default (Components.swift:104/108).</summary>
    public static readonly DependencyProperty SpinnerSizeProperty = DependencyProperty.Register(
        nameof(SpinnerSize), typeof(double), typeof(Spinner), new PropertyMetadata(14.0, OnSizeChanged));

    private readonly Ellipse _track;
    private readonly Ellipse _arc;
    private readonly RotateTransform _rotate;
    private Storyboard? _storyboard;

    public Spinner()
    {
        _track = new Ellipse();
        _arc = new Ellipse
        {
            StrokeStartLineCap = PenLineCap.Round,
            StrokeEndLineCap = PenLineCap.Round,
            RenderTransformOrigin = new Point(0.5, 0.5),
        };
        _rotate = new RotateTransform();
        _arc.RenderTransform = _rotate;

        Children.Add(_track);
        Children.Add(_arc);

        Loaded += (_, _) => StartOrRestartAnimation();
        Unloaded += (_, _) => StopAnimation();

        UpdateGeometry();
        UpdateColors();
    }

    /// <summary>Mirrors Swift's `color: Color` init param (Components.swift:103/108 — required,
    /// no default). Falls back to the shared accent brush if unset so a bare
    /// <c>&lt;controls:Spinner/&gt;</c> still renders something reasonable.</summary>
    public Brush? SpinnerColor
    {
        get => (Brush?)GetValue(SpinnerColorProperty);
        set => SetValue(SpinnerColorProperty, value);
    }

    public double SpinnerSize
    {
        get => (double)GetValue(SpinnerSizeProperty);
        set => SetValue(SpinnerSizeProperty, value);
    }

    private static void OnColorChanged(DependencyObject d, DependencyPropertyChangedEventArgs e) =>
        ((Spinner)d).UpdateColors();

    private static void OnSizeChanged(DependencyObject d, DependencyPropertyChangedEventArgs e) =>
        ((Spinner)d).UpdateGeometry();

    private void UpdateColors()
    {
        var brush = SpinnerColor ?? (Brush)Application.Current.Resources["AccentSolidBrush"];
        _track.Stroke = brush;
        _track.Opacity = TrackOpacity;
        _arc.Stroke = brush;
    }

    private void UpdateGeometry()
    {
        Width = SpinnerSize;
        Height = SpinnerSize;

        var diameter = Math.Max(0, SpinnerSize - LineWidth);
        _track.Width = diameter;
        _track.Height = diameter;
        _track.StrokeThickness = LineWidth;

        _arc.Width = diameter;
        _arc.Height = diameter;
        _arc.StrokeThickness = LineWidth;

        // StrokeDashArray values are multiples of StrokeThickness (WinUI shape-stroke convention),
        // not absolute pixels — convert the desired arc-length fraction of the circle's
        // circumference into that unit so exactly ArcFraction (25%) of the ring draws, matching
        // SwiftUI's `.trim(from:to:)` percentage semantics.
        var circumference = Math.PI * diameter;
        var dashLength = circumference * ArcFraction / LineWidth;
        var gapLength = circumference * (1 - ArcFraction) / LineWidth;
        _arc.StrokeDashArray = new DoubleCollection { dashLength, gapLength };

        StartOrRestartAnimation();
    }

    private void StartOrRestartAnimation()
    {
        StopAnimation();

        // Defensive reduce-motion gate — see file header. Swift's own Spinner doesn't check this,
        // but the contract's gotcha list asks every repeat-forever loop to respect it.
        if (!new UISettings().AnimationsEnabled)
        {
            _rotate.Angle = 0;
            return;
        }

        var animation = new DoubleAnimation
        {
            From = 0,
            To = 360,
            Duration = new Duration(TimeSpan.FromSeconds(0.7)),
            RepeatBehavior = RepeatBehavior.Forever,
            EasingFunction = null, // linear, no easing — matches `.linear(duration: 0.7)`.
        };
        Storyboard.SetTarget(animation, _rotate);
        Storyboard.SetTargetProperty(animation, nameof(RotateTransform.Angle));

        _storyboard = new Storyboard();
        _storyboard.Children.Add(animation);
        _storyboard.Begin();
    }

    private void StopAnimation()
    {
        _storyboard?.Stop();
        _storyboard = null;
    }
}
