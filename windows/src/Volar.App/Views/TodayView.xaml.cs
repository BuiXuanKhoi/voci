// Views/TodayView.xaml.cs — see TodayView.xaml header. Port of TodayView.swift.
//
// Two-phase construction (parameterless ctor for XAML activation + a settable ViewModel property,
// rather than constructor-injecting the VM): Stage C constructs this view via XAML/CompositionRoot
// wiring and assigns ViewModel afterward — mirrors SidebarControl's own ViewModel DependencyProperty
// pattern, just as a plain CLR property here since nothing needs to declaratively XAML-bind TO this
// view's own ViewModel property from outside (Stage C sets it once, in code, per MainWindow's own
// established "resolve from App.Services, wire by hand" convention — MainWindow.xaml.cs's
// constructor).
//
// FOCUS COUNTDOWN TIMER: FocusSessionService raises no change event of its own (plain class, ticks
// via its own internal fire-and-forget loop) — per wave4-contract.md decision 12 ("subscribe to...
// timer-driven state via a DispatcherQueueTimer owned by the VM's host"), THIS view owns that timer,
// not TodayViewModel, so the VM stays a plain INPC class with no XAML/dispatcher type baked in beyond
// the DispatcherQueue? seam UiDispatch already established.
using System.ComponentModel;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Volar.App.ViewModels;
using Volar.App.Views.Controls;

namespace Volar.App.Views;

public sealed partial class TodayView : UserControl
{
    private TodayViewModel? _viewModel;
    private DispatcherQueueTimer? _focusTimer;

    public TodayView()
    {
        InitializeComponent();
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
    }

    public TodayViewModel? ViewModel
    {
        get => _viewModel;
        set
        {
            if (_viewModel is not null)
            {
                _viewModel.PropertyChanged -= OnViewModelPropertyChanged;
            }
            _viewModel = value;
            Sidebar.ViewModel = value;
            if (_viewModel is not null)
            {
                _viewModel.PropertyChanged += OnViewModelPropertyChanged;
            }
            UpdateVisual();
        }
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        _focusTimer = DispatcherQueue.CreateTimer();
        _focusTimer.Interval = TimeSpan.FromSeconds(1);
        _focusTimer.Tick += OnFocusTimerTick;
        _focusTimer.Start();
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        if (_focusTimer is not null)
        {
            _focusTimer.Stop();
            _focusTimer.Tick -= OnFocusTimerTick;
            _focusTimer = null;
        }
    }

    /// <summary>Only re-derives VM state while a focus session is actually running — otherwise this
    /// tick is a no-op, avoiding a full <see cref="TodayViewModel.Refresh"/> once per second for the
    /// entire lifetime of an idle window.</summary>
    private void OnFocusTimerTick(DispatcherQueueTimer sender, object args)
    {
        if (ViewModel?.FocusActive == true)
        {
            ViewModel.Refresh();
        }
    }

    private void OnViewModelPropertyChanged(object? sender, PropertyChangedEventArgs e) => UpdateVisual();

    // ------------------------------------------------------------------------------------------
    // MARK: Toolbar
    // ------------------------------------------------------------------------------------------

    private void OnAmbientSoundClick(object sender, RoutedEventArgs e) => ViewModel?.ToggleAmbientSound();

    private void OnReadDayAloudClick(object sender, RoutedEventArgs e) => ViewModel?.ReadDayAloud();

    private async void OnToggleCaptureClick(object sender, RoutedEventArgs e)
    {
        if (ViewModel is TodayViewModel vm)
        {
            await vm.ToggleCaptureAsync().ConfigureAwait(true);
        }
    }

    // ------------------------------------------------------------------------------------------
    // MARK: Running-focus pill / frog pill
    // ------------------------------------------------------------------------------------------

    private void OnStartFocusClick(object sender, RoutedEventArgs e) => ViewModel?.StartFocus();

    private void OnToggleFocusPauseClick(object sender, RoutedEventArgs e) => ViewModel?.ToggleFocusPause();

