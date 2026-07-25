// State/TaskListServiceTests.cs — TaskListService (inventory cluster A). Exercises the real
// TaskRepository (via SqliteFixture) for the store-backed paths so FIX 3's sibling trap
// (recurrence reset-in-place, parent-completion cascade) is genuinely covered — TaskRepository
// itself implements both, so a passing test here proves TaskListService reflects them rather than
// hand-patching around them.
using Volar.App.Services.State;
using Volar.Core;
using Volar.Data;
using Volar.Data.Entities;
using Volar.Domain;
using Volar.Reminders;
using Xunit;
using TaskState = Volar.Core.TaskState;

namespace Volar.App.Tests.State;

public sealed class TaskListServiceTests
{
    private static readonly DateTimeOffset Now = new(2026, 7, 25, 9, 0, 0, TimeSpan.Zero);

    // MARK: - Derived groupings

    [Fact]
    public async Task DerivedGroupings_ReflectStatusAndWhenBucket()
    {
        using var db = new SqliteFixture();
        var repository = db.CreateTaskRepository();
        var eligibility = new RecordingEligibilityService();
        var service = new TaskListService(eligibility, new FixedTimeProvider(Now), repository);

        var nowOpen = TestTasks.New(title: "now-open", when: When.Now);
        var laterOpen = TestTasks.New(title: "later-open", when: When.Later);
        var done = TestTasks.New(title: "done", when: When.Now, status: TaskState.Done);
        var frog = TestTasks.New(title: "frog", when: When.Now, frog: true);
        await repository.AddAsync(nowOpen.ToEntity());
        await repository.AddAsync(laterOpen.ToEntity());
        await repository.AddAsync(done.ToEntity());
        await repository.AddAsync(frog.ToEntity());

        await service.RefreshAsync();

        Assert.Equal(2, service.NowTasks.Count);
        Assert.Contains(service.NowTasks, t => t.Title == "now-open");
        Assert.Contains(service.NowTasks, t => t.Title == "frog");
        Assert.DoesNotContain(service.NowTasks, t => t.Title == "done");
        Assert.Single(service.LaterTasks);
        Assert.Equal("later-open", service.LaterTasks[0].Title);
        Assert.Single(service.DoneTasks);
        Assert.Equal("done", service.DoneTasks[0].Title);
        Assert.Equal(3, service.OpenTasks.Count); // now-open, frog, later-open — never the done one.
        Assert.NotNull(service.FrogTask);
        Assert.Equal("frog", service.FrogTask!.Value.Title);
    }

    [Fact]
    public async Task FrogTask_ExcludesADoneFrog()
    {
        using var db = new SqliteFixture();
        var repository = db.CreateTaskRepository();
        var service = new TaskListService(new RecordingEligibilityService(), new FixedTimeProvider(Now), repository);
        await repository.AddAsync(TestTasks.New(title: "done-frog", frog: true, status: TaskState.Done).ToEntity());

        await service.RefreshAsync();

        Assert.Null(service.FrogTask);
    }

    // MARK: - ActiveTask: recomputed per read, never cached

    [Fact]
    public async Task ActiveTask_RecomputesAfterAnyMutation_NeverCached()
    {
        using var db = new SqliteFixture();
        var repository = db.CreateTaskRepository();
        var service = new TaskListService(new RecordingEligibilityService(), new FixedTimeProvider(Now), repository);

        var high = TestTasks.New(title: "high-priority", priority: Priority.High, createdAt: Now.AddDays(-1));
        await repository.AddAsync(high.ToEntity());
        await service.RefreshAsync();

        Assert.Equal("high-priority", service.ActiveTask?.Title);

        await service.ToggleDoneAsync(high.Id); // completes the only eligible task.

        Assert.Null(service.ActiveTask); // re-read reflects the mutation with no separate invalidation step.

        var low = TestTasks.New(title: "low-priority", priority: Priority.Low, createdAt: Now);
        await service.AddAsync(low);

        Assert.Equal("low-priority", service.ActiveTask?.Title);
    }

    // MARK: - FIX 3 sibling trap: recurrence reset-in-place and parent cascade must be reflected,
    // never hand-patched around.

    [Fact]
    public async Task ToggleDoneAsync_RecurringTask_ReopensInPlaceWithResettersResult()
    {
        using var db = new SqliteFixture();
        var resetter = new LocalFixedOffsetRecurrenceResetter(TimeSpan.FromDays(1));
        var repository = db.CreateTaskRepository(resetter);
        var service = new TaskListService(new RecordingEligibilityService(), new FixedTimeProvider(Now), repository);

        var recurring = TestTasks.New(title: "daily standup", deadline: Now);
        await repository.AddAsync(recurring.ToEntity());
        await service.RefreshAsync();
        var recurringId = service.Tasks.Single().Id;
        await repository.SetRecurrenceAsync(recurringId, """{"kind":"daily"}""");

        await service.ToggleDoneAsync(recurringId);

        var reloaded = service.Tasks.Single(t => t.Id == recurringId);
        // A hand-patched "just flip Status to Done" would show Done here — the resetter's actual
        // result (reopened, deadline pushed by the resetter's fixed offset) proves TaskListService
        // reloaded from the repository instead.
        Assert.Equal(TaskState.Todo, reloaded.Status);
        Assert.Equal(Now.AddDays(1), reloaded.Deadline);
        Assert.Equal(1, resetter.CallCount);
    }

