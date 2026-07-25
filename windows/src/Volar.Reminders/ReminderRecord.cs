// ReminderRecord.cs — port of Sources/Model/ReminderRecord.swift: one persisted reminder intent
// for a task, plus the pure `derive` math.
//
// NOTE: an EF entity `Volar.Data.Entities.ReminderRecordEntity` already exists (Wave 1, Volar.Data)
// and looks superficially identical. This type is deliberately NOT that one: `Volar.Reminders` must
// not reference Volar.Data (no EF Core — dependency rules in this task's brief), and the scheduler
// itself is pure/no-I/O, so it owns its records as a plain in-memory list of this class rather than
// a database-backed model. A Wave-3 persistence adapter is expected to map between this type and
// `ReminderRecordEntity` to make the scheduler's state durable across launches — see
// `ReminderScheduler`'s class doc comment for the exact seam.
namespace Volar.Reminders;

/// <summary>
/// One reminder fire-time for one task (phase4-contract.md §A). Mutable in place
/// (<see cref="FireAt"/>/<see cref="OffsetKind"/>/<see cref="State"/>/<see cref="IsHighUrgency"/>
/// all change post-construction) to mirror the Swift <c>@Model</c> reference-type semantics
/// <c>ReminderScheduler</c> relies on (e.g. <c>record.state = "delivered"</c> mutates the one
/// shared instance rather than a copy).
/// </summary>
public sealed class ReminderRecord
{
    public Guid Id { get; }

    public Guid TaskId { get; }

    public DateTimeOffset FireAt { get; set; }

    /// <summary>
    /// One of the contract's frozen kinds: "-1d" / "-1h" / "at" / "override" / "resurface" /
    /// "unblocked". "-1d"/"-1h"/"at" come from the global <see cref="Volar.Domain.ReminderPolicy.DefaultPolicy"/>;
    /// "override" is any per-task override offset that doesn't match one of those three standard
    /// values; "resurface" covers both <see cref="ReminderScheduler.ScheduleResurface"/> (FR-017)
    /// and <see cref="ReminderScheduler.OfferReschedule"/> (FR-016); "unblocked" is
    /// <see cref="ReminderScheduler.NotifyUnblocked"/> (FR-015).
    /// </summary>
    public string OffsetKind { get; set; }

    /// <summary>
    /// "scheduled" (durable, not yet fired) / "delivered" (visual shown, awaiting acknowledgment) /
    /// "satisfied" (suppressed-as-done, or resolved by a user action).
    /// </summary>
    public string State { get; set; }

    /// <summary>
    /// Drives the voice escalation rung (contract §A): <see langword="true"/> for at-or-after-
    /// deadline offsets, so a plain "-1d"/"-1h" heads-up stays visual-only unless a PRIOR visual for
    /// the same task went unacknowledged (see <see cref="ReminderScheduler"/>'s evaluate step).
    /// </summary>
    public bool IsHighUrgency { get; set; }

    public ReminderRecord(
        Guid taskId,
        DateTimeOffset fireAt,
        string offsetKind,
        Guid? id = null,
        string state = "scheduled",
        bool isHighUrgency = false)
    {
        Id = id ?? Guid.NewGuid();
        TaskId = taskId;
        FireAt = fireAt;
        OffsetKind = offsetKind;
        State = state;
        IsHighUrgency = isHighUrgency;
    }

    // MARK: - Derivation (pure — no I/O, no `ModelContext`, no clock reads)

    /// <summary>
    /// Labels a raw policy offset with its contract-frozen kind string. Any offset that isn't one
    /// of the three global-policy standard values is necessarily a custom per-task override.
    /// </summary>
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

    /// <summary>
    /// One <see cref="ReminderRecord"/> per offset in <paramref name="reminderOverride"/> ??
    /// <paramref name="globalPolicy"/>, anchored to <paramref name="deadline"/>. Returns <c>[]</c>
    /// when there's no deadline — per Volar.Core's own contract, deadlines never gate eligibility,
    /// and a reminder has nothing to count down to without one. Pure: deterministic for identical
    /// inputs, no dependency on the current wall clock (fire times land in the past for an
    /// already-overdue deadline; the scheduler's recovery path, not this function, decides what to
    /// do about that — see <see cref="ReminderScheduler.RebuildFromStorage"/>).
    /// </summary>
    public static IReadOnlyList<ReminderRecord> Derive(
        Guid taskId,
        DateTimeOffset? deadline,
        Volar.Domain.ReminderPolicy? reminderOverride,
        Volar.Domain.ReminderPolicy? globalPolicy = null)
    {
        if (deadline is not DateTimeOffset value)
        {
            return Array.Empty<ReminderRecord>();
        }

        var policy = reminderOverride ?? globalPolicy ?? Volar.Domain.ReminderPolicy.DefaultPolicy;
        var result = new List<ReminderRecord>(policy.Offsets.Count);
        foreach (var offset in policy.Offsets)
        {
            result.Add(new ReminderRecord(
                taskId: taskId,
                fireAt: value + offset,
                offsetKind: OffsetKindFor(offset),
                isHighUrgency: offset >= TimeSpan.Zero));
        }
        return result;
    }
}
