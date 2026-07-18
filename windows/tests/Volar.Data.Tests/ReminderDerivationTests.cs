// ReminderDerivationTests.cs — port of the Swift file's `ReminderRecordTests`-equivalent coverage
// for the pure `derive`/`Derive` math (see ReminderRecordEntity.cs's ReminderDerivation).
using Volar.Data.Entities;
using Xunit;

namespace Volar.Data.Tests;

public sealed class ReminderDerivationTests
{
    [Fact]
    public void Derive_NoDeadline_ReturnsEmpty()
    {
        var result = ReminderDerivation.Derive(Guid.NewGuid(), null, [TimeSpan.FromDays(-1)]);

        Assert.Empty(result);
    }

    [Fact]
    public void Derive_OneRecordPerOffset_AnchoredToDeadline()
    {
        var deadline = new DateTimeOffset(2026, 8, 1, 17, 0, 0, TimeSpan.Zero);
        var taskId = Guid.NewGuid();

        var result = ReminderDerivation.Derive(
            taskId, deadline, [TimeSpan.FromDays(-1), TimeSpan.FromHours(-1), TimeSpan.Zero]);

        Assert.Equal(3, result.Count);
        Assert.All(result, r => Assert.Equal(taskId, r.TaskId));
        Assert.Contains(result, r => r.FireAt == deadline.AddDays(-1) && r.OffsetKind == "-1d" && !r.IsHighUrgency);
        Assert.Contains(result, r => r.FireAt == deadline.AddHours(-1) && r.OffsetKind == "-1h" && !r.IsHighUrgency);
        Assert.Contains(result, r => r.FireAt == deadline && r.OffsetKind == "at" && r.IsHighUrgency);
    }

    [Fact]
    public void Derive_NonStandardOffset_LabeledOverride()
    {
        var deadline = new DateTimeOffset(2026, 8, 1, 17, 0, 0, TimeSpan.Zero);

        var result = ReminderDerivation.Derive(Guid.NewGuid(), deadline, [TimeSpan.FromMinutes(-30)]);

        var record = Assert.Single(result);
        Assert.Equal("override", record.OffsetKind);
    }

    [Fact]
    public void Derive_PositiveOffset_IsHighUrgency()
    {
        var deadline = new DateTimeOffset(2026, 8, 1, 17, 0, 0, TimeSpan.Zero);

        var result = ReminderDerivation.Derive(Guid.NewGuid(), deadline, [TimeSpan.FromHours(2)]);

        Assert.True(Assert.Single(result).IsHighUrgency);
    }

    [Fact]
    public void Derive_EmptyOffsetsList_ReturnsEmpty()
    {
        var result = ReminderDerivation.Derive(Guid.NewGuid(), DateTimeOffset.UtcNow, []);

        Assert.Empty(result);
    }
}