    private void OnEndFocusClick(object sender, RoutedEventArgs e) => ViewModel?.EndFocus();

    // ------------------------------------------------------------------------------------------
    // MARK: NOW spotlight
    // ------------------------------------------------------------------------------------------

    private void OnNowSpotlightTapped(object sender, Microsoft.UI.Xaml.Input.TappedRoutedEventArgs e) => ViewModel?.OpenActiveDetail();

    private void OnNowBreakdownClick(object sender, RoutedEventArgs e) => ViewModel?.RequestActiveBreakdown();

    private async void OnNowToggleDoneClick(object sender, RoutedEventArgs e)
    {
        if (ViewModel is TodayViewModel vm)
        {
            await vm.ToggleActiveDoneAsync().ConfigureAwait(true);
        }
    }

    private async void OnNowDelegateClick(object sender, RoutedEventArgs e)
    {
        if (ViewModel is TodayViewModel vm)
        {
            await vm.DelegateActiveAsync().ConfigureAwait(true);
        }
    }

    private async void OnNowDeleteClick(object sender, RoutedEventArgs e)
    {
        if (ViewModel is TodayViewModel vm)
        {
            await vm.DeleteActiveAsync().ConfigureAwait(true);
        }
    }

    // ------------------------------------------------------------------------------------------
    // MARK: DelegationAmbientSection
    // ------------------------------------------------------------------------------------------

    private void OnDismissWipHintClick(object sender, RoutedEventArgs e) => ViewModel?.DismissWipHint();

    private async void OnDisambiguationCandidateClick(object sender, RoutedEventArgs e)
    {
        if (ViewModel is TodayViewModel vm && sender is FrameworkElement { Tag: Guid id })
        {
            await vm.ResolveDisambiguationAsync(id).ConfigureAwait(true);
        }
    }

    private void OnDismissDisambiguationClick(object sender, RoutedEventArgs e) => ViewModel?.DismissDisambiguation();

    private async void OnResolveDelegationDoneClick(object sender, RoutedEventArgs e)
    {
        if (ViewModel is TodayViewModel vm && sender is FrameworkElement { Tag: Guid id })
        {
            await vm.ResolveDelegationDoneAsync(id).ConfigureAwait(true);
        }
    }

    private void OnResolveDelegationStillWaitingClick(object sender, RoutedEventArgs e)
    {
        if (ViewModel is TodayViewModel vm && sender is FrameworkElement { Tag: Guid id })
        {
            vm.ResolveDelegationStillWaiting(id);
        }
    }

    private void OnResolveDelegationCheckLaterClick(object sender, RoutedEventArgs e)
    {
        if (ViewModel is TodayViewModel vm && sender is FrameworkElement { Tag: Guid id })
        {
            vm.ResolveDelegationCheckLater(id);
        }
    }

    // ------------------------------------------------------------------------------------------
    // MARK: NEXT peek — same action set as TaskRowControl, applied to ViewModel.NextPeek directly.
    // ------------------------------------------------------------------------------------------

    private void OnNextPeekTapped(object sender, Microsoft.UI.Xaml.Input.TappedRoutedEventArgs e) => ViewModel?.NextPeek?.OpenDetail();

    private void OnNextPeekBreakdownClick(object sender, RoutedEventArgs e) => ViewModel?.NextPeek?.RequestBreakdown();

    private async void OnNextPeekToggleDoneClick(object sender, RoutedEventArgs e)
    {
        if (ViewModel?.NextPeek is TaskRowViewModel row)
        {
            await row.ToggleDoneAsync().ConfigureAwait(true);
        }
    }

    private async void OnNextPeekCheckboxClick(object sender, RoutedEventArgs e)
    {
        if (ViewModel?.NextPeek is TaskRowViewModel row)
        {
            await row.ToggleDoneAsync().ConfigureAwait(true);
        }
    }

    private async void OnNextPeekDeleteClick(object sender, RoutedEventArgs e)
    {
        if (ViewModel?.NextPeek is TaskRowViewModel row)
        {
            await row.DeleteAsync().ConfigureAwait(true);
        }
    }

