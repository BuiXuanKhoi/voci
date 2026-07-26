// Views/Controls/GlassPanel.cs — port of Glass.swift's `GlassBackground`/`.volarGlass(...)` (spec
// §6) as a reusable WinUI ContentControl. wave4-contract.md Stage A deliverable 3; shared-control
// manifest item 2 (views-inventory.md §2) — nearly every modal/sheet view (Notification,
// MorningFrog, TaskDetail, TaskBreakdown, Triage, Sweep, Popover) plus Sidebar's conditional
// background needs this instead of hand-rolling the Border+Border composition each view would
// otherwise duplicate slightly differently.
//
// No companion `.xaml` file (this task's brief names a single "GlassPanel.cs" deliverable) — but a
// custom `ControlTemplate` IS still required: verified against the actual WindowsAppSDK WinUI
// package (`Microsoft.WinUI/Themes/generic.xaml` in the local NuGet cache) that the STOCK default
// `ContentControl` template is a BARE `ContentPresenter` with no `Border`/`Background`/
// `BorderBrush`/`CornerRadius` wiring at all — unlike `Button`/`ComboBox`, plain `ContentControl`
// has no chrome by default, so simply setting `Background`/`BorderBrush`/`BorderThickness`/
// `CornerRadius` on an untemplated `ContentControl` would render NOTHING (an earlier draft of this
// file made that (wrong) assumption; corrected after checking the actual shipped template XAML).
//
// WinUI/UWP has no programmatic `FrameworkElementFactory` equivalent — a `ControlTemplate` can only
// be built by parsing XAML — so the constructor below builds one via
// `XamlReader.Load(string)` from an inline XAML string constant, keeping the whole control in this
// one `.cs` file (no separate `.xaml` page) while still getting a real templated Border+
// ContentPresenter visual tree.
//
// CornerRadius gotcha: `Control.CornerRadius` is a real DP (type `Microsoft.UI.Xaml.CornerRadius`),
// so `<controls:GlassPanel CornerRadius="16"/>` works directly in XAML — but per the
// CornerRadius/Thickness gotcha, every CALLER must still hand-copy its literal radius number
// (12 glass / 9 hairline / 6 small / one-offs 14/16/18 per view, citing the Metrics.xaml name or
// noting "one-off" in a comment at the call site) rather than reach for a `{StaticResource
// VolarCornerRadiusGlass}` binding, which XAML cannot resolve for a CornerRadius-typed property.
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using Volar.App.Services.State;
using Windows.UI;

namespace Volar.App.Views.Controls;

/// <summary>
/// <c>&lt;controls:GlassPanel Level="Heavy" CornerRadius="16"&gt;...&lt;/controls:GlassPanel&gt;</c>
/// — Background/BorderBrush computed from <see cref="Level"/> (and optionally
/// <see cref="TintOverlay"/>) on construction and whenever either property changes.
/// </summary>
public sealed class GlassPanel : ContentControl
{
    // Matches Glass.swift's `GlassBackground.body`: fill(material) -> overlay(tint.opacity(...))
    // -> overlay(stroke(borderColor, 0.5)) — expressed here as Border.Background (material+tint,
    // already combined in the AcrylicBrush UpdateVisual assigns) + Border.BorderBrush/Thickness
    // (the hairline stroke) wrapping a ContentPresenter that mirrors the stock ContentControl
    // template's own TemplateBinding set (see file header) so Padding/ContentTemplate/alignment
    // all keep working normally for any content placed inside a GlassPanel.
    private const string TemplateXaml = """
        <ControlTemplate
            xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
            xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
            TargetType="ContentControl">
            <Border
                Background="{TemplateBinding Background}"
                BorderBrush="{TemplateBinding BorderBrush}"
                BorderThickness="{TemplateBinding BorderThickness}"
                CornerRadius="{TemplateBinding CornerRadius}">
                <ContentPresenter
                    Content="{TemplateBinding Content}"
                    ContentTemplate="{TemplateBinding ContentTemplate}"
                    Margin="{TemplateBinding Padding}"
                    HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                    VerticalAlignment="{TemplateBinding VerticalContentAlignment}" />
            </Border>
        </ControlTemplate>
        """;

