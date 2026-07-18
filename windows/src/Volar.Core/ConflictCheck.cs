using System.Globalization;
using System.Text;

namespace Volar.Core;

/// <summary>
/// A half-open time interval <c>[Start, End)</c> used by <see cref="ConflictChecker"/> for
/// calendar-busy time and capacity-window math. Volar.Core is zero-NuGet/BCL-only, so this stands
/// in for Swift Foundation's <c>DateInterval</c> rather than depending on it.
/// </summary>
public readonly record struct DateInterval(DateTimeOffset Start, DateTimeOffset End)
{
    internal TimeSpan Duration => End - Start;

    /// <summary>
    /// The overlap between this interval and <paramref name="other"/>, or <see langword="null"/>
    /// when they do not overlap (including when they merely touch, i.e. zero-length overlap) —
    /// matching Swift's <c>DateInterval.intersection(with:)</c>.
    /// </summary>
    internal DateInterval? Intersect(DateInterval other)
    {
        var start = Start > other.Start ? Start : other.Start;
        var end = End < other.End ? End : other.End;
        if (start >= end)
        {
            return null;
        }
        return new DateInterval(start, end);
    }
}

/// <summary>
/// A capture-time conflict signal detected when adding a candidate to the current task snapshot
/// (spec.md FR-011c; phase4-contract.md §C). The app renders at most one calm advisory line from
/// whatever <see cref="ConflictChecker.Conflicts"/> returns — this is purely advisory (Constitution
/// Principle II): it never blocks capture and never auto-modifies anything.
/// </summary>
public abstract record TaskConflict
{
    private protected TaskConflict() { }

    /// <summary>
    /// The candidate's deadline day is already over-committed by existing tasks' estimates plus
    /// calendar-busy time. <paramref name="ExistingCount"/> excludes the candidate;
    /// <paramref name="EstimatedMinutes"/> is the total (existing + busy + candidate) minutes on
    /// that day; <paramref name="WindowEnd"/> is the end of that calendar day.
    /// </summary>
    public sealed record DeadlineCapacity(int ExistingCount, int EstimatedMinutes, DateTimeOffset WindowEnd) : TaskConflict;

    /// <summary>
    /// The candidate's deadline falls within a small window of an existing urgent (InProgress /
    /// priority-1 / frog) task's deadline.
    /// </summary>
    public sealed record DeadlineCollision(Guid WithTaskId, string Title) : TaskConflict;

    /// <summary>
    /// The candidate depends (via <see cref="TaskDoneCondition"/>) on a task that is itself
    /// overdue or stuck behind its own unsatisfied condition.
    /// </summary>
    public sealed record DependsOnBlocked(Guid TaskId, string Title) : TaskConflict;

    /// <summary>
    /// The candidate is high-stakes (priority 1, or a today/overdue deadline) and a different task
    /// is today's chosen "frog" (most important task).
    /// </summary>
    public sealed record CompetesWithFrog(Guid TaskId, string Title) : TaskConflict;

    /// <summary>
    /// The candidate's title fuzzy-matches an existing open task at or above the duplicate
    /// threshold. <paramref name="Score"/> is the raw similarity in [0, 1].
    /// </summary>
    public sealed record PossibleDuplicate(Guid TaskId, string Title, double Score) : TaskConflict;
}

/// <summary>
/// Detects capture-time conflicts (port of <c>conflicts(forAdding:into:now:calendar:busyIntervals:
/// frogId:)</c>). Every threshold below is deliberately conservative — the whole point of this
/// class (per phase4-contract.md §C) is that a clean capture, the common case, returns an empty
/// list.
/// </summary>
public static class ConflictChecker
{
    /// <summary>A "reasonable working day" for capacity math, in minutes (8h).</summary>
    private const int WorkdayMinutes = 480;

    /// <summary>
    /// Capacity fires once existing + busy + candidate minutes on the deadline day reach this
    /// share of a working day (~80%). A single threshold covers both "adding the candidate tips
    /// the day over 80%" and "the day is already clearly over-committed": if existing + busy alone
    /// already meet or exceed a full working day, that total is trivially also &gt;= this (lower)
    /// threshold, so no second branch is needed.
    /// </summary>
    private static readonly int CapacityThresholdMinutes =
        (int)Math.Round(WorkdayMinutes * 0.8, MidpointRounding.AwayFromZero);

