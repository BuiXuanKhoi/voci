// ViewModels/FocusViewModel.cs — VM for Views/FocusOverlay.* (wave4-contract.md Stage B5;
// views-inventory.md §1.12, port of FocusOverlay.swift's 268 lines).
//
// TICK MECHANISM FOUND (this task's brief asked to report this): FocusSessionService already owns
// its own self-ticking 1s loop (TickLoopAsync, a fire-and-forget Task.Delay loop armed from
// StartFocus()) that decrements FocusSecondsLeft on its own, entirely independent of any view. But
// it raises NO change event when it ticks — Contracts.cs only gives services a TasksChanged event
// (fired on task mutations, not on every second), and FocusSessionService itself has none at all.
// So nothing tells this VM "a second passed, re-read FocusSecondsLeft" on its own. Per
// wave4-contract.md decision 12 ("any timer-driven state via a DispatcherQueueTimer owned by the
// VM's host"), the HOST view (Views/FocusOverlay.xaml.cs) owns a 1s DispatcherQueueTimer while the
// overlay is visible and calls this VM's public <see cref="Refresh"/> each tick — this VM itself
// stays host-agnostic (constructible in a plain xunit host, no DispatcherQueue required) exactly
// like ThemeState/UiDispatch already establish (Stage A).
//
// COMMAND, NOT DIRECT MUTATION (frozen decision 6): Swift's FocusOverlay is the one view in the
// whole app that mutates `appState.focusIndex` directly for prev/next
// (FocusOverlay.swift:198-205) — FocusSessionService.StepFocusIndex(±1) already fixes that into a
// proper command surface (its own doc comment). GoToPreviousCommand/GoToNextCommand below just
// expose that command, matching the frozen decision's "behavior identical; idiom fixed" framing.
using System.ComponentModel;
using System.Globalization;
using System.Windows.Input;
using Microsoft.UI.Dispatching;
using Volar.App.Services;
using Volar.App.Services.State;
using Volar.Domain;

namespace Volar.App.ViewModels;

/// <summary>Countdown color state — mirrors FocusOverlay.swift's `timerColor` switch
/// (FocusOverlay.swift:212-217: &lt;=60s high / &lt;=300s med / else accent.solid). A plain enum
/// (not a Brush) so this VM stays headlessly constructible (wave4-contract.md decision 12) — the
/// view's code-behind maps this to VolarHighBrush/VolarMedBrush/AccentSolidBrush.</summary>
public enum FocusTimerUrgency
{
    Normal,
    Warning,
    Danger,
}

public sealed class FocusViewModel : INotifyPropertyChanged
{
    private readonly FocusSessionService _focusService;
    private readonly ITaskListService _taskList;
    private readonly DispatcherQueue? _dispatcherQueue;
    private readonly ICommand[] _commands;

    private TaskItem? _currentTask;

