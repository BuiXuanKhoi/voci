// ViewModels/NavSection.cs — which sidebar nav row the main column is showing.
//
// The sidebar's three rows have existed since Wave 1 but only Today did anything; Upcoming and Inbox
// were decorative (empty click handlers, hardcoded counts). This enum is what makes them navigation
// rather than decoration. Definitions of the two new sections live in Volar.Domain.TaskSections —
// deliberately NOT here, because they are data rules the domain tests own, not view state.
namespace Volar.App.ViewModels;

public enum NavSection
{
    Today,
    Upcoming,
    Inbox,
}

/// <summary>One day's worth of Upcoming rows. <see cref="Header"/> is pre-formatted by the view model
/// ("Tomorrow", "Wed, Mar 18") so the view stays free of date formatting, matching how
/// <c>TodayDateLabel</c> is already handed over ready to render.</summary>
public sealed class UpcomingDayGroup
{
    public required string Header { get; init; }

    /// <summary>Same row VM the Today drawers use, so a task looks and behaves identically wherever
    /// it appears — checkbox, hover, context menu, open-detail.</summary>
    public required IReadOnlyList<TaskRowViewModel> Rows { get; init; }
}
