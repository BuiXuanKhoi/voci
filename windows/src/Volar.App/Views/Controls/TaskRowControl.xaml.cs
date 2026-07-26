// Views/Controls/TaskRowControl.xaml.cs — see TaskRowControl.xaml header. Port of TaskRow.swift.
// DataContext-driven (ViewModels.TaskRowViewModel) rather than DependencyProperty-driven, since this
// control is always used inside an ItemsControl template (Later/Completed drawers) where the
// framework already assigns DataContext per item — following the same "UpdateVisual() from the
// current bound state" idiom Stage A's controls use, just keyed off DataContext + INotifyPropertyChanged
// instead of DependencyProperties.
using System.ComponentModel;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Volar.App.ViewModels;
using Volar.Domain;
using Windows.UI;
using Windows.UI.Text;

namespace Volar.App.Views.Controls;

public sealed partial class TaskRowControl : UserControl
{
    // VolarColor.veil(0.28) -> alpha = round(0.28*255) = 71.4 -> 71 = 0x47 (TaskRow.swift:108,
    // the not-done checkbox ring stroke).
    private static readonly SolidColorBrush CheckboxRingIdleBrush = new(Color.FromArgb(0x47, 0x94, 0xB2, 0xE0));

    private static readonly SolidColorBrush TransparentBrush = new(Colors.Transparent);
    private static readonly SolidColorBrush WhiteBrush = new(Color.FromArgb(0xFF, 255, 255, 255));

    private TaskRowViewModel? _viewModel;
    private bool _isHovering;

    public TaskRowControl()
    {
        InitializeComponent();
        DataContextChanged += OnDataContextChanged;
    }

    private void OnDataContextChanged(FrameworkElement sender, DataContextChangedEventArgs args)
    {
        if (_viewModel is not null)
        {
            _viewModel.PropertyChanged -= OnViewModelPropertyChanged;
        }
        _viewModel = args.NewValue as TaskRowViewModel;
        if (_viewModel is not null)
        {
            _viewModel.PropertyChanged += OnViewModelPropertyChanged;
        }
        UpdateVisual();
    }

    private void OnViewModelPropertyChanged(object? sender, PropertyChangedEventArgs e) => UpdateVisual();

    // ------------------------------------------------------------------------------------------
    // MARK: Hover / press (TaskRow.swift:80,92-94 — `.onHover`/press-scale)
    // ------------------------------------------------------------------------------------------

    private void OnPointerEntered(object sender, Microsoft.UI.Xaml.Input.PointerRoutedEventArgs e)
    {
        _isHovering = true;
        UpdateVisual();
    }

    private void OnPointerExited(object sender, Microsoft.UI.Xaml.Input.PointerRoutedEventArgs e)
    {
        _isHovering = false;
        UpdateVisual();
    }

    private void OnPointerPressed(object sender, Microsoft.UI.Xaml.Input.PointerRoutedEventArgs e)
    {
        PressScale.ScaleX = 0.985;
        PressScale.ScaleY = 0.985;
    }

    private void OnPointerReleased(object sender, Microsoft.UI.Xaml.Input.PointerRoutedEventArgs e)
    {
        PressScale.ScaleX = 1;
        PressScale.ScaleY = 1;
    }

    // ------------------------------------------------------------------------------------------
    // MARK: Actions
    // ------------------------------------------------------------------------------------------

    private async void OnCheckboxClick(object sender, RoutedEventArgs e)
    {
        if (_viewModel is TaskRowViewModel vm)
        {
            await vm.ToggleDoneAsync().ConfigureAwait(true);
        }
    }

    private void OnRowTapped(object sender, Microsoft.UI.Xaml.Input.TappedRoutedEventArgs e) => _viewModel?.OpenDetail();

    private void OnBreakdownClick(object sender, RoutedEventArgs e) => _viewModel?.RequestBreakdown();

    private async void OnToggleDoneClick(object sender, RoutedEventArgs e)
    {
        if (_viewModel is TaskRowViewModel vm)
        {
            await vm.ToggleDoneAsync().ConfigureAwait(true);
        }
    }

    private async void OnDeleteClick(object sender, RoutedEventArgs e)
    {
        if (_viewModel is TaskRowViewModel vm)
        {
            await vm.DeleteAsync().ConfigureAwait(true);
        }
    }

