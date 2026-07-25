// ReminderSchedulerTests.cs — xUnit port of Tests/ReminderSchedulerTests.swift (contracts/
// phase4-contract.md §A/§B). Every `[Fact]` below is named after, and carries the same assertions
// as, its Swift counterpart (noted in each doc comment) unless marked "NEW" for a case this Windows
// port added on top (DST-gap coverage lives in ReminderSchedulerDstTests.cs; explicit IToastChannel
// delivery-content coverage lives in ToastChannelDeliveryTests.cs).
using Volar.Domain;
using Xunit;
using static Volar.Reminders.Tests.Fixtures;
using TaskState = Volar.Core.TaskState;

namespace Volar.Reminders.Tests;

public class ReminderSchedulerTests
{
    // MARK: - rebuild-from-storage on launch
    // Swift: testRebuildFromStorageDerivesRemindersForOpenDatedTasks

    [Fact]
    public void RebuildFromStorageDerivesRemindersForOpenDatedTasks()
    {
        var (scheduler, store, _) = MakeScheduler();
        var deadline = ReferenceNow.AddDays(3); // every offset is future
        var task = MakeTask(title: $"Rebuild test {Guid.NewGuid()}", deadline: deadline);
        store.Add(task);

        scheduler.RebuildFromStorage(ReferenceNow);

        var records = scheduler.RecordsForTask(task.Id);
        Assert.Equal(3, records.Count); // global default policy has 3 offsets (-1d/-1h/at)
        Assert.Equal(new HashSet<string> { "-1d", "-1h", "at" }, records.Select(r => r.OffsetKind).ToHashSet());
        Assert.All(records, r => Assert.Equal("scheduled", r.State)); // nothing is due yet
    }

    // MARK: - overdue-while-closed fires once
    // Swift: testOverdueReminderFiresOnceOnRecovery

    [Fact]
    public void OverdueReminderFiresOnceOnRecovery()
    {
        var (scheduler, store, _) = MakeScheduler();
        // Deadline 2 hours in the past: -1d/-1h/at are ALL already due at derivation time.
        var deadline = ReferenceNow.AddHours(-2);
        var task = MakeTask(title: $"Overdue test {Guid.NewGuid()}", deadline: deadline);
        store.Add(task);

        scheduler.RebuildFromStorage(ReferenceNow);
        var afterFirst = scheduler.RecordsForTask(task.Id);
        Assert.NotEmpty(afterFirst);
        Assert.All(afterFirst, r => Assert.Equal("delivered", r.State)); // due-but-missed must fire on recovery

        // A second rebuild (e.g. a second wake) must NOT re-fire already-delivered records.
        scheduler.RebuildFromStorage(ReferenceNow);
        var afterSecond = scheduler.RecordsForTask(task.Id);
        Assert.Equal(
            afterFirst.Select(r => r.State).OrderBy(s => s, StringComparer.Ordinal),
            afterSecond.Select(r => r.State).OrderBy(s => s, StringComparer.Ordinal));
    }

    // MARK: - done-task suppression
    // Swift: testDoneTaskSuppressesFire (SB-2 fix: drives the REAL fire path — derive while open,
    // complete afterward, then fire each derived record — rather than asserting over an empty
    // array for a task that was already done at derivation time).

    [Fact]
    public void DoneTaskSuppressesFire()
    {
        var (scheduler, store, _) = MakeScheduler();
        // Deadline far enough out that ALL THREE offsets (-1d/-1h/at) are still future — unlike the
        // Swift original (`deadline = now + 3600`), which only reads as "nothing due yet" because
        // its due-but-missed pass runs inside a fire-and-forget `Task {}` the test never awaits (see
        // that file's own header comment, point 3: "None of it is awaited by these tests"). This
        // port's RebuildFromStorage is synchronous by design (this task's brief: pure, no I/O), so
        // due-but-missed firing happens inline within the call — a deadline 1 hour out would put the
        // "-1d"/"-1h" offsets in the PAST already (deadline - 24h / deadline - 1h), and they'd be
        // fired for real before this method returns, which is not what this test is exercising.
        var deadline = ReferenceNow.AddDays(2);
        var task = MakeTask(title: $"Done test {Guid.NewGuid()}", deadline: deadline);
        store.Add(task);

        scheduler.RebuildFromStorage(ReferenceNow);
        var scheduled = scheduler.RecordsForTask(task.Id);
        Assert.NotEmpty(scheduled); // an open, dated task must get reminders derived while still open
        Assert.All(scheduled, r => Assert.Equal("scheduled", r.State));

        // Complete it in the store — the derived records themselves are untouched by this call;
        // constitution IV's fresh reload at FIRE time is what's supposed to catch this.
        store.Toggle(task.Id, ReferenceNow);

        // Drive the real fire path for every derived record (as due-but-missed recovery or a live
        // system notification would).
        foreach (var record in scheduled)
        {
            scheduler.HandleFire(record.Id, ReferenceNow);
        }

        var afterFire = scheduler.RecordsForTask(task.Id);
        Assert.All(afterFire, r => Assert.Equal("satisfied", r.State));
    }

