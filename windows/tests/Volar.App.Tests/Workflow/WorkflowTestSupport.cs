// Workflow/WorkflowTestSupport.cs — small shared test doubles for this folder's E/G/H/I/J service
// tests (FocusSessionService, ReminderAndDeliverySettingsService, TriageAndSweepService,
// DelegationOrchestratorService, AppearanceAndPersistenceService), mirroring the
// State/TestSupport.cs convention C2 already established. Deliberately does NOT duplicate
// FixedTimeProvider/RecordingEligibilityService/TestTasks/LocalFakeReminderTaskStore/
// LocalFakeToastChannel/LocalFixedOffsetRecurrenceResetter/SqliteFixture — those are `public`/
// `internal` types in `Volar.App.Tests.State` and this is the SAME test assembly, so this file's
// tests simply `using Volar.App.Tests.State;` and reuse them directly rather than forking a second
// copy.
using System.Linq;
using Volar.App.Services;
using Volar.Domain;
using TaskState = Volar.Core.TaskState;

namespace Volar.App.Tests.Workflow;

/// <summary>Lightweight in-memory <see cref="ITaskListService"/> fake for tests that don't need a
/// real repository behind them (no recurrence reset-in-place / parent-cascade behavior to exercise —
/// those live in <c>Volar.App.Tests.State.SqliteFixture</c>-backed tests instead, mirroring how
/// <c>TaskListServiceTests</c> itself splits the same way). <see cref="ActiveTask"/> is directly
/// test-settable rather than routed through the real <c>NextTaskSelector</c> integration — this
/// folder's services never read <see cref="ActiveTask"/> at all except
/// <c>DelegationOrchestratorService</c>'s doc comments reference it only for parity narration, so no
/// test here needs the real selection engine.</summary>
internal sealed class FakeTaskListService : ITaskListService
{
    private readonly List<TaskItem> _tasks;

    public FakeTaskListService(IEnumerable<TaskItem>? tasks = null)
    {
        _tasks = tasks is null ? new List<TaskItem>() : new List<TaskItem>(tasks);
    }

    public int RefreshCount { get; private set; }

    public TaskItem? ActiveTask { get; set; }

    public event Action? TasksChanged;

    public IReadOnlyList<TaskItem> Tasks => _tasks.ToList();

    public IReadOnlyList<TaskItem> NowTasks =>
        _tasks.Where(t => t.Status != TaskState.Done && t.When == When.Now).ToList();

    public IReadOnlyList<TaskItem> LaterTasks =>
        _tasks.Where(t => t.Status != TaskState.Done && t.When == When.Later).ToList();

    public IReadOnlyList<TaskItem> DoneTasks =>
        _tasks.Where(t => t.Status == TaskState.Done).ToList();

    public IReadOnlyList<TaskItem> OpenTasks => NowTasks.Concat(LaterTasks).ToList();

    public TaskItem? FrogTask =>
        _tasks.Where(t => t.Frog && t.Status != TaskState.Done).Select(t => (TaskItem?)t).FirstOrDefault();

    public Task RefreshAsync()
    {
        RefreshCount++;
        TasksChanged?.Invoke();
        return Task.CompletedTask;
    }

    public Task AddAsync(TaskItem task)
    {
        _tasks.Insert(0, task);
        TasksChanged?.Invoke();
        return Task.CompletedTask;
    }

    public Task ToggleDoneAsync(Guid id)
    {
        var index = _tasks.FindIndex(t => t.Id == id);
        if (index >= 0)
        {
            var item = _tasks[index];
            item.Status = item.Status == TaskState.Done ? TaskState.Todo : TaskState.Done;
            if (item.Status != TaskState.Done)
            {
                item.When = When.Later;
            }
            _tasks[index] = item;
        }
        TasksChanged?.Invoke();
        return Task.CompletedTask;
    }

    public Task DeleteAsync(Guid id)
    {
        _tasks.RemoveAll(t => t.Id == id);
        TasksChanged?.Invoke();
        return Task.CompletedTask;
    }

    public Task SetFrogAsync(Guid id)
    {
        for (var i = 0; i < _tasks.Count; i++)
        {
            var item = _tasks[i];
            item.Frog = item.Id == id;
            _tasks[i] = item;
        }
        TasksChanged?.Invoke();
        return Task.CompletedTask;
    }
}

/// <summary>Polling helper for the fire-and-forget async loops this folder's services use
/// (<c>FocusSessionService</c>'s tick loop) — same shape as
/// <c>Volar.App.Tests.Adapters.AppNotificationToastChannelTests.WaitUntil</c>, duplicated locally
/// per that file's own precedent (a small, self-contained helper, not worth cross-folder plumbing).</summary>
internal static class Poll
{
    public static void WaitUntil(Func<bool> condition, TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (!condition())
        {
            if (DateTime.UtcNow > deadline)
            {
                throw new TimeoutException("Condition was not met within the timeout.");
            }
            Thread.Sleep(5);
        }
    }
}
