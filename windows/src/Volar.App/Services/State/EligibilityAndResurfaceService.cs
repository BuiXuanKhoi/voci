// Services/State/EligibilityAndResurfaceService.cs — port of AppState.swift's
// `notifyEligibilityAndScheduleResurface(before:now:)` (1826-1834) and
// `scheduleNextResurface(from:now:)` (1843-1896), i.e. inventory cluster D (T031/T032,
// FR-015/FR-017). This is the shared mutation tail every task-writer calls, kept separate from
// TaskListService specifically so FIX 2's resurface-chaining logic stays unit-testable in
// isolation (wave3c-services.md, C2 section).
//
// FIX 2 (specs/003-windows-port/appstate-inventory.md §6), the three sub-parts this file must get
// right together:
//   (a) scan EVERY task's own earliest future `.afterDate`, not just the single global-earliest
//       one, and register each with the durable scheduler (`ReminderScheduler.ScheduleResurface`,
//       itself already deduped per task — see that method's own doc comment, so calling this on
//       every mutation never piles up duplicate durable rows).
//   (b) chain forward on wake: when the locally-armed wait elapses, re-run the same scan against a
//       FRESH task snapshot so whichever `.afterDate` comes next gets armed too, rather than firing
//       once and going dormant.
//   (c) be safe to call twice (idempotent) — `RearmAsync` doubles as the launch re-arm Swift's
//       `activateServices()` performs, and that method is itself documented double-call-safe.
//
// CONSTRUCTOR-CYCLE NOTE (read before wiring this into DI): the wake-continuation in (b) needs to
// re-read the CURRENT task list at the moment a resurface fires, which could be minutes or years
// after this service armed it — it cannot rely on the `after` snapshot a caller passed to
// `NotifyEligibilityAndScheduleResurfaceAsync` at arm-time, because that snapshot goes stale the
// instant any OTHER mutation happens in between. That means this service needs a live, read-through
// reference to `ITaskListService` (decision 5 explicitly sanctions holding such a reference — only
// CACHING a second `TaskItem` collection is forbidden). But `TaskListService` itself needs to call
// INTO `IEligibilityAndResurfaceService` after every mutation (its own constructor dependency) — a
// naive two-way constructor injection is a cycle neither a hand-built graph nor
// Microsoft.Extensions.DependencyInjection can resolve. <see cref="TaskList"/> below is a settable
// property (not a constructor parameter) specifically to break that cycle: the composition root
// constructs this service first (it needs no `ITaskListService` to be constructed), then constructs
// `TaskListService` with this service injected, then assigns `eligibility.TaskList = taskListService`
// once both exist. A <see langword="null"/> `TaskList` degrades the wake-chain to a no-op — the same
// nullable-collaborator convention already used throughout this codebase (`store`/`scheduler`
// everywhere else) — rather than throwing. See this task's final report for the exact
// CompositionRoot snippet C5 must add.
using System.Diagnostics;
using Volar.Core;
using Volar.Domain;
using Volar.Reminders;

namespace Volar.App.Services.State;

public sealed class EligibilityAndResurfaceService : IEligibilityAndResurfaceService
{
    /// <summary>
    /// Defensive cap on the locally-armed wake delay (self-review "client-exploit", mirrors
    /// `AppState.swift:1875`'s own `min(..., 60*60*24*365*5)`): a corrupted/hostile store could carry
    /// an absurd far-future `.afterDate`; this only bounds the optional live-refresh nicety — the
    /// durable scheduler registration above it is never clamped.
    /// </summary>
    private static readonly TimeSpan MaxLocalWakeDelay = TimeSpan.FromDays(365 * 5);

    private readonly ITimeProvider _clock;
    private readonly ReminderScheduler? _scheduler;
    private int _resurfaceSession;

    public EligibilityAndResurfaceService(ITimeProvider clock, ReminderScheduler? scheduler = null)
    {
        _clock = clock ?? throw new ArgumentNullException(nameof(clock));
        _scheduler = scheduler;
    }