    /// <summary>
    /// Per-task estimate cap used only to bound the capacity sum against adversarial input (e.g. a
    /// snapshot task carrying <c>EstimateMinutes == int.MaxValue</c>); real captures never
    /// approach this.
    /// </summary>
    private const int PerTaskEstimateCapMinutes = 100_000;

    /// <summary>
    /// "Small window" for deadline-collision: 2 hours either side of an existing urgent task's
    /// deadline.
    /// </summary>
    private static readonly TimeSpan CollisionWindow = TimeSpan.FromHours(2);

    /// <summary>Fuzzy title-similarity floor for possible-duplicate (Jaccard over normalized token sets).</summary>
    private const double DuplicateScoreThreshold = 0.8;

    /// <summary>
    /// Bounds applied when tokenizing a title, so an adversarially huge title cannot blow up the
    /// duplicate scorer's cost.
    /// </summary>
    private const int MaxTitleCharsForMatching = 500;

    private const int MaxTokensForMatching = 64;

    /// <summary>
    /// Detects capture-time conflicts for <paramref name="candidate"/> against the current
    /// <paramref name="snapshot"/>.
    /// </summary>
    /// <remarks>
    /// PURE (Constitution Principle III): no I/O, no clock, no calendar read. <paramref
    /// name="now"/>, <paramref name="timeZone"/>, and <paramref name="busyIntervals"/> are all
    /// caller-supplied data — the app passes the user's real time zone / real busy intervals,
    /// tests pass fixed fixtures — so this method never reads a global and always produces the
    /// same result for the same inputs, regardless of <paramref name="snapshot"/>'s list order.
    /// <para>
    /// Returns HIGH-SIGNAL conflicts only, at most one per kind (so a flood of same-kind matches
    /// never has to be prioritized downstream — the app's "one calm advisory line" always has a
    /// small, stable list to pick from), in the fixed order the <see cref="TaskConflict"/> cases
    /// are declared. An empty result means a clean capture.
    /// </para>
    /// </remarks>
    public static IReadOnlyList<TaskConflict> Conflicts(
        TaskSnapshot candidate,
        IReadOnlyList<TaskSnapshot> snapshot,
        DateTimeOffset now,
        TimeZoneInfo timeZone,
        IReadOnlyList<DateInterval> busyIntervals,
        Guid? frogId)
    {
        var result = new List<TaskConflict>();

        var capacity = DeadlineCapacityConflict(candidate, snapshot, now, timeZone, busyIntervals);
        if (capacity is not null)
        {
            result.Add(capacity);
        }

        var collision = DeadlineCollisionConflict(candidate, snapshot, frogId);
        if (collision is not null)
        {
            result.Add(collision);
        }

        var blocked = DependsOnBlockedConflict(candidate, snapshot, now);
        if (blocked is not null)
        {
            result.Add(blocked);
        }

        var frog = CompetesWithFrogConflict(candidate, snapshot, now, timeZone, frogId);
        if (frog is not null)
        {
            result.Add(frog);
        }

        var duplicate = PossibleDuplicateConflict(candidate, snapshot);
        if (duplicate is not null)
        {
            result.Add(duplicate);
        }

        return result;
    }

    // MARK: - deadlineCapacity

