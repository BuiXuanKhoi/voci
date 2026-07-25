// DelegationTracker.cs — port of Sources/Orchestrator/DelegationTracker.swift: AI-delegation
// lifecycle (feature 002, US4, contracts/phase6-contract.md §A + contracts/app-links.md).
//
// A task is "delegated" when it carries an `ExternalCondition("waiting on AI: <label>",
// Satisfied:false)` (Volar.Core.Condition) plus a `DelegationMeta` (Volar.Domain.Recurrence.cs).
//
// PERSISTENCE SEAM: mirrors the Swift original's own documented seam (see that file's header) —
// `IOrchestratorTaskStore` has no write path for `TaskItem.Delegation` on an EXISTING task, only
// the `ExternalCondition` mutators (`AddCondition`/`ClearExternalCondition`). This file treats
// that condition as the single source of truth for "is this task delegated / has it been signaled
// done", and persists the scheduling metadata (checkBackAt/backoffStage/cwdHint/label/delegatedAt)
// itself, via the injected `IDelegationMetaStore` (Swift: UserDefaults-backed; here: an
// injectable seam, see that interface's header for why). `PruneOrphans()` keeps that store from
// drifting if a task is deleted out from under it.
//
// DOMAIN-PURITY DEVIATION FROM SWIFT: every method that Swift resolves via an internal `Date()`
// read (`dueForRecheck(now: Date = Date())`'s default, `bumpBackoff`'s two `Date()` calls) instead
// takes an explicit `DateTimeOffset now` parameter here, matching this project's existing
// convention that "every 'now' instant must be supplied explicitly by the caller" (see
// Volar.Domain.TaskItem's remarks). No default value is provided, so callers cannot accidentally
// reintroduce a hidden clock read.
using Volar.Core;
using Volar.Domain;

namespace Volar.Orchestrator;

/// <summary>
/// Delegation lifecycle: mark-delegated, WIP count, check-back scheduling/backoff, and batch
/// reconciliation. All mutation happens through <see cref="IOrchestratorTaskStore"/>'s public API
/// — this class owns no direct persistence access of its own beyond <see cref="IDelegationMetaStore"/>.
/// </summary>
/// <remarks>
/// Swift's original is <c>@MainActor</c>-isolated (single-threaded by construction via the main
/// actor). This port carries no such isolation of its own — callers on Windows are expected to
/// confine access to a single thread (e.g. the UI thread), the same way every other pure
/// Volar.Orchestrator type in this project is documented as not being thread-safe.
/// </remarks>
public sealed class DelegationTracker
{
    /// <summary>
    /// Fixed prefix contract A mandates for the waiting-condition description
    /// (<c>ExternalCondition("waiting on AI: &lt;label&gt;", Satisfied:false)</c>); also used to
    /// recognize a waiting-on-AI condition among a task's other <see cref="ExternalCondition"/>s.
    /// </summary>
    public const string WaitingPrefix = "waiting on AI: ";

    /// <summary>Stage thresholds (research.md R9): 0 -&gt; 10', 1 -&gt; 30', 2+ -&gt; batch-only.</summary>
    private const int BatchOnlyStage = 2;

    private static readonly TimeSpan SecondBackoff = TimeSpan.FromMinutes(30);

    private readonly IOrchestratorTaskStore _store;
    private readonly IDelegationMetaStore _metaStore;

    /// <summary>
    /// <paramref name="metaStore"/> defaults to an in-memory (non-durable) store purely so this
    /// type has a working default constructor for tests and early callers, mirroring
    /// `TaskStore.init(inMemory:)`'s existing test-hygiene convention — see
    /// <see cref="InMemoryDelegationMetaStore"/>'s doc comment for why a durable implementation is
    /// still required before shipping.
    /// </summary>
    public DelegationTracker(IOrchestratorTaskStore store, IDelegationMetaStore? metaStore = null)
    {
        _store = store;
        _metaStore = metaStore ?? new InMemoryDelegationMetaStore();
    }

