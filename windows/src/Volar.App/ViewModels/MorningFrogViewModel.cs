// ViewModels/MorningFrogViewModel.cs — port of MorningFrogView.swift (views-inventory.md §1.6),
// backed by `TriageAndSweepService` (the morning-frog gate cluster, Opus decision 4) +
// `ITaskListService.OpenTasks` (candidate list — ALL open tasks, not a curated subset, per that
// file's own header comment) + `CaptureFlowService.ToggleCaptureAsync` (the voice CTA).
//
// PICK/DISMISS SURFACE (contract's own open question, resolved): the contract asked this agent to
// "find the pick/dismiss surface [on TriageAndSweepService] and bind it; if a pickFrog equivalent is
// missing, note it as residual, stub the command no-op." It is NOT missing —
// `TriageAndSweepService.PickFrogAsync(Guid)` (mirrors `pickFrog(_:)`, AppState.swift:1756-1759) and
// `TriageAndSweepService.DismissMorningFrog()` (mirrors `dismissMorningFrog()`) both exist and are
// bound directly below. No residual/stub needed for this surface.
//
// GATE TIMING: same caveat as Triage/Sweep — `TriageAndSweepService.MaybeShowMorningFrog` raises no
// event; Stage C's shell must call <see cref="Refresh"/> right after invoking it.
using System.ComponentModel;
using System.Windows.Input;
using Microsoft.UI.Dispatching;
using Volar.App.Services;
using Volar.App.Services.State;
using Volar.Domain;

namespace Volar.App.ViewModels;

/// <summary>One row of MorningFrogView.swift's `candidateList` (lines 119-140).</summary>
public sealed class FrogCandidateViewModel
{
    public FrogCandidateViewModel(TaskItem task)
    {
        Id = task.Id;
        Title = task.Title;
        Priority = task.Priority;
    }

    public Guid Id { get; }

    public string Title { get; }

    public Volar.Domain.Priority Priority { get; }
}

public sealed class MorningFrogViewModel : INotifyPropertyChanged
{
    private readonly TriageAndSweepService _service;
    private readonly ITaskListService _taskList;
    private readonly CaptureFlowService _capture;
    private readonly DispatcherQueue? _dispatcherQueue;

    public MorningFrogViewModel(
        TriageAndSweepService service,
        ITaskListService taskList,
        CaptureFlowService capture,
        DispatcherQueue? dispatcherQueue = null)
    {
        _service = service ?? throw new ArgumentNullException(nameof(service));
        _taskList = taskList ?? throw new ArgumentNullException(nameof(taskList));
        _capture = capture ?? throw new ArgumentNullException(nameof(capture));
        _dispatcherQueue = dispatcherQueue;
        _taskList.TasksChanged += OnTasksChanged;

        PickCommand = new RelayCommand<Guid>(id => _ = PickAsync(id));
        SkipCommand = new RelayCommand(Skip);
        VoiceCommand = new RelayCommand(() => _ = VoiceAsync());

        Refresh();
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public bool IsVisible { get; private set; }

    public IReadOnlyList<FrogCandidateViewModel> Candidates { get; private set; } =
        Array.Empty<FrogCandidateViewModel>();

    /// <summary>Gates the "Nothing open today — enjoy it." placeholder vs. the candidate list
    /// (MorningFrogView.swift:128-138) — a plain `Count > 0` check exposed as a bound bool since
    /// x:Bind's function-call syntax cannot express `> 0` inline.</summary>
    public bool HasCandidates => Candidates.Count > 0;

    /// <summary>View-local "which row is highlighted" state, mirroring Swift's `@State private var
    /// picked: UUID?` (MorningFrogView.swift:10) — purely cosmetic (the real state change is
    /// `TriageAndSweepService.PickFrogAsync` closing this sheet immediately after), kept for visual
    /// parity with the tapped row's brief accent highlight before the sheet dismisses.</summary>
    public Guid? SelectedId { get; private set; }

    public ICommand PickCommand { get; }

    /// <summary>"Skip today" (MorningFrogView.swift:52-61, `onSkip()` -> `dismissMorningFrog()`).</summary>
    public ICommand SkipCommand { get; }

    /// <summary>The voice CTA (MorningFrogView.swift:73-105): `appState.toggleCapture()` then
    /// dismiss the same way Skip does.</summary>
    public ICommand VoiceCommand { get; }

    /// <summary>Public so Stage C can force a re-read after calling
    /// <see cref="TriageAndSweepService.MaybeShowMorningFrog"/> — see file header "GATE TIMING".</summary>
    public void Refresh()
    {
        IsVisible = _service.ShowMorningFrog;
        var open = _taskList.OpenTasks;
        var candidates = new List<FrogCandidateViewModel>(open.Count);
        foreach (var task in open)
        {
            candidates.Add(new FrogCandidateViewModel(task));
        }
        Candidates = candidates;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(null));
    }

    private void OnTasksChanged() => UiDispatch.Post(_dispatcherQueue, Refresh);

    /// <summary>Mirrors the candidate row's `.onTapGesture` (MorningFrogView.swift:184-187):
    /// `picked = candidate.id; onPick(candidate.id)`.</summary>
    private async Task PickAsync(Guid id)
    {
        SelectedId = id;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(SelectedId)));
        await _service.PickFrogAsync(id).ConfigureAwait(false);
        UiDispatch.Post(_dispatcherQueue, Refresh);
    }

    private void Skip()
    {
        _service.DismissMorningFrog();
        Refresh();
    }

    /// <summary>`appState.toggleCapture(); onSkip()` (MorningFrogView.swift:77-78) — starts/stops
    /// capture, then dismisses this sheet exactly like "Skip today".</summary>
    private async Task VoiceAsync()
    {
        await _capture.ToggleCaptureAsync().ConfigureAwait(false);
        _service.DismissMorningFrog();
        UiDispatch.Post(_dispatcherQueue, Refresh);
    }
}
