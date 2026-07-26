// Views/TaskDetailView.xaml.cs — see TaskDetailView.xaml header. Port of TaskDetailView.swift.
using Microsoft.UI.Xaml.Controls;
using Volar.App.ViewModels;

namespace Volar.App.Views;

public sealed partial class TaskDetailView : UserControl
{
    private TaskDetailViewModel? _viewModel;

    public TaskDetailView()
    {
        InitializeComponent();
    }

    /// <summary>Stage C constructs the real <see cref="TaskDetailViewModel"/> once (it holds a
    /// reference to the app's singleton <c>ITaskListService</c>/<c>VoicePlayback</c>) and assigns it
    /// here; every `{x:Bind ViewModel...}` in the XAML resolves against this property (x:Bind binds
    /// to this code-behind instance, not `DataContext`). <see cref="FrameworkElement.Bindings"/>'s
    /// <c>Update()</c> re-evaluates every x:Bind expression once so subsequent updates flow purely
    /// through <see cref="TaskDetailViewModel.PropertyChanged"/> (Mode=OneWay auto-subscribes to
    /// that once the source is non-null).</summary>
    public TaskDetailViewModel? ViewModel
    {
        get => _viewModel;
        set
        {
            _viewModel = value;
            Bindings.Update();
        }
    }
}
