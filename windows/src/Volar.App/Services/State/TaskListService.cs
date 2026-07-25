// Services/State/TaskListService.cs — port of AppState.swift's derived task groupings (§1.9,
// 520-538) and task CRUD (§1.10, 542-648): `tasks`, `nowTasks`/`laterTasks`/`doneTasks`/`openTasks`/
// `frogTask`/`activeTask`, `addTask`/`toggleDone`/`deleteTask`/`refreshFromStore`, plus `setFrog`
// (1742-1751, listed under "Appearance/frog" in the Swift file but owned by cluster A per
// wave3c-services.md's contract — it is exactly the same "mutate store -> reload -> notify" shape
// as every other CRUD method here). This is inventory cluster A and, per Opus decision 5, THE
// single owner of task state in the whole app: every other Wave 3-C service holds a reference to
// <see cref="ITaskListService"/> and reads through it — nobody else caches a second `TaskItem`
// collection.
//
// FIX 3's "sibling trap" (this task's hard constraints, MAJOR bug #2 in the 2026-07-16 review):
// after ANY store-backed mutation, this class re-reads the full task list from
// <see cref="TaskRepository.GetAllAsync"/> rather than hand-patching `_tasks` in place. Recurrence
// resets in place (a completed recurring task reopens with a fresh deadline/conditions,
// TaskRepository.CompleteOne) and parent-completion cascades (closing the last open child can also
// close its parent, TaskRepository.CompleteCascadingAsync) — a hand-patched list cannot reproduce
// either without duplicating TaskRepository's own logic, and would silently drift out of sync the
// moment it did. <see cref="ActiveTask"/> is recomputed fresh on every read for the same reason —
// see that property's doc comment.
//
// BEHAVIOR NOTE (self-review "behaviour drift", flagged deliberately): Swift's `addTask` is the one
// mutation that does NOT re-read from the store afterward (`AppState.swift:542-550` — it hand-inserts
// at index 0 and never calls `store.fetchAll()`), because adding a brand-new task cannot retroactively
// change any OTHER task's cascade/recurrence state. This port applies the "mutate -> reload -> notify"
// pattern to `AddAsync` too, for two reasons that make it strictly more correct rather than just
// different: (1) `TaskRepository.AddAsync` can silently DROP an invalid `.taskDone` condition
// (`SanitizeConditions`) before persisting, so the caller's in-memory `TaskItem` can differ from what
// was actually written — a hand-patch would show the caller's (wrong) unsanitized conditions;
// (2) it keeps every mutation method in this file structurally identical, which is easier to audit
// than "every method reloads except this one." The cost is one extra `GetAllAsync` round trip per
// add, which is not on any hot path here.
//
// NULLABLE-STORE DEGRADE: mirrors the six `guard let store else { <in-memory fallback> } ` sites in
// AppState.swift — this class implements the four of those six that belong to cluster A
// (`toggleDone`, `deleteTask`, `refreshFromStore`, `setFrog`; `clearExternalCondition`/`triageDefer`
// belong to Wave 3-C's stage-2 clusters C/H). A <see langword="null"/> <see cref="TaskRepository"/>
// degrades every mutation to an in-memory-only edit of `_tasks`, matching Swift's preview/test
// fallback exactly.
using Volar.Core;
using Volar.Data;
using Volar.Data.Entities;
using Volar.Domain;
using Volar.Reminders;

namespace Volar.App.Services.State;

public sealed class TaskListService : ITaskListService
{
    private readonly TaskRepository? _repository;
    private readonly IEligibilityAndResurfaceService _eligibility;
    private readonly ReminderScheduler? _scheduler;
    private readonly ITimeProvider _clock;
    private readonly TimeZoneInfo _timeZone;
    private readonly object _gate = new();
    private List<TaskItem> _tasks;

