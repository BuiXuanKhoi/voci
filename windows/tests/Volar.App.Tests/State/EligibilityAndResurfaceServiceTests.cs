// State/EligibilityAndResurfaceServiceTests.cs — EligibilityAndResurfaceService (inventory cluster
// D, FIX 2). Uses a real ReminderScheduler (+ local fakes) to assert on durable resurface
// registration, and a short real delay (milliseconds, via FixedTimeProvider driving the "now" the
// service reasons about while a genuine — but tiny — Task.Delay elapses) to exercise FIX 2(b)'s
// wake-chaining without making the test suite slow.
using Volar.App.Services.State;
using Volar.Core;
using Volar.Domain;
using Volar.Reminders;
using Xunit;

namespace Volar.App.Tests.State;

public sealed class EligibilityAndResurfaceServiceTests
{
    private static readonly DateTimeOffset Now = new(2026, 7, 25, 9, 0, 0, TimeSpan.Zero);

    // MARK: - NotifyEligibilityAndScheduleResurfaceAsync: eligibility diff -> NotifyUnblocked

    [Fact]
    public async Task NotifyEligibilityAndScheduleResurfaceAsync_NotifiesOnlyNewlyEligibleTasks()
    {
        var reminderStore = new LocalFakeReminderTaskStore();
        var scheduler = new ReminderScheduler(reminderStore, new LocalFakeToastChannel(), new ReminderContextGate());
        var service = new EligibilityAndResurfaceService(new FixedTimeProvider(Now), scheduler);

        var blockerId = Guid.NewGuid();
        var dependent = TestTasks.New(title: "dependent", conditions: [new TaskDoneCondition(blockerId)]);
        var before = new List<TaskItem> { dependent };
        var after = new List<TaskItem>
        {
            new(dependent.Id, dependent.Title, dependent.Priority, dependent.When, dependent.CreatedAt,
                conditions: [new TaskDoneCondition(blockerId)]), // still blocked in `after` too
        };

        await service.NotifyEligibilityAndScheduleResurfaceAsync(before, after);

        Assert.Empty(scheduler.RecordsForTask(dependent.Id)); // never unblocked -> never notified.
    }

    [Fact]
    public async Task NotifyEligibilityAndScheduleResurfaceAsync_NotifiesATaskThatBecameEligible()
    {
        var reminderStore = new LocalFakeReminderTaskStore();
        var scheduler = new ReminderScheduler(reminderStore, new LocalFakeToastChannel(), new ReminderContextGate());
        var service = new EligibilityAndResurfaceService(new FixedTimeProvider(Now), scheduler);

        var dependentId = Guid.NewGuid();
        var blockerId = Guid.NewGuid();
        var beforeDependent = new TaskItem(dependentId, "dependent", Priority.Medium, When.Now, Now,
            conditions: [new TaskDoneCondition(blockerId)]);
        var afterDependent = new TaskItem(dependentId, "dependent", Priority.Medium, When.Now, Now,
            conditions: [new TaskDoneCondition(blockerId)], status: TaskState.Todo);
        var afterBlocker = new TaskItem(blockerId, "blocker", Priority.Medium, When.Now, Now, status: TaskState.Done);

        reminderStore.Set(afterDependent); // ReminderScheduler.NotifyUnblocked -> HandleFire resolves via the store.

        await service.NotifyEligibilityAndScheduleResurfaceAsync(
            before: [beforeDependent, new TaskItem(blockerId, "blocker", Priority.Medium, When.Now, Now)],
            after: [afterDependent, afterBlocker]);

        Assert.NotEmpty(scheduler.RecordsForTask(dependentId));
        Assert.Contains(scheduler.RecordsForTask(dependentId), r => r.OffsetKind == "unblocked");
    }

    // MARK: - FIX 2(a): every task's own earliest future afterDate is registered, not just the
    // single global-earliest one.

