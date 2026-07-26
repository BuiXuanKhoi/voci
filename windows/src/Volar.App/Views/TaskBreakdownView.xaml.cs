// Views/TaskBreakdownView.xaml.cs — see TaskBreakdownView.xaml header. Port of TaskBreakdownView.swift.
using Microsoft.UI.Xaml.Controls;
using Volar.App.ViewModels;

namespace Volar.App.Views;

public sealed partial class TaskBreakdownView : UserControl
{
    private TaskBreakdownViewModel? _viewModel;

    public TaskBreakdownView()
    {
        InitializeComponent();
    }

    /// <summary>Stage C constructs this VM once (pure UI-local state, no service dependency — see
    /// TaskBreakdownViewModel.cs's header) and subscribes its own handler to
    /// `TriageAndSweepService.BreakdownRequested` to call <see cref="TaskBreakdownViewModel.Show"/>.</summary>
    public TaskBreakdownViewModel? ViewModel
    {
        get => _viewModel;
        set
        {
            _viewModel = value;
            Bindings.Update();
        }
    }
}
