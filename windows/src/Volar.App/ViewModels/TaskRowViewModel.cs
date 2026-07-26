// ViewModels/TaskRowViewModel.cs — port of TaskRow.swift's per-row state/actions (views-inventory.md
// §1.4). wave4-contract.md Stage B1 deliverable. One instance per rendered row, constructed fresh by
// TodayViewModel.Refresh() from a TaskItem snapshot — mirrors ITaskListService's own "recompute, never
// hand-patch" discipline (TaskListService.cs's header comment) rather than mutating a long-lived VM in
// place across refreshes.
//
// VM RULES (wave4-contract.md decision 12): INPC, no XAML control types (Priority is a plain
// Volar.Domain enum, not a XAML type — TaskRowControl's code-behind maps it to a brush). Actions call
// straight through to ITaskListService (the single owner of task state, Opus decision 5) and raise
// OpenDetailRequested/BreakdownRequested for whatever Stage C wires those two overlays to — this row
// does not know what TaskDetailView/TaskBreakdownView are (B1 must not mount them, contract "SCOPE").
using System.ComponentModel;
using System.Globalization;
using Volar.App.Services;
using Volar.Domain;

namespace Volar.App.ViewModels;

/// <summary>Bindable wrapper over one <see cref="TaskItem"/>, reused for TaskRowControl's three call
/// sites (Later drawer, Completed drawer) AND for TodayViewModel's NEXT peek row (bespoke XAML layout
/// in TodayView, same underlying VM — NextPeekRow's action set is identical to TaskRow's per
/// views-inventory.md §1.16's own doc comment: "every action TaskRow offers is preserved here").</summary>
public sealed class TaskRowViewModel : INotifyPropertyChanged
{
    private readonly ITaskListService _taskList;
    private TaskItem _task;