    [Fact]
    public async Task NotifyEligibilityAndScheduleResurfaceAsync_RegistersEveryTasksOwnEarliestAfterDate()
    {
        var reminderStore = new LocalFakeReminderTaskStore();
        var scheduler = new ReminderScheduler(reminderStore, new LocalFakeToastChannel(), new ReminderContextGate());
        var service = new EligibilityAndResurfaceService(new FixedTimeProvider(Now), scheduler);

        var soon = TestTasks.New(title: "soon", conditions: [new AfterDateCondition(Now.AddHours(1))]);
        var later = TestTasks.New(title: "later", conditions: [new AfterDateCondition(Now.AddDays(30))]);

        await service.NotifyEligibilityAndScheduleResurfaceAsync(before: [], after: [soon, later]);

        // Both get their OWN resurface record — a naive "only the global earliest" port would leave
        // `later` completely unregistered.
        Assert.Contains(scheduler.RecordsForTask(soon.Id), r => r.OffsetKind == "resurface");
        Assert.Contains(scheduler.RecordsForTask(later.Id), r => r.OffsetKind == "resurface");
        Assert.Equal(Now.AddHours(1), scheduler.RecordsForTask(soon.Id).Single(r => r.OffsetKind == "resurface").FireAt);
        Assert.Equal(Now.AddDays(30), scheduler.RecordsForTask(later.Id).Single(r => r.OffsetKind == "resurface").FireAt);
    }

    [Fact]
    public async Task ArmResurface_IgnoresConditionsNotStrictlyInTheFuture()
    {
        var reminderStore = new LocalFakeReminderTaskStore();
        var scheduler = new ReminderScheduler(reminderStore, new LocalFakeToastChannel(), new ReminderContextGate());
        var service = new EligibilityAndResurfaceService(new FixedTimeProvider(Now), scheduler);

        var alreadyDue = TestTasks.New(title: "already due", conditions: [new AfterDateCondition(Now)]);

        await service.NotifyEligibilityAndScheduleResurfaceAsync(before: [], after: [alreadyDue]);

        Assert.DoesNotContain(scheduler.RecordsForTask(alreadyDue.Id), r => r.OffsetKind == "resurface");
    }

    [Fact]
    public async Task ArmResurface_PicksEachTasksEarliestCondition_NotItsFirst()
    {
        var reminderStore = new LocalFakeReminderTaskStore();
        var scheduler = new ReminderScheduler(reminderStore, new LocalFakeToastChannel(), new ReminderContextGate());
        var service = new EligibilityAndResurfaceService(new FixedTimeProvider(Now), scheduler);

        var task = TestTasks.New(
            title: "multi-condition",
            conditions:
            [
                new AfterDateCondition(Now.AddDays(10)),
                new AfterDateCondition(Now.AddHours(1)), // earliest, listed second on purpose
                new AfterDateCondition(Now.AddDays(5)),
            ]);

        await service.NotifyEligibilityAndScheduleResurfaceAsync(before: [], after: [task]);

        Assert.Equal(Now.AddHours(1), scheduler.RecordsForTask(task.Id).Single(r => r.OffsetKind == "resurface").FireAt);
    }

    // MARK: - RearmAsync: idempotent, degrades gracefully with no TaskList attached

    [Fact]
    public async Task RearmAsync_WithNoTaskListAttached_DoesNotThrow()
    {
        var service = new EligibilityAndResurfaceService(new FixedTimeProvider(Now));
        await service.RearmAsync(); // must not throw — TaskList is null (composition root hasn't wired it).
    }

    [Fact]
    public async Task RearmAsync_CalledTwice_ReArmsWithoutDuplicatingDurableRecords()
    {
        var reminderStore = new LocalFakeReminderTaskStore();
        var scheduler = new ReminderScheduler(reminderStore, new LocalFakeToastChannel(), new ReminderContextGate());
        var clock = new FixedTimeProvider(Now);
        var service = new EligibilityAndResurfaceService(clock, scheduler);
        var task = TestTasks.New(title: "t", conditions: [new AfterDateCondition(Now.AddDays(1))]);
        var eligibility = new RecordingEligibilityService();
        var taskList = new TaskListService(eligibility, clock, initialTasks: [task]);
        service.TaskList = taskList;

        await service.RearmAsync();
        await service.RearmAsync(); // FIX 2(c): must be safe to call twice.

        // ReminderScheduler.ScheduleResurface itself dedupes same-fire-time rows per task (see that
        // method's own doc comment) — asserting exactly one row proves the second RearmAsync call
        // didn't pile up a duplicate.
        Assert.Single(scheduler.RecordsForTask(task.Id), r => r.OffsetKind == "resurface");
    }

    // MARK: - FIX 2(b): chains forward on wake instead of firing once and going dormant.

