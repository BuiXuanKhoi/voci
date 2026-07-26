// Views/Controls/VolarIcon.cs — port of `Volar/Sources/Design/VolarIcon.swift`'s
// `VolarIcon(_ name:size:color:weight:)` view (spec: wave4-contract.md Stage A deliverable 1).
//
// Implemented as a plain code-behind FontIcon wrapper (no separate .xaml/ControlTemplate — the
// contract explicitly allows "a plain templated control / FontIcon wrapper — your choice") rather
// than a UserControl, for one concrete reason: FrameworkElement already declares a CLR property
// named `Name` (string, used by the x:Name/namescope mechanism) — the contract's own prose asks
// for a "`Name` dependency property taking a `VolarIconName` enum", but that literally cannot
// coexist with the inherited `Name` (same identifier, incompatible type, and WinUI's XAML compiler
// has special-cased handling of the bare `Name=` attribute for namescope registration). The DP is
// named `IconName` instead — flagged as a deviation in this agent's final report, not a silent
// rename.
//
// Swift's `weight: Font.Weight` parameter has no port here: Segoe MDL2 Assets/Segoe Fluent Icons
// glyphs are single-weight (unlike SF Symbols, which render at the surrounding text's weight) — no
// WinUI FontIcon equivalent exists, so `weight` is dropped rather than faked.
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Volar.App.Views.Controls;

/// <summary>`&lt;controls:VolarIcon IconName="Mic"/&gt;` — the one place XAML reaches for an icon
/// glyph. Composes a `FontIcon` (glyph mode) and a `TextBlock` (text-fallback mode, `Cmd` only),
/// toggling which is visible based on <see cref="VolarIconGlyphs.IsTextMode"/>.</summary>
public sealed class VolarIcon : Grid
{
    /// <summary>Segoe Fluent Icons is listed first so a Win11 box with the newer font renders from
    /// it; Segoe MDL2 Assets is the guaranteed fallback on the Win10 19045 dev/test machine (frozen
    /// contract decision 1). Every codepoint in <see cref="VolarIconGlyphs"/> is chosen to exist in
    /// the OLDER (MDL2) font, so both resolve to the same glyph.</summary>
    private static readonly FontFamily IconFontFamily = new("Segoe Fluent Icons,Segoe MDL2 Assets");

    public static readonly DependencyProperty IconNameProperty = DependencyProperty.Register(
        nameof(IconName),
        typeof(VolarIconName),
        typeof(VolarIcon),
        new PropertyMetadata(VolarIconName.Mic, OnVisualPropertyChanged));

    /// <summary>Mirrors Swift's `size: CGFloat = 14` default (VolarIcon.swift:55).</summary>
    public static readonly DependencyProperty IconSizeProperty = DependencyProperty.Register(
        nameof(IconSize),
        typeof(double),
        typeof(VolarIcon),
        new PropertyMetadata(14.0, OnVisualPropertyChanged));

    /// <summary>Mirrors Swift's `color: Color = VolarColor.textPri` default. Left <see langword="null"/>
    /// until first applied so the default can resolve `VolarTextPriBrush` from Application.Resources
    /// lazily (avoids touching resources from a static field initializer).</summary>
    public static readonly DependencyProperty IconBrushProperty = DependencyProperty.Register(
        nameof(IconBrush),
        typeof(Brush),
        typeof(VolarIcon),
        new PropertyMetadata(null, OnVisualPropertyChanged));

    private readonly FontIcon _glyphIcon;
    private readonly TextBlock _textFallback;

    public VolarIcon()
    {
        _glyphIcon = new FontIcon { FontFamily = IconFontFamily };
        _textFallback = new TextBlock
        {
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        Children.Add(_glyphIcon);
        Children.Add(_textFallback);
        UpdateVisual();
    }

    public VolarIconName IconName
    {
        get => (VolarIconName)GetValue(IconNameProperty);
        set => SetValue(IconNameProperty, value);
    }

    public double IconSize
    {
        get => (double)GetValue(IconSizeProperty);
        set => SetValue(IconSizeProperty, value);
    }

    public Brush? IconBrush
    {
        get => (Brush?)GetValue(IconBrushProperty);
        set => SetValue(IconBrushProperty, value);
    }

    private static void OnVisualPropertyChanged(DependencyObject d, DependencyPropertyChangedEventArgs e) =>
        ((VolarIcon)d).UpdateVisual();

    private void UpdateVisual()
    {
        var brush = IconBrush ?? (Brush)Application.Current.Resources["VolarTextPriBrush"];
        if (VolarIconGlyphs.IsTextMode(IconName))
        {
            _glyphIcon.Visibility = Visibility.Collapsed;
            _textFallback.Visibility = Visibility.Visible;
            _textFallback.Text = VolarIconGlyphs.TextFallback(IconName);
            _textFallback.FontSize = IconSize;
            _textFallback.Foreground = brush;
        }
        else
        {
            _textFallback.Visibility = Visibility.Collapsed;
            _glyphIcon.Visibility = Visibility.Visible;
            _glyphIcon.Glyph = VolarIconGlyphs.Glyph(IconName);
            _glyphIcon.FontSize = IconSize;
            _glyphIcon.Foreground = brush;
        }
    }
}
