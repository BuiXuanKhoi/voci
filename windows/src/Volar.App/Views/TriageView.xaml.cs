// Views/TriageView.xaml.cs — see TriageView.xaml header. Port of TriageView.swift.
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Volar.App.ViewModels;
using Windows.UI.ViewManagement;

namespace Volar.App.Views;

public sealed partial class TriageView : UserControl
{
    private TriageViewModel? _viewModel;

    public TriageView()
    {
        InitializeComponent();
    }

    public TriageViewModel? ViewModel
    {
        get => _viewModel;
        set
        {
            _viewModel = value;
            Bindings.Update();
        }
    }

    /// <summary>Mirrors `TriageRow`'s `.onHover` (TriageView.swift:148-154): swaps the row's
    /// background between `VolarCardBrush`/`VolarCardHoverBrush`. Gated on
    /// <see cref="UISettings.AnimationsEnabled"/> (the WinUI analog of Swift's
    /// `accessibilityReduceMotion` check, per wave4-contract.md's gotcha list) — this port has no
    /// authored transition either way (a plain instant `Background` swap, not a Storyboard), so the
    /// gate's only effect is skipping the hover highlight altogether when the user has disabled UI
    /// animations system-wide, matching the Swift original's intent of not drawing extra motion for
    /// a reduce-motion user.</summary>
    private void OnRowPointerEntered(object sender, PointerRoutedEventArgs e)
    {
        if (sender is Border border && new UISettings().AnimationsEnabled)
        {
            border.Background = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["VolarCardHoverBrush"];
        }
    }

    private void OnRowPointerExited(object sender, PointerRoutedEventArgs e)
    {
        if (sender is Border border)
        {
            border.Background = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["VolarCardBrush"];
        }
    }
}
