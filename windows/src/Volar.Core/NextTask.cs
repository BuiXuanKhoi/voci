namespace Volar.Core;

/// <summary>
/// Selects the single task the tray/popover should display right now (port of
/// <c>nextTask(from:now:calendar:)</c>), and exposes the shared ordering/eligibility building
/// blocks used across Volar.Core.
/// </summary>
public static class NextTaskSelector
{
    /// <summary>
    /// Returns the single task the caller should display right now, or <see langword="null"/> when
    /// no task is eligible.
    /// </summary>
    /// <remarks>
    /// This is the core of Constitution Principle III (Deterministic, Pure, Test-Gated Core): the
    /// method performs no I/O, reads no global clock, and depends only on its arguments —
    /// <paramref name="timeZone"/> is data supplied by the caller (app: the user's configured time
    /// zone; tests: a fixed <see cref="TimeZoneInfo"/>), never read from
    /// <see cref="TimeZoneInfo.Local"/>, so the method remains pure/deterministic. For identical
    /// <c>(snapshot, now, timeZone)</c> it always returns the same result, regardless of the order
    /// of <paramref name="snapshot"/> (see <see cref="OrderedBefore"/> for the total-order
    /// guarantee that makes this true).
    /// <para>
    /// Eligibility (v2 — see <c>Condition.cs</c> and
    /// <c>specs/002-workflow-command-center/data-model.md</c> "Engine layer"):
    /// </para>
    /// <list type="bullet">
    /// <item>Only tasks with status in {Todo, InProgress} are considered.</item>
    /// <item>A task is excluded while any of its conditions is unsatisfied (AND semantics).</item>
    /// <item>
    /// A task that is the parent (via another task's <c>ParentId</c>) of any Todo/InProgress child
    /// is excluded, even if that child is itself ineligible for other reasons.
    /// </item>
    /// </list>
    /// <para>
    /// Ordering (unchanged from 001): among eligible tasks, the minimum under
    /// <see cref="OrderedBefore"/> is returned.
    /// </para>
    /// </remarks>
    public static TaskSnapshot? NextTask(IReadOnlyList<TaskSnapshot> snapshot, DateTimeOffset now, TimeZoneInfo timeZone)
    {
        var eligible = EligibleTasks(snapshot, now);
        if (eligible.Count == 0)
        {
            return null;
        }

        var best = eligible[0];
        for (var i = 1; i < eligible.Count; i++)
        {
            if (OrderedBefore(eligible[i], best, now, timeZone))
            {
                best = eligible[i];
            }
        }
        return best;
    }

    /// <summary>
    /// All eligible tasks in <paramref name="snapshot"/> at <paramref name="now"/>, in the
    /// original (unordered) list order. Shared by <see cref="NextTask"/>, <c>Snapshots</c>, and
    /// <c>ConflictChecker</c> so the eligibility rule lives in exactly one place.
    /// </summary>
    /// <remarks>
    /// O(n) precomputation (an id -&gt; status lookup and an id -&gt; hasOpenChild set, each built
    /// with a single pass) followed by an O(n) filter — no per-task or per-comparison rescans of
    /// the snapshot, so this stays linear even at large n.
    /// </remarks>
    internal static IReadOnlyList<TaskSnapshot> EligibleTasks(IReadOnlyList<TaskSnapshot> snapshot, DateTimeOffset now)
    {
        // Built with an explicit loop and indexer assignment (never `.Add`, never `ToDictionary`)
        // so a malformed snapshot with duplicate ids cannot throw; the last occurrence for a given
        // id wins, matching Swift's dictionary-indexer-based construction.
        var statusById = new Dictionary<Guid, TaskState>(snapshot.Count);
        foreach (var task in snapshot)
        {
            statusById[task.Id] = task.Status;
        }

        // Ids that are the ParentId of at least one currently-open (todo/inProgress) task. This is
        // a single O(n) pass over direct parent-child edges only — it does not walk parent chains,
        // so a ParentId cycle in adversarial data cannot cause unbounded recursion here.
        var parentsWithOpenChild = new HashSet<Guid>();
        foreach (var task in snapshot)
        {
            if (task.ParentId is not Guid parentId)
            {
                continue;
            }
            if (task.Status != TaskState.Todo && task.Status != TaskState.InProgress)
            {
                continue;
            }
            parentsWithOpenChild.Add(parentId);
        }

        var result = new List<TaskSnapshot>();
        foreach (var task in snapshot)
        {
            if (task.Status != TaskState.Todo && task.Status != TaskState.InProgress)
            {
                continue;
            }
            if (parentsWithOpenChild.Contains(task.Id))
            {
                continue;
            }

            var allSatisfied = true;
            foreach (var condition in task.Conditions)
            {
                if (!condition.IsSatisfied(statusById, now))
                {
                    allSatisfied = false;
                    break;
                }
            }
            if (allSatisfied)
            {
                result.Add(task);
            }
        }
        return result;
    }

