// Services/State/DelegationOrchestratorService.cs — port of AppState.swift's Phase 6 (US4)
// AI-delegation orchestrator (§1.23, lines 2222-2350) plus the `dueDelegationRechecks`/
// `pendingDisambiguationTaskIDs`/`lastAppLinkAt` collaborator state (§1.6 rows 49-54). Inventory
// cluster I.
//
// SEAM FOR C3 (per this task's brief — read this before wiring anything into it):
// `DelegateTaskAsync(Guid taskId, string? label = null, int checkBackMinutes = 10)` is the plain
// public method C3's voice delegation-intent classification (inside `CaptureFlowService`,
// `confirmVoiceDone`'s `.delegate(checkBackMinutes:)` branch, mirroring `AppState.swift:1045-1064`'s
// `confirmVoiceDone`) should call once it decides the user said something like "nhắn Claude làm
// việc này" / "delegate this". It takes the SAME shape Swift's `delegateTask(_:label:checkBackMinutes:)`
// exposes: an optional label (falls back to the task's own title, then "Claude"), and a check-back
// minute count. This file does not call into `CaptureFlowService` or vice versa — the two agents'
// files are file-disjoint and this seam is intentionally a plain async method with primitive
// parameters, no shared type either side would need to newly define.
//
// CLAUDECONNECTOR/EDITORCONNECTOR: NOT owned here (flagged, not silently invented). The frozen
// wave3c-services.md text for cluster I names only "the recheck queue, ambient-card resolution
// (done/still-waiting/check-later), DelegateTask, app-link handling and disambiguation" —
// appstate-inventory.md §3's broader cluster-proposal framing additionally mentions
// `claudeConnector` "collaborator wiring," but `Volar.Orchestrator.EditorConnector`'s only consumer
// in the Swift original is `SettingsView` (connect/disconnect/preview/test-signal — a Settings-UI
// concern with zero interaction with delegation/task state). Recommend C5 continues registering
// `EditorConnector` as its own DI singleton (unchanged from the pre-existing CompositionRoot, over
// `Win32EditorTransport`) for Wave 4's Settings surface to consume directly, rather than routing it
// through this service for no behavioral reason.
using System.Linq;
using Volar.Orchestrator;

namespace Volar.App.Services.State;

public sealed class DelegationOrchestratorService
{
    private readonly ITaskListService _taskList;
    private readonly IEligibilityAndResurfaceService _eligibility;
    private readonly ITimeProvider _clock;
    private readonly DelegationTracker? _delegation;
    private readonly AppLinkHandler? _appLinkHandler;
    private readonly Volar.Reminders.ReminderScheduler? _scheduler;
    private List<Guid> _dueDelegationRechecks = new();
    private List<Guid> _pendingDisambiguationTaskIds = new();

    /// <param name="delegation">Nullable — mirrors Swift's `delegation: DelegationTracker?`, `nil`
    /// exactly when there is no store (`AppState.swift:486-487`). Every method below that needs it
    /// degrades to a documented no-op without one, matching every other nullable-collaborator seam
    /// in this codebase.</param>
    /// <param name="appLinkHandler">Nullable, same reasoning as <paramref name="delegation"/>
    /// (`AppState.swift:487`). C5 is expected to set its <c>OnCapture</c> delegate to whatever public
    /// seam C3's `CaptureFlowService` exposes for a capture app-link (`volar://capture?text=...`) —
    /// this service does not wire that itself (it has no reference to C3's file); see this task's
    /// final report, "handoff."</param>
    /// <param name="scheduler">Nullable — mirrors every other `scheduler?.` call site in this
    /// codebase. Used only by <see cref="DelegateTaskAsync"/> to re-derive the delegated task's
    /// reminders (WG-1), matching `AppState.swift:2277`'s `scheduler?.scheduleReminders(taskId:)`.</param>
    public DelegationOrchestratorService(
        ITaskListService taskList,
        IEligibilityAndResurfaceService eligibility,
        ITimeProvider clock,
        DelegationTracker? delegation = null,
        AppLinkHandler? appLinkHandler = null,
        Volar.Reminders.ReminderScheduler? scheduler = null)
    {
        _taskList = taskList ?? throw new ArgumentNullException(nameof(taskList));
        _eligibility = eligibility ?? throw new ArgumentNullException(nameof(eligibility));
        _clock = clock ?? throw new ArgumentNullException(nameof(clock));
        _delegation = delegation;
        _appLinkHandler = appLinkHandler;
        _scheduler = scheduler;
    }

    /// <summary>Reachable for C5's post-construction wiring (e.g. setting
    /// <see cref="AppLinkHandler.OnCapture"/>) without needing a second reference threaded through
    /// DI — see this file's header comment.</summary>
    public AppLinkHandler? AppLinkHandler => _appLinkHandler;

