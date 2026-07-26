// Views/Controls/AmbientBackground.xaml.cs — see AmbientBackground.xaml header. Static v1 port of
// AmbientBackground.swift (417 lines) per wave4-contract.md frozen decision 3.
//
// DELETED, NOT PORTED (views-inventory.md §1.14 point 6, decision 3's own instruction):
// `SecureImageBookmark`'s entire App-Sandbox security-scoped-bookmark subsystem
// (AmbientBackground.swift:303-397, 77 lines) is Mac-sandbox-only plumbing with no Windows
// equivalent need — Windows has no App Sandbox for this unpackaged deployment, so a chosen file
// path is simply stored and re-read directly. This control accepts a plain <see cref="ImagePath"/>
// string (matching AppearanceAndPersistenceService.CustomImagePath's own already-plain storage) and
// loads it straight into a BitmapImage — no bookmark/re-resolution dance.
//
// NO PARTICLE SYSTEM: rain/snow/embers each render as a flat 3-stop gradient backdrop (the exact
// AMBIENT_BACKDROPS hex literals from AmbientBackground.swift:60-83) instead of the Swift file's
// TimelineView+Canvas per-frame particle animation (130/90/38 rain/snow/embers particles,
// SplitMix64-seeded) — views-inventory.md §1.14 point 7 flags this as needing a rendering-strategy
// decision the frozen contract already made for v1 (static only; full particle fidelity is backlog).
using System;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Volar.Speech.Ambient;
using Windows.UI;

namespace Volar.App.Views.Controls;

public sealed partial class AmbientBackground : UserControl
{
    // Decode-size cap on the long edge — bounds decode memory for an arbitrarily large user-chosen
    // photo while staying generous for a full-window background (no dedicated size budget existed
    // in the Swift source either — views-inventory.md §1.14 doesn't flag one — this is a new,
    // Windows-side-only guard, not a ported value).
    private const int MaxDecodePixels = 2048;

    public static readonly DependencyProperty ModeProperty = DependencyProperty.Register(
        nameof(Mode), typeof(AmbientMode), typeof(AmbientBackground), new PropertyMetadata(AmbientMode.None, OnVisualChanged));

    public static readonly DependencyProperty ImagePathProperty = DependencyProperty.Register(
        nameof(ImagePath), typeof(string), typeof(AmbientBackground), new PropertyMetadata(null, OnVisualChanged));

    private string? _loadedImagePath;

    public AmbientBackground()
    {
        InitializeComponent();
        UpdateVisual();
    }

    public AmbientMode Mode
    {
        get => (AmbientMode)GetValue(ModeProperty);
        set => SetValue(ModeProperty, value);
    }

    public string? ImagePath
    {
        get => (string?)GetValue(ImagePathProperty);
        set => SetValue(ImagePathProperty, value);
    }

    private static void OnVisualChanged(DependencyObject d, DependencyPropertyChangedEventArgs e) =>
        ((AmbientBackground)d).UpdateVisual();

    private void UpdateVisual()
    {
        var appResources = Application.Current.Resources;
        CustomImage.Visibility = Visibility.Collapsed;
        CustomImageDimBorder.Visibility = Visibility.Collapsed;
        CustomPlaceholder.Visibility = Visibility.Collapsed;
        VignetteBorder.Visibility = Visibility.Collapsed;

        switch (Mode)
        {
            case AmbientMode.Custom:
                // AmbientBackground.swift:34 `Color(volar: 0x101014)`.
                BackdropBorder.Background = SolidBrush(0xFF101014);
                ApplyCustomImage();
                VignetteBorder.Background = VignetteBrush();
                VignetteBorder.Visibility = Visibility.Visible;
                break;

            // AmbientBackground.swift:63-67 `AMBIENT_BACKDROPS.rain`.
            case AmbientMode.Rain:
                BackdropBorder.Background = BackdropBrush(0xFF0C1220, 0xFF101A2E, 0xFF090E1A, 0.55);
                VignetteBorder.Background = VignetteBrush();
                VignetteBorder.Visibility = Visibility.Visible;
                break;

            // AmbientBackground.swift:69-73 `AMBIENT_BACKDROPS.snow`.
            case AmbientMode.Snow:
                BackdropBorder.Background = BackdropBrush(0xFF0E1422, 0xFF16203A, 0xFF0B101E, 0.60);
                VignetteBorder.Background = VignetteBrush();
                VignetteBorder.Visibility = Visibility.Visible;
                break;

            // AmbientBackground.swift:75-79 `AMBIENT_BACKDROPS.embers`.
            case AmbientMode.Embers:
                BackdropBorder.Background = BackdropBrush(0xFF120D0C, 0xFF1C120E, 0xFF0D0908, 0.60);
                VignetteBorder.Background = VignetteBrush();
                VignetteBorder.Visibility = Visibility.Visible;
                break;

            case AmbientMode.None:
            default:
                BackdropBorder.Background = (Brush)appResources["VolarBgBrush"];
                break;
        }
    }