    /// <summary>
    /// A strict total order over tasks for a given reference time: returns <see langword="true"/>
    /// iff <paramref name="self"/> should be selected before <paramref name="other"/>.
    /// </summary>
    /// <remarks>
    /// Comparison is first-difference-wins across five tiers (data-model.md; unchanged from 001):
    /// <list type="number">
    /// <item>
    /// Status class — InProgress before Todo (and, defensively, before Done/Archived should this
    /// comparator ever be invoked on ineligible tasks).
    /// </item>
    /// <item>
    /// Deadline urgency relative to <paramref name="now"/> — a today-or-overdue deadline ranks
    /// before no such deadline; among today/overdue tasks, the earlier deadline instant ranks
    /// first. A deadline strictly in the future beyond today does NOT participate in this tier.
    /// </item>
    /// <item>
    /// Explicit priority ascending (1 highest); <see langword="null"/> (unset) ranks after every
    /// explicit 1...4 value.
    /// </item>
    /// <item>Earlier <c>CreatedAt</c> first.</item>
    /// <item>
    /// Ordinal order of <c>Id.ToString()</c> — this final tier is total over distinct
    /// <see cref="Guid"/>s, which is what makes the overall relation a strict total order
    /// (irreflexive, asymmetric, transitive) and therefore safe to use for selecting a minimum.
    /// Deliberately <see cref="string.CompareOrdinal(string?, string?)"/>, never a
    /// culture-sensitive comparison — otherwise the result could differ across machines/locales.
    /// Swift compares the UPPERCASE canonical <c>id.uuidString</c>; .NET's default
    /// <see cref="Guid.ToString()"/> is lowercase, but ordinal comparison between two hex strings
    /// yields the same relative order regardless of a *consistently* applied case (digits always
    /// sort before letters in ASCII in either case, and same-case letters preserve their relative
    /// alphabetic order), so this still agrees with the Swift ordering.
    /// </item>
    /// </list>
    /// <para>
    /// <paramref name="timeZone"/> is an explicit injected input (never read from
    /// <see cref="TimeZoneInfo.Local"/>) used only by tier 2's "same calendar day as now"
    /// classification — this keeps the comparator pure while letting the caller decide what
    /// "today" means.
    /// </para>
    /// </remarks>
    public static bool OrderedBefore(TaskSnapshot self, TaskSnapshot other, DateTimeOffset now, TimeZoneInfo timeZone)
    {
        // Tier 1: status class.
        var selfStatusRank = StatusRank(self.Status);
        var otherStatusRank = StatusRank(other.Status);
        if (selfStatusRank != otherStatusRank)
        {
            return selfStatusRank < otherStatusRank;
        }

        // Tier 2: deadline urgency (today/overdue) relative to `now`.
        var selfIsNearTerm = IsNearTermDeadline(self.Deadline, now, timeZone);
        var otherIsNearTerm = IsNearTermDeadline(other.Deadline, now, timeZone);
        if (selfIsNearTerm != otherIsNearTerm)
        {
            return selfIsNearTerm;
        }
        if (selfIsNearTerm && otherIsNearTerm
            && self.Deadline is DateTimeOffset selfDeadline
            && other.Deadline is DateTimeOffset otherDeadline
            && selfDeadline != otherDeadline)
        {
            return selfDeadline < otherDeadline;
        }

        // Tier 3: explicit priority ascending; null sorts after every explicit value.
        var selfPriorityRank = PriorityRank(self.Priority);
        var otherPriorityRank = PriorityRank(other.Priority);
        if (selfPriorityRank != otherPriorityRank)
        {
            return selfPriorityRank < otherPriorityRank;
        }

        // Tier 4: earlier creation time first.
        if (self.CreatedAt != other.CreatedAt)
        {
            return self.CreatedAt < other.CreatedAt;
        }

        // Tier 5: stable total-order tiebreak.
        return string.CompareOrdinal(self.Id.ToString(), other.Id.ToString()) < 0;
    }

