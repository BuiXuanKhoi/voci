// Views/SweepView.xaml.cs — see SweepView.xaml header. Port of SweepView.swift.
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Volar.App.ViewModels;
using Windows.UI.ViewManagement;

namespace Volar.App.Views;

public sealed partial class SweepView : UserControl
{
    private SweepViewModel? _viewModel;

    public SweepView()
    {
        InitializeComponent();
    }

    public SweepViewModel? ViewModel
    {
        get => _viewModel;
        set
        {
            _viewModel = value;
            Bindings.Update();
        }
    }

    /// <summary>Mirrors `SweepRow`'s `.onHover` — same gate/shape as TriageView.xaml.cs's identical
    /// handler (see that file's doc comment; duplicated here per this wave's file-disjoint views
    /// convention rather than factored into a shared base, matching Swift's own two independent
    /// `TriageRow`/`SweepRow` private structs).</summary>
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
