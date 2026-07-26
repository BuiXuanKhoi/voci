// ViewModels/SweepViewModel.cs — port of SweepView.swift (views-inventory.md §1.10), backed by
// `TriageAndSweepService` (inventory cluster H). Deliberate sibling of `TriageViewModel` (mirrors
// the Swift source's own "explicitly a sibling design of TriageView" header comment) — SAME shell
// shape (IsVisible/Items/Dismiss), but keeps the 3 documented asymmetries vs. Triage rather than
// forcing symmetry (per this task's brief, quoting views-inventory.md §1.9/§1.10):
//  1. Only 2 actions (Complete/Skip), not 4 — no shared `actionButton` factoring needed.
//  2. Footer count uses the MONO font style (`Font.volarMono`, SweepView.swift:87) — Triage's
//     footer is plain digits. This VM exposes the same plain string either way; the MONO-vs-plain
//     choice is a View-layer (XAML `FontFamily`) decision, not VM state.
//  3. No `@Environment(\.dismiss)` — Swift's SweepView calls the injected `onDismiss` closure
//     directly (`AppState.dismissSweep()`) instead of a SwiftUI sheet-dismiss primitive; this VM's
//     `DismissCommand` is that same direct call, so there is nothing extra to model.
//
// GATE TIMING: identical caveat to TriageViewModel — `TriageAndSweepService.MaybeShowEveningSweep`
// raises no event; Stage C's shell must call <see cref="Refresh"/> right after invoking it.
using System.ComponentModel;
using System.Windows.Input;
using Microsoft.UI.Dispatching;
using Volar.App.Services;
using Volar.App.Services.State;
using Volar.Domain;

namespace Volar.App.ViewModels;

public sealed class SweepViewModel : INotifyPropertyChanged
{
    private readonly TriageAndSweepService _service;
    private readonly ITaskListService _taskList;
    private readonly DispatcherQueue? _dispatcherQueue;

    public SweepViewModel(
        TriageAndSweepService service,
        ITaskListService taskList,
        DispatcherQueue? dispatcherQueue = null)
    {
        _service = service ?? throw new ArgumentNullException(nameof(service));
        _taskList = taskList ?? throw new ArgumentNullException(nameof(taskList));
        _dispatcherQueue = dispatcherQueue;
        _taskList.TasksChanged += OnTasksChanged;

        CompleteCommand = new RelayCommand<TaskItem>(item => _ = CompleteAsync(item));
        SkipCommand = new RelayCommand<TaskItem>(Skip);
        DismissCommand = new RelayCommand(Dismiss);

        Refresh();
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public bool IsVisible { get; private set; }

    public IReadOnlyList<TaskItem> Items { get; private set; } = Array.Empty<TaskItem>();

    /// <summary>"N task(s) open" (SweepView.swift:86) — View renders this in
    /// `VolarInstrumentMonoTextStyle` (Typography.xaml), per this file's header asymmetry note 2.</summary>
    public string FooterCountText { get; private set; } = "0 tasks open";

    public ICommand CompleteCommand { get; }

    public ICommand SkipCommand { get; }

    /// <summary>"Done for today" (SweepView.swift:90-92, direct `onDismiss()` call — no
    /// `\.dismiss` environment value here, per file header asymmetry note 3).</summary>
    public ICommand DismissCommand { get; }

    /// <summary>Public so Stage C can force a re-read after calling
    /// <see cref="TriageAndSweepService.MaybeShowEveningSweep"/> — see file header "GATE TIMING".</summary>
    public void Refresh()
    {
        IsVisible = _service.ShowSweep;
        var items = _service.SweepItems;
        Items = items;
        FooterCountText = string.Create(
            System.Globalization.CultureInfo.InvariantCulture,
            $"{items.Count} task{(items.Count == 1 ? string.Empty : "s")} open");
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(null));
    }

    private void OnTasksChanged() => UiDispatch.Post(_dispatcherQueue, Refresh);

    private async Task CompleteAsync(TaskItem item)
    {
        await _service.SweepCompleteAsync(item).ConfigureAwait(false);
        UiDispatch.Post(_dispatcherQueue, Refresh);
    }

    /// <summary>Mirrors `sweepSkip(_:)` — intentionally a service no-op (see
    /// `TriageAndSweepService.SweepSkip`'s own doc comment: "carried over silently"); refreshed
    /// anyway for symmetry with every other action here, even though nothing will have changed.</summary>
    private void Skip(TaskItem item)
    {
        _service.SweepSkip(item);
        Refresh();
    }

    private void Dismiss()
    {
        _service.DismissSweep();
        Refresh();
    }
}