    /// <summary>
    /// Ordinal used purely for tier-1 comparison; lower ranks are selected first. Done/Archived
    /// are never eligible for selection, but are given a defined (and higher) rank so
    /// <see cref="OrderedBefore"/> remains a valid total order even if ever invoked outside the
    /// eligible-only code path in <see cref="NextTask"/>.
    /// </summary>
    private static int StatusRank(TaskState status) => status switch
    {
        TaskState.InProgress => 0,
        TaskState.Todo => 1,
        TaskState.Done => 2,
        TaskState.Archived => 3,
        _ => throw new NotSupportedException($"Unhandled {nameof(TaskState)} value: {status}")
    };

    /// <summary>
    /// A deadline is "near-term" (today or overdue) relative to <paramref name="now"/> iff it is
    /// strictly before <paramref name="now"/> (overdue) or falls on the same calendar day as
    /// <paramref name="now"/> under the caller-supplied <paramref name="timeZone"/> (today). A
    /// <see langword="null"/> deadline, or one strictly in the future beyond today, is not
    /// near-term. <paramref name="timeZone"/> is injected data, not read from
    /// <see cref="TimeZoneInfo.Local"/>, so this stays pure regardless of which zone the caller
    /// passes. Shared with <c>ConflictChecker</c> (which reimplements the same "today or overdue"
    /// classification against a different Swift file-private helper originally, but there is no
    /// equivalent visibility need in C#, so it reuses this one directly).
    /// </summary>
    internal static bool IsNearTermDeadline(DateTimeOffset? deadline, DateTimeOffset now, TimeZoneInfo timeZone)
    {
        if (deadline is not DateTimeOffset value)
        {
            return false;
        }
        if (value < now)
        {
            return true;
        }
        return IsSameCalendarDay(value, now, timeZone);
    }

    /// <summary>
    /// Whether <paramref name="a"/> and <paramref name="b"/> fall on the same calendar day under
    /// <paramref name="timeZone"/> — the injected-timezone equivalent of Swift's
    /// <c>Calendar.isDate(_:inSameDayAs:)</c>.
    /// </summary>
    internal static bool IsSameCalendarDay(DateTimeOffset a, DateTimeOffset b, TimeZoneInfo timeZone)
    {
        var aLocal = TimeZoneInfo.ConvertTime(a, timeZone);
        var bLocal = TimeZoneInfo.ConvertTime(b, timeZone);
        return aLocal.Year == bLocal.Year && aLocal.Month == bLocal.Month && aLocal.Day == bLocal.Day;
    }

    /// <summary>
    /// Maps an optional priority to a rank where lower sorts first; <see langword="null"/> (unset)
    /// maps to a value greater than any valid explicit priority (1...4) so it always sorts last.
    /// </summary>
    private static int PriorityRank(int? priority) => priority ?? int.MaxValue;
}

/// <summary>
/// An <see cref="IComparer{T}"/> adapter over <see cref="NextTaskSelector.OrderedBefore"/>, for
/// callers (e.g. Volar.Domain view models) that want to sort a list of tasks with
/// <see cref="System.Linq.Enumerable.Order{T}(IEnumerable{T}, IComparer{T})"/> or
/// <see cref="List{T}.Sort(IComparer{T})"/> rather than repeatedly calling
/// <see cref="NextTaskSelector.NextTask"/>. Delegates entirely to
/// <see cref="NextTaskSelector.OrderedBefore"/> so there is exactly one implementation of the
/// five-tier ordering.
/// </summary>
public sealed class TaskOrderComparer(DateTimeOffset now, TimeZoneInfo timeZone) : IComparer<TaskSnapshot>
{
    public int Compare(TaskSnapshot x, TaskSnapshot y)
    {
        if (NextTaskSelector.OrderedBefore(x, y, now, timeZone))
        {
            return -1;
        }
        if (NextTaskSelector.OrderedBefore(y, x, now, timeZone))
        {
            return 1;
        }
        return 0;
    }
}