    // ------------------------------------------------------------------------------------------
    // MARK: UpdateVisual
    // ------------------------------------------------------------------------------------------

    private void UpdateVisual()
    {
        var appResources = Application.Current.Resources;
        var vm = _viewModel;
        if (vm is null)
        {
            return;
        }

        RootBorder.Padding = new Thickness(0, vm.RowPadY, 0, vm.RowPadY);
        RootBorder.Margin = new Thickness(0, 0, 0, vm.RowGap);

        // rowBackground (TaskRow.swift:43-46): active -> accentColors.surface; else hover-swapped
        // card/cardHover.
        RootBorder.Background = vm.IsActive
            ? (Brush)appResources["AccentSurfaceBrush"]
            : (Brush)appResources[_isHovering ? "VolarCardHoverBrush" : "VolarCardBrush"];

        RootBorder.BorderBrush = vm.IsActive ? (Brush)Resources["ActiveBorderBrush"] : (Brush)appResources["VolarBorderBrush"];

        // Checkbox (TaskRow.swift:103-121).
        var checkboxColor = vm.IsDone ? (Brush)appResources["AccentSolidBrush"] : CheckboxRingIdleBrush;
        CheckboxRing.Stroke = checkboxColor;
        CheckboxFill.Fill = vm.IsDone ? (Brush)appResources["AccentSolidBrush"] : TransparentBrush;
        CheckIcon.Visibility = vm.IsDone ? Visibility.Visible : Visibility.Collapsed;
        CheckIcon.IconBrush = WhiteBrush;

        // Title (TaskRow.swift:123-139).
        FrogDot.Visibility = vm.ShowFrogMarker ? Visibility.Visible : Visibility.Collapsed;
        TitleText.Text = vm.Title;
        TitleText.FontWeight = vm.IsDone ? Microsoft.UI.Text.FontWeights.Normal : Microsoft.UI.Text.FontWeights.Medium;
        TitleText.Foreground = vm.IsDone ? (Brush)appResources["VolarTextMutBrush"] : (Brush)appResources["VolarTextPriBrush"];
        TitleText.TextDecorations = vm.IsDone ? TextDecorations.Strikethrough : TextDecorations.None;

        // Subrow (TaskRow.swift:141-157).
        var priorityBrushKey = vm.Priority switch
        {
            Priority.High => "VolarHighBrush",
            Priority.Low => "VolarLowBrush",
            _ => "VolarMedBrush",
        };
        PriorityDot.Fill = (Brush)appResources[priorityBrushKey];
        PriorityLabelText.Text = vm.PriorityOrStatusLabel;

        var showDuration = !string.IsNullOrEmpty(vm.DurationLabel);
        DurationSeparator.Visibility = showDuration ? Visibility.Visible : Visibility.Collapsed;
        DurationText.Visibility = showDuration ? Visibility.Visible : Visibility.Collapsed;
        DurationText.Text = vm.DurationLabel ?? string.Empty;

        var showFrogLabel = vm.ShowFrogMarker;
        FrogSeparator.Visibility = showFrogLabel ? Visibility.Visible : Visibility.Collapsed;
        FrogLabelText.Visibility = showFrogLabel ? Visibility.Visible : Visibility.Collapsed;

        // Trailing (TaskRow.swift:161-171).
        var hasTimeBadge = !vm.IsDone && !string.IsNullOrEmpty(vm.TimeBadgeText);
        var hasDoneTime = vm.IsDone && !string.IsNullOrEmpty(vm.DoneTimeLabel);
        TrailingTimeBadge.Visibility = hasTimeBadge ? Visibility.Visible : Visibility.Collapsed;
        if (hasTimeBadge)
        {
            TrailingTimeBadge.Text = vm.TimeBadgeText ?? string.Empty;
            TrailingTimeBadge.Filled = vm.IsTimeBadgeFilled;
        }
        TrailingDoneTimeText.Visibility = hasDoneTime ? Visibility.Visible : Visibility.Collapsed;
        TrailingDoneTimeText.Text = vm.DoneTimeLabel ?? string.Empty;

        // Context menu labels (TaskRow.swift:95-100).
        ToggleDoneMenuItem.Text = vm.IsDone ? "Mark not done" : "Mark done";
    }
}