    [Fact]
    public async Task ArmedWake_RefreshesTaskListAndReArmsForTheNextAfterDate()
    {
        var reminderStore = new LocalFakeReminderTaskStore();
        var scheduler = new ReminderScheduler(reminderStore, new LocalFakeToastChannel(), new ReminderContextGate());
        var clock = new FixedTimeProvider(Now);
        var service = new EligibilityAndResurfaceService(clock, scheduler);

        // Two tasks: the first's afterDate is a few milliseconds away (so the local wake actually
        // fires during this test), the second's is far in the future — proving the wake-continuation
        // re-arms the SECOND task's date after the first one passes, rather than going dormant.
        var soon = TestTasks.New(title: "soon", conditions: [new AfterDateCondition(Now.AddMilliseconds(30))]);
        var farFuture = TestTasks.New(title: "far-future", conditions: [new AfterDateCondition(Now.AddDays(10))]);
        var eligibility = new RecordingEligibilityService();
        var taskList = new TaskListService(eligibility, clock, initialTasks: [soon, farFuture]);
        service.TaskList = taskList;

        await service.NotifyEligibilityAndScheduleResurfaceAsync(before: [], after: taskList.Tasks);

        // Advance the injected clock so, once the wake fires, `soon`'s condition reads as already
        // satisfied (matching real elapsed time) and only `farFuture`'s remains a future candidate.
        clock.Now = Now.AddMilliseconds(30);

        // Give the fire-and-forget wake (armed for ~30ms of real wall-clock Task.Delay) time to run.
        await Task.Delay(500);

        Assert.NotEmpty(scheduler.RecordsForTask(farFuture.Id));
        // The wake's own re-arm call reads through TaskListService, not a cached copy — this is the
        // one assertion that would fail if the chain re-armed against a stale snapshot instead.
        var record = scheduler.RecordsForTask(farFuture.Id).Single(r => r.OffsetKind == "resurface");
        Assert.Equal(Now.AddDays(10), record.FireAt);
    }

    [Fact]
    public async Task ArmedWake_WithNoTaskListAttached_DoesNotThrow()
    {
        var reminderStore = new LocalFakeReminderTaskStore();
        var scheduler = new ReminderScheduler(reminderStore, new LocalFakeToastChannel(), new ReminderContextGate());
        var service = new EligibilityAndResurfaceService(new FixedTimeProvider(Now), scheduler);
        var task = TestTasks.New(title: "t", conditions: [new AfterDateCondition(Now.AddMilliseconds(20))]);

        await service.NotifyEligibilityAndScheduleResurfaceAsync(before: [], after: [task]);

        // No TaskList was ever attached — the wake must degrade to a no-op, never throw into the
        // fire-and-forget continuation (an unobserved exception there would crash the process).
        await Task.Delay(300);
    }

    // MARK: - Superseded-wake guard (resurfaceSession)

    [Fact]
    public async Task ASupersededWake_NeverFires_OnceALaterMutationRearmsAgainstADifferentSnapshot()
    {
        var reminderStore = new LocalFakeReminderTaskStore();
        var scheduler = new ReminderScheduler(reminderStore, new LocalFakeToastChannel(), new ReminderContextGate());
        var clock = new FixedTimeProvider(Now);
        var service = new EligibilityAndResurfaceService(clock, scheduler);

        var task = TestTasks.New(title: "t", conditions: [new AfterDateCondition(Now.AddMilliseconds(30))]);
        var eligibility = new RecordingEligibilityService();
        var taskListA = new TaskListService(eligibility, clock, initialTasks: [task]);
        service.TaskList = taskListA;
        await service.NotifyEligibilityAndScheduleResurfaceAsync(before: [], after: [task]); // arms session N, ~30ms wake.

        // Swap in a second, empty TaskListService BEFORE re-arming — RearmAsync's re-scan then finds
        // no candidate at all (nothing further gets armed), isolating the assertion to exactly one
        // question: did the FIRST (now superseded) wake ever act on `taskListA`?
        var taskListB = new TaskListService(new RecordingEligibilityService(), clock, initialTasks: []);
        service.TaskList = taskListB;
        await service.RearmAsync(); // arms session N+1 — invalidates the pending ~30ms wake from session N.

        var refreshesOnA = 0;
        taskListA.TasksChanged += () => refreshesOnA++;

        await Task.Delay(300); // comfortably longer than the superseded wake's ~30ms delay.

        // The superseded wake's session guard must have short-circuited it before it ever called
        // `taskListA.RefreshAsync()` (which would have raised this event).
        Assert.Equal(0, refreshesOnA);
    }
}