    public FocusViewModel(FocusSessionService focusService, ITaskListService taskList, DispatcherQueue? dispatcherQueue = null)
    {
        _focusService = focusService ?? throw new ArgumentNullException(nameof(focusService));
        _taskList = taskList ?? throw new ArgumentNullException(nameof(taskList));
        _dispatcherQueue = dispatcherQueue;

        MarkDoneCommand = new DelegateCommand(async () => await MarkDoneAsync().ConfigureAwait(false), () => IsVisible && _currentTask is not null);
        TogglePauseCommand = new DelegateCommand(() => { _focusService.ToggleFocusPause(); Refresh(); }, () => IsVisible);
        EndSessionCommand = new DelegateCommand(() => { _focusService.EndFocus(); Refresh(); }, () => IsVisible);
        GoToPreviousCommand = new DelegateCommand(() => { _focusService.StepFocusIndex(-1); Refresh(); }, () => CanGoPrevious);
        GoToNextCommand = new DelegateCommand(() => { _focusService.StepFocusIndex(1); Refresh(); }, () => CanGoNext);
        _commands = [MarkDoneCommand, TogglePauseCommand, EndSessionCommand, GoToPreviousCommand, GoToNextCommand];

        _taskList.TasksChanged += OnTasksChanged;

        Refresh();
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public ICommand MarkDoneCommand { get; }

    public ICommand TogglePauseCommand { get; }

    public ICommand EndSessionCommand { get; }

    /// <summary>Frozen decision 6 — calls <see cref="FocusSessionService.StepFocusIndex"/>, never
    /// writes an index directly.</summary>
    public ICommand GoToPreviousCommand { get; }

    /// <summary>Frozen decision 6 — calls <see cref="FocusSessionService.StepFocusIndex"/>, never
    /// writes an index directly.</summary>
    public ICommand GoToNextCommand { get; }

    /// <summary>Mirrors FocusOverlay.swift:27-35's `if openTasks.isEmpty { EmptyView() }` guard,
    /// combined with the mount-site gate ("FocusOverlay (when focusActive)",
    /// views-inventory.md §1.16) — both conditions live here so the host view has one bool to
    /// watch.</summary>
    public bool IsVisible { get; private set; }

    public bool IsPaused { get; private set; }

    public int SecondsLeft { get; private set; } = FocusSessionService.DefaultFocusSeconds;

    /// <summary>"m:ss" — FocusOverlay.swift:207-210's `formattedTime`, minutes NOT zero-padded.</summary>
    public string TimeText { get; private set; } = "25:00";

    /// <summary>0..1, SecondsLeft / DefaultFocusSeconds — FocusOverlay.swift:100-112's
    /// `progressHairline`. No per-second animation (v1, per this task's brief) — the host just sets
    /// a width each Refresh.</summary>
    public double ProgressFraction { get; private set; } = 1.0;

    public FocusTimerUrgency Urgency { get; private set; } = FocusTimerUrgency.Normal;

    public string TaskTitle { get; private set; } = string.Empty;

    public Priority? TaskPriority { get; private set; }

    public string PriorityLabel { get; private set; } = string.Empty;

    public string? DurationLabel { get; private set; }

    public string? TimeBadge { get; private set; }

    /// <summary>"i of N" — FocusOverlay.swift:181.</summary>
    public string IndexLabel { get; private set; } = string.Empty;

    /// <summary>"N tasks left today" — FocusOverlay.swift:190.</summary>
    public string TasksLeftLabel { get; private set; } = string.Empty;

    public bool CanGoPrevious { get; private set; }

    public bool CanGoNext { get; private set; }

    public bool PauseButtonShowsResume => IsPaused;

    /// <summary>Called by the host view's 1s DispatcherQueueTimer (see this file's header) AND
    /// after every command — re-reads <see cref="FocusSessionService"/>/<see cref="ITaskListService"/>
    /// state and raises every changed property. Safe to call from any thread; state writes
    /// themselves are plain field/property sets (no DependencyObject touched here — the host view
    /// does that), matching this wave's "no XAML types in the VM" rule.</summary>
    public void Refresh()
    {
        var openTasks = _taskList.OpenTasks;
        var focusActive = _focusService.FocusActive;

        IsPaused = _focusService.FocusPaused;
        SecondsLeft = Math.Max(_focusService.FocusSecondsLeft, 0);
        TimeText = FormatTime(SecondsLeft);
        ProgressFraction = FocusSessionService.DefaultFocusSeconds > 0
            ? Math.Clamp((double)SecondsLeft / FocusSessionService.DefaultFocusSeconds, 0, 1)
            : 0;
        Urgency = ComputeUrgency(SecondsLeft);

        IsVisible = focusActive && openTasks.Count > 0;

        if (IsVisible)
        {
            var clampedIndex = Math.Min(Math.Max(_focusService.FocusIndex, 0), openTasks.Count - 1);
            var task = openTasks[clampedIndex];
            _currentTask = task;

            TaskTitle = task.Title;
            TaskPriority = task.Priority;
            PriorityLabel = task.Priority switch
            {
                Priority.High => "High",
                Priority.Low => "Low",
                _ => "Medium",
            };
            DurationLabel = task.DurationLabel;
            TimeBadge = task.TimeBadge;
            IndexLabel = string.Create(CultureInfo.InvariantCulture, $"{clampedIndex + 1} of {openTasks.Count}");
            TasksLeftLabel = openTasks.Count == 1
                ? "1 task left today"
                : string.Create(CultureInfo.InvariantCulture, $"{openTasks.Count} tasks left today");
            CanGoPrevious = clampedIndex > 0;
            CanGoNext = clampedIndex < openTasks.Count - 1;
        }
        else
        {
            _currentTask = null;
            TaskTitle = string.Empty;
            TaskPriority = null;
            PriorityLabel = string.Empty;
            DurationLabel = null;
            TimeBadge = null;
            IndexLabel = string.Empty;
            TasksLeftLabel = string.Empty;
            CanGoPrevious = false;
            CanGoNext = false;
        }

        RaiseAll();
        foreach (var command in _commands)
        {
            ((DelegateCommand)command).RaiseCanExecuteChanged();
        }
    }

    private async Task MarkDoneAsync()
    {
        if (_currentTask is not TaskItem task)
        {
            return;
        }
        await _focusService.CompleteFocusTaskAsync(task.Id).ConfigureAwait(false);
        UiDispatch.Post(_dispatcherQueue, Refresh);
    }

    private void OnTasksChanged() => UiDispatch.Post(_dispatcherQueue, Refresh);

    private static string FormatTime(int seconds)
    {
        var clamped = Math.Max(seconds, 0);
        return string.Create(CultureInfo.InvariantCulture, $"{clamped / 60}:{clamped % 60:D2}");
    }

    /// <summary>FocusOverlay.swift:212-217's `timerColor` thresholds, extracted as a pure static
    /// function — `public` (not `internal`) so it stays unit-testable from Volar.App.Tests without
    /// an `InternalsVisibleTo` entry, matching Theme/ThemeState.cs's own established precedent
    /// (editing Volar.App.csproj is barred for this wave's agents).</summary>
    public static FocusTimerUrgency ComputeUrgency(int secondsLeft) => secondsLeft switch
    {
        <= 60 => FocusTimerUrgency.Danger,
        <= 300 => FocusTimerUrgency.Warning,
        _ => FocusTimerUrgency.Normal,
    };

    private void RaiseAll()
    {
        RaiseChanged(nameof(IsVisible));
        RaiseChanged(nameof(IsPaused));
        RaiseChanged(nameof(SecondsLeft));
        RaiseChanged(nameof(TimeText));
        RaiseChanged(nameof(ProgressFraction));
        RaiseChanged(nameof(Urgency));
        RaiseChanged(nameof(TaskTitle));
        RaiseChanged(nameof(TaskPriority));
        RaiseChanged(nameof(PriorityLabel));
        RaiseChanged(nameof(DurationLabel));
        RaiseChanged(nameof(TimeBadge));
        RaiseChanged(nameof(IndexLabel));
        RaiseChanged(nameof(TasksLeftLabel));
        RaiseChanged(nameof(CanGoPrevious));
        RaiseChanged(nameof(CanGoNext));
        RaiseChanged(nameof(PauseButtonShowsResume));
    }

    private void RaiseChanged(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    /// <summary>Minimal ICommand — nested/private so it can never collide with another Wave-4 Stage
    /// B agent's own command helper (each agent's ViewModels live in the same namespace,
    /// Volar.App.ViewModels, and are built concurrently against the same solution).</summary>
    private sealed class DelegateCommand(Action execute, Func<bool>? canExecute = null) : ICommand
    {
        public event EventHandler? CanExecuteChanged;

        public bool CanExecute(object? parameter) => canExecute?.Invoke() ?? true;

        public void Execute(object? parameter) => execute();

        public void RaiseCanExecuteChanged() => CanExecuteChanged?.Invoke(this, EventArgs.Empty);
    }
}