    /// <summary>
    /// Sums the estimates of existing eligible tasks (via the shared
    /// <see cref="NextTaskSelector.EligibleTasks"/> used by <see cref="NextTaskSelector.NextTask"/>)
    /// whose deadline falls on the same calendar day as the candidate's deadline, plus
    /// calendar-busy minutes on that day, plus the candidate's own estimate — and fires only once
    /// that total reaches <see cref="CapacityThresholdMinutes"/>. Requires at least one existing
    /// same-day task (busy-calendar time alone never fires this; the advisory reads "N tasks
    /// already due...").
    /// </summary>
    private static TaskConflict.DeadlineCapacity? DeadlineCapacityConflict(
        TaskSnapshot candidate,
        IReadOnlyList<TaskSnapshot> snapshot,
        DateTimeOffset now,
        TimeZoneInfo timeZone,
        IReadOnlyList<DateInterval> busyIntervals)
    {
        if (candidate.Deadline is not DateTimeOffset candidateDeadline)
        {
            return null;
        }

        var dayStart = StartOfDay(candidateDeadline, timeZone);
        var dayEnd = StartOfDay(dayStart.AddDays(1), timeZone);
        var dayInterval = new DateInterval(dayStart, dayEnd);

        var existingCount = 0;
        var existingMinutes = 0;
        foreach (var task in NextTaskSelector.EligibleTasks(snapshot, now))
        {
            if (task.Id == candidate.Id)
            {
                continue;
            }
            if (task.Deadline is not DateTimeOffset deadline)
            {
                continue;
            }
            if (!NextTaskSelector.IsSameCalendarDay(deadline, candidateDeadline, timeZone))
            {
                continue;
            }
            existingCount++;
            existingMinutes += ClampedEstimateMinutes(task.EstimateMinutes);
        }

        // Busy-calendar time alone (with no existing same-day tasks) is not high-signal enough to
        // warrant an advisory — keep the noise floor tied to actual competing tasks.
        if (existingCount == 0)
        {
            return null;
        }

        var busyMinutes = 0;
        foreach (var interval in busyIntervals)
        {
            var overlap = dayInterval.Intersect(interval);
            if (overlap is null)
            {
                continue;
            }
            // `overlap` is clipped to a single day, so its duration is inherently bounded (<= 24h)
            // regardless of how the caller constructed `interval` — no per-item overflow risk.
            busyMinutes += (int)Math.Round(overlap.Value.Duration.TotalMinutes, MidpointRounding.AwayFromZero);
        }

        var candidateMinutes = ClampedEstimateMinutes(candidate.EstimateMinutes);
        var totalMinutes = existingMinutes + busyMinutes + candidateMinutes;

        if (totalMinutes < CapacityThresholdMinutes)
        {
            return null;
        }

        return new TaskConflict.DeadlineCapacity(existingCount, totalMinutes, dayEnd);
    }

    /// <summary>
    /// Clamps a (possibly absent, possibly adversarial) estimate into
    /// <c>[0, PerTaskEstimateCapMinutes]</c> so a single malformed task (negative, or
    /// <see cref="int.MaxValue"/>) cannot skew or overflow the capacity sum.
    /// </summary>
    private static int ClampedEstimateMinutes(int? minutes)
    {
        if (minutes is not int value)
        {
            return 0;
        }
        return Math.Min(Math.Max(value, 0), PerTaskEstimateCapMinutes);
    }

    // MARK: - deadlineCollision

    /// <summary>
    /// Finds the closest existing urgent (InProgress / priority-1 / frog) open task whose deadline
    /// falls within <see cref="CollisionWindow"/> of the candidate's deadline. At most one match
    /// is returned (nearest by time delta, then ordinal id tiebreak) to stay low-noise.
    /// </summary>
    private static TaskConflict.DeadlineCollision? DeadlineCollisionConflict(
        TaskSnapshot candidate,
        IReadOnlyList<TaskSnapshot> snapshot,
        Guid? frogId)
    {
        if (candidate.Deadline is not DateTimeOffset candidateDeadline)
        {
            return null;
        }

        TaskSnapshot? best = null;
        var bestDelta = TimeSpan.Zero;

        foreach (var task in snapshot)
        {
            if (task.Id == candidate.Id)
            {
                continue;
            }
            if (task.Status != TaskState.Todo && task.Status != TaskState.InProgress)
            {
                continue;
            }
            if (task.Deadline is not DateTimeOffset deadline)
            {
                continue;
            }
            var isUrgent = task.Status == TaskState.InProgress || task.Priority == 1 || task.Id == frogId;
            if (!isUrgent)
            {
                continue;
            }

            var delta = (deadline - candidateDeadline).Duration();
            if (delta > CollisionWindow)
            {
                continue;
            }

            if (best is not TaskSnapshot currentBest)
            {
                best = task;
                bestDelta = delta;
                continue;
            }
            if (delta < bestDelta
                || (delta == bestDelta && string.CompareOrdinal(task.Id.ToString(), currentBest.Id.ToString()) < 0))
            {
                best = task;
                bestDelta = delta;
            }
        }

        if (best is not TaskSnapshot match)
        {
            return null;
        }
        return new TaskConflict.DeadlineCollision(match.Id, match.Title);
    }

    // MARK: - dependsOnBlocked

