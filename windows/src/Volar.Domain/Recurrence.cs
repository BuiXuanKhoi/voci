// Volar.Domain/Recurrence.cs — port of Sources/Model/Recurrence.swift: recurrence rule +
// reset-in-place engine (research.md R8), reminder policy, delegation metadata, and task kind. All
// four are persisted (as JSON blobs in the Swift app) by the data layer, out of this project's
// scope — this file only defines the pure value types + pure math.
using Volar.Core;

namespace Volar.Domain;

// MARK: - TaskKind

/// <summary>UI treatment only (data-model.md) — the Volar.Core engine has no notion of this.</summary>
public enum TaskKind
{
    Task,
    Review
}

// MARK: - Recurrence

/// <summary>
/// Leaf-task-only schedule. The persistence layer is responsible for enforcing "no children"
/// (data-model.md validation rule 2) at the store boundary — this type itself is a pure value with
/// no awareness of the task graph.
/// </summary>
/// <remarks>
/// Modeled as a closed discriminated union (an <see langword="abstract record"/> with four
/// <see langword="sealed"/> subtypes — three carrying no data, mirroring Swift's
/// <c>enum Recurrence: Sendable, Equatable</c> with an associated value on exactly one case),
/// matched exhaustively via <see langword="switch"/> expressions (see <see cref="Condition"/> for
/// the same pattern in Volar.Core). Every instance of e.g. <see cref="Daily"/> compares equal,
/// mirroring the Swift enum case's trivial equality.
/// </remarks>
public abstract record Recurrence
{
    // `private protected`: only the sealed subtypes declared below may derive from Recurrence,
    // keeping the union effectively closed, mirroring the Swift enum.
    private protected Recurrence() { }

    public sealed record Daily : Recurrence;

    public sealed record Weekly : Recurrence;

    public sealed record Monthly : Recurrence;

    /// <summary>
    /// Repeats every <paramref name="Days"/> days. <paramref name="Days"/> should be &gt; 0; a
    /// non-positive value is accepted here (this is a pure value type with no validation of its
    /// own) but is treated by <see cref="RecurrenceEngine.Advance"/> as "cannot advance" — matching
    /// Swift's defensive guard on the same malformed-rule case.
    /// </summary>
    public sealed record Every(int Days) : Recurrence;
}

// MARK: - ReminderPolicy

/// <summary>
/// Reminder offsets relative to a task's deadline, plus an optional post-deadline repeat interval.
/// </summary>
/// <param name="Offsets">
/// Offsets relative to the task's deadline; negative = before. The default global policy (see
/// <see cref="DefaultPolicy"/>) per data-model.md is -1 day, -1 hour, at-deadline.
/// </param>
/// <param name="RepeatEvery">
/// "Every 30 minutes" style repeat after the deadline; <see langword="null"/> = fire once per
/// offset only.
/// </param>
public readonly record struct ReminderPolicy(IReadOnlyList<TimeSpan> Offsets, TimeSpan? RepeatEvery)
{
    public static ReminderPolicy DefaultPolicy { get; } = new(
        new TimeSpan[] { TimeSpan.FromDays(-1), TimeSpan.FromHours(-1), TimeSpan.Zero },
        null);
}

// MARK: - DelegationMeta

/// <summary>
/// Present on a task while delegated-to-AI (feature 002, US4). Lifecycle owned by the orchestrator
/// layer (Volar.Orchestrator, out of this project's scope) — this type only defines the persisted
/// shape.
/// </summary>
/// <param name="BackoffStage">
/// 0 -&gt; 10 minutes, 1 -&gt; 30 minutes, &gt;= 2 -&gt; batch-only (research.md R9).
/// </param>
public readonly record struct DelegationMeta(
    string Label,
    DateTimeOffset CheckBackAt,
    int BackoffStage,
    string? CwdHint,
    DateTimeOffset DelegatedAt);

// MARK: - Recurrence reset result

/// <summary>
/// The persisted fields a completion-triggered reset touches — deliberately narrow (not an entire
/// task record) so <see cref="RecurrenceEngine.Reset"/> stays a pure function that's trivially
/// unit-testable.
/// </summary>
public readonly record struct RecurrenceReset(DateTimeOffset? Deadline, IReadOnlyList<Condition> Conditions);

// MARK: - Recurrence reset-in-place engine (research.md R8)