    [Fact]
    public async Task ToggleDoneAsync_LastOpenChild_CascadesParentToDoneToo()
    {
        using var db = new SqliteFixture();
        var repository = db.CreateTaskRepository();
        var service = new TaskListService(new RecordingEligibilityService(), new FixedTimeProvider(Now), repository);

        var parent = TestTasks.New(title: "parent");
        await repository.AddAsync(parent.ToEntity());
        await service.RefreshAsync();
        var parentId = service.Tasks.Single().Id;

        var child = TestTasks.New(title: "only child", parentId: parentId);
        await repository.AddAsync(child.ToEntity());
        await service.RefreshAsync();

        await service.ToggleDoneAsync(child.Id);

        // A hand-patched list would only flip `child`; the cascade closing `parent` too only shows
        // up if TaskListService reloaded the whole list from the repository.
        Assert.All(service.Tasks, t => Assert.Equal(TaskState.Done, t.Status));
    }

    [Fact]
    public async Task DeleteAsync_ClearsDependentsAndReloadsFromRepository()
    {
        using var db = new SqliteFixture();
        var repository = db.CreateTaskRepository();
        var service = new TaskListService(new RecordingEligibilityService(), new FixedTimeProvider(Now), repository);

        var blocker = TestTasks.New(title: "blocker");
        await repository.AddAsync(blocker.ToEntity());
        await service.RefreshAsync();
        var blockerId = service.Tasks.Single().Id;

        var dependent = TestTasks.New(title: "dependent", conditions: [new TaskDoneCondition(blockerId)]);
        await repository.AddAsync(dependent.ToEntity());
        await service.RefreshAsync();

        await service.DeleteAsync(blockerId);

        var remaining = service.Tasks.Single();
        Assert.Equal("dependent", remaining.Title);
        Assert.Empty(remaining.Conditions); // the taskDone condition referencing the deleted blocker was stripped.
    }

    // MARK: - Eligibility tail wiring

    [Fact]
    public async Task AddAsync_CallsEligibilityTailWithBeforeAndAfterSnapshots()
    {
        using var db = new SqliteFixture();
        var repository = db.CreateTaskRepository();
        var eligibility = new RecordingEligibilityService();
        var service = new TaskListService(eligibility, new FixedTimeProvider(Now), repository);
        var task = TestTasks.New(title: "new task");

        await service.AddAsync(task);

        Assert.Single(eligibility.Calls);
        Assert.Empty(eligibility.Calls[0].Before);
        Assert.Single(eligibility.Calls[0].After);
        Assert.Equal("new task", eligibility.Calls[0].After[0].Title);
    }

    [Fact]
    public async Task ToggleDoneAsync_CallsEligibilityTail()
    {
        using var db = new SqliteFixture();
        var repository = db.CreateTaskRepository();
        var eligibility = new RecordingEligibilityService();
        var service = new TaskListService(eligibility, new FixedTimeProvider(Now), repository);
        var task = TestTasks.New(title: "t");
        await repository.AddAsync(task.ToEntity());
        await service.RefreshAsync();

        await service.ToggleDoneAsync(task.Id);

        Assert.Single(eligibility.Calls);
    }

    [Fact]
    public async Task SetFrogAsync_NeverCallsTheEligibilityTail()
    {
        using var db = new SqliteFixture();
        var repository = db.CreateTaskRepository();
        var eligibility = new RecordingEligibilityService();
        var service = new TaskListService(eligibility, new FixedTimeProvider(Now), repository);
        var task = TestTasks.New(title: "t");
        await repository.AddAsync(task.ToEntity());
        await service.RefreshAsync();

        await service.SetFrogAsync(task.Id);

        Assert.Empty(eligibility.Calls);
        Assert.True(service.Tasks.Single().Frog);
    }

    // MARK: - Reminder scheduler wiring (real ReminderScheduler + local fakes)

    [Fact]
    public async Task AddAsync_SchedulesReminders_ForADatedTask()
    {
        using var db = new SqliteFixture();
        var repository = db.CreateTaskRepository();
        var reminderStore = new LocalFakeReminderTaskStore();
        var scheduler = new ReminderScheduler(reminderStore, new LocalFakeToastChannel(), new ReminderContextGate());
        var service = new TaskListService(new RecordingEligibilityService(), new FixedTimeProvider(Now), repository, scheduler);
        var dated = TestTasks.New(title: "dated", deadline: Now.AddHours(2));
        reminderStore.Set(dated); // ReminderScheduler.ScheduleReminders(Guid) resolves via the store, not the caller's copy.

        await service.AddAsync(dated);

        Assert.NotEmpty(scheduler.RecordsForTask(dated.Id));
    }

