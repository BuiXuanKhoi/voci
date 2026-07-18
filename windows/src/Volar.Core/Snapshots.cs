namespace Volar.Core;

/// <summary>
/// Snapshot-diffing helpers layered on top of <see cref="NextTaskSelector.EligibleTasks"/>: port
/// of Swift's <c>eligibilityDiff(before:after:now:)</c> and
/// <c>nextResurfaceDate(in:after:)</c>.
/// </summary>
public static class Snapshots
{
    /// <summary>
    /// Ids of tasks that are eligible (per <see cref="NextTaskSelector.EligibleTasks"/>, the same
    /// rule <see cref="NextTaskSelector.NextTask"/> uses) in <paramref name="after"/> but were not
    /// eligible in <paramref name="before"/> — pure set logic, feeding auto-unblock notifications
    /// (FR-015).
    /// </summary>
    /// <remarks>
    /// Only status/condition-driven changes are reported: a task absent from
    /// <paramref name="before"/> entirely but eligible in <paramref name="after"/> counts as newly
    /// eligible (it was, trivially, not eligible in <paramref name="before"/>). A task that
    /// becomes ineligible (e.g. un-completing a prerequisite re-blocks a dependent) is simply not
    /// in the result — this method only ever reports additions, never removals.
    /// <para>
    /// Deduplicates by id (an adversarial snapshot with duplicate ids never yields duplicate ids
    /// in the result) and preserves the order in which each newly-eligible id first appears in
    /// <paramref name="after"/>.
    /// </para>
    /// </remarks>
    public static IReadOnlyList<Guid> EligibilityDiff(
        IReadOnlyList<TaskSnapshot> before,
        IReadOnlyList<TaskSnapshot> after,
        DateTimeOffset now)
    {
        var eligibleBeforeIds = new HashSet<Guid>();
        foreach (var task in NextTaskSelector.EligibleTasks(before, now))
        {
            eligibleBeforeIds.Add(task.Id);
        }

        var seen = new HashSet<Guid>();
        var newlyEligible = new List<Guid>();
        foreach (var task in NextTaskSelector.EligibleTasks(after, now))
        {
            if (eligibleBeforeIds.Contains(task.Id))
            {
                continue;
            }
            if (!seen.Add(task.Id))
            {
                continue;
            }
            newlyEligible.Add(task.Id);
        }
        return newlyEligible;
    }

    /// <summary>
    /// The earliest strictly-future <see cref="AfterDateCondition"/> payload anywhere in
    /// <paramref name="snapshot"/>, or <see langword="null"/> if none exists — feeds the resurface
    /// scheduler (FR-017).
    /// </summary>
    /// <remarks>
    /// Scans every task's conditions regardless of current eligibility or status (a task that is
    /// currently ineligible for other reasons may still resurface once its
    /// <see cref="AfterDateCondition"/> arrives). "Strictly future" means <c>date &gt; after</c>; a
    /// date equal to or before <paramref name="after"/> is already satisfied (see
    /// <c>Condition.IsSatisfied</c>) and never a candidate for resurfacing.
    /// </remarks>
    public static DateTimeOffset? NextResurfaceDate(IReadOnlyList<TaskSnapshot> snapshot, DateTimeOffset after)
    {
        DateTimeOffset? earliest = null;
        foreach (var task in snapshot)
        {
            foreach (var condition in task.Conditions)
            {
                if (condition is not AfterDateCondition afterDate)
                {
                    continue;
                }
                if (afterDate.Date <= after)
                {
                    continue;
                }
                if (earliest is null || afterDate.Date < earliest.Value)
                {
                    earliest = afterDate.Date;
                }
            }
        }
        return earliest;
    }
}
