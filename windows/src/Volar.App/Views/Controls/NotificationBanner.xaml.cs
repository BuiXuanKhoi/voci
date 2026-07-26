// Views/Controls/NotificationBanner.xaml.cs — see NotificationBanner.xaml header. Port of
// NotificationView.swift:10-78.
using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Volar.App.ViewModels;

namespace Volar.App.Views.Controls;

public sealed partial class NotificationBanner : UserControl
{
    private NotificationBannerViewModel? _viewModel;

    public NotificationBanner()
    {
        InitializeComponent();
        Visibility = Visibility.Collapsed;
    }

    /// <summary>Set once by Stage C's composition/wiring code.</summary>
    public NotificationBannerViewModel? ViewModel
    {
        get => _viewModel;
        set
        {
            if (_viewModel is not null)
            {
                _viewModel.PropertyChanged -= OnViewModelPropertyChanged;
            }
            _viewModel = value;
            if (_viewModel is not null)
            {
                _viewModel.PropertyChanged += OnViewModelPropertyChanged;
            }
            Apply();
        }
    }

    private void OnViewModelPropertyChanged(object? sender, PropertyChangedEventArgs e) => Apply();

    private void OnDoneClick(object sender, RoutedEventArgs e) => Invoke(_viewModel?.DoneCommand);

    private void OnSnoozeClick(object sender, RoutedEventArgs e) => Invoke(_viewModel?.SnoozeCommand);

    private void OnRescheduleClick(object sender, RoutedEventArgs e) => Invoke(_viewModel?.RescheduleCommand);

    private static void Invoke(System.Windows.Input.ICommand? command)
    {
        if (command?.CanExecute(null) == true)
        {
            command.Execute(null);
        }
    }

    private void Apply()
    {
        var vm = _viewModel;
        Visibility = vm?.IsVisible == true ? Visibility.Visible : Visibility.Collapsed;
        if (vm is null)
        {
            return;
        }

        // NotificationView.swift:37 `Text("Coming up: \(title)")`.
        ComingUpText.Text = $"Coming up: {vm.Title}";
        TimingText.Text = vm.Timing;
    }
}