    public static readonly DependencyProperty LevelProperty = DependencyProperty.Register(
        nameof(Level), typeof(GlassLevel), typeof(GlassPanel), new PropertyMetadata(GlassLevel.Standard, OnVisualChanged));

    /// <summary>Mirrors Glass.swift's `GlassBackground.tint: Color = VolarColor.bg` init param —
    /// <see langword="null"/> (the default) uses the shared, pre-built
    /// <c>VolarGlassSubtleBrush/StandardBrush/HeavyBrush</c> resource for <see cref="Level"/>
    /// (Glass.xaml) exactly as-is; a non-null override (e.g. NotificationView's one-off
    /// <c>Color(volar: 0x282828)</c> tint, views-inventory.md §1.1) builds a fresh
    /// <see cref="AcrylicBrush"/> with the same TintOpacity table but a caller-supplied TintColor.</summary>
    public static readonly DependencyProperty TintOverlayProperty = DependencyProperty.Register(
        nameof(TintOverlay), typeof(Color?), typeof(GlassPanel), new PropertyMetadata(null, OnVisualChanged));

    public GlassPanel()
    {
        Template = (ControlTemplate)XamlReader.Load(TemplateXaml);

        // VolarCornerRadiusGlass (Metrics.xaml) — the GlassBackground default (Glass.swift:22);
        // callers needing a different one-off (14/16/18 etc.) set CornerRadius explicitly.
        CornerRadius = new CornerRadius(12);
        BorderThickness = new Thickness(0.5); // VolarHairlineThickness (Metrics.xaml) — literal per the gotcha.
        HorizontalContentAlignment = HorizontalAlignment.Stretch;
        VerticalContentAlignment = VerticalAlignment.Stretch;
        UpdateVisual();
    }

    public GlassLevel Level
    {
        get => (GlassLevel)GetValue(LevelProperty);
        set => SetValue(LevelProperty, value);
    }

    public Color? TintOverlay
    {
        get => (Color?)GetValue(TintOverlayProperty);
        set => SetValue(TintOverlayProperty, value);
    }

    private static void OnVisualChanged(DependencyObject d, DependencyPropertyChangedEventArgs e) =>
        ((GlassPanel)d).UpdateVisual();

    private void UpdateVisual()
    {
        var appResources = Application.Current.Resources;
        Background = TintOverlay is Color tint
            ? new AcrylicBrush
            {
                TintColor = tint,
                TintOpacity = BgOpacityFor(Level),
                FallbackColor = (Color)appResources["VolarSurface"],
            }
            : (Brush)appResources[SharedBrushKeyFor(Level)];

        // "always bundling the hairline border" (this task's brief) — VolarGlassBorderBrush exists
        // in Glass.xaml (bound to VolarBorderHi), so that's the one used, per the brief's own
        // fallback note ("...if it exists in Glass.xaml, else VolarBorderBrush").
        BorderBrush = (Brush)appResources["VolarGlassBorderBrush"];
    }

    private static string SharedBrushKeyFor(GlassLevel level) => level switch
    {
        GlassLevel.Subtle => "VolarGlassSubtleBrush",
        GlassLevel.Heavy => "VolarGlassHeavyBrush",
        _ => "VolarGlassStandardBrush",
    };

    /// <summary>`GlassLevel.bgOpacity` (Theme.swift:198-205 / Glass.xaml's AcrylicBrush TintOpacity
    /// values) — duplicated here (not read from the XAML brushes) because an overridden
    /// <see cref="TintOverlay"/> needs a brand-new <see cref="AcrylicBrush"/> instance, not a
    /// TintColor swap on the shared one (mutating a shared brush's TintColor would leak into every
    /// OTHER view still using the default tint).</summary>
    private static double BgOpacityFor(GlassLevel level) => level switch
    {
        GlassLevel.Subtle => 0.92,
        GlassLevel.Heavy => 0.55,
        _ => 0.78,
    };
}
