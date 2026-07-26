// ViewModels/TriageViewModel.cs — port of TriageView.swift (views-inventory.md §1.9), backed by
// `TriageAndSweepService` (inventory cluster H). Swift's own file header says this view "touches no
// app state ... presentation (when/how this is shown ...) is entirely the caller's job" — on
// Windows that caller is this VM: it owns translating `TriageAndSweepService.ShowTriage`/
// `StaleTasks(now)` into bound state, and forwarding the 4 anti-shame actions
// (Keep/Break down/Defer/Drop, FR-036 — all four MUST stay visually identical, never single out
// "Drop") to the service.
//
// GATE TIMING (flagged, not silently assumed): `TriageAndSweepService.MaybeShowTriage(now)` is the
// ONLY thing that flips `ShowTriage` true, and it raises no event of its own (unlike
// `ITaskListService.TasksChanged`) — Stage C's shell, which owns calling `MaybeShowTriage` on
// whatever weekly-check cadence it wires up, MUST call this VM's <see cref="Refresh"/> right after,
// or the gate firing will never reach this VM. Every other trigger (Keep/Breakdown/Defer/Drop/
// Dismiss, plus any `ITaskListService.TasksChanged` from elsewhere in the app) already re-runs
// <see cref="Refresh"/> internally below.
using System.ComponentModel;
using System.Windows.Input;
using Microsoft.UI.Dispatching;
using Volar.App.Services;
using Volar.App.Services.State;
using Volar.Domain;

namespace Volar.App.ViewModels;

public sealed class TriageViewModel : INotifyPropertyChanged
{
    private readonly TriageAndSweepService _service;
    private readonly ITaskListService _taskList;
    private readonly ITimeProvider _clock;
    private readonly DispatcherQueue? _dispatcherQueue;

    public TriageViewModel(
        TriageAndSweepService service,
        ITaskListService taskList,
        ITimeProvider clock,
        DispatcherQueue? dispatcherQueue = null)
    {
        _service = service ?? throw new ArgumentNullException(nameof(service));
        _taskList = taskList ?? throw new ArgumentNullException(nameof(taskList));
        _clock = clock ?? throw new ArgumentNullException(nameof(clock));
        _dispatcherQueue = dispatcherQueue;
        _taskList.TasksChanged += OnTasksChanged;

        KeepCommand = new RelayCommand<TaskItem>(item => Keep(item));
        BreakdownCommand = new RelayCommand<TaskItem>(item => Breakdown(item));
        DeferCommand = new RelayCommand<TaskItem>(item => _ = DeferAsync(item));
        DropCommand = new RelayCommand<TaskItem>(item => _ = DropAsync(item));
        DismissCommand = new RelayCommand(Dismiss);

        Refresh();
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public bool IsVisible { get; private set; }

    public IReadOnlyList<TaskItem> Items { get; private set; } = Array.Empty<TaskItem>();

    /// <summary>"N task(s)" (TriageView.swift:97) — footer count, plain (non-mono) digits, matching
    /// the 3rd asymmetry views-inventory.md §1.10 flags vs. SweepView's mono footer.</summary>
    public string FooterCountText { get; private set; } = "0 tasks";

    public ICommand KeepCommand { get; }

    public ICommand BreakdownCommand { get; }

    public ICommand DeferCommand { get; }

    public ICommand DropCommand { get; }

    /// <summary>"Maybe later" (TriageView.swift:102-104, `dismiss()`).</summary>
    public ICommand DismissCommand { get; }

    /// <summary>Public so Stage C can force a re-read after calling
    /// <see cref="TriageAndSweepService.MaybeShowTriage"/> — see file header "GATE TIMING".</summary>
    public void Refresh()
    {
        IsVisible = _service.ShowTriage;
        var stale = _service.StaleTasks(_clock.Now);
        Items = stale;
        FooterCountText = string.Create(
            System.Globalization.CultureInfo.InvariantCulture,
            $"{stale.Count} task{(stale.Count == 1 ? string.Empty : "s")}");
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(null));
    }

    private void OnTasksChanged() => UiDispatch.Post(_dispatcherQueue, Refresh);

    /// <summary>Mirrors `triageKeep(_:)` — synchronous, no task-list mutation, so
    /// <see cref="OnTasksChanged"/> will not fire on its own; refresh explicitly.</summary>
    private void Keep(TaskItem item)
    {
        _service.TriageKeep(item);
        Refresh();
    }

    /// <summary>Mirrors `triageBreakdown(_:)` — raises `TriageAndSweepService.BreakdownRequested`
    /// (Stage C's shell forwards that to `TaskBreakdownViewModel.Show`, per that VM's own file
    /// header); this VM only needs to refresh its own stale-count/visibility afterward.</summary>
    private void Breakdown(TaskItem item)
    {
        _service.TriageBreakdown(item);
        Refresh();
    }

    private async Task DeferAsync(TaskItem item)
    {
        await _service.TriageDeferAsync(item).ConfigureAwait(false);
        UiDispatch.Post(_dispatcherQueue, Refresh);
    }

    private async Task DropAsync(TaskItem item)
    {
        await _service.TriageDropAsync(item).ConfigureAwait(false);
        UiDispatch.Post(_dispatcherQueue, Refresh);
    }

    private void Dismiss()
    {
        _service.DismissTriage();
        Refresh();
    }
}