    /// <summary>
    /// Scans the candidate's <see cref="TaskDoneCondition"/> conditions (in declaration order,
    /// first match wins) for a referenced task that is either overdue (past its own deadline,
    /// still open) or itself stuck behind an unsatisfied condition. An absent or already
    /// done/archived reference is satisfied, per <c>Condition.IsSatisfied</c>'s existing
    /// resolution mapping, and never flagged here.
    /// </summary>
    private static TaskConflict.DependsOnBlocked? DependsOnBlockedConflict(
        TaskSnapshot candidate,
        IReadOnlyList<TaskSnapshot> snapshot,
        DateTimeOffset now)
    {
        if (candidate.Conditions.Count == 0)
        {
            return null;
        }

        // Built with explicit loops and indexer assignment (not `.Add`/`ToDictionary`) so a
        // snapshot with duplicate ids can't throw; last occurrence for a given id wins, matching
        // the convention in NextTask.cs.
        var statusById = new Dictionary<Guid, TaskState>(snapshot.Count);
        var taskById = new Dictionary<Guid, TaskSnapshot>(snapshot.Count);
        foreach (var task in snapshot)
        {
            statusById[task.Id] = task.Status;
            taskById[task.Id] = task;
        }

        foreach (var condition in candidate.Conditions)
        {
            if (condition is not TaskDoneCondition taskDone)
            {
                continue;
            }
            if (!taskById.TryGetValue(taskDone.TaskId, out var reference))
            {
                continue; // absent from snapshot = satisfied
            }
            if (reference.Status != TaskState.Todo && reference.Status != TaskState.InProgress)
            {
                continue; // done/archived = satisfied
            }

            var isOverdue = reference.Deadline is DateTimeOffset deadline && deadline < now;

            var isStuck = false;
            foreach (var referenceCondition in reference.Conditions)
            {
                if (!referenceCondition.IsSatisfied(statusById, now))
                {
                    isStuck = true;
                    break;
                }
            }

            if (isOverdue || isStuck)
            {
                return new TaskConflict.DependsOnBlocked(reference.Id, reference.Title);
            }
        }
        return null;
    }

    // MARK: - competesWithFrog

    /// <summary>
    /// Fires when the candidate is itself high-stakes (explicit priority 1, or a today/overdue
    /// deadline) and a <i>different</i>, still-open task is the caller-designated "frog" for the
    /// day.
    /// </summary>
    private static TaskConflict.CompetesWithFrog? CompetesWithFrogConflict(
        TaskSnapshot candidate,
        IReadOnlyList<TaskSnapshot> snapshot,
        DateTimeOffset now,
        TimeZoneInfo timeZone,
        Guid? frogId)
    {
        if (frogId is not Guid frog || frog == candidate.Id)
        {
            return null;
        }

        var candidateIsHighStakes = candidate.Priority == 1
            || NextTaskSelector.IsNearTermDeadline(candidate.Deadline, now, timeZone);
        if (!candidateIsHighStakes)
        {
            return null;
        }

        TaskSnapshot? frogTask = null;
        foreach (var task in snapshot)
        {
            if (task.Id == frog)
            {
                frogTask = task;
                break;
            }
        }
        if (frogTask is not TaskSnapshot frogValue)
        {
            return null;
        }
        if (frogValue.Status != TaskState.Todo && frogValue.Status != TaskState.InProgress)
        {
            return null;
        }

        return new TaskConflict.CompetesWithFrog(frogValue.Id, frogValue.Title);
    }

    // MARK: - possibleDuplicate

    /// <summary>
    /// Finds the highest-scoring existing open task whose title fuzzy-matches the candidate's at
    /// or above <see cref="DuplicateScoreThreshold"/>, using a simple token-set (Jaccard)
    /// similarity over diacritic- and case-folded titles. Dependency-free, Vietnamese-diacritic-
    /// aware (folds "Đọc" ~ "doc" the same way as ASCII case folding).
    /// </summary>
    private static TaskConflict.PossibleDuplicate? PossibleDuplicateConflict(
        TaskSnapshot candidate,
        IReadOnlyList<TaskSnapshot> snapshot)
    {
        var candidateTokens = new HashSet<string>(NormalizedTitleTokens(candidate.Title), StringComparer.Ordinal);
        if (candidateTokens.Count == 0)
        {
            return null;
        }

        TaskSnapshot? best = null;
        var bestScore = 0.0;

        foreach (var task in snapshot)
        {
            if (task.Id == candidate.Id)
            {
                continue;
            }
            if (task.Status != TaskState.Todo && task.Status != TaskState.InProgress)
            {
                continue;
            }

            var score = TitleSimilarity(candidateTokens, task.Title);
            if (score < DuplicateScoreThreshold)
            {
                continue;
            }

            if (best is not TaskSnapshot currentBest)
            {
                best = task;
                bestScore = score;
                continue;
            }
            if (score > bestScore
                || (score == bestScore && string.CompareOrdinal(task.Id.ToString(), currentBest.Id.ToString()) < 0))
            {
                best = task;
                bestScore = score;
            }
        }

        if (best is not TaskSnapshot match)
        {
            return null;
        }
        return new TaskConflict.PossibleDuplicate(match.Id, match.Title, bestScore);
    }