/// <summary>
/// Pure recurrence math: every function takes an explicit <see cref="TimeZoneInfo"/> and does all
/// date math via <see cref="LocalCalendar"/> (never bare <see cref="DateTimeOffset"/> +
/// <see cref="TimeSpan"/> arithmetic), so DST transitions and variable month lengths are resolved
/// consistently with the injected time zone rather than assumed by this code.
/// </summary>
public static class RecurrenceEngine
{
    /// <summary>
    /// The date one occurrence of <paramref name="rule"/> after <paramref name="anchor"/>, or
    /// <see langword="null"/> for a malformed <see cref="Recurrence.Every"/> rule (<c>Days &lt;=
    /// 0</c>) — never produced by a valid parse/UI path, but a corrupted store could contain one;
    /// treated as "can't advance" rather than looping the caller or producing a date in the past.
    /// </summary>
    public static DateTimeOffset? Advance(DateTimeOffset anchor, Recurrence rule, TimeZoneInfo timeZone) => rule switch
    {
        Recurrence.Daily => LocalCalendar.AddDays(anchor, 1, timeZone),
        Recurrence.Weekly => LocalCalendar.AddDays(anchor, 7, timeZone),
        Recurrence.Monthly => LocalCalendar.AddMonths(anchor, 1, timeZone),
        Recurrence.Every e => e.Days > 0 ? LocalCalendar.AddDays(anchor, e.Days, timeZone) : null,
        _ => throw new NotSupportedException($"Unhandled {nameof(Recurrence)} subtype: {rule.GetType()}")
    };

    /// <summary>
    /// Completion -&gt; reset-in-place: reopen at the next occurrence. Schedule-anchored by default
    /// (weekly-Monday stays Monday no matter which weekday it was actually completed);
    /// <paramref name="anchorToCompletion"/> re-anchors this ONE cycle to <paramref
    /// name="completedAt"/> instead (the capture-time "starting from today" override, FR-006).
    /// <see cref="AfterDateCondition"/> conditions shift by the same rule, each from its own prior
    /// date; <see cref="ExternalCondition"/> conditions reset to unsatisfied (a fresh cycle
    /// re-waits on whatever it was waiting on); <see cref="TaskDoneCondition"/> conditions are left
    /// untouched — a recurring task's cross-task prerequisites don't reset with its own schedule.
    /// </summary>
    public static RecurrenceReset Reset(
        Recurrence recurrence,
        DateTimeOffset? deadline,
        IReadOnlyList<Condition> conditions,
        DateTimeOffset completedAt,
        bool anchorToCompletion,
        TimeZoneInfo timeZone)
    {
        // A single `Advance(anchor, ...)` call only moves ONE period past the old deadline/
        // condition date. Completing a recurring task more than one period late (e.g. a daily task
        // completed after 5 days away) then reopened with a deadline still in the past would
        // immediately re-fire as overdue. Loop the advance until the new date is strictly after
        // `completedAt`, so the reopened task's next occurrence is always actually in the future.
        // `maxIterations` is a defensive backstop against a pathological/corrupted rule that would
        // otherwise spin (e.g. `Advance` returning the same instant it was given).
        DateTimeOffset NextOccurrence(DateTimeOffset original)
        {
            var anchor = anchorToCompletion ? completedAt : original;
            var candidate = anchor;
            var iterations = 0;
            const int maxIterations = 1000;
            while (candidate <= completedAt && iterations < maxIterations)
            {
                var advanced = Advance(candidate, recurrence, timeZone);
                if (advanced is not DateTimeOffset next)
                {
                    // Advancing failed (defensive — see `Advance`'s doc comment): stop and fall back
                    // to the last good candidate rather than producing a stuck/crashing result.
                    break;
                }
                candidate = next;
                iterations++;
            }
            return candidate;
        }

        DateTimeOffset? nextDeadline;
        if (deadline is DateTimeOffset deadlineValue)
        {
            nextDeadline = NextOccurrence(deadlineValue);
        }
        else if (anchorToCompletion)
        {
            nextDeadline = Advance(completedAt, recurrence, timeZone);
        }
        else
        {
            // No prior schedule to anchor to and no override — stays undated; only its
            // AfterDate/External conditions (if any) gate the next cycle.
            nextDeadline = null;
        }

        var nextConditions = new List<Condition>(conditions.Count);
        foreach (var condition in conditions)
        {
            nextConditions.Add(condition switch
            {
                AfterDateCondition afterDate => new AfterDateCondition(NextOccurrence(afterDate.Date)),
                ExternalCondition external => new ExternalCondition(external.Description, false),
                TaskDoneCondition taskDone => taskDone,
                _ => throw new NotSupportedException($"Unhandled {nameof(Condition)} subtype: {condition.GetType()}")
            });
        }

        return new RecurrenceReset(nextDeadline, nextConditions);
    }
}