    // MARK: - policy escalation offsets
    // Swift: testDeriveUsesGlobalPolicyOffsetsAndHighUrgencyFlag

    [Fact]
    public void DeriveUsesGlobalPolicyOffsetsAndHighUrgencyFlag()
    {
        var deadline = ReferenceNow;
        var records = ReminderRecord.Derive(Guid.NewGuid(), deadline, reminderOverride: null);

        Assert.Equal(3, records.Count);
        var byKind = records.ToDictionary(r => r.OffsetKind);

        Assert.Equal(deadline.AddDays(-1), byKind["-1d"].FireAt);
        Assert.Equal(deadline.AddHours(-1), byKind["-1h"].FireAt);
        Assert.Equal(deadline, byKind["at"].FireAt);

        Assert.False(byKind["-1d"].IsHighUrgency);
        Assert.False(byKind["-1h"].IsHighUrgency);
        Assert.True(byKind["at"].IsHighUrgency); // at-or-after-deadline offsets drive the voice escalation rung
    }

    // Swift: testDerivePrefersPerTaskOverride

    [Fact]
    public void DerivePrefersPerTaskOverride()
    {
        var deadline = ReferenceNow;
        var overridePolicy = new ReminderPolicy(new[] { TimeSpan.FromMinutes(-30) }, null); // 30 min before — nonstandard
        var records = ReminderRecord.Derive(Guid.NewGuid(), deadline, overridePolicy);

        var record = Assert.Single(records);
        Assert.Equal("override", record.OffsetKind);
        Assert.Equal(deadline.AddMinutes(-30), record.FireAt);
    }

    // Swift: testDeriveReturnsEmptyForUndatedTask

    [Fact]
    public void DeriveReturnsEmptyForUndatedTask()
    {
        var records = ReminderRecord.Derive(Guid.NewGuid(), deadline: null, reminderOverride: null);
        Assert.Empty(records); // reminders never gate eligibility and have nothing to anchor to without a deadline
    }

    // MARK: - nearest-N refill under the system cap
    // Swift: testNearestCandidatesPicksEarliestUnderCapacity

    [Fact]
    public void NearestCandidatesPicksEarliestUnderCapacity()
    {
        var records = Enumerable.Range(0, 10)
            .Select(offset => new ReminderRecord(Guid.NewGuid(), ReferenceNow.AddMinutes(offset), "at"))
            .ToList();
        var shuffled = records.OrderBy(_ => Guid.NewGuid()).ToList();

        var selected = ReminderScheduler.NearestCandidates(shuffled, Array.Empty<Guid>(), 3);

        Assert.Equal(3, selected.Count);
        Assert.Equal(records.Take(3).Select(r => r.FireAt), selected.Select(r => r.FireAt));
    }

    // Swift: testNearestCandidatesExcludesAlreadyRegistered

    [Fact]
    public void NearestCandidatesExcludesAlreadyRegistered()
    {
        var records = Enumerable.Range(0, 5)
            .Select(offset => new ReminderRecord(Guid.NewGuid(), ReferenceNow.AddMinutes(offset), "at"))
            .ToList();

        var selected = ReminderScheduler.NearestCandidates(
            records, new[] { records[0].Id, records[1].Id }, 10);

        Assert.Equal(3, selected.Count);
        Assert.DoesNotContain(selected, r => r.Id == records[0].Id || r.Id == records[1].Id);
    }

    // Swift: testNearestCandidatesRespectsZeroCapacity

    [Fact]
    public void NearestCandidatesRespectsZeroCapacity()
    {
        var record = new ReminderRecord(Guid.NewGuid(), ReferenceNow, "at");
        Assert.Empty(ReminderScheduler.NearestCandidates(new[] { record }, Array.Empty<Guid>(), 0));
    }

    // Swift: testNearestCandidatesSkipsNonScheduledStates

    [Fact]
    public void NearestCandidatesSkipsNonScheduledStates()
    {
        var scheduled = new ReminderRecord(Guid.NewGuid(), ReferenceNow, "at", state: "scheduled");
        var delivered = new ReminderRecord(Guid.NewGuid(), ReferenceNow.AddSeconds(-10), "at", state: "delivered");

        var selected = ReminderScheduler.NearestCandidates(new[] { scheduled, delivered }, Array.Empty<Guid>(), 10);

        Assert.Equal(new[] { scheduled.Id }, selected.Select(r => r.Id));
    }
}