    /// <param name="rowPadY">Density-dependent vertical row padding (decision 10 — "density-dependent
    /// paddings x:Bind ThemeState"), captured once at construction from the owning
    /// <see cref="TodayViewModel"/>'s <c>Theme.RowPadY</c> so <see cref="TaskRowControl"/> can bind a
    /// plain <see langword="double"/> DependencyProperty via classic <c>{Binding}</c> against this
    /// row's own DataContext (no ElementName plumbing needed across the drawer's DataTemplate) and
    /// convert it to a <see cref="Thickness"/> in code-behind — see this file's header CornerRadius/
    /// Thickness gotcha note: a raw <c>x:Double</c> StaticResource cannot back a Thickness-typed XAML
    /// property directly, but a data-bound double CAN be converted to one in code.</param>
    public TaskRowViewModel(TaskItem task, bool isActive, ITaskListService taskList, double rowPadY = 10.0, double rowGap = 4.0)
    {
        _task = task;
        IsActive = isActive;
        _taskList = taskList ?? throw new ArgumentNullException(nameof(taskList));
        RowPadY = rowPadY;
        RowGap = rowGap;
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>Row tapped (or NOW-spotlight-equivalent action) — Stage C routes this to whatever owns
    /// the TaskDetailView overlay (B3).</summary>
    public event Action<Guid>? OpenDetailRequested;

    /// <summary>Context-menu "Break down into steps…" — mirrors Swift's `appState.showBreakdown = true`
    /// direct bool write (views-inventory.md §1.4 row 2: task-agnostic in Swift too, the flag doesn't
    /// carry which task). The task id still rides along here as useful context for whatever Stage C
    /// wires this to; a subscriber that doesn't need it may ignore the argument.</summary>
    public event Action<Guid>? BreakdownRequested;

    public Guid Id => _task.Id;

    public string Title => _task.Title;

    public bool IsDone => _task.Done;

    /// <summary>Mirrors Swift's `isActive: Bool` init param (views-inventory.md §1.4) — every current
    /// TodayView call site passes <see langword="false"/> (the retheme moved the "active" hero
    /// treatment to the bespoke NOW spotlight card instead), but the control still supports it for
    /// fidelity/reuse.</summary>
    public bool IsActive { get; }

    /// <summary>See the constructor's <c>rowPadY</c> parameter doc comment.</summary>
    public double RowPadY { get; }

    /// <summary>Density-dependent gap BELOW this row, mirrors `VStack(spacing: rowGap)`
    /// (TodayView.swift:732 — `CollapsibleTaskSection`'s row stack) applied per-row as a trailing
    /// margin instead of a container-level stack spacing (WinUI's plain `ItemsControl` has no
    /// `Spacing` property to template-bind against a runtime VM value — see TaskRowControl's own doc
    /// comment). The last row in a drawer ends up with one extra trailing gap versus a true
    /// inter-item spacing; cosmetic-only, same class of drift as `CollapsibleTaskSection`'s own
    /// UNVERIFIED `approxRowHeight` estimate (TodayView.swift:719-722).</summary>
    public double RowGap { get; }

    public Priority Priority => _task.Priority;

    /// <summary>Mirrors `task.done ? "Done" : priorityLabel` (TaskRow.swift:143).</summary>
    public string PriorityOrStatusLabel => IsDone ? "Done" : PriorityLabel(_task.Priority);

    /// <summary>Mirrors `task.frog && !task.done` (TaskRow.swift:126,148) — gates both the leading frog
    /// dot and the "Frog" subrow label.</summary>
    public bool ShowFrogMarker => _task.Frog && !IsDone;

    /// <summary>Mirrors `task.durationLabel, !task.done` (TaskRow.swift:144).</summary>
    public string? DurationLabel => IsDone ? null : _task.DurationLabel;

    /// <summary>Mirrors `task.timeBadge, !task.done` (TaskRow.swift:163) — trailing pill.</summary>
    public string? TimeBadgeText => IsDone ? null : _task.TimeBadge;

    /// <summary>`TimeBadge(filled:)` mirrors `isActive` (TaskRow.swift:164).</summary>
    public bool IsTimeBadgeFilled => IsActive;

    /// <summary>Mirrors `rawTimeLabel` (TaskRow.swift:38-41) — the muted done-state deadline readout,
    /// independent of <see cref="TimeBadgeText"/> (only ever populated once done).</summary>
    public string? DoneTimeLabel => IsDone && _task.Deadline is DateTimeOffset deadline
        ? deadline.ToString("h:mm tt", CultureInfo.InvariantCulture)
        : null;

    /// <summary>Replaces this row's backing <see cref="TaskItem"/> in place (used by
    /// <see cref="TodayViewModel"/> if it ever chooses to reuse a row VM instance across a refresh
    /// rather than rebuilding — current TodayViewModel rebuilds fresh each time, per
    /// ITaskListService's own "recompute, never hand-patch" convention, but this seam is provided so a
    /// future caller isn't forced to always throw the VM away).</summary>
    public void UpdateTask(TaskItem task, bool? isActiveOverride = null)
    {
        _task = task;
        RaiseAllChanged();
    }

    public async Task ToggleDoneAsync() => await _taskList.ToggleDoneAsync(Id).ConfigureAwait(false);

    public async Task DeleteAsync() => await _taskList.DeleteAsync(Id).ConfigureAwait(false);

    public void OpenDetail() => OpenDetailRequested?.Invoke(Id);

    public void RequestBreakdown() => BreakdownRequested?.Invoke(Id);

    private static string PriorityLabel(Priority priority) => priority switch
    {
        Priority.High => "High",
        Priority.Low => "Low",
        _ => "Medium",
    };

    private void RaiseAllChanged()
    {
        foreach (var name in new[]
        {
            nameof(Title), nameof(IsDone), nameof(Priority), nameof(PriorityOrStatusLabel),
            nameof(ShowFrogMarker), nameof(DurationLabel), nameof(TimeBadgeText),
            nameof(IsTimeBadgeFilled), nameof(DoneTimeLabel),
        })
        {
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
        }
    }
}
