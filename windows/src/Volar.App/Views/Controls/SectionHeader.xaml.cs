// Views/Controls/SectionHeader.xaml.cs — see SectionHeader.xaml header. Port of
// Components.swift:186-223.
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Volar.App.Views.Controls;

public sealed partial class SectionHeader : UserControl
{
    public static readonly DependencyProperty TitleProperty = DependencyProperty.Register(
        nameof(Title), typeof(string), typeof(SectionHeader), new PropertyMetadata(string.Empty, OnVisualChanged));

    /// <summary>Mirrors Swift's `count: Int?` (Components.swift:190/196) — <see langword="null"/>
    /// hides the trailing count text entirely, same as the Swift `if let count` branch.</summary>
    public static readonly DependencyProperty CountProperty = DependencyProperty.Register(
        nameof(Count), typeof(int?), typeof(SectionHeader), new PropertyMetadata(null, OnVisualChanged));

    /// <summary>Mirrors Swift's `accent: Bool = false` (Components.swift:191/198).</summary>
    public static readonly DependencyProperty AccentProperty = DependencyProperty.Register(
        nameof(Accent), typeof(bool), typeof(SectionHeader), new PropertyMetadata(false, OnVisualChanged));

    public SectionHeader()
    {
        InitializeComponent();
        UpdateVisual();
    }

    public string Title
    {
        get => (string)GetValue(TitleProperty);
        set => SetValue(TitleProperty, value);
    }

    public int? Count
    {
        get => (int?)GetValue(CountProperty);
        set => SetValue(CountProperty, value);
    }

    public bool Accent
    {
        get => (bool)GetValue(AccentProperty);
        set => SetValue(AccentProperty, value);
    }

    private static void OnVisualChanged(DependencyObject d, DependencyPropertyChangedEventArgs e) =>
        ((SectionHeader)d).UpdateVisual();

    private void UpdateVisual()
    {
        // `.textCase(.uppercase)` (Components.swift:208) — display-only transform, see file header.
        TitleText.Text = Title.ToUpperInvariant();

        var appResources = Application.Current.Resources;
        TitleText.Foreground = Accent
            ? (Microsoft.UI.Xaml.Media.Brush)appResources["AccentSolidBrush"]
            : (Microsoft.UI.Xaml.Media.Brush)appResources["VolarTextMutBrush"];

        RuleLine.Fill = (Microsoft.UI.Xaml.Media.Brush)appResources["VolarBorderBrush"];

        if (Count is int count)
        {
            CountText.Visibility = Visibility.Visible;
            CountText.Text = count.ToString();
        }
        else
        {
            CountText.Visibility = Visibility.Collapsed;
        }
    }
}