    /// <summary>Late-bound to break the constructor cycle described in this file's header comment.
    /// The composition root must set this immediately after constructing both singletons, before
    /// either is used for a real mutation.</summary>
    public ITaskListService? TaskList { get; set; }

    /// <inheritdoc/>
    /// <remarks>
    /// DEVIATION FLAGGED (self-review "conflict"): the frozen signature takes no explicit
    /// <c>now</c> parameter, unlike Swift's <c>notifyEligibilityAndScheduleResurface(before:now:)</c>,
    /// which receives the caller's already-captured instant. This service computes its own `now`
    /// from <see cref="_clock"/> instead — implemented exactly as the contract specifies rather than
    /// silently adding a parameter, per this task's hard constraints. The practical effect is two
    /// clock reads a few microseconds apart (the caller's `now` for its own repository mutation, and
    /// this method's fresh `now` for the diff) instead of Swift's one shared instant; harmless here
    /// because the diff is computed over already-materialized <paramref name="before"/>/<paramref
    /// name="after"/> lists, not against timing-sensitive live state.
    /// </remarks>
    public Task NotifyEligibilityAndScheduleResurfaceAsync(IReadOnlyList<TaskItem> before, IReadOnlyList<TaskItem> after)
    {
        var now = _clock.Now;
        var beforeSnapshot = ToSnapshots(before);
        var afterSnapshot = ToSnapshots(after);

        var newlyEligible = Snapshots.EligibilityDiff(beforeSnapshot, afterSnapshot, now);
        if (newlyEligible.Count > 0)
        {
            _scheduler?.NotifyUnblocked(newlyEligible, now);
        }

        ArmResurface(afterSnapshot, now);
        return Task.CompletedTask;
    }

    /// <inheritdoc/>
    /// <remarks>
    /// Mirrors Swift's launch call <c>scheduleNextResurface(from: tasks.map { $0.snapshot() }, now:
    /// clock())</c> inside <c>activateServices()</c> — uses whatever <see cref="TaskList"/> already
    /// holds rather than forcing a fresh repository reload itself. The composition root/shell must
    /// call <c>await taskList.RefreshAsync()</c> once at launch BEFORE calling this, matching Swift's
    /// own ordering (tasks loaded in <c>AppState.init</c>, <c>activateServices()</c> runs later).
    /// Idempotent per FIX 2(c): every call bumps <see cref="_resurfaceSession"/>, invalidating any
    /// still-pending wake from a previous call, and every <see cref="ReminderScheduler.ScheduleResurface"/>
    /// it issues is itself deduped per task — so a repeat call just re-arms the same state, never a
    /// duplicate.
    /// </remarks>
    public Task RearmAsync()
    {
        var now = _clock.Now;
        // OPUS REVIEW (2026-07-25): a null `TaskList` here is tolerated by design (see that
        // property's remarks, and the test that pins "RearmAsync must not throw when unwired") —
        // but tolerated must not mean invisible. Unwired means resurface is armed for NOTHING, which
        // is exactly the class of silent failure FIX 2 was written to eliminate: the user's
        // "remind me about this on Friday" task simply never resurfaces, with no error anywhere.
        // Say so, once, so a half-wired composition root is diagnosable from the log instead of
        // from a user noticing months later. The composition root is additionally covered by a
        // wiring test (C5) that asserts this property is set in the real DI graph.
        if (TaskList is null && !_warnedUnwired)
        {
            _warnedUnwired = true;
            Debug.WriteLine(
                "[Volar.EligibilityAndResurfaceService] RearmAsync ran with TaskList unset — " +
                "resurface is armed for no tasks. The composition root must assign " +
                "`eligibility.TaskList = taskListService` immediately after constructing both.");
        }
        var tasks = TaskList?.Tasks ?? Array.Empty<TaskItem>();
        ArmResurface(ToSnapshots(tasks), now);
        return Task.CompletedTask;
    }

    /// One-shot latch for the unwired warning above — a warning per wake would be noise.
    private bool _warnedUnwired;

