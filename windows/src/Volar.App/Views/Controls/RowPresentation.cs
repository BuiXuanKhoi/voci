// Views/Controls/RowPresentation.cs — small x:Bind-callable static helpers for B3's 5 modal views
// (TaskDetailView/TaskBreakdownView/TriageView/SweepView/MorningFrogView). WinUI's compiled
// `{x:Bind}` supports calling any accessible static method directly from XAML (including inside a
// nested `DataTemplate`, e.g. Triage/Sweep's row template and MorningFrog's candidate-row
// template) — this file exists so those bindings never need a separate `IValueConverter` class:
// `{x:Bind controls:RowPresentation.PriorityBrush(Priority)}`,
// `{x:Bind controls:RowPresentation.VisibleIfNotEmpty(DurationLabel)}`, etc.
//
// Deliberately in `Views/Controls/` (not `ViewModels/`): these return `Brush`/`Visibility` — real
// XAML/UI types — which wave4-contract.md decision 12 says belong in "XAML/converters", not on a
// ViewModel. `ViewModels/PriorityPresentation.cs` is this file's plain-data counterpart (returns
// resource-key strings only); this file is the one place that actually resolves those keys against
// `Application.Current.Resources`.
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Volar.App.ViewModels;
using Volar.Domain;

namespace Volar.App.Views.Controls;

public static class RowPresentation
{
    /// <summary>Resolves <see cref="PriorityPresentation.ColorResourceKey"/> against
    /// `Application.Current.Resources` — the dot/text color TaskDetailView's meta row and every
    /// Triage/Sweep row title use (views-inventory.md §1.7/§1.9/§1.10, all 3 share the identical
    /// high/med/low switch — see PriorityPresentation.cs's header for why the switch itself isn't
    /// duplicated a 4th time here).</summary>
    public static Brush PriorityBrush(Priority priority) =>
        (Brush)Application.Current.Resources[PriorityPresentation.ColorResourceKey(priority)];

    /// <summary>Swift's `if candidate.priority == .high { ...urgent badge... }`
    /// (MorningFrogView.swift:162) — the one place across this wave's 5 views that branches on
    /// priority without going through the shared high/med/low switch (only High matters here).</summary>
    public static Visibility VisibleIfHighPriority(Priority priority) =>
        priority == Priority.High ? Visibility.Visible : Visibility.Collapsed;

    /// <summary>Swift's `if let durationLabel = item.durationLabel` (TriageRow/SweepRow's optional
    /// trailing duration text) — collapses the element when <see cref="TaskItem.DurationLabel"/> is
    /// null/empty instead of rendering an empty pill.</summary>
    public static Visibility VisibleIfNotEmpty(string? text) =>
        string.IsNullOrEmpty(text) ? Visibility.Collapsed : Visibility.Visible;

    public static Visibility VisibleIfTrue(bool value) => value ? Visibility.Visible : Visibility.Collapsed;

    public static Visibility VisibleIfFalse(bool value) => value ? Visibility.Collapsed : Visibility.Visible;

    /// <summary>x:Bind requires a non-null `Text` even when the paired element is Collapsed (a null
    /// `DurationLabel` would otherwise throw on TextBlock.Text's non-nullable string binding).</summary>
    public static string OrEmpty(string? text) => text ?? string.Empty;

    /// <summary>"&lt;label&gt; — &lt;title&gt;" (TriageView.swift:199 / SweepView.swift's identical
    /// `.accessibilityLabel` pattern) -> `AutomationProperties.Name`, per this wave's contract.</summary>
    public static string ActionAutomationName(string label, string title) => $"{label} — {title}";
}
