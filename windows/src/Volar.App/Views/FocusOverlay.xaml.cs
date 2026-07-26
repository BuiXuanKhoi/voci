// Views/FocusOverlay.xaml.cs — see FocusOverlay.xaml header. Port of FocusOverlay.swift:18-234.
//
// FOCUS TICK HOST (wave4-contract.md decision 12 — see ViewModels/FocusViewModel.cs's header for
// the full "what ticks the countdown" investigation): this UserControl is FocusViewModel's host, so
// it owns the 1s DispatcherQueueTimer that keeps the on-screen countdown live. FocusSessionService
// already self-decrements FocusSecondsLeft on its own background loop but raises no event when it
// does — nothing else would ever repaint this view's countdown text without this timer.
using System;
using System.ComponentModel;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Volar.App.ViewModels;
using Volar.App.Views.Controls;
using Volar.Domain;

namespace Volar.App.Views;

public sealed partial class FocusOverlay : UserControl
{
    // FocusOverlay.swift:101 literal `total: CGFloat = 240` — the progress hairline's fixed track
    // width, hand-copied (not a Metrics.xaml resource; see FocusOverlay.xaml's own comment).
    private const double ProgressTrackWidth = 240;

    private FocusViewModel? _viewModel;
    private DispatcherQueueTimer? _tickTimer;

    public FocusOverlay()
    {
        InitializeComponent();
        Visibility = Visibility.Collapsed;
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
    }

    /// <summary>Set once by Stage C's composition/wiring code. Re-subscribes to
    /// <see cref="INotifyPropertyChanged.PropertyChanged"/> and repaints immediately.</summary>
    public FocusViewModel? ViewModel
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

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        var dispatcherQueue = DispatcherQueue.GetForCurrentThread();
        if (dispatcherQueue is not null)
        {
            _tickTimer = dispatcherQueue.CreateTimer();
            _tickTimer.Interval = TimeSpan.FromSeconds(1);
            _tickTimer.Tick += OnTick;
            _tickTimer.Start();
        }

        if (Visibility == Visibility.Visible)
        {
            // FocusOverlay.swift:38-41 `.focusable().focused($isFocused).onAppear { isFocused = true }`.
            Focus(FocusState.Programmatic);
        }
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        if (_tickTimer is not null)
        {
            _tickTimer.Stop();
            _tickTimer.Tick -= OnTick;
            _tickTimer = null;
        }
    }

    private void OnTick(DispatcherQueueTimer sender, object args)
    {
        if (Visibility == Visibility.Visible)
        {
            _viewModel?.Refresh();
        }
    }

    private void OnViewModelPropertyChanged(object? sender, PropertyChangedEventArgs e) => Apply();

    private void OnPreviousClick(object sender, RoutedEventArgs e) => Invoke(_viewModel?.GoToPreviousCommand);

    private void OnNextClick(object sender, RoutedEventArgs e) => Invoke(_viewModel?.GoToNextCommand);

    private void OnMarkDoneClick(object sender, RoutedEventArgs e) => Invoke(_viewModel?.MarkDoneCommand);

    private void OnPauseClick(object sender, RoutedEventArgs e) => Invoke(_viewModel?.TogglePauseCommand);

    private void OnEndClick(object sender, RoutedEventArgs e) => Invoke(_viewModel?.EndSessionCommand);

    // FocusOverlay.swift:42-49 `.onKeyPress(.leftArrow)`/`.onKeyPress(.rightArrow)`.
    private void OnPreviousAccelerator(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        Invoke(_viewModel?.GoToPreviousCommand);
    }

    private void OnNextAccelerator(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        Invoke(_viewModel?.GoToNextCommand);
    }

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
        var wasVisible = Visibility == Visibility.Visible;
        var isVisible = vm?.IsVisible == true;
        Visibility = isVisible ? Visibility.Visible : Visibility.Collapsed;
        if (isVisible && !wasVisible)
        {
            Focus(FocusState.Programmatic);
        }
        if (vm is null)
        {
            return;
        }

        var appResources = Application.Current.Resources;

        StateLabelText.Text = vm.IsPaused ? "Paused" : "Focus";
        CountdownText.Text = vm.TimeText;
        CountdownText.Opacity = vm.IsPaused ? 0.45 : 1.0;

        var timerBrush = vm.Urgency switch
        {
            FocusTimerUrgency.Danger => (Brush)appResources["VolarHighBrush"],
            FocusTimerUrgency.Warning => (Brush)appResources["VolarMedBrush"],
            _ => (Brush)appResources["AccentSolidBrush"],
        };
        CountdownText.Foreground = timerBrush;
        ProgressFillBorder.Background = timerBrush;
        ProgressFillBorder.Width = Math.Clamp(ProgressTrackWidth * vm.ProgressFraction, 0, ProgressTrackWidth);

        TaskTitleText.Text = vm.TaskTitle;
        PriorityLabelText.Text = vm.PriorityLabel;
        PriorityDot.Fill = vm.TaskPriority switch
        {
            Priority.High => (Brush)appResources["VolarHighBrush"],
            Priority.Low => (Brush)appResources["VolarLowBrush"],
            _ => (Brush)appResources["VolarMedBrush"],
        };

        var hasDuration = !string.IsNullOrEmpty(vm.DurationLabel);
        DurationSep.Visibility = hasDuration ? Visibility.Visible : Visibility.Collapsed;
        DurationText.Visibility = hasDuration ? Visibility.Visible : Visibility.Collapsed;
        DurationText.Text = vm.DurationLabel ?? string.Empty;

        var hasTimeBadge = !string.IsNullOrEmpty(vm.TimeBadge);
        TimeBadgeSep.Visibility = hasTimeBadge ? Visibility.Visible : Visibility.Collapsed;
        TimeBadgeText.Visibility = hasTimeBadge ? Visibility.Visible : Visibility.Collapsed;
        TimeBadgeText.Text = vm.TimeBadge ?? string.Empty;

        PauseIcon.IconName = vm.PauseButtonShowsResume ? VolarIconName.Play : VolarIconName.Pause;
        ToolTipService.SetToolTip(PauseButton, vm.PauseButtonShowsResume ? "Resume" : "Pause");

        IndexText.Text = vm.IndexLabel;
        TasksLeftText.Text = vm.TasksLeftLabel;

        PrevButton.IsEnabled = vm.CanGoPrevious;
        PrevButton.Opacity = vm.CanGoPrevious ? 1.0 : 0.3;
        NextButton.IsEnabled = vm.CanGoNext;
        NextButton.Opacity = vm.CanGoNext ? 1.0 : 0.3;
    }
}
