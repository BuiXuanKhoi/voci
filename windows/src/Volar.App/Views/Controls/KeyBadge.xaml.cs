// Views/Controls/KeyBadge.xaml.cs — see KeyBadge.xaml header. Port of Components.swift:11-38.
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace Volar.App.Views.Controls;

public sealed partial class KeyBadge : UserControl
{
    // VolarColor.veil(0.08) -> alpha = round(0.08*255) = 20.4 -> 20 = 0x14 (Components.swift:31,
    // the non-accent background).
    private static readonly SolidColorBrush WhiteOpacity08 = new(Color.FromArgb(0x14, 0x94, 0xB2, 0xE0));

    // VolarColor.veil(0.10) -> alpha = round(0.10*255) = 25.5 -> 26 = 0x1A (Components.swift:35,
    // the non-accent border stroke).
    private static readonly SolidColorBrush WhiteOpacity10 = new(Color.FromArgb(0x1A, 0x94, 0xB2, 0xE0));

    public static readonly DependencyProperty TextProperty = DependencyProperty.Register(
        nameof(Text), typeof(string), typeof(KeyBadge), new PropertyMetadata(string.Empty, OnVisualChanged));

    public static readonly DependencyProperty AccentProperty = DependencyProperty.Register(
        nameof(Accent), typeof(bool), typeof(KeyBadge), new PropertyMetadata(false, OnVisualChanged));

    public KeyBadge()
    {
        InitializeComponent();
        UpdateVisual();
    }

    public string Text
    {
        get => (string)GetValue(TextProperty);
        set => SetValue(TextProperty, value);
    }

    /// <summary>Mirrors Swift's `accent: Bool` init param (Components.swift:14/18).</summary>
    public bool Accent
    {
        get => (bool)GetValue(AccentProperty);
        set => SetValue(AccentProperty, value);
    }

    private static void OnVisualChanged(DependencyObject d, DependencyPropertyChangedEventArgs e) =>
        ((KeyBadge)d).UpdateVisual();

    private void UpdateVisual()
    {
        LabelText.Text = Text;
        var appResources = Application.Current.Resources;
        if (Accent)
        {
            LabelText.Foreground = (Brush)appResources["AccentSolidBrush"];
            RootBorder.Background = (Brush)appResources["AccentSurfaceBrush"];
            RootBorder.BorderBrush = (Brush)Resources["AccentStrokeOpacityBrush"];
        }
        else
        {
            LabelText.Foreground = (Brush)appResources["VolarTextSecBrush"];
            RootBorder.Background = WhiteOpacity08;
            RootBorder.BorderBrush = WhiteOpacity10;
        }
    }
}