    /// <param name="eligibility">Cluster D's shared mutation tail — called after every real
    /// mutation (not <see cref="SetFrogAsync"/>, which Swift's own `setFrog` never routes through it
    /// either; frog assignment cannot change any task's eligibility).</param>
    /// <param name="clock">Wave-wide rule: no service reads <see cref="DateTimeOffset.Now"/>/
    /// <see cref="DateTimeOffset.UtcNow"/> directly.</param>
    /// <param name="repository">Nullable per this class's header comment — <see langword="null"/>
    /// degrades every mutation to an in-memory-only edit (previews/tests without a database).</param>
    /// <param name="scheduler">Nullable — the reminder side-effects inside Add/Toggle/Delete become
    /// no-ops without one, matching every other `scheduler?.` call site in the Swift original.</param>
    /// <param name="timeZone">Explicit injected zone for <see cref="ActiveTask"/>'s
    /// <see cref="NextTaskSelector.NextTask"/> call and for <see cref="TaskRepository.ToggleAsync"/>'s
    /// recurrence-reset calendar math — never defaults to <see cref="TimeZoneInfo.Local"/> implicitly
    /// (matches <see cref="TaskRepository.ToggleAsync"/>'s own documented convention); pass
    /// <see langword="null"/> only from a test or a caller that deliberately wants UTC-calendar
    /// semantics. The real app (C5) should pass <see cref="TimeZoneInfo.Local"/> explicitly, matching
    /// how <c>ReminderScheduler</c> is already registered in <c>CompositionRoot</c>.</param>
    /// <param name="initialTasks">Constructor-supplied seed, mirroring Swift's `init(tasks:)`
    /// parameter — used only when <paramref name="repository"/> is <see langword="null"/> (a real
    /// launch instead calls <see cref="RefreshAsync"/> once, mirroring `store?.loadOrSeed()`).</param>
    public TaskListService(
        IEligibilityAndResurfaceService eligibility,
        ITimeProvider clock,
        TaskRepository? repository = null,
        ReminderScheduler? scheduler = null,
        TimeZoneInfo? timeZone = null,
        IReadOnlyList<TaskItem>? initialTasks = null)
    {
        _eligibility = eligibility ?? throw new ArgumentNullException(nameof(eligibility));
        _clock = clock ?? throw new ArgumentNullException(nameof(clock));
        _repository = repository;
        _scheduler = scheduler;
        _timeZone = timeZone ?? TimeZoneInfo.Utc;
        _tasks = initialTasks is null ? new List<TaskItem>() : new List<TaskItem>(initialTasks);
    }

    /// <inheritdoc/>
    /// <remarks>
    /// DEVIATION FLAGGED (self-review "conflict"/"determinism"): the interface doc comment says
    /// "on the UI thread." This class does no thread marshaling of its own — it is a plain
    /// C#/no-WinUI-type service so it stays trivially unit-testable outside any UI dispatcher. The
    /// event fires synchronously from whichever thread's `async` continuation resumes the calling
    /// mutation, which is the UI thread as long as callers invoke this interface's methods from the
    /// UI thread (the normal WinUI `SynchronizationContext`-capture behavior every `await` already
    /// relies on) — C5 must ensure hotkey/hosted-service callbacks that call into this interface are
    /// already marshaled onto the UI thread before doing so, exactly as WinUI/UWP code elsewhere in
    /// this app must already do for XAML-bound state. See this task's final report, "handoff."
    /// </remarks>
    public event Action? TasksChanged;

    public IReadOnlyList<TaskItem> Tasks
    {
        get { lock (_gate) { return _tasks.ToList(); } }
    }

    public IReadOnlyList<TaskItem> NowTasks
    {
        get
        {
            var result = new List<TaskItem>();
            foreach (var task in Snapshot())
            {
                if (!task.Done && task.When == When.Now)
                {
                    result.Add(task);
                }
            }
            return result;
        }
    }

    public IReadOnlyList<TaskItem> LaterTasks
    {
        get
        {
            var result = new List<TaskItem>();
            foreach (var task in Snapshot())
            {
                if (!task.Done && task.When == When.Later)
                {
                    result.Add(task);
                }
            }
            return result;
        }
    }

    public IReadOnlyList<TaskItem> DoneTasks
    {
        get
        {
            var result = new List<TaskItem>();
            foreach (var task in Snapshot())
            {
                if (task.Done)
                {
                    result.Add(task);
                }
            }
            return result;
        }
    }