    [Fact]
    public async Task ToggleDoneAsync_CancelsReminders_WhenTaskBecomesDone()
    {
        using var db = new SqliteFixture();
        var repository = db.CreateTaskRepository();
        var dated = TestTasks.New(title: "dated", deadline: Now.AddHours(2));
        await repository.AddAsync(dated.ToEntity());

        var reminderStore = new LocalFakeReminderTaskStore();
        reminderStore.Set(dated);
        var scheduler = new ReminderScheduler(reminderStore, new LocalFakeToastChannel(), new ReminderContextGate());
        scheduler.ScheduleReminders(dated.Id);
        Assert.NotEmpty(scheduler.RecordsForTask(dated.Id));

        var service = new TaskListService(new RecordingEligibilityService(), new FixedTimeProvider(Now), repository, scheduler);
        await service.RefreshAsync();

        await service.ToggleDoneAsync(dated.Id);

        Assert.Empty(scheduler.RecordsForTask(dated.Id));
    }

    // MARK: - TasksChanged liveness

    [Fact]
    public async Task RefreshAsync_RaisesTasksChanged_EvenWhenNothingChanged()
    {
        var service = new TaskListService(new RecordingEligibilityService(), new FixedTimeProvider(Now));
        var raised = 0;
        service.TasksChanged += () => raised++;

        await service.RefreshAsync();

        Assert.Equal(1, raised);
    }

    [Fact]
    public async Task EveryMutation_RaisesTasksChangedExactlyOnce()
    {
        using var db = new SqliteFixture();
        var repository = db.CreateTaskRepository();
        var service = new TaskListService(new RecordingEligibilityService(), new FixedTimeProvider(Now), repository);
        var raised = 0;
        service.TasksChanged += () => raised++;
        var task = TestTasks.New(title: "t");

        await service.AddAsync(task);
        Assert.Equal(1, raised);

        await service.ToggleDoneAsync(task.Id);
        Assert.Equal(2, raised);

        await service.SetFrogAsync(task.Id);
        Assert.Equal(3, raised);

        await service.DeleteAsync(task.Id);
        Assert.Equal(4, raised);
    }

    // MARK: - Nullable-store degrade (previews/tests without a repository)

    [Fact]
    public async Task WithNoRepository_AddAsync_HandInsertsAndStillCallsEligibilityTail()
    {
        var eligibility = new RecordingEligibilityService();
        var service = new TaskListService(eligibility, new FixedTimeProvider(Now));
        var task = TestTasks.New(title: "in-memory only");

        await service.AddAsync(task);

        Assert.Single(service.Tasks);
        Assert.Single(eligibility.Calls); // Swift's addTask has no store-guard at all — always calls the tail.
    }

    [Fact]
    public async Task WithNoRepository_ToggleDoneAsync_FlipsInPlace_AndForcesLaterBucket_WithoutCallingEligibilityTail()
    {
        var eligibility = new RecordingEligibilityService();
        var task = TestTasks.New(title: "t", when: When.Now);
        var service = new TaskListService(eligibility, new FixedTimeProvider(Now), initialTasks: [task]);

        await service.ToggleDoneAsync(task.Id);

        var updated = service.Tasks.Single();
        Assert.True(updated.Done);
        Assert.Equal(When.Later, updated.When); // mirrors "completing always bumps to Later" (volar-mac.jsx toggleTask).
        Assert.Empty(eligibility.Calls);
    }

    [Fact]
    public async Task WithNoRepository_DeleteAsync_RemovesInPlace_WithoutCallingEligibilityTail()
    {
        var eligibility = new RecordingEligibilityService();
        var task = TestTasks.New(title: "t");
        var service = new TaskListService(eligibility, new FixedTimeProvider(Now), initialTasks: [task]);

        await service.DeleteAsync(task.Id);

        Assert.Empty(service.Tasks);
        Assert.Empty(eligibility.Calls);
    }

    [Fact]
    public async Task WithNoRepository_SetFrogAsync_ClearsFrogOnEveryOtherTask()
    {
        var first = TestTasks.New(title: "a", frog: true);
        var second = TestTasks.New(title: "b");
        var service = new TaskListService(new RecordingEligibilityService(), new FixedTimeProvider(Now), initialTasks: [first, second]);

        await service.SetFrogAsync(second.Id);

        Assert.False(service.Tasks.Single(t => t.Id == first.Id).Frog);
        Assert.True(service.Tasks.Single(t => t.Id == second.Id).Frog);
    }
}