    // MARK: - §1.6 collaborator state (dueDelegationRechecks / pendingDisambiguationTaskIDs / lastAppLinkAt)

    /// <summary>Mirrors `dueDelegationRechecks` (`AppState.swift:334`) — the ambient "needs review"
    /// queue `TodayView` renders as an ordinary, dismissible in-app card (constitution I: never a
    /// system notification).</summary>
    public IReadOnlyList<Guid> DueDelegationRechecks => _dueDelegationRechecks;

    /// <summary>Mirrors `pendingDisambiguationTaskIDs` (`AppState.swift:342`).</summary>
    public IReadOnlyList<Guid> PendingDisambiguationTaskIds => _pendingDisambiguationTaskIds;

    /// <summary>Mirrors `lastAppLinkAt` (`AppState.swift:346`) — session-only receipt signal, not
    /// persisted (same as the Swift original).</summary>
    public DateTimeOffset? LastAppLinkAt { get; private set; }

    /// <summary>Passthrough convenience — mirrors `appState.delegation?.wipCount()`'s call sites
    /// (`MenuBarLabel`/`TodayView`/`SettingsView`) without those views needing a direct reference to
    /// <see cref="DelegationTracker"/> themselves.</summary>
    public int WipCount() => _delegation?.WipCount() ?? 0;

    // MARK: - T043 minute-scale ambient recheck (the caller/shell owns the actual Timer — see
    // this file's header/final-report note: unlike Swift's self-armed `Timer`, this service exposes
    // only the pure refresh; C5's shell is expected to call RefreshDelegationQueue on its own
    // 60s cadence, mirroring how `EligibilityAndResurfaceService`/`FocusSessionService` each own
    // their OWN timing primitive but a repeating UI-cadence poll is squarely shell/Wave-4 territory)

    /// <summary>Mirrors `refreshDelegationQueue(now:)` (`AppState.swift:2254-2256`).</summary>
    public void RefreshDelegationQueue(DateTimeOffset? now = null)
    {
        _dueDelegationRechecks = _delegation?.DueForRecheck(now ?? _clock.Now).ToList() ?? new List<Guid>();
    }

    /// <summary>Mirrors the evening-sweep-triggered `reconcileBatch()` merge inside
    /// `maybeShowEveningSweep()` (`AppState.swift:2077-2081`) — called by
    /// <see cref="TriageAndSweepService.MaybeShowEveningSweep"/> (a cross-cluster call from H into
    /// I; both clusters are this agent's own files — see that file's header comment). Deliberately
    /// NOT unioned into <see cref="RefreshDelegationQueue"/>'s 60s cadence:
    /// <see cref="DelegationTracker.ReconcileBatch"/> is independent of backoff stage, so folding it
    /// into every tick would show every in-flight delegation immediately regardless of its
    /// check-back schedule, defeating the whole point of the 10'/30'/batch-only backoff.</summary>
    public void ReconcileEveningBatch()
    {
        if (_delegation is null)
        {
            return;
        }
        var batchIds = _delegation.ReconcileBatch();
        var alreadyQueued = new HashSet<Guid>(_dueDelegationRechecks);
        foreach (var id in batchIds)
        {
            if (alreadyQueued.Add(id))
            {
                _dueDelegationRechecks.Add(id);
            }
        }
    }

    // MARK: - T042 delegate / resolve actions

    /// <summary>
    /// Mirrors `delegateTask(_:label:checkBackMinutes:)` (`AppState.swift:2268-2280`) — THE seam C3
    /// binds into (see this file's header comment). No-op (mirrors Swift's
    /// <c>guard let delegation, let store else { return }</c>) when there is no
    /// <see cref="DelegationTracker"/> wired — delegation state has nowhere durable to live without
    /// one.
    /// </summary>
    public async Task DelegateTaskAsync(Guid taskId, string? label = null, int checkBackMinutes = 10)
    {
        if (_delegation is null)
        {
            return;
        }
        var before = _taskList.Tasks;
        var resolvedLabel = label;
        if (resolvedLabel is null)
        {
            foreach (var task in before)
            {
                if (task.Id == taskId)
                {
                    resolvedLabel = task.Title;
                    break;
                }
            }
            resolvedLabel ??= "Claude";
        }
        var now = _clock.Now;
        _delegation.Delegate(taskId, resolvedLabel, now, cwdHint: null, checkBackMinutes: checkBackMinutes);
        await _taskList.RefreshAsync().ConfigureAwait(false);
        // WG-1: this task's condition state just changed — re-derive its reminders, same as every
        // other condition-adding path in this codebase.
        _scheduler?.ScheduleReminders(taskId);
        await _eligibility.NotifyEligibilityAndScheduleResurfaceAsync(before, _taskList.Tasks).ConfigureAwait(false);
        RefreshDelegationQueue(now);
    }