    /// <summary>Now-bucket first, then later-bucket — matches Swift's `nowTasks + laterTasks`
    /// concatenation order exactly (not a re-sort).</summary>
    public IReadOnlyList<TaskItem> OpenTasks
    {
        get
        {
            var result = new List<TaskItem>(NowTasks);
            result.AddRange(LaterTasks);
            return result;
        }
    }

    public TaskItem? FrogTask
    {
        get
        {
            foreach (var task in Snapshot())
            {
                if (task.Frog && !task.Done)
                {
                    return task;
                }
            }
            return null;
        }
    }

    /// <summary>
    /// THE integration point with Volar.Core's selection engine (mirrors
    /// `AppState.activeTask`, `AppState.swift:534-538`): recomputed from a fresh <see cref="Tasks"/>
    /// snapshot on every access — never cached — so it can never drift out of sync with the live
    /// list the way a memoized "current active task" field could. This is exactly the property the
    /// whole `TasksChanged`/`RefreshAsync` liveness mechanism exists to keep honest.
    /// </summary>
    public TaskItem? ActiveTask
    {
        get
        {
            var now = _clock.Now;
            var tasks = Snapshot();
            var engineSnapshot = new List<TaskSnapshot>(tasks.Count);
            foreach (var task in tasks)
            {
                engineSnapshot.Add(task.Snapshot());
            }
            var winner = NextTaskSelector.NextTask(engineSnapshot, now, _timeZone);
            if (winner is null)
            {
                return null;
            }
            foreach (var task in tasks)
            {
                if (task.Id == winner.Value.Id)
                {
                    return task;
                }
            }
            return null;
        }
    }

    /// <summary>Port of `refreshFromStore()`. A no-op (still raises <see cref="TasksChanged"/>, since
    /// a caller-requested refresh "completing" is itself meaningful to a subscriber even when nothing
    /// changed) when there is no repository, matching every other no-store fallback in this file.</summary>
    public async Task RefreshAsync()
    {
        if (_repository is not null)
        {
            await ReloadFromRepositoryAsync().ConfigureAwait(false);
        }
        NotifyChanged();
    }

    /// <summary>Port of `addTask(_:)`. See this file's header comment for why this port re-reads from
    /// the repository afterward where Swift's original does not.</summary>
    public async Task AddAsync(TaskItem task)
    {
        var before = Snapshot();

        if (_repository is not null)
        {
            await _repository.AddAsync(task.ToEntity()).ConfigureAwait(false);
            await ReloadFromRepositoryAsync().ConfigureAwait(false);
        }
        else
        {
            lock (_gate)
            {
                _tasks.Insert(0, task);
            }
        }

        // WG-1 (constitution IV): every newly created dated task must actually get its reminders
        // scheduled — a no-op for an undated task (`ReminderRecord.Derive` returns empty).
        _scheduler?.ScheduleReminders(task.Id);
        await _eligibility.NotifyEligibilityAndScheduleResurfaceAsync(before, Snapshot()).ConfigureAwait(false);
        NotifyChanged();
    }

    /// <summary>
    /// Port of `toggleDone(_:)` (T037, phase5-contract.md §C, FR-020) — the one consolidated
    /// completion+advance funnel every reachable completion source (plain UI toggle, voice-done
    /// `.complete`, evening-sweep complete) is expected to call rather than each re-implementing
    /// toggle + reload + reminder-cancel + eligibility-diff.
    /// </summary>
    public async Task ToggleDoneAsync(Guid id)
    {
        if (_repository is null)
        {
            lock (_gate)
            {
                var index = _tasks.FindIndex(t => t.Id == id);
                if (index < 0)
                {
                    return;
                }
                var item = _tasks[index];
                var wasDone = item.Done;
                item.Status = wasDone ? TaskState.Todo : TaskState.Done;
                if (!wasDone)
                {
                    item.When = When.Later;
                }
                _tasks[index] = item;
            }
            NotifyChanged();
            return;
        }

        var before = Snapshot();
        var now = _clock.Now;

        await _repository.ToggleAsync(id, now, _timeZone).ConfigureAwait(false);
        await ReloadFromRepositoryAsync().ConfigureAwait(false);

        // WG-2 (constitution IV): a backgrounded reminder delivery bypasses the live-presentation
        // path, so a completed/archived task's outstanding reminders must be actively cancelled here
        // rather than relying solely on fire-time fresh-reload suppression. The flip side also
        // applies: TaskRepository.ToggleAsync can REOPEN a task (un-marking done) or reset a
        // recurring task back to Todo in place with a fresh deadline — either way it needs its
        // reminders re-derived, not left cancelled.
        var toggled = FindById(id);
        if (toggled is TaskItem t)
        {
            if (t.Status == TaskState.Done || t.Status == TaskState.Archived)
            {
                _scheduler?.CancelReminders(id);
            }
            else
            {
                _scheduler?.ScheduleReminders(id);
            }
        }

        await _eligibility.NotifyEligibilityAndScheduleResurfaceAsync(before, Snapshot()).ConfigureAwait(false);
        NotifyChanged();
    }