    /// <summary>
    /// Mark a task delegated: add the external waiting-condition + <see cref="DelegationMeta"/>,
    /// schedule the first minute-scale check-back (default 10'). Returns nothing; caller advances
    /// the menu bar.
    /// </summary>
    /// <remarks>
    /// Guards against piling up a second waiting-on-AI condition if the task is already delegated
    /// (re-delegating updates the existing schedule/label instead) — the contract models one
    /// delegation per task at a time (singular "a <see cref="DelegationMeta"/>").
    /// </remarks>
    public void Delegate(Guid taskId, string label, DateTimeOffset now, string? cwdHint, int checkBackMinutes = 10)
    {
        var alreadyWaiting = CurrentCondition(taskId, IsWaitingOnAI) is not null;
        if (!alreadyWaiting)
        {
            var description = WaitingPrefix + label;
            // `AddCondition` never throws from a well-behaved store (Swift's documented guarantee
            // 5 on the equivalent `TaskStore.addCondition`) — swallow any failure here rather than
            // let a best-effort delegation call crash the caller, matching Swift's `try?`.
            try
            {
                _store.AddCondition(new ExternalCondition(description, false), taskId);
            }
            catch
            {
                // Intentionally swallowed — see remark above.
            }
        }
        var minutes = Math.Max(1, checkBackMinutes);
        var meta = new DelegationMeta(
            Label: label,
            CheckBackAt: now.AddMinutes(minutes),
            BackoffStage: 0,
            CwdHint: cwdHint,
            DelegatedAt: now);
        _metaStore.Set(taskId, meta);
    }

    /// <summary>
    /// Count of in-flight delegations (unsatisfied waiting-on-AI conditions) — drives the WIP
    /// badge. Derived live from <see cref="IOrchestratorTaskStore"/> (not the local meta shadow) so
    /// it can never drift from what the rest of the app considers "delegated". O(n) over tasks, not
    /// per-frame — callers (menu-bar label refresh) are expected to call this on state-change
    /// ticks, not every draw.
    /// </summary>
    public int WipCount()
    {
        var count = 0;
        foreach (var item in _store.FetchAll())
        {
            if (item.Status == TaskState.Done || item.Status == TaskState.Archived)
            {
                continue;
            }
            if (item.Conditions.Any(IsWaitingOnAI))
            {
                count++;
            }
        }
        return count;
    }

    /// <summary>
    /// Tasks whose check-back is due now → resurface AMBIENTLY (menu-bar queue, NOT a
    /// notification). Backoff: 10' -&gt; 30' -&gt; batch-only (<see cref="DelegationMeta.BackoffStage"/>).
    /// Called by a timer + on app foreground. Self-heals the meta store against tasks deleted (or
    /// completed/reviewed) since the last call. Ordered earliest-due-first (stable, no notion of
    /// urgency beyond that — the UI decides presentation).
    /// </summary>
    public IReadOnlyList<Guid> DueForRecheck(DateTimeOffset now)
    {
        PruneOrphans();
        // A meta entry alone can't tell a completed/reviewed task from one still genuinely in
        // flight — every completion path completes the task via the store WITHOUT touching this
        // shadow store (only `MarkNeedsReview` removes a meta entry). Self-heal by cross-checking
        // against the SAME live-store predicate `WipCount()`/`ReconcileBatch()` already use — task
        // exists, status not done/archived, still carries an unsatisfied waiting-on-AI condition —
        // so a completed task's stale meta entry can never keep re-surfacing its check-in card.
        // Also prunes the now-stale meta for excluded ids so the shadow store self-cleans.
        var waitingIds = new HashSet<Guid>(
            _store.FetchAll()
                .Where(t => t.Status != TaskState.Done && t.Status != TaskState.Archived)
                .Where(t => t.Conditions.Any(IsWaitingOnAI))
                .Select(t => t.Id));
        _metaStore.PruneKeys(waitingIds);

        return _metaStore.All()
            .Where(kv => kv.Value.BackoffStage < BatchOnlyStage && kv.Value.CheckBackAt <= now)
            .OrderBy(kv => kv.Value.CheckBackAt)
            .Select(kv => kv.Key)
            .ToList();
    }

    /// <summary>
    /// User ignored a recheck -&gt; next stage. No-op for a task with no known delegation meta
    /// (already reviewed/never delegated — nothing to bump).
    /// </summary>
    public void BumpBackoff(Guid taskId, DateTimeOffset now)
    {
        var meta = _metaStore.Get(taskId);
        if (meta is not DelegationMeta current)
        {
            return;
        }
        var nextStage = Math.Min(current.BackoffStage + 1, BatchOnlyStage);
        var nextCheckBackAt = nextStage >= BatchOnlyStage
            // batch-only: `DueForRecheck`'s stage filter already excludes it — this just keeps the
            // stored instant from ever comparing "due" again.
            ? DateTimeOffset.MaxValue
            : now + SecondBackoff;
        _metaStore.Set(taskId, current with { BackoffStage = nextStage, CheckBackAt = nextCheckBackAt });
    }

