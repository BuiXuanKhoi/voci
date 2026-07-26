// Views/Controls/PriorityBadge.xaml.cs — see PriorityBadge.xaml header. Port of
// Components.swift:40-72. Uses `Volar.Domain.Priority` (High=1/Medium=2/Low=3) — not
// `System.Threading.Tasks.TaskStatus`, so the wave4-contract.md ambiguity gotcha doesn't apply
// here (that alias collision is `Volar.Core.TaskStatus` vs the BCL type, unrelated to `Priority`).
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Volar.Domain;
using Windows.UI;

namespace Volar.App.Views.Controls;

public sealed partial class PriorityBadge : UserControl
{
    // VolarColor.veil(0.05) -> alpha = round(0.05*255) = 12.75 -> 13 = 0x0D (Components.swift:55,
    // Low's background — the one case that does NOT derive from VolarLow/VolarHigh/VolarMed).
    private static readonly SolidColorBrush LowBackground = new(Color.FromArgb(0x0D, 0x94, 0xB2, 0xE0));

    // VolarHigh (#B9705A) @0.14 -> alpha = round(0.14*255) = 35.7 -> 36 = 0x24 (Components.swift:51).
    private static readonly SolidColorBrush HighBackground = new(Color.FromArgb(0x24, 0xB9, 0x70, 0x5A));

    // VolarMed (#9C8C6B) @0.14 -> alpha = 0x24 (same math as High) (Components.swift:53).
    private static readonly SolidColorBrush MedBackground = new(Color.FromArgb(0x24, 0x9C, 0x8C, 0x6B));

    public static readonly DependencyProperty PriorityProperty = DependencyProperty.Register(
        nameof(Priority), typeof(Priority), typeof(PriorityBadge),
        new PropertyMetadata(Priority.Medium, OnPriorityChanged));

    public PriorityBadge()
    {
        InitializeComponent();
        UpdateVisual();
    }

    public Priority Priority
    {
        get => (Priority)GetValue(PriorityProperty);
        set => SetValue(PriorityProperty, value);
    }

    private static void OnPriorityChanged(DependencyObject d, DependencyPropertyChangedEventArgs e) =>
        ((PriorityBadge)d).UpdateVisual();

    private void UpdateVisual()
    {
        var appResources = Application.Current.Resources;
        var (dot, background, foreground, label) = Priority switch
        {
            Priority.High => ((Brush)appResources["VolarHighBrush"], (Brush)HighBackground, (Brush)appResources["VolarHighBrush"], "High"),
            Priority.Low => ((Brush)appResources["VolarLowBrush"], (Brush)LowBackground, (Brush)appResources["VolarTextSecBrush"], "Low"),
            _ => ((Brush)appResources["VolarMedBrush"], (Brush)MedBackground, (Brush)appResources["VolarMedBrush"], "Medium"),
        };
        Dot.Fill = dot;
        RootBorder.Background = background;
        LabelText.Foreground = foreground;
        LabelText.Text = label;
    }
}
