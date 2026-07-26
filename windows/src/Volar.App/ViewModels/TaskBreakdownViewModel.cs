// ViewModels/TaskBreakdownViewModel.cs — port of TaskBreakdownView.swift (views-inventory.md §1.8).
// Pure UI-local state, no service dependency: per wave4-contract.md's assignment text ("Trigger
// comes via TriageAndSweepService.BreakdownRequested event (Stage C wires; your VM just exposes
// Show/Task/Close)"), THIS class does not subscribe to TriageAndSweepService itself — Stage C's
// shell subscribes to `TriageAndSweepService.BreakdownRequested` and calls
// <see cref="Show(TaskItem)"/> from that handler (already marshaled onto the UI thread by whatever
// dispatcher wrapper Stage C uses for every other cross-service event in this wave).
//
// Steps are hardcoded sample content, exactly like the Swift source (TaskBreakdownView.swift:17-23)
// — a real AI-breakdown generator is a later phase (see that file's own header comment). FIX G
// (TaskBreakdownView.swift:185-208): "Save all as tasks" stays permanently disabled
// (<see cref="IsSaveEnabled"/> is a read-only `false` constant, never flipped) until a real
// generator exists — do NOT "helpfully" enable this.
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Windows.Input;
using Volar.Domain;

namespace Volar.App.ViewModels;

/// <summary>One row of `TaskBreakdownView.swift`'s private `Step` struct (lines 10-15).</summary>
public sealed class BreakdownStepViewModel
{
    public BreakdownStepViewModel(int number, string label, string duration)
    {
        Number = number;
        Label = label;
        Duration = duration;
    }

    public int Number { get; }

    public string Label { get; }

    public string Duration { get; }
}

public sealed class TaskBreakdownViewModel : INotifyPropertyChanged
{
    // Hardcoded sample steps — TaskBreakdownView.swift:17-23, byte-for-byte.
    private static readonly IReadOnlyList<BreakdownStepViewModel> SampleSteps = new List<BreakdownStepViewModel>
    {
        new(1, "Open Framer", "10 min"),
        new(2, "Draft headline + subhead", "5 min"),
        new(3, "Drop in demo screenshot", "10 min"),
        new(4, "Test email signup form", "10 min"),
        new(5, "Publish + share link", "5 min"),
    };

    public TaskBreakdownViewModel()
    {
        Steps = new ReadOnlyObservableCollection<BreakdownStepViewModel>(
            new ObservableCollection<BreakdownStepViewModel>(SampleSteps));

        EditCommand = new RelayCommand(Close);
        CancelCommand = new RelayCommand(Close);
        // FIX G: CanExecute is permanently false (IsSaveEnabled never flips) — Execute is wired for
        // completeness/parity with Swift's still-present (if unreachable) onSave callback, not
        // because this button can currently be clicked.
        SaveAllCommand = new RelayCommand(SaveAll, () => IsSaveEnabled);
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public bool IsVisible { get; private set; }

    /// <summary>The task whose context-menu "Break down into steps…" triggered this sheet
    /// (TriageAndSweepService.BreakdownRequested's payload). Swift's own header text is hardcoded
    /// ("“Launch landing page”", TaskBreakdownView.swift:54) and does NOT read this task's
    /// title — exposed anyway per the contract's explicit "Show/Task/Close" API shape, and so a
    /// future real generator has the triggering task available without an API change.</summary>
    public TaskItem? TriggerTask { get; private set; }

    public IReadOnlyList<BreakdownStepViewModel> Steps { get; }

    /// <summary>"Total: 40 min" (TaskBreakdownView.swift:24/134-136).</summary>
    public string TotalLabel => "40 min";

    public int StepCount => SampleSteps.Count;

    /// <summary>Pre-formatted digit string for the summary line's 3rd `Run` — kept separate from
    /// <see cref="StepCount"/> (still exposed as a plain `int` for anything that wants the raw
    /// count) because `{x:Bind}` targeting a `Run.Text` (`string`) needs a `string` source to avoid
    /// depending on x:Bind's implicit numeric-to-string coercion.</summary>
    public string StepCountText => StepCount.ToString(System.Globalization.CultureInfo.InvariantCulture);

    /// <summary>FIX G — permanently false. See file header.</summary>
    public bool IsSaveEnabled => false;

    public ICommand EditCommand { get; }

    public ICommand CancelCommand { get; }

    public ICommand SaveAllCommand { get; }

    /// <summary>Mirrors the sheet being presented (`appState.showBreakdown = true` at the
    /// TaskRow context-menu call site) — see file header for who calls this.</summary>
    public void Show(TaskItem task)
    {
        TriggerTask = task;
        IsVisible = true;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(null));
    }

    /// <summary>Mirrors `onClose` (wired to `appState.showBreakdown = false`) — both Edit and
    /// Cancel call this (TaskBreakdownView.swift:158/172).</summary>
    public void Close()
    {
        IsVisible = false;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(null));
    }

    /// <summary>Mirrors `onSave(steps.map(\.label))` (TaskBreakdownView.swift:193) — unreachable
    /// while <see cref="IsSaveEnabled"/> is false (FIX G), kept as a real method rather than a
    /// literal no-op so re-enabling this later (per that file's own comment: "a one-line change") is
    /// just flipping <see cref="IsSaveEnabled"/>, not writing new logic.</summary>
    private void SaveAll()
    {
        // Intentionally unreachable under FIX G — see class + file header. `AppState.saveBreakdown`
        // has no Wave 3-C service port (TriageAndSweepService.cs's own header: "showBreakdown's
        // bool/sheet-presentation ownership is NOT part of this file's scope"); wiring a real target
        // here is future work for whenever the breakdown generator ships.
    }
}
