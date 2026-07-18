// Entities/ReminderRecordEntity.cs — port of Sources/Model/ReminderRecord.swift's @Model.
namespace Volar.Data.Entities;

/// <summary>
/// Durable record of one reminder fire-time for one task (phase4-contract.md §A). Constitution IV:
/// the (Volar.Reminders) scheduler's entire heap is rebuilt from rows of this type on every
/// launch/wake.
/// </summary>
public sealed class ReminderRecordEntity
{
    public Guid Id { get; set; }

    /// FK to <see cref="TaskEntity"/>, cascade delete (see VolarDbContext config — DESIGN DECISION
    /// flagged in the final report: `TaskStore.swift` itself never manages `ReminderRecord`
    /// lifecycle at all, that's entirely `ReminderScheduler`'s job in the Swift original, so there
    /// is no directly-equivalent Swift behavior to mirror here for "what happens to a task's
    /// reminders when the task is deleted." Cascade delete was chosen because a reminder for a
    /// deleted task is meaningless — Opus/the Reminders agent should confirm this matches
    /// `ReminderScheduler`'s expectations once that module exists.)
    public Guid TaskId { get; set; }

    public DateTimeOffset FireAt { get; set; }

    /// One of "-1d" / "-1h" / "at" / "override" / "resurface" / "unblocked" — same frozen kinds as
    /// the Swift contract.
    public required string OffsetKind { get; set; }

    /// "scheduled" / "delivered" / "satisfied".
    public string State { get; set; } = "scheduled";

    public bool IsHighUrgency { get; set; }
}

/// <summary>
/// Pure derivation math — port of the Swift file's `extension ReminderRecord` static `derive`.
/// </summary>
/// <remarks>
/// DESIGN DECISION (flagged for Opus review): Swift's `derive` takes a `ReminderPolicy?` override
/// and a `ReminderPolicy` global default and resolves `reminderOverride ?? globalPolicy` itself.
/// `ReminderPolicy` is a Volar.Reminders-owned type that does not exist yet (this is a Wave-2
/// module; this task's brief is Wave-1 Volar.Data only), so this port instead takes the
/// already-resolved list of offsets directly — the trivial `??` resolution is left to the
/// Volar.Reminders caller once `ReminderPolicy` exists. Everything else (fire-time computation,
/// offset-kind labeling, high-urgency flag) is ported unchanged.
/// </remarks>
public static class ReminderDerivation
{
    /// <summary>
    /// One <see cref="ReminderRecordEntity"/> per entry in <paramref name="offsets"/>, anchored to
    /// <paramref name="deadline"/>. Returns <c>[]</c> when there's no deadline, matching Swift's
    /// "deadlines never gate eligibility, and a reminder has nothing to count down to without one."
    /// Pure: deterministic for identical inputs, no wall-clock read.
    /// </summary>
    public static IReadOnlyList<ReminderRecordEntity> Derive(
        Guid taskId,
        DateTimeOffset? deadline,
        IReadOnlyList<TimeSpan> offsets)
    {
        if (deadline is not DateTimeOffset value)
        {
            return [];
        }

        var result = new List<ReminderRecordEntity>(offsets.Count);
        foreach (var offset in offsets)
        {
            result.Add(new ReminderRecordEntity
            {
                Id = Guid.NewGuid(),
                TaskId = taskId,
                FireAt = value + offset,
                OffsetKind = OffsetKindFor(offset),
                State = "scheduled",
                IsHighUrgency = offset >= TimeSpan.Zero,
            });
        }
        return result;
    }

    private static string OffsetKindFor(TimeSpan offset)
    {
        if (offset == TimeSpan.FromDays(-1))
        {
            return "-1d";
        }
        if (offset == TimeSpan.FromHours(-1))
        {
            return "-1h";
        }
        if (offset == TimeSpan.Zero)
        {
            return "at";
        }
        return "override";
    }
}
