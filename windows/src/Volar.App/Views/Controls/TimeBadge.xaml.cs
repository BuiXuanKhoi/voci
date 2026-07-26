// Views/Controls/TimeBadge.xaml.cs — see TimeBadge.xaml header. Port of Components.swift:74-99.
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace Volar.App.Views.Controls;

public sealed partial class TimeBadge : UserControl
{
    private static readonly SolidColorBrush WhiteBrush = new(Color.FromArgb(0xFF, 255, 255, 255));

    public static readonly DependencyProperty TextProperty = DependencyProperty.Register(
        nameof(Text), typeof(string), typeof(TimeBadge), new PropertyMetadata(string.Empty, OnVisualChanged));

    /// <summary>Mirrors Swift's `filled: Bool` init param (Components.swift:78/82) — the
    /// solid-fill "isActive" variant TaskRow uses.</summary>
    public static readonly DependencyProperty FilledProperty = DependencyProperty.Register(
        nameof(Filled), typeof(bool), typeof(TimeBadge), new PropertyMetadata(false, OnVisualChanged));

    public TimeBadge()
    {
        InitializeComponent();
        UpdateVisual();
    }

    public string Text
    {
        get => (string)GetValue(TextProperty);
        set => SetValue(TextProperty, value);
    }

    public bool Filled
    {
        get => (bool)GetValue(FilledProperty);
        set => SetValue(FilledProperty, value);
    }

    private static void OnVisualChanged(DependencyObject d, DependencyPropertyChangedEventArgs e) =>
        ((TimeBadge)d).UpdateVisual();

    private void UpdateVisual()
    {
        LabelText.Text = Text;
        var appResources = Application.Current.Resources;
        if (Filled)
        {
            LabelText.Foreground = WhiteBrush;
            RootBorder.Background = (Brush)appResources["AccentSolidBrush"];
        }
        else
        {
            LabelText.Foreground = (Brush)appResources["AccentSolidBrush"];
            RootBorder.Background = (Brush)appResources["AccentSurfaceBrush"];
        }
    }
}