    private static List<TaskSnapshot> ToSnapshots(IReadOnlyList<TaskItem> tasks)
    {
        var result = new List<TaskSnapshot>(tasks.Count);
        foreach (var task in tasks)
        {
            result.Add(task.Snapshot());
        }
        return result;
    }

    /// <summary>FIX 2(a): scans every task's own conditions for its earliest strictly-future
    /// <see cref="AfterDateCondition"/> and registers each individually with the durable scheduler,
    /// then arms a local one-shot wake for whichever date is earliest overall (FIX 2(b) chains
    /// forward from inside <see cref="WakeAsync"/> once that wake fires).</summary>
    private void ArmResurface(IReadOnlyList<TaskSnapshot> snapshot, DateTimeOffset now)
    {
        var session = Interlocked.Increment(ref _resurfaceSession);

        DateTimeOffset? earliestOverall = null;
        foreach (var task in snapshot)
        {
            DateTimeOffset? earliestForTask = null;
            foreach (var condition in task.Conditions)
            {
                if (condition is not AfterDateCondition afterDate || afterDate.Date <= now)
                {
                    continue;
                }
                if (earliestForTask is null || afterDate.Date < earliestForTask.Value)
                {
                    earliestForTask = afterDate.Date;
                }
            }
            if (earliestForTask is not DateTimeOffset taskDate)
            {
                continue;
            }
            _scheduler?.ScheduleResurface(taskDate, task.Id);
            if (earliestOverall is null || taskDate < earliestOverall.Value)
            {
                earliestOverall = taskDate;
            }
        }

        if (earliestOverall is not DateTimeOffset date)
        {
            return;
        }

        var delay = date - now;
        if (delay < TimeSpan.Zero)
        {
            delay = TimeSpan.Zero;
        }
        else if (delay > MaxLocalWakeDelay)
        {
            delay = MaxLocalWakeDelay;
        }

        // Fire-and-forget by design (mirrors Swift's detached `_Concurrency.Task { ... }`): arming a
        // wake must not make the calling mutation (AddAsync/ToggleDoneAsync/...) wait for it.
        // WakeAsync guards every exit with a try/catch so a failure here can never surface as an
        // unobserved-task-exception crash.
        _ = WakeAsync(session, delay);
    }

    /// <summary>FIX 2(b): the local one-shot continuation. Guarded by <paramref name="session"/> so a
    /// still-pending wake from an earlier (now-superseded) arm can never fire — the same monotonic
    /// pattern <c>CaptureFlowService</c>'s `captureSession` will use for its own guard. Cannot loop
    /// forever: the moment that just fired is now &lt;= `now`, and <see cref="ArmResurface"/> only
    /// ever selects a STRICTLY future date, so the same moment can never be re-selected — each
    /// recursive re-arm either lands strictly later (and stops after that one wait) or finds nothing
    /// left (and returns immediately, ending the chain).</summary>
    private async Task WakeAsync(int session, TimeSpan delay)
    {
        try
        {
            await Task.Delay(delay).ConfigureAwait(false);
            if (Volatile.Read(ref _resurfaceSession) != session)
            {
                return; // superseded by a later mutation/re-arm — stale wake, no-op.
            }

            var taskList = TaskList;
            if (taskList is not null)
            {
                await taskList.RefreshAsync().ConfigureAwait(false);
            }

            var now = _clock.Now;
            var tasks = taskList?.Tasks ?? Array.Empty<TaskItem>();
            ArmResurface(ToSnapshots(tasks), now); // FIX 2(b): re-run against the fresh snapshot.
        }
        catch (Exception ex)
        {
            // Never let a fire-and-forget wake crash the process — log, matching this codebase's
            // established "corrupt/unreadable state degrades, never throws into a caller that isn't
            // expecting it" convention (e.g. JsonFileSettingsStore.Save, ReminderScheduler.Persist*).
            Debug.WriteLine($"[Volar.App.Services.State.EligibilityAndResurfaceService] resurface wake failed: {ex.Message}");
        }
    }
}