    /// <summary>Mirrors `resolveDelegationDone(_:)` (`AppState.swift:2284-2287`) — routes through the
    /// SAME completion funnel as every other completion source (decision 5 / T037).</summary>
    public async Task ResolveDelegationDoneAsync(Guid taskId)
    {
        await _taskList.ToggleDoneAsync(taskId).ConfigureAwait(false);
        RefreshDelegationQueue();
    }

    /// <summary>Mirrors `resolveDelegationStillWaiting(_:)` (`AppState.swift:2291-2294`).</summary>
    public void ResolveDelegationStillWaiting(Guid taskId, DateTimeOffset now)
    {
        _delegation?.BumpBackoff(taskId, now);
        RefreshDelegationQueue(now);
    }

    /// <summary>Mirrors `resolveDelegationCheckLater(_:minutes:)` (`AppState.swift:2301-2306`) — an
    /// explicit user-directed snooze, re-delegating the SAME task under its current title/cwd hint.
    /// <see cref="DelegationTracker.Delegate"/> is documented idempotent for an already-waiting
    /// task (updates the schedule in place instead of piling up a second condition), so this never
    /// touches the store and needs no <see cref="ITaskListService.RefreshAsync"/> — same shape as
    /// the Swift original, which also skips a `tasks` reload here.</summary>
    public void ResolveDelegationCheckLater(Guid taskId, DateTimeOffset now, int minutes = 10)
    {
        if (_delegation is null)
        {
            return;
        }
        string? label = null;
        foreach (var task in _taskList.Tasks)
        {
            if (task.Id == taskId)
            {
                label = task.Title;
                break;
            }
        }
        label ??= "Claude";
        _delegation.Delegate(taskId, label, now, cwdHint: _delegation.CwdHint(taskId), checkBackMinutes: minutes);
        RefreshDelegationQueue(now);
    }

    // MARK: - App-link (volar://) handling

    /// <summary>
    /// Combined convenience mirroring the Swift call site's two-step sequence
    /// (`AppDelegate.application(_:open:)`, `VolarApp.swift:328-330`:
    /// <c>appState.appLinkHandler?.handle(url); appState.onAppLinkHandled()</c>). No-op if there is
    /// no <see cref="AppLinkHandler"/> wired.
    /// </summary>
    public async Task HandleAppLinkAsync(Uri url, DateTimeOffset now)
    {
        _appLinkHandler?.Handle(url);
        await OnAppLinkHandledAsync(now).ConfigureAwait(false);
    }

    /// <summary>
    /// Mirrors `onAppLinkHandled()` (`AppState.swift:2314-2326`) — refreshes the task list FIRST
    /// (whatever `AppLinkHandler.Handle` just resolved mutated the underlying store, not this
    /// service's cache; see decision 5), then stamps the receipt signal and re-syncs the mirrored
    /// disambiguation/recheck queues. Exposed separately from <see cref="HandleAppLinkAsync"/> so a
    /// caller that already invoked <see cref="AppLinkHandler.Handle(Uri)"/> itself (or a test) can
    /// still drive the rest of this sequence.
    /// </summary>
    public async Task OnAppLinkHandledAsync(DateTimeOffset now)
    {
        await _taskList.RefreshAsync().ConfigureAwait(false);
        LastAppLinkAt = now;
        _pendingDisambiguationTaskIds = _appLinkHandler?.PendingDisambiguation.ToList() ?? new List<Guid>();
        RefreshDelegationQueue(now);
    }

    /// <summary>Mirrors `resolveAppLinkDisambiguation(taskId:)` (`AppState.swift:2332-2342`) — the
    /// refresh runs AFTER <see cref="AppLinkHandler.ResolveDisambiguation"/> (which itself mutates
    /// the store via `DelegationTracker.MarkNeedsReview`), matching the Swift original's exact
    /// ordering comment.</summary>
    public async Task ResolveAppLinkDisambiguationAsync(Guid taskId, DateTimeOffset now)
    {
        _appLinkHandler?.ResolveDisambiguation(taskId);
        await _taskList.RefreshAsync().ConfigureAwait(false);
        _pendingDisambiguationTaskIds = _appLinkHandler?.PendingDisambiguation.ToList() ?? new List<Guid>();
        RefreshDelegationQueue(now);
    }

    /// <summary>Mirrors `dismissAppLinkDisambiguation()` (`AppState.swift:2346-2349`) — purely local
    /// UI state, no task touched.</summary>
    public void DismissAppLinkDisambiguation()
    {
        _appLinkHandler?.DismissDisambiguation();
        _pendingDisambiguationTaskIds = new List<Guid>();
    }
}
