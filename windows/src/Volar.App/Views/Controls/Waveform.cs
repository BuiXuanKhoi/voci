// Views/Controls/Waveform.cs — port of Waveform.swift (views-inventory.md §1.2), Composition-driven
// bar rendering per wave4-contract.md frozen decision 2: "No new NuGet packages... Waveform =
// Composition/keyframe animations on 32 Rectangles." No Win2D/Canvas involved.
//
// STRATEGY (a genuine re-design, not a mechanical port — see views-inventory.md §1.2 point 5's own
// flag): Swift drives every bar's height by re-evaluating a layered-sine formula on EVERY FRAME via
// `TimelineView(.animation)` + `Canvas` — the WinUI-idiomatic, no-CPU-tick equivalent is to give each
// bar ITS OWN looping Composition `ScalarKeyFrameAnimation` on its `Visual.Scale.Y`, seeded once from
// the SAME Gaussian edge-envelope Swift's formula uses (barHeight(at:t:), lines 52-61: `0.4 + 0.6 *
// exp(-((i-half)/denom)^2)`), with a per-bar duration/delay offset standing in for Swift's per-bar
// `phase = i * 0.35` (so bars visibly desync instead of moving in lockstep). Once started, the
// compositor thread drives every frame — this class's own code never re-runs after `RebuildBars`/
// `ApplyActiveState`, satisfying "must not tick CPU-side per frame."
//
// Glow: `Windows.UI.Composition.DropShadow` (built into WinAppSDK's Composition surface, NOT part of
// the Win2D package the contract forbids — the same primitive `ThemeShadow`/card-elevation shadows
// already use elsewhere in WinUI) attached to a small `SpriteVisual` sized to the bar row, colored by
// `GlowColor`, opacity toggled (not animated) by `Active` — a rectangular blurred glow standing in for
// Swift's per-bar `.addFilter(.shadow(color: glow, radius: 4))`, same "structural material-system
// approximation" caveat already documented for Glass.xaml's AcrylicBrush/NowSpotlightBrush.
//
// Gotcha compliance: gated on `UISettings.AnimationsEnabled` (contract's "Gate loops on
// UISettings.AnimationsEnabled where the Swift checks reduce-motion" — Waveform.swift itself has no
// reduce-motion check, applied here defensively per the same convention Spinner.cs already follows).
using System.Numerics;
using Microsoft.UI; // `Colors.Transparent` lives here in WinUI3, NOT Windows.UI.Colors (UWP).
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;
using Windows.UI.ViewManagement;

namespace Volar.App.Views.Controls;

/// <summary>`&lt;controls:Waveform Active="{x:Bind ViewModel.WaveformActive}" BarColor="{StaticResource AccentSolidBrush}"
/// GlowColor="{StaticResource AccentGlowBrush}"/&gt;`.</summary>
public sealed class Waveform : Grid
{
    private const double BarWidth = 3;
    private const double BarSpacing = 3;

    public static readonly DependencyProperty ActiveProperty = DependencyProperty.Register(
        nameof(Active), typeof(bool), typeof(Waveform), new PropertyMetadata(false, OnActiveChanged));

    public static readonly DependencyProperty BarColorProperty = DependencyProperty.Register(
        nameof(BarColor), typeof(Brush), typeof(Waveform), new PropertyMetadata(null, OnColorChanged));

    public static readonly DependencyProperty GlowColorProperty = DependencyProperty.Register(
        nameof(GlowColor), typeof(Brush), typeof(Waveform), new PropertyMetadata(null, OnColorChanged));

    /// <summary>Mirrors Swift's `bars: Int = 32` default (Waveform.swift:13).</summary>
    public static readonly DependencyProperty BarsProperty = DependencyProperty.Register(
        nameof(Bars), typeof(int), typeof(Waveform), new PropertyMetadata(32, OnGeometryChanged));

    /// <summary>Mirrors Swift's `height: CGFloat = 42` default (Waveform.swift:14).</summary>
    public static readonly DependencyProperty BarHeightProperty = DependencyProperty.Register(
        nameof(BarHeight), typeof(double), typeof(Waveform), new PropertyMetadata(42.0, OnGeometryChanged));

    private readonly Grid _glowHost;
    private readonly StackPanel _barsHost;
    private Rectangle[] _bars = Array.Empty<Rectangle>();
    private DropShadow? _shadow;
    private SpriteVisual? _shadowVisual;
    private bool _loaded;

    public Waveform()
    {
        HorizontalAlignment = HorizontalAlignment.Stretch;
        VerticalAlignment = VerticalAlignment.Center;

        _glowHost = new Grid { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        _barsHost = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = BarSpacing,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };

        Children.Add(_glowHost);
        Children.Add(_barsHost);

        Loaded += (_, _) =>
        {
            _loaded = true;
            RebuildBars();
        };
        Unloaded += (_, _) =>
        {
            _loaded = false;
            StopAllBarAnimations();
        };

        RebuildBars();
    }

    public bool Active
    {
        get => (bool)GetValue(ActiveProperty);
        set => SetValue(ActiveProperty, value);
    }

    public Brush? BarColor
    {
        get => (Brush?)GetValue(BarColorProperty);
        set => SetValue(BarColorProperty, value);
    }

    public Brush? GlowColor
    {
        get => (Brush?)GetValue(GlowColorProperty);
        set => SetValue(GlowColorProperty, value);
    }

    public int Bars
    {
        get => (int)GetValue(BarsProperty);
        set => SetValue(BarsProperty, value);
    }

    public double BarHeight
    {
        get => (double)GetValue(BarHeightProperty);
        set => SetValue(BarHeightProperty, value);
    }

    private static void OnActiveChanged(DependencyObject d, DependencyPropertyChangedEventArgs e) =>
        ((Waveform)d).ApplyActiveState();