    /// <summary>
    /// Port of `deleteTask(_:)`. Self-review "performance" flagged: Swift reuses
    /// `TaskStore.delete`'s own already-computed eligibility diff directly to avoid a second
    /// `eligibilityDiff` pass; the frozen <see cref="IEligibilityAndResurfaceService"/> contract has
    /// no bare "resurface-only, reuse this diff" entry point (only the combined
    /// before/after-diffing method), so this port recomputes the diff once more via the shared tail
    /// instead of threading <see cref="TaskRepository.DeleteAsync"/>'s own return value through.
    /// Both computations run the identical pure `Snapshots.EligibilityDiff` function over equivalent
    /// before/after data, so the result is the same either way — this is flagged as a minor,
    /// deliberate inefficiency, not a correctness gap, and kept this way rather than silently adding
    /// a third method to the frozen interface.
    /// </summary>
    public async Task DeleteAsync(Guid id)
    {
        if (_repository is null)
        {
            lock (_gate)
            {
                _tasks.RemoveAll(t => t.Id == id);
            }
            NotifyChanged();
            return;
        }

        var before = Snapshot();

        await _repository.DeleteAsync(id, _clock.Now).ConfigureAwait(false);
        await ReloadFromRepositoryAsync().ConfigureAwait(false);

        // WG-2 (constitution IV): cascade cancellation — a deleted task's reminders must never
        // orphan-fire.
        _scheduler?.CancelReminders(id);

        await _eligibility.NotifyEligibilityAndScheduleResurfaceAsync(before, Snapshot()).ConfigureAwait(false);
        NotifyChanged();
    }

    /// <summary>Port of `setFrog(_:)`. Never calls the eligibility tail — Swift's own `setFrog`
    /// doesn't either; assigning the frog flag cannot change any task's eligibility.</summary>
    public async Task SetFrogAsync(Guid id)
    {
        if (_repository is null)
        {
            lock (_gate)
            {
                for (var i = 0; i < _tasks.Count; i++)
                {
                    var item = _tasks[i];
                    item.Frog = item.Id == id;
                    _tasks[i] = item;
                }
            }
            NotifyChanged();
            return;
        }

        await _repository.SetFrogAsync(id).ConfigureAwait(false);
        await ReloadFromRepositoryAsync().ConfigureAwait(false);
        NotifyChanged();
    }

    private List<TaskItem> Snapshot()
    {
        lock (_gate)
        {
            return new List<TaskItem>(_tasks);
        }
    }

    private TaskItem? FindById(Guid id)
    {
        foreach (var task in Snapshot())
        {
            if (task.Id == id)
            {
                return task;
            }
        }
        return null;
    }

    /// <summary>FIX 3's sibling-trap guard, centralized: every store-backed mutation calls this
    /// instead of hand-patching `_tasks`, so recurrence resets and parent-completion cascades — both
    /// computed entirely inside <see cref="TaskRepository"/> — are always reflected exactly.</summary>
    private async Task ReloadFromRepositoryAsync()
    {
        if (_repository is null)
        {
            return;
        }
        var entities = await _repository.GetAllAsync().ConfigureAwait(false);
        var mapped = new List<TaskItem>(entities.Count);
        foreach (var entity in entities)
        {
            mapped.Add(entity.ToTaskItem());
        }
        lock (_gate)
        {
            _tasks = mapped;
        }
    }

    private void NotifyChanged() => TasksChanged?.Invoke();
}