    /// <summary>
    /// Normalizes and tokenizes a title for fuzzy matching: diacritic- and case-fold (so
    /// "Đọc sách" and "doc sach" tokenize identically), then split on any non-letter/non-digit
    /// boundary. Bounded on both input length and token count so an adversarially huge title
    /// cannot make this (or the O(n) scan that calls it once per snapshot task) expensive.
    /// </summary>
    private static IReadOnlyList<string> NormalizedTitleTokens(string title)
    {
        var bounded = title.Length > MaxTitleCharsForMatching ? title[..MaxTitleCharsForMatching] : title;

        // Unicode NFD decomposition splits base letters from their combining diacritical marks
        // (the Vietnamese tone marks, and letters like o/ó/ô/ơ whose modifier is a canonically
        // decomposable combining mark); stripping Mark, Nonspacing (Mn) codepoints then folds them
        // away. It does NOT touch "đ"/"Đ": that is an atomic Latin letter-with-stroke with no
        // Unicode decomposition mapping (a different phoneme, not a diacritic), so it survives
        // decomposition untouched. Map it explicitly (post-lowercasing, so only "đ" remains) so
        // "Đọc" and "doc" tokenize identically.
        var decomposed = bounded.Normalize(NormalizationForm.FormD);
        var stripped = new StringBuilder(decomposed.Length);
        foreach (var ch in decomposed)
        {
            if (CharUnicodeInfo.GetUnicodeCategory(ch) == UnicodeCategory.NonSpacingMark)
            {
                continue;
            }
            stripped.Append(ch);
        }

        var folded = stripped.ToString().ToLowerInvariant().Replace('đ', 'd');

        var tokens = new List<string>();
        var current = new StringBuilder();
        foreach (var ch in folded)
        {
            if (char.IsLetterOrDigit(ch))
            {
                current.Append(ch);
            }
            else if (current.Length > 0)
            {
                tokens.Add(current.ToString());
                current.Clear();
            }
        }
        if (current.Length > 0)
        {
            tokens.Add(current.ToString());
        }

        return tokens.Count > MaxTokensForMatching ? tokens.Take(MaxTokensForMatching).ToList() : tokens;
    }

    /// <summary>
    /// Jaccard similarity (<c>|intersection| / |union|</c>) between <paramref
    /// name="candidateTokens"/> and <paramref name="otherTitle"/>'s normalized token set. A title
    /// that tokenizes to nothing (empty/punctuation-only) never matches — no divide-by-zero, no
    /// degenerate empty-vs-empty "match".
    /// </summary>
    private static double TitleSimilarity(IReadOnlySet<string> candidateTokens, string otherTitle)
    {
        var otherTokens = new HashSet<string>(NormalizedTitleTokens(otherTitle), StringComparer.Ordinal);
        if (otherTokens.Count == 0)
        {
            return 0;
        }

        var intersection = 0;
        foreach (var token in candidateTokens)
        {
            if (otherTokens.Contains(token))
            {
                intersection++;
            }
        }
        var union = candidateTokens.Count + otherTokens.Count - intersection;
        if (union == 0)
        {
            return 0;
        }
        return (double)intersection / union;
    }

    /// <summary>
    /// Start of the calendar day (00:00:00 local wall-clock, converted back to an absolute
    /// instant) containing <paramref name="instant"/> under <paramref name="timeZone"/> — the
    /// injected-timezone equivalent of Swift's <c>Calendar.startOfDay(for:)</c>. Deliberately
    /// round-trips through an unspecified-kind local <see cref="DateTime"/> rather than doing
    /// fixed-offset arithmetic, so this stays correct across a DST transition.
    /// </summary>
    private static DateTimeOffset StartOfDay(DateTimeOffset instant, TimeZoneInfo timeZone)
    {
        var local = TimeZoneInfo.ConvertTime(instant, timeZone);
        var localMidnight = new DateTime(local.Year, local.Month, local.Day, 0, 0, 0, DateTimeKind.Unspecified);
        var utcMidnight = TimeZoneInfo.ConvertTimeToUtc(localMidnight, timeZone);
        return new DateTimeOffset(utcMidnight, TimeSpan.Zero);
    }
}
