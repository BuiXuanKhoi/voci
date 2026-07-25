// Workflow/ReminderAndDeliverySettingsServiceTests.cs — ReminderAndDeliverySettingsService
// (inventory cluster G): the IReminderSettingsProvider seam ReminderScheduler actually reads,
// SetVoiceDeliveryMode/SetGlobalReminderPolicy persistence, and OfferRescheduleForOverdueTasks
// (FR-016, assigned here by the stage-1 review).
using Volar.App.Services.State;
using Volar.App.Tests.State;
using Volar.Domain;
using Volar.Reminders;
using Xunit;

namespace Volar.App.Tests.Workflow;

public sealed class ReminderAndDeliverySettingsServiceTests
{
    private static readonly DateTimeOffset Now = new(2026, 7, 25, 9, 0, 0, TimeSpan.Zero);

    // MARK: - Defaults (absent settings -> library defaults, never throws)

    [Fact]
    public void Constructor_WithNoPersistedSettings_UsesLibraryDefaults()
    {
        var service = new ReminderAndDeliverySettingsService(new InMemorySettingsStore(), new FakeTaskListService());

        Assert.Equal(VoiceDeliveryMode.VisualPlusVoice, service.CurrentVoiceDeliveryMode);
        Assert.Equal(ReminderPolicy.DefaultPolicy, service.CurrentGlobalReminderPolicy);
    }

    [Fact]
    public void Constructor_WithGarbagePersistedVoiceDeliveryMode_FallsBackToTheDefault_NeverThrows()
    {
        var settings = new InMemorySettingsStore();
        settings.SetString(ReminderAndDeliverySettingsService.VoiceDeliveryModeKey, "not-a-real-mode");

        var service = new ReminderAndDeliverySettingsService(settings, new FakeTaskListService());

        Assert.Equal(VoiceDeliveryMode.VisualPlusVoice, service.CurrentVoiceDeliveryMode);
    }

    [Fact]
    public void Constructor_WithGarbagePersistedReminderPolicyJson_FallsBackToTheDefault_NeverThrows()
    {
        var settings = new InMemorySettingsStore();
        settings.SetString(ReminderAndDeliverySettingsService.GlobalReminderPolicyKey, "{not json");

        var service = new ReminderAndDeliverySettingsService(settings, new FakeTaskListService());

        Assert.Equal(ReminderPolicy.DefaultPolicy, service.CurrentGlobalReminderPolicy);
    }

    // MARK: - Persistence round trips (through a SECOND instance sharing the same store — proves
    // this actually persists, not just an in-memory field).

    [Fact]
    public void SetVoiceDeliveryMode_PersistsAndRoundTripsThroughANewInstance()
    {
        var settings = new InMemorySettingsStore();
        var first = new ReminderAndDeliverySettingsService(settings, new FakeTaskListService());

        first.SetVoiceDeliveryMode(VoiceDeliveryMode.VoiceOnly);

        var second = new ReminderAndDeliverySettingsService(settings, new FakeTaskListService());
        Assert.Equal(VoiceDeliveryMode.VoiceOnly, second.CurrentVoiceDeliveryMode);
        Assert.Equal(VoiceDeliveryMode.VoiceOnly, second.VoiceDeliveryMode);
    }

    [Fact]
    public void SetGlobalReminderPolicy_PersistsAndRoundTripsThroughANewInstance()
    {
        var settings = new InMemorySettingsStore();
        var first = new ReminderAndDeliverySettingsService(settings, new FakeTaskListService());
        var policy = new ReminderPolicy(
            new[] { TimeSpan.FromHours(-2), TimeSpan.FromMinutes(-15) },
            TimeSpan.FromMinutes(30));

        first.SetGlobalReminderPolicy(policy);

        var second = new ReminderAndDeliverySettingsService(settings, new FakeTaskListService());
        Assert.Equal(policy.Offsets, second.CurrentGlobalReminderPolicy.Offsets);
        Assert.Equal(policy.RepeatEvery, second.CurrentGlobalReminderPolicy.RepeatEvery);
    }

    [Fact]
    public void SetGlobalReminderPolicy_WithNoRepeatEvery_RoundTripsANullRepeatInterval()
    {
        var settings = new InMemorySettingsStore();
        var first = new ReminderAndDeliverySettingsService(settings, new FakeTaskListService());
        var policy = new ReminderPolicy(new[] { TimeSpan.FromDays(-1) }, null);

        first.SetGlobalReminderPolicy(policy);

        var second = new ReminderAndDeliverySettingsService(settings, new FakeTaskListService());
        Assert.Null(second.CurrentGlobalReminderPolicy.RepeatEvery);
    }