    /// <summary>
    /// Signal arrived (from <see cref="AppLinkHandler"/>): move the matched task to needs-review
    /// (clear the waiting condition + <see cref="DelegationMeta"/>, keep the task eligible). NEVER
    /// auto-completes — clearing the condition only flips it to satisfied, which makes the task
    /// ELIGIBLE for next-task/needs-review presentation; it does not touch
    /// <see cref="TaskItem.Status"/> (Constitution II). Idempotent: a task with nothing unsatisfied
    /// to clear (already reviewed, or never delegated) is a no-op.
    /// </summary>
    /// <remarks>
    /// Uses <see cref="IOrchestratorTaskStore.ClearExternalCondition"/> scoped to
    /// <see cref="WaitingPrefix"/> — not "clear whichever external condition happened to be first"
    /// — so a hostile/errant signal can never flip a HUMAN-tracked gate (e.g. "waiting on legal")
    /// that happened to sort first. The <see cref="DelegationMeta"/> entry is only removed when a
    /// matching waiting-on-AI condition genuinely existed to clear — a signal that matches no real
    /// delegation must not blindly wipe scheduling state that was never touched.
    /// </remarks>
    public void MarkNeedsReview(Guid taskId)
    {
        var hadWaitingCondition = CurrentCondition(taskId, IsWaitingOnAI) is not null;
        _ = _store.ClearExternalCondition(WaitingPrefix, taskId);
        if (hadWaitingCondition)
        {
            _metaStore.Remove(taskId);
        }
    }

    /// <summary>
    /// Batch reconcile card content at natural touchpoints (popover open / evening): the waiting
    /// tasks the user should confirm are done/not. Independent of backoff stage — a batch-only
    /// (stage 2) delegation is exactly what this surfaces, since it stopped getting ambient
    /// check-backs.
    /// </summary>
    public IReadOnlyList<Guid> ReconcileBatch()
    {
        PruneOrphans();
        return _store.FetchAll()
            .Where(t => t.Status != TaskState.Done && t.Status != TaskState.Archived)
            .Where(t => t.Conditions.Any(IsWaitingOnAI))
            .Select(t => t.Id)
            .ToList();
    }

    /// <summary>
    /// Exposes a delegated task's cwd hint for <see cref="AppLinkHandler"/>'s cwd-based matching
    /// step (app-links.md's matching ladder, step 2). Not itself one of contract A's five listed
    /// methods, but required to implement that ladder without exposing the meta store (and its
    /// persistence detail) outside this file.
    /// </summary>
    public string? CwdHint(Guid taskId) => _metaStore.Get(taskId)?.CwdHint;

    /// <summary>
    /// Whether <paramref name="condition"/> is an unsatisfied "waiting on AI" delegation gate.
    /// Public (not private) so <see cref="AppLinkHandler"/> can reuse the exact same recognition
    /// rule when building its own waiting-task candidate list — a single definition avoids the two
    /// types drifting apart on what counts as "waiting".
    /// </summary>
    public static bool IsWaitingOnAI(Condition condition) =>
        condition is ExternalCondition { Satisfied: false } external && external.Description.StartsWith(WaitingPrefix, StringComparison.Ordinal);

    // MARK: - Internals

    private Condition? CurrentCondition(Guid taskId, Func<Condition, bool> predicate)
    {
        foreach (var item in _store.FetchAll())
        {
            if (item.Id != taskId)
            {
                continue;
            }
            return item.Conditions.FirstOrDefault(predicate);
        }
        return null;
    }

    /// <summary>
    /// Drops any meta-store entry whose task no longer exists in <see cref="IOrchestratorTaskStore"/>
    /// — keeps the local shadow copy from leaking scheduling state for a deleted task forever.
    /// </summary>
    private void PruneOrphans()
    {
        var liveIds = new HashSet<Guid>(_store.FetchAll().Select(t => t.Id));
        _metaStore.PruneKeys(liveIds);
    }
}
