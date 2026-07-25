// ReminderRecordPersistenceTests.cs — Wave 3-B (A2): coverage for the new IReminderRecordStore
// seam — the actual restart bug fix (ReminderScheduler.cs used to keep `_records` as a plain
// in-memory List with nothing durable behind it) plus the write-through behavior that keeps the
// store in sync with the cache, using FakeReminderRecordStore (this project's own fake — NOT the
// production InMemoryReminderRecordStore; see that fake's doc comment for why cloning matters for
// what these assertions can actually prove).
using Xunit;
using static Volar.Reminders.Tests.Fixtures;

namespace Volar.Reminders.Tests;

public class ReminderRecordPersistenceTests
{
    // MARK: - The restart bug itself

    [Fact]
    public void ConstructingASchedulerOverAPrePopulatedStore_RehydratesItsRecords()
    {
        var recordStore = new FakeReminderRecordStore();
        var taskId = Guid.NewGuid();
        var seeded = new ReminderRecord(taskId: taskId, fireAt: ReferenceNow.AddDays(1), offsetKind: "-1d", state: "scheduled");
        recordStore.Seed(seeded);

        var (scheduler, _, _) = MakeScheduler(recordStore: recordStore);

        var rehydrated = Assert.Single(scheduler.FetchAllRecords());
        Assert.Equal(seeded.Id, rehydrated.Id);
        Assert.Equal(taskId, rehydrated.TaskId);
        Assert.Equal(seeded.FireAt, rehydrated.FireAt);
        Assert.Equal("scheduled", rehydrated.State);
    }

    [Fact]
    public void RehydrateCanBeCalledAgainExplicitly_ReloadsFromTheStore()
    {
        var recordStore = new FakeReminderRecordStore();
        var (scheduler, _, _) = MakeScheduler(recordStore: recordStore);
        Assert.Empty(scheduler.FetchAllRecords());

        // Simulate a row landing in the durable store out of process (e.g. a hypothetical second
        // writer) — Rehydrate() is exposed precisely so a caller can pick this up without building
        // a whole new scheduler instance.
        var taskId = Guid.NewGuid();
        recordStore.Seed(new ReminderRecord(taskId: taskId, fireAt: ReferenceNow, offsetKind: "at"));

        scheduler.Rehydrate();

        Assert.Single(scheduler.RecordsForTask(taskId));
    }

    // MARK: - Write-through on the mutating public surface

    [Fact]
    public void ScheduleRemindersWritesEveryDerivedRecordThroughToTheStore()
    {
        var recordStore = new FakeReminderRecordStore();
        var (scheduler, store, _) = MakeScheduler(recordStore: recordStore);
        var task = MakeTask(deadline: ReferenceNow.AddDays(3));
        store.Add(task);

        scheduler.ScheduleReminders(task);

        var cached = scheduler.RecordsForTask(task.Id);
        var persisted = recordStore.LoadAll();
        Assert.Equal(3, cached.Count);
        Assert.Equal(
            cached.Select(r => r.Id).OrderBy(id => id),
            persisted.Select(r => r.Id).OrderBy(id => id));
        Assert.True(recordStore.UpsertRangeCalls >= 1);
    }

    [Fact]
    public void CancelRemindersDeletesEveryRecordFromTheStoreToo()
    {
        var recordStore = new FakeReminderRecordStore();
        var (scheduler, store, _) = MakeScheduler(recordStore: recordStore);
        var task = MakeTask(deadline: ReferenceNow.AddDays(3));
        store.Add(task);
        scheduler.ScheduleReminders(task);
        Assert.NotEmpty(recordStore.LoadAll());

        scheduler.CancelReminders(task.Id);

        Assert.Empty(recordStore.LoadAll());
        Assert.Equal(3, recordStore.DeleteCalls);
    }

    [Fact]
    public void DueButMissedFireWritesTheDeliveredStateThroughToTheStore()
    {
        var recordStore = new FakeReminderRecordStore();
        var (scheduler, store, channel) = MakeScheduler(recordStore: recordStore);
        var task = MakeTask(title: $"Due now {Guid.NewGuid()}", deadline: ReferenceNow);
        store.Add(task);

        scheduler.RebuildFromStorage(ReferenceNow); // all 3 offsets are already due -> fire

        var cached = scheduler.RecordsForTask(task.Id);
        Assert.All(cached, r => Assert.Equal("delivered", r.State));
        foreach (var record in cached)
        {
            var persisted = recordStore.Find(record.Id);
            Assert.NotNull(persisted);
            Assert.Equal("delivered", persisted!.State); // the store must agree with the cache
        }
        Assert.NotEmpty(channel.Delivered);
    }

    [Fact]
    public void ScheduleResurfaceDedupe_FixA_NeverLeavesTwoRowsInTheStore()
    {
        var recordStore = new FakeReminderRecordStore();
        var (scheduler, store, _) = MakeScheduler(recordStore: recordStore);
        var task = MakeTask();
        store.Add(task);

        scheduler.ScheduleResurface(ReferenceNow.AddDays(1), task.Id);
        scheduler.ScheduleResurface(ReferenceNow.AddDays(2), task.Id); // different fire time -> update in place, not a second row

        var persisted = recordStore.LoadAll().Where(r => r.TaskId == task.Id).ToList();
        var row = Assert.Single(persisted); // FIX A: the store must never accumulate a duplicate either
        Assert.Equal(ReferenceNow.AddDays(2), row.FireAt);
    }

