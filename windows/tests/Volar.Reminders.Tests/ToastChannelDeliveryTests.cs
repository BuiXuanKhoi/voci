// ToastChannelDeliveryTests.cs — NEW (not in the Swift original; required by this task's brief:
// "an IToastChannel-delivery test using a fake channel"). Asserts on the exact content
// ReminderScheduler hands to IToastChannel — banner text, category routing, and
// spoken/not-spoken decisions — using FakeToastChannel (Volar.Reminders.Tests-only, in-memory).
using Xunit;
using static Volar.Reminders.Tests.Fixtures;

namespace Volar.Reminders.Tests;

public class ToastChannelDeliveryTests
{
    [Fact]
    public void NotifyUnblockedDeliversImmediatelyUnderTheUnblockedCategoryWithNoSpokenText()
    {
        var (scheduler, store, channel) = MakeScheduler();
        var task = MakeTask(title: $"Unblocked task {Guid.NewGuid()}");
        store.Add(task);

        scheduler.NotifyUnblocked(new[] { task.Id }, ReferenceNow);

        var delivery = Assert.Single(channel.Delivered);
        Assert.Equal(task.Id, delivery.TaskId);
        Assert.Equal("Volar", delivery.BannerTitle);
        Assert.Contains(task.Title, delivery.BannerBody);
        Assert.Equal(ReminderCategory.UnblockedReady, delivery.CategoryId);
        // "unblocked" is not a high-urgency offset kind and there's no prior unacknowledged
        // delivery for this brand-new task, so nothing should be spoken.
        Assert.Null(delivery.SpokenText);
    }

    [Fact]
    public void OfferRescheduleDeliversUnderTheOverdueRescheduleCategory()
    {
        var (scheduler, store, channel) = MakeScheduler();
        var task = MakeTask(title: $"Overdue task {Guid.NewGuid()}");
        store.Add(task);

        scheduler.OfferReschedule(task.Id, ReferenceNow);

        var delivery = Assert.Single(channel.Delivered);
        Assert.Equal(ReminderCategory.OverdueReschedule, delivery.CategoryId);
    }

    [Fact]
    public void DueDeadlineFireSpeaksBecauseAtOffsetIsHighUrgencyAndNothingSuppresses()
    {
        var (scheduler, store, channel) = MakeScheduler();
        // Deadline exactly now: derivation immediately marks the "at" offset high-urgency, and it's
        // already due, so RebuildFromStorage's due-but-missed pass fires it straight away.
        var task = MakeTask(title: $"Due now task {Guid.NewGuid()}", deadline: ReferenceNow);
        store.Add(task);

        scheduler.RebuildFromStorage(ReferenceNow);

        var atDelivery = channel.Delivered.Single(d => d.CategoryId == ReminderCategory.Deadline
            && d.BannerBody.Contains("due now"));
        Assert.NotNull(atDelivery.SpokenText);
        Assert.Equal($"{task.Title}, due now.", atDelivery.SpokenText);
        Assert.Contains(atDelivery.SpokenText, channel.Spoken);
    }

    [Fact]
    public void SensitiveTaskSpeaksAGenericPhraseNeverTheTaskTitle()
    {
        var (scheduler, store, channel) = MakeScheduler();
        var task = MakeTask(title: "Secret medical appointment", deadline: ReferenceNow);
        store.Add(task);
        store.MarkSensitive(task.Id);

        scheduler.RebuildFromStorage(ReferenceNow);

        var atDelivery = channel.Delivered.Single(d => d.BannerBody.Contains("due now"));
        Assert.Equal("You have a reminder due now.", atDelivery.SpokenText);
        Assert.DoesNotContain(channel.Spoken, s => s.Contains(task.Title));
        // The visual banner is unaffected by sensitivity — only speech is redacted.
        Assert.Contains(task.Title, atDelivery.BannerBody);
    }

    [Fact]
    public void RebuildFromStorageReconcilesAnAlreadyDeliveredNotificationInsteadOfRefiringIt()
    {
        var (scheduler, store, channel) = MakeScheduler();
        var deadline = ReferenceNow.AddDays(3); // nothing due yet
        var task = MakeTask(deadline: deadline);
        store.Add(task);
        scheduler.RebuildFromStorage(ReferenceNow); // derives 3 "scheduled" records

        var record = scheduler.RecordsForTask(task.Id).First();
        // Simulate the OS having already shown this one (e.g. delivered while the app was dead) —
        // FIX B's reconciliation pass should mark it "delivered" rather than let the due-but-missed
        // pass re-fire it as a duplicate on a later rebuild.
        channel.SimulateAlreadyDelivered(record.Id);
        var deliveredCountBefore = channel.Delivered.Count;

        scheduler.RebuildFromStorage(ReferenceNow);

        Assert.Equal("delivered", scheduler.FetchRecord(record.Id)!.State);
        // Reconciliation must NOT have gone through DeliverNow a second time for this record.
        Assert.Equal(deliveredCountBefore, channel.Delivered.Count);
    }

    [Fact]
    public void RefillSchedulesTheNearestRecordsWithTheChannelAfterDeriving()
    {
        var (scheduler, store, channel) = MakeScheduler();
        var deadline = ReferenceNow.AddDays(3);
        var task = MakeTask(deadline: deadline);
        store.Add(task);

        scheduler.ScheduleReminders(task);

        // All 3 derived offsets are still in the future ("scheduled"), so the refill pass should
        // have registered all of them with the channel's scheduled queue.
        Assert.Equal(3, channel.Scheduled.Count);
        Assert.All(channel.Scheduled, s => Assert.Equal(task.Id, s.Delivery.TaskId));
    }

    [Fact]
    public void CancelRemindersCancelsPendingChannelRegistrations()
    {
        var (scheduler, store, channel) = MakeScheduler();
        var task = MakeTask(deadline: ReferenceNow.AddDays(3));
        store.Add(task);
        scheduler.ScheduleReminders(task);
        Assert.NotEmpty(channel.Scheduled);

        scheduler.CancelReminders(task.Id);

        Assert.Empty(scheduler.RecordsForTask(task.Id));
        Assert.Empty(channel.GetPendingIds());
    }
}
