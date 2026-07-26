// ViewModels/PriorityPresentation.cs — shared High/Medium/Low label + color-role lookup for B3's
// modal surfaces (TaskDetailView's meta row, TriageView/SweepView's row title dot). Ported from the
// IDENTICAL private `priorityColor`/`priorityLabel` switch duplicated verbatim in
// `TaskDetailView.swift:55-69`, `TriageView.swift`'s private `TriageRow.priorityColor`, and
// `SweepView.swift`'s private `SweepRow.priorityColor` (views-inventory.md §1.7 flags the
// TaskDetailView/TaskRow duplication by name; the Triage/Sweep copies are the same 3-case switch
// again, a 4th/5th occurrence).
//
// DELIBERATE NON-UNIFICATION (contract instruction, verbatim): "Share priority label/color logic
// via TaskRowViewModel? NO — that's B1's file; put a small shared PriorityPresentation static
// helper in YOUR OWN file ... and note it for Opus to unify later." B1's `TaskRowViewModel`
// (Views/TodayView.xaml's TaskRowControl) almost certainly needs the exact same 3-case switch for
// its own priority pill — this file is NOT that one, by design, to keep B3 file-disjoint from B1
// during Wave 4's parallel build. FLAGGED FOR OPUS: after Stage C merges, `PriorityPresentation`
// here and B1's equivalent priority-color logic on `TaskRowViewModel` should collapse into one
// shared helper (candidate location: a new `ViewModels/Shared/` file, or promote this one) — left
// as two copies deliberately for this wave, not an oversight.
//
// Returns plain data only (strings) — no `Brush`/`Color` here, per wave4-contract.md decision 12
// ("brushes live in XAML/converters"). The XAML-facing brush lookup this feeds is
// `Views/Controls/RowPresentation.PriorityBrush`.
using Volar.Domain;

namespace Volar.App.ViewModels;

public static class PriorityPresentation
{
    /// <summary>Mirrors `priorityLabel(_:)` (TaskDetailView.swift:63-69) — identical 3-case switch
    /// to `PriorityBadge`'s own label (Components.swift), duplicated here per this file's header
    /// note rather than referencing `Views/Controls/PriorityBadge.xaml.cs` (a Stage-A control file
    /// this task may not edit, and whose "Label" is private/baked into its own visual, not exposed
    /// as a reusable static).</summary>
    public static string Label(Priority priority) => priority switch
    {
        Priority.High => "High",
        Priority.Low => "Low",
        _ => "Medium",
    };

    /// <summary>Mirrors `priorityColor(_:)` (TaskDetailView.swift:55-61) /
    /// `TriageRow.priorityColor` / `SweepRow.priorityColor` — all three switch high/medium/low onto
    /// `VolarColor.high/.med/.low` identically. Returns the Colors.xaml brush KEY (not a `Brush`
    /// instance — see file header) for the caller to resolve via
    /// `Application.Current.Resources[...]`, exactly the pattern `PriorityBadge.xaml.cs`'s own
    /// `UpdateVisual` already uses for its (differently-shaped) pill.</summary>
    public static string ColorResourceKey(Priority priority) => priority switch
    {
        Priority.High => "VolarHighBrush",
        Priority.Low => "VolarLowBrush",
        _ => "VolarMedBrush",
    };
}