    private static void OnColorChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        var waveform = (Waveform)d;
        waveform.UpdateBarColors();
        waveform.UpdateGlow();
    }

    private static void OnGeometryChanged(DependencyObject d, DependencyPropertyChangedEventArgs e) =>
        ((Waveform)d).RebuildBars();

    private void RebuildBars()
    {
        StopAllBarAnimations();
        _barsHost.Children.Clear();

        var count = Math.Max(1, Bars);
        var barMaxHeight = Math.Max(BarWidth, BarHeight - 4);
        Height = BarHeight;

        _bars = new Rectangle[count];
        for (var i = 0; i < count; i++)
        {
            var rect = new Rectangle
            {
                Width = BarWidth,
                Height = barMaxHeight,
                RadiusX = BarWidth / 2,
                RadiusY = BarWidth / 2,
                VerticalAlignment = VerticalAlignment.Center,
            };
            _bars[i] = rect;
            _barsHost.Children.Add(rect);
        }

        UpdateBarColors();
        UpdateGlow();
        ApplyActiveState();
    }

    private void UpdateBarColors()
    {
        var brush = BarColor ?? (Brush)Application.Current.Resources["AccentSolidBrush"];
        foreach (var bar in _bars)
        {
            bar.Fill = brush;
        }
    }

    private void UpdateGlow()
    {
        var count = Math.Max(1, Bars);
        var width = count * BarWidth + Math.Max(0, count - 1) * BarSpacing;
        _glowHost.Width = width;
        _glowHost.Height = BarHeight;

        var visual = ElementCompositionPreview.GetElementVisual(_glowHost);
        var compositor = visual.Compositor;

        if (_shadow is null)
        {
            _shadow = compositor.CreateDropShadow();
            _shadow.BlurRadius = 16f;
            _shadowVisual = compositor.CreateSpriteVisual();
            _shadowVisual.Shadow = _shadow;
            ElementCompositionPreview.SetElementChildVisual(_glowHost, _shadowVisual);
        }

        _shadow.Color = (GlowColor as SolidColorBrush)?.Color ?? Colors.Transparent;
        _shadowVisual!.Size = new Vector2((float)width, (float)BarHeight);
        UpdateGlowOpacity();
    }

    private void UpdateGlowOpacity()
    {
        if (_shadow is not null)
        {
            _shadow.Opacity = Active ? 0.55f : 0f;
        }
    }

    private void ApplyActiveState()
    {
        UpdateGlowOpacity();
        if (!_loaded || _bars.Length == 0)
        {
            return;
        }

        var animationsEnabled = new UISettings().AnimationsEnabled;
        var barMaxHeight = Math.Max(BarWidth, BarHeight - 4);

        if (Active && animationsEnabled)
        {
            StartBarAnimations(barMaxHeight);
        }
        else
        {
            SettleFlat(barMaxHeight);
        }
    }

    /// <summary>Gaussian edge-envelope + per-bar looping scale animation — see file header
    /// "STRATEGY". Envelope formula ported verbatim from Waveform.swift's `barHeight(at:t:)`
    /// (58-60): `0.4 + 0.6 * exp(-((i-half)/denom)^2)`.</summary>
    private void StartBarAnimations(double barMaxHeight)
    {
        var half = (_bars.Length - 1) / 2.0;
        var denom = _bars.Length / 2.6;
        var minScale = (float)(2.0 / barMaxHeight); // Swift's `max(2, ...)` height floor.

        for (var i = 0; i < _bars.Length; i++)
        {
            var visual = ElementCompositionPreview.GetElementVisual(_bars[i]);
            var compositor = visual.Compositor;
            visual.CenterPoint = new Vector3((float)(BarWidth / 2), (float)(barMaxHeight / 2), 0);

            var envelope = 0.4 + 0.6 * Math.Exp(-Math.Pow((i - half) / denom, 2));
            var peakScale = (float)Math.Clamp(envelope, minScale, 1.0);
            var restScale = (float)Math.Clamp(envelope * 0.4, minScale, 1.0);

            var animation = compositor.CreateScalarKeyFrameAnimation();
            animation.InsertKeyFrame(0f, minScale);
            animation.InsertKeyFrame(0.30f, peakScale);
            animation.InsertKeyFrame(0.55f, restScale);
            animation.InsertKeyFrame(0.80f, peakScale * 0.85f);
            animation.InsertKeyFrame(1f, minScale);
            // Per-bar phase desync stands in for Swift's shared-clock `phase = i * 0.35` term — no
            // two bars share an identical cycle, approximating the layered-sine "organic murmur"
            // without any shared per-frame driver.
            animation.Duration = TimeSpan.FromSeconds(0.9 + (i % 7) * 0.11);
            animation.DelayTime = TimeSpan.FromSeconds((i % 5) * 0.07);
            animation.IterationBehavior = AnimationIterationBehavior.Forever;

            visual.StartAnimation("Scale.Y", animation);
        }
    }

    /// <summary>Port of Waveform.swift's inactive branch (39-43): "settles to a flat 3px line (no
    /// animation)".</summary>
    private void SettleFlat(double barMaxHeight)
    {
        var flatScale = (float)Math.Clamp(3.0 / barMaxHeight, 0.0, 1.0);
        foreach (var bar in _bars)
        {
            var visual = ElementCompositionPreview.GetElementVisual(bar);
            visual.StopAnimation("Scale.Y");
            visual.Scale = new Vector3(1f, flatScale, 1f);
        }
    }

    private void StopAllBarAnimations()
    {
        foreach (var bar in _bars)
        {
            ElementCompositionPreview.GetElementVisual(bar).StopAnimation("Scale.Y");
        }
    }
}