    // ------------------------------------------------------------------------------------------
    // MARK: Drawer toggles
    // ------------------------------------------------------------------------------------------

    private void OnToggleLaterExpandedClick(object sender, RoutedEventArgs e) => ViewModel?.ToggleLaterExpanded();

    private void OnToggleCompletedExpandedClick(object sender, RoutedEventArgs e) => ViewModel?.ToggleCompletedExpanded();

    // ------------------------------------------------------------------------------------------
    // MARK: UpdateVisual — re-renders everything from the current ViewModel snapshot
    // ------------------------------------------------------------------------------------------

    private void UpdateVisual()
    {
        var appResources = Application.Current.Resources;
        var vm = ViewModel;

        MainColumnOverlay.Background = vm?.IsAmbientBackgroundActive == true
            ? (Brush)Resources["MainColumnAmbientDimBrush"]
            : (Brush)Resources["MainColumnDepthBrush"];

        // Toolbar.
        var soundPlaying = vm?.IsAmbientSoundPlaying ?? false;
        AmbientSoundButton.IconName = soundPlaying ? VolarIconName.Volume : VolarIconName.VolumeOff;
        AmbientSoundButton.Tint = soundPlaying;

        // Greeting header.
        TodayDateLabelText.Text = vm?.TodayDateLabel ?? string.Empty;
        OpenCountText.Text = (vm?.OpenTaskCount ?? 0).ToString(System.Globalization.CultureInfo.InvariantCulture);
        DoneCountText.Text = (vm?.DoneTaskCount ?? 0).ToString(System.Globalization.CultureInfo.InvariantCulture);

        var focusActive = vm?.FocusActive ?? false;
        RunningFocusPill.Visibility = focusActive ? Visibility.Visible : Visibility.Collapsed;
        FrogPill.Visibility = focusActive ? Visibility.Collapsed : Visibility.Visible;
        RunningFocusTitleText.Text = vm?.RunningFocusTitle ?? "Focus";
        FocusClockText.Text = vm?.FocusClockLabel ?? "0:00";
        FocusPauseIcon.IconName = vm?.FocusPaused == true ? VolarIconName.Play : VolarIconName.Pause;
        FrogPillTitleText.Text = vm?.FrogPillTitle ?? "Ship the auth fix";

        // Empty state vs task stack.
        var hasOpenTasks = vm?.HasOpenTasks ?? false;
        EmptyTodayCard.Visibility = hasOpenTasks ? Visibility.Collapsed : Visibility.Visible;
        TaskScrollViewer.Visibility = hasOpenTasks ? Visibility.Visible : Visibility.Collapsed;

        // NOW spotlight.
        var now = vm?.NowSpotlight;
        NowSpotlightCard.Visibility = now is not null ? Visibility.Visible : Visibility.Collapsed;
        NowEmptyCard.Visibility = now is null ? Visibility.Visible : Visibility.Collapsed;
        if (now is not null)
        {
            NowTitleText.Text = now.Title;
            NowLeftChip.Visibility = string.IsNullOrEmpty(now.DurationLabel) ? Visibility.Collapsed : Visibility.Visible;
            NowLeftChipValue.Text = now.DurationLabel ?? string.Empty;
            NowDueChip.Visibility = string.IsNullOrEmpty(now.TimeBadgeText) ? Visibility.Collapsed : Visibility.Visible;
            NowDueChipValue.Text = now.TimeBadgeText ?? string.Empty;
            NowFrogChip.Visibility = now.ShowFrogChip ? Visibility.Visible : Visibility.Collapsed;
            NowDependencyChip.Visibility = now.ShowDependencyChip ? Visibility.Visible : Visibility.Collapsed;
            StartFocusButton.Visibility = focusActive ? Visibility.Collapsed : Visibility.Visible;
            NowDoneButtonText.Text = now.IsDone ? "Mark not done" : "Done";
            DelegateButton.Visibility = now.IsDone ? Visibility.Collapsed : Visibility.Visible;
            NowToggleDoneMenuItem.Text = now.IsDone ? "Mark not done" : "Mark done";
        }

        // DelegationAmbientSection.
        var showWipHint = vm?.ShowWipHint ?? false;
        WipHintCard.Visibility = showWipHint ? Visibility.Visible : Visibility.Collapsed;
        if (showWipHint)
        {
            WipHintText.Text = string.Create(
                System.Globalization.CultureInfo.InvariantCulture,
                $"{vm!.WipCount} tasks are out with Claude right now — review before delegating more?");
        }
        var hasDisambiguation = vm?.HasDisambiguationCandidates ?? false;
        DisambiguationCard.Visibility = hasDisambiguation ? Visibility.Visible : Visibility.Collapsed;
        DisambiguationList.ItemsSource = vm?.DisambiguationCandidates;
        DueDelegationList.ItemsSource = vm?.DueDelegationTasks;

        // NEXT peek.
        var peek = vm?.NextPeek;
        NextPeekRow.Visibility = peek is not null ? Visibility.Visible : Visibility.Collapsed;
        if (peek is not null)
        {
            NextPeekTitleText.Text = peek.Title;
            NextPeekTitleText.Foreground = peek.IsDone ? (Brush)appResources["VolarTextMutBrush"] : (Brush)appResources["VolarTextSecBrush"];
            NextPeekTitleText.TextDecorations = peek.IsDone ? Windows.UI.Text.TextDecorations.Strikethrough : Windows.UI.Text.TextDecorations.None;
            NextPeekMetaText.Text = peek.DurationLabel ?? peek.TimeBadgeText ?? string.Empty;
            var checkboxColor = peek.IsDone ? (Brush)appResources["AccentSolidBrush"] : new SolidColorBrush(Windows.UI.Color.FromArgb(0x47, 255, 255, 255));
            NextPeekCheckboxRing.Stroke = checkboxColor;
            NextPeekCheckboxFill.Fill = peek.IsDone ? (Brush)appResources["AccentSolidBrush"] : new SolidColorBrush(Microsoft.UI.Colors.Transparent);
            NextPeekCheckIcon.Visibility = peek.IsDone ? Visibility.Visible : Visibility.Collapsed;
            NextPeekCheckIcon.IconBrush = new SolidColorBrush(Microsoft.UI.Colors.White);
            NextPeekToggleDoneMenuItem.Text = peek.IsDone ? "Mark not done" : "Mark done";
        }

        // Later drawer.
        var hasLater = vm?.HasLaterTasks ?? false;
        LaterDrawer.Visibility = hasLater ? Visibility.Visible : Visibility.Collapsed;
        LaterCountText.Text = (vm?.LaterTasks.Count ?? 0).ToString(System.Globalization.CultureInfo.InvariantCulture);
        var laterExpanded = vm?.LaterExpanded ?? false;
        LaterToggleText.Text = laterExpanded ? "Hide" : "Show";
        LaterScrollViewer.Visibility = laterExpanded ? Visibility.Visible : Visibility.Collapsed;
        LaterScrollViewer.MaxHeight = vm?.LaterDrawerMaxHeight ?? 0;
        LaterItemsControl.ItemsSource = vm?.LaterTasks;

        // Completed drawer.
        var hasCompleted = vm?.HasCompletedTasks ?? false;
        CompletedDrawer.Visibility = hasCompleted ? Visibility.Visible : Visibility.Collapsed;
        CompletedCountText.Text = (vm?.CompletedTasks.Count ?? 0).ToString(System.Globalization.CultureInfo.InvariantCulture);
        var completedExpanded = vm?.CompletedExpanded ?? false;
        CompletedToggleText.Text = completedExpanded ? "Hide" : "Show";
        CompletedScrollViewer.Visibility = completedExpanded ? Visibility.Visible : Visibility.Collapsed;
        CompletedScrollViewer.MaxHeight = vm?.CompletedDrawerMaxHeight ?? 0;
        CompletedItemsControl.ItemsSource = vm?.CompletedTasks;
    }
}
