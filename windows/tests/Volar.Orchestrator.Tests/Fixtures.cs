using System.Globalization;
using Volar.Core;
using Volar.Domain;

namespace Volar.Orchestrator.Tests;

/// <summary>Deterministic time/id/task fixtures shared by every test in this project.</summary>
internal static class Fixtures
{
    /// <summary>Fixed reference instant: 2026-07-15 12:00:00 UTC.</summary>
    public static readonly DateTimeOffset ReferenceNow = new(2026, 7, 15, 12, 0, 0, TimeSpan.Zero);

    /// <summary>
    /// Produces a stable, orderable <see cref="Guid"/> from a small integer, mirroring
    /// Volar.Core.Tests' own <c>FixedGuid</c> helper.
    /// </summary>
    public static Guid FixedGuid(int n)
    {
        var hex = n.ToString("x12", CultureInfo.InvariantCulture);
        return Guid.Parse($"00000000-0000-0000-0000-{hex}", CultureInfo.InvariantCulture);
    }

    /// <summary>Builds a <see cref="TaskItem"/> with sensible defaults for orchestrator tests.</summary>
    public static TaskItem MakeTask(
        Guid? id = null,
        string title = "Untitled task",
        TaskState status = TaskState.Todo,
        IReadOnlyList<Condition>? conditions = null,
        DateTimeOffset? createdAt = null) =>
        new(
            id ?? Guid.NewGuid(),
            title,
            Priority.Medium,
            When.Now,
            createdAt ?? ReferenceNow,
            status: status,
            conditions: conditions ?? Array.Empty<Condition>());

    /// <summary>An unsatisfied waiting-on-AI condition with the given label, matching <see cref="DelegationTracker.WaitingPrefix"/>.</summary>
    public static ExternalCondition WaitingOnAi(string label) =>
        new(DelegationTracker.WaitingPrefix + label, false);
}