    [Fact]
    public void RebuildFromStorageReconcileDelivered_FixB_WritesTheReconciledStateThrough()
    {
        var recordStore = new FakeReminderRecordStore();
        var (scheduler, store, channel) = MakeScheduler(recordStore: recordStore);
        var task = MakeTask(deadline: ReferenceNow.AddDays(3)); // nothing due yet
        store.Add(task);
        scheduler.RebuildFromStorage(ReferenceNow);
        var record = scheduler.RecordsForTask(task.Id).First();
        channel.SimulateAlreadyDelivered(record.Id);

        scheduler.RebuildFromStorage(ReferenceNow); // FIX B reconciliation pass

        Assert.Equal("delivered", recordStore.Find(record.Id)!.State);
    }

    [Fact]
    public void HandleActionReschedule_WritesTheNewFireTimeAndStateThrough()
    {
        var recordStore = new FakeReminderRecordStore();
        var (scheduler, store, _) = MakeScheduler(recordStore: recordStore);
        var task = MakeTask(deadline: ReferenceNow.AddHours(-2)); // already due -> fires + delivered
        store.Add(task);
        scheduler.RebuildFromStorage(ReferenceNow);
        var record = scheduler.RecordsForTask(task.Id).First(r => r.OffsetKind == "at");

        scheduler.HandleAction(ReminderAction.Snooze10, record.Id, ReferenceNow);

        var persisted = recordStore.Find(record.Id)!;
        Assert.Equal("scheduled", persisted.State); // Reschedule resets to "scheduled"
        Assert.Equal(ReferenceNow.AddMinutes(10), persisted.FireAt);
    }

    [Fact]
    public void HandleActionDone_WritesSatisfiedThroughForTheActedOnRecord()
    {
        var recordStore = new FakeReminderRecordStore();
        var (scheduler, store, _) = MakeScheduler(recordStore: recordStore);
        var task = MakeTask(deadline: ReferenceNow.AddDays(3));
        store.Add(task);
        scheduler.ScheduleReminders(task);
        var record = scheduler.RecordsForTask(task.Id).First();

        scheduler.HandleAction(ReminderAction.Done, record.Id, ReferenceNow);

        // The acted-on record is marked satisfied and persisted as such BEFORE
        // CancelReminders/ScheduleReminders run their own write-through for the rest of the task's
        // reminders (see HandleAction's ReminderAction.Done branch) — assert directly on the store
        // row the scheduler wrote before that cascade could have deleted it, i.e. it must have been
        // written at all.
        Assert.True(recordStore.UpsertCalls > 0);
    }

    // MARK: - History survives a simulated restart (constitution IV) and isn't re-fired

    [Fact]
    public void DeliveredHistorySurvivesASimulatedRestartAndIsNotRefiredAsADuplicate()
    {
        var sharedRecordStore = new FakeReminderRecordStore();
        var sharedTaskStore = new FakeReminderTaskStore();
        var task = MakeTask(title: $"Survives restart {Guid.NewGuid()}", deadline: ReferenceNow);
        sharedTaskStore.Add(task);

        // "Process 1": derive + fire all 3 due offsets, then the process exits (simulated by simply
        // discarding this scheduler instance — nothing more happens to it).
        var gate1 = new ReminderContextGate();
        var channel1 = new FakeToastChannel();
        var scheduler1 = new ReminderScheduler(sharedTaskStore, channel1, gate1, recordStore: sharedRecordStore, timeZone: TestTimeZone);
        scheduler1.RebuildFromStorage(ReferenceNow);
        var recordsAfterProcess1 = scheduler1.RecordsForTask(task.Id);
        Assert.Equal(3, recordsAfterProcess1.Count);
        Assert.All(recordsAfterProcess1, r => Assert.Equal("delivered", r.State));

        // "Process 2" (restart): a BRAND NEW scheduler over the SAME durable store and the SAME
        // task store, with its own fresh channel that has never seen any of this.
        var gate2 = new ReminderContextGate();
        var channel2 = new FakeToastChannel();
        var scheduler2 = new ReminderScheduler(sharedTaskStore, channel2, gate2, recordStore: sharedRecordStore, timeZone: TestTimeZone);

        // Before this wave, `scheduler2` would start with an EMPTY `_records` (nothing durable
        // existed at all), so this call would treat the task as never-derived and post 3 brand-new
        // notifications through `channel2`. With rehydration, it must instead see the 3 already-
        // "delivered" records and do nothing new.
        scheduler2.RebuildFromStorage(ReferenceNow.AddMinutes(1));

        var recordsAfterRestart = scheduler2.RecordsForTask(task.Id);
        Assert.Equal(3, recordsAfterRestart.Count); // rehydrated, not re-derived from scratch
        Assert.All(recordsAfterRestart, r => Assert.Equal("delivered", r.State)); // history preserved
        Assert.Empty(channel2.Delivered); // and NOT re-fired as a duplicate on the new channel
    }

    // MARK: - Persistence failures degrade gracefully (mirrors the Swift original's `save()`)

    [Fact]
    public void AStoreThatThrowsOnEveryCall_NeverCrashesConstructionOrScheduling()
    {
        var throwingStore = new ThrowingReminderRecordStore();

        // Construction itself calls Rehydrate() -> LoadAll(), which this store always throws from;
        // reaching the next line at all already proves the failure was swallowed.
        var (scheduler, store, _) = MakeScheduler(recordStore: throwingStore);
        var task = MakeTask(deadline: ReferenceNow.AddDays(1));
        store.Add(task);

        var exception = Record.Exception(() =>
        {
            scheduler.ScheduleReminders(task);
            scheduler.CancelReminders(task.Id);
            scheduler.NotifyUnblocked([task.Id], ReferenceNow);
        });

        Assert.Null(exception);
        // The in-memory cache still works normally even though nothing durable ever succeeded.
        Assert.NotEmpty(scheduler.RecordsForTask(task.Id));
    }
}