    // MARK: - OfferRescheduleForOverdueTasks (FR-016)

    [Fact]
    public void OfferRescheduleForOverdueTasks_WithNoScheduler_NeverThrows()
    {
        var taskList = new FakeTaskListService(new[] { TestTasks.New(title: "overdue", deadline: Now.AddDays(-1)) });
        var service = new ReminderAndDeliverySettingsService(new InMemorySettingsStore(), taskList);

        service.OfferRescheduleForOverdueTasks(Now);
    }

    [Fact]
    public void OfferRescheduleForOverdueTasks_SkipsATaskThatIsNotYetOverdue()
    {
        var futureTask = TestTasks.New(title: "future", deadline: Now.AddDays(1));
        var reminderStore = new LocalFakeReminderTaskStore();
        reminderStore.Set(futureTask);
        var scheduler = new ReminderScheduler(reminderStore, new LocalFakeToastChannel(), new ReminderContextGate());
        var taskList = new FakeTaskListService(new[] { futureTask });
        var service = new ReminderAndDeliverySettingsService(new InMemorySettingsStore(), taskList, scheduler);

        service.OfferRescheduleForOverdueTasks(Now);

        Assert.Empty(scheduler.RecordsForTask(futureTask.Id));
    }

    [Fact]
    public void OfferRescheduleForOverdueTasks_OverdueOpenTaskWithNoOutstandingRecord_OffersOneReschedule()
    {
        var overdueTask = TestTasks.New(title: "overdue", deadline: Now.AddDays(-1));
        var reminderStore = new LocalFakeReminderTaskStore();
        reminderStore.Set(overdueTask);
        var scheduler = new ReminderScheduler(reminderStore, new LocalFakeToastChannel(), new ReminderContextGate());
        var taskList = new FakeTaskListService(new[] { overdueTask });
        var service = new ReminderAndDeliverySettingsService(new InMemorySettingsStore(), taskList, scheduler);

        service.OfferRescheduleForOverdueTasks(Now);

        var records = scheduler.RecordsForTask(overdueTask.Id);
        Assert.Contains(records, r => r.OffsetKind == "resurface");
    }

    [Fact]
    public void OfferRescheduleForOverdueTasks_CalledTwice_NeverDuplicatesAnOutstandingOffer()
    {
        var overdueTask = TestTasks.New(title: "overdue", deadline: Now.AddDays(-1));
        var reminderStore = new LocalFakeReminderTaskStore();
        reminderStore.Set(overdueTask);
        var scheduler = new ReminderScheduler(reminderStore, new LocalFakeToastChannel(), new ReminderContextGate());
        var taskList = new FakeTaskListService(new[] { overdueTask });
        var service = new ReminderAndDeliverySettingsService(new InMemorySettingsStore(), taskList, scheduler);

        service.OfferRescheduleForOverdueTasks(Now);
        var afterFirst = scheduler.RecordsForTask(overdueTask.Id).Count;
        service.OfferRescheduleForOverdueTasks(Now.AddMinutes(1));
        var afterSecond = scheduler.RecordsForTask(overdueTask.Id).Count;

        Assert.Equal(afterFirst, afterSecond);
    }

    [Fact]
    public void OfferRescheduleForOverdueTasks_SkipsADoneTask_EvenIfPastItsDeadline()
    {
        var doneTask = TestTasks.New(title: "done", deadline: Now.AddDays(-1), status: Volar.Core.TaskState.Done);
        var reminderStore = new LocalFakeReminderTaskStore();
        reminderStore.Set(doneTask);
        var scheduler = new ReminderScheduler(reminderStore, new LocalFakeToastChannel(), new ReminderContextGate());
        // A done task never appears in `ITaskListService.OpenTasks` in the first place — the fake
        // task list here mirrors that by simply not including it, matching what the real
        // TaskListService would report.
        var taskList = new FakeTaskListService();
        var service = new ReminderAndDeliverySettingsService(new InMemorySettingsStore(), taskList, scheduler);

        service.OfferRescheduleForOverdueTasks(Now);

        Assert.Empty(scheduler.RecordsForTask(doneTask.Id));
    }
}