    private void ApplyCustomImage()
    {
        if (string.IsNullOrEmpty(ImagePath))
        {
            CustomPlaceholder.Visibility = Visibility.Visible;
            _loadedImagePath = null;
            CustomImage.Source = null;
            return;
        }

        CustomPlaceholder.Visibility = Visibility.Collapsed;
        CustomImage.Visibility = Visibility.Visible;
        CustomImageDimBorder.Visibility = Visibility.Visible;

        if (_loadedImagePath == ImagePath && CustomImage.Source is not null)
        {
            return; // already loaded/cached — avoid re-decoding on every unrelated property change.
        }

        try
        {
            var bitmap = new BitmapImage { DecodePixelWidth = MaxDecodePixels };
            bitmap.UriSource = new Uri(ImagePath!);
            CustomImage.Source = bitmap;
            _loadedImagePath = ImagePath;
        }
        catch
        {
            // A missing/unreadable path degrades to the placeholder — never throw out of a visual
            // update. Mirrors SecureImageBookmark.loadImage's own "never throws" contract, even
            // though that whole subsystem itself is deliberately not ported (see file header).
            CustomImage.Visibility = Visibility.Collapsed;
            CustomImageDimBorder.Visibility = Visibility.Collapsed;
            CustomPlaceholder.Visibility = Visibility.Visible;
            _loadedImagePath = null;
        }
    }

    private static Brush SolidBrush(uint argb) => new SolidColorBrush(ColorFromArgb(argb));

    private static Brush BackdropBrush(uint top, uint mid, uint bottom, double midOffset)
    {
        var brush = new LinearGradientBrush
        {
            StartPoint = new Windows.Foundation.Point(0.5, 0),
            EndPoint = new Windows.Foundation.Point(0.5, 1),
        };
        brush.GradientStops.Add(new GradientStop { Color = ColorFromArgb(top), Offset = 0 });
        brush.GradientStops.Add(new GradientStop { Color = ColorFromArgb(mid), Offset = midOffset });
        brush.GradientStops.Add(new GradientStop { Color = ColorFromArgb(bottom), Offset = 1 });
        return brush;
    }

    /// <summary>AmbientBackground.swift:85-99's vignette: `radial-gradient(120% 90% at 50% 30%,
    /// transparent 40%, rgba(0,0,0,0.45) 100%)`. Same relative-vs-absolute + off-axis-center mapping
    /// approach as Theme/Glass.xaml's `NowSpotlightVignetteBrush` (Stage A) — not added to that
    /// shared dictionary (frozen decision 3: the ambient palette stays a separate, view-local
    /// literal set, matching the Swift file's own distinct-from-UI-palette framing).</summary>
    private static Brush VignetteBrush()
    {
        var brush = new RadialGradientBrush
        {
            Center = new Windows.Foundation.Point(0.5, 0.3),
            RadiusX = 0.85,
            RadiusY = 0.85,
        };
        brush.GradientStops.Add(new GradientStop { Color = Colors.Transparent, Offset = 0.4 });
        // rgba(0,0,0,0.45) -> alpha round(0.45*255) = 114.75 -> 115 = 0x73.
        brush.GradientStops.Add(new GradientStop { Color = ColorFromArgb(0x73000000), Offset = 1.0 });
        return brush;
    }

    private static Color ColorFromArgb(uint argb) => Color.FromArgb(
        (byte)(argb >> 24), (byte)(argb >> 16), (byte)(argb >> 8), (byte)argb);
}
