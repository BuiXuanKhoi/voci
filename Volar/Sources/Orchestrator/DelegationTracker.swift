// Sources/Orchestrator/DelegationTracker.swift — AI-delegation lifecycle (US4,
// specs/002-workflow-command-center/contracts/phase6-contract.md §A +
// specs/002-workflow-command-center/contracts/app-links.md).
//
// A task is "delegated" when it carries an `.external("waiting on AI: <label>", satisfied:false)`
// condition (VolarCore.Condition, VolarCore/Sources/VolarCore/Condition.swift) plus a
// `DelegationMeta` (Volar/Sources/Model/Recurrence.swift: label, checkBackAt, backoffStage,
// cwdHint, delegatedAt).
//
// PERSISTENCE SEAM (self-review "conflict", flagged in this task's final report): `VolarTask`
// already has a `delegation: DelegationMeta?` computed property (Volar/Sources/Model/
// VolarTask.swift) and `TaskItem` mirrors it, but `TaskStore`'s PUBLIC surface
// (Volar/Sources/Model/TaskStore.swift) has no write path for it on an EXISTING task — only
// `add`/`addBatch` set `delegation` on a brand-new row; every other mutator (`addCondition`,
// `setRecurrence`, `setParent`, `toggle`, `clearFirstExternalCondition`, ...) is narrow and
// specific, and the field that would let a caller reach it (`ModelContext`/`fetchModel`) is
// `private` to that file. This task's scope is contractually limited to the two NEW Orchestrator
// files — Volar/Sources/Model/TaskStore.swift is not in the owned-files list for T039/T040, so it
// is not edited here. Given that constraint, this file treats the `.external` condition on
// `TaskStore` (via the already-public `addCondition`/`clearFirstExternalCondition`) as the single
// source of truth for "is this task delegated / has it been signaled done", and persists the
// scheduling metadata (checkBackAt/backoffStage/cwdHint/label/delegatedAt) itself, in
// `DelegationMetaStore` below — UserDefaults-backed (sandbox-safe, no extra entitlement) so it
// survives relaunch, satisfying the contract's "no in-memory-only delegation state" requirement
// without touching a file outside this task's ownership. `pruneOrphans()` keeps that store from
// drifting if a task is deleted out from under it. A follow-up `TaskStore.setDelegation(_:on:)` (or
// a generalized `TaskStore.update(_:)`) would let `VolarTask.delegation` become the single real
// store instead of this file's UserDefaults shadow copy — flagged for the integrating agent /
// backlog rather than implemented here, since it requires editing TaskStore.swift.
import Foundation
import VolarCore

/// Delegation lifecycle: mark-delegated, WIP count, check-back scheduling/backoff, and batch
/// reconciliation. All mutation happens through `TaskStore`'s existing public API — this class
/// owns no direct SwiftData/ModelContext access.
@MainActor
final class DelegationTracker {
    /// Fixed prefix contract A mandates for the waiting-condition description
    /// (`.external("waiting on AI: <label>", satisfied:false)`); also used to recognize a
    /// waiting-on-AI condition among a task's other `.external` conditions.
    static let waitingPrefix = "waiting on AI: "

    /// Stage thresholds (research.md R9): 0 -> 10' (set by `delegate`), 1 -> 30', 2+ -> batch-only
    /// (no more ambient timer resurfacing; still visible via `reconcileBatch()`).
    private static let batchOnlyStage = 2
    private static let secondBackoffMinutes: TimeInterval = 30

    private let store: TaskStore
    private let metaStore: DelegationMetaStore

    /// `defaults` is exposed (defaulted to `.standard`) purely so tests can inject an isolated
    /// suite, mirroring `TaskStore.init(inMemory:)`'s existing test-hygiene convention — the
    /// contract's `init(store:)` call shape is unaffected since this parameter is defaulted.
    init(store: TaskStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.metaStore = DelegationMetaStore(defaults: defaults)
    }

    /// Mark a task delegated: add the external waiting-condition + `DelegationMeta`, schedule the
    /// first minute-scale check-back (default 10'). Returns nothing; caller advances the menu bar.
    ///
    /// Guards against piling up a second `.external("waiting on AI: ...")` condition if the task
    /// is already delegated (re-delegating updates the existing schedule/label instead) — the
    /// contract models one delegation per task at a time (singular "a `DelegationMeta`").
    func delegate(taskId: UUID, label: String, checkBackMinutes: Int = 10, cwdHint: String?) {
        let now = Date()
        let alreadyWaiting = currentCondition(taskId: taskId, matching: Self.isWaitingOnAI) != nil
        if !alreadyWaiting {
            let description = Self.waitingPrefix + label
            // `.external` conditions never throw from `addCondition` (TaskStore.swift's own
            // documented guarantee 5) — `try?` rather than `try!`/force-try per this task's
            // "no force-unwrap" self-review requirement.
            try? store.addCondition(.external(description: description, satisfied: false), to: taskId)
        }
        let minutes = max(1, checkBackMinutes)
        let meta = DelegationMeta(
            label: label,
            checkBackAt: now.addingTimeInterval(TimeInterval(minutes) * 60),
            backoffStage: 0,
            cwdHint: cwdHint,
            delegatedAt: now
        )
        metaStore.set(meta, for: taskId)
    }

    /// Count of in-flight delegations (unsatisfied waiting-on-AI conditions) — drives the WIP
    /// badge. Derived live from `TaskStore` (not the local meta shadow) so it can never drift from
    /// what the rest of the app considers "delegated". O(n) over tasks, not per-frame — callers
    /// (menu-bar label refresh) are expected to call this on state-change ticks, not every draw.
    func wipCount() -> Int {
        store.fetchAll().reduce(into: 0) { count, item in
            guard item.status != .done, item.status != .archived else { return }
            if item.conditions.contains(where: Self.isWaitingOnAI) {
                count += 1
            }
        }
    }

    /// Tasks whose check-back is due now → resurface AMBIENTLY (menu-bar queue, NOT a
    /// notification). Backoff: 10' -> 30' -> batch-only (`backoffStage`). Called by a timer + on
    /// app foreground. Self-heals `metaStore` against tasks deleted since the last call. Ordered
    /// earliest-due-first (stable, no notion of urgency beyond that — the UI decides presentation).
    func dueForRecheck(now: Date = Date()) -> [UUID] {
        pruneOrphans()
        // WG2 (ship-blocker, reviewer fix): `metaStore` alone can't tell a completed/reviewed task
        // from one still genuinely in flight — every completion path (ambient [Done], NOW Done,
        // voice-done, sweep) completes the task via `store.toggle`/`store.delete` WITHOUT touching
        // this shadow store (only `markNeedsReview` removes a meta entry). Self-heal by
        // cross-checking against the SAME live-store predicate `wipCount()`/`reconcileBatch()`
        // already use — task exists in `store.fetchAll()`, `status != .done && status != .archived`,
        // and still carries an unsatisfied waiting-on-AI condition — so a completed task's stale
        // meta entry can never keep re-surfacing its check-in card. Also prunes the now-stale meta
        // for excluded ids so the shadow store self-cleans (same shape as `pruneOrphans()`'s
        // existing "task no longer exists" prune, one level stricter: "task exists but isn't
        // waiting anymore").
        let waitingIds = Set(
            store.fetchAll()
                .filter { $0.status != .done && $0.status != .archived }
                .filter { $0.conditions.contains(where: Self.isWaitingOnAI) }
                .map(\.id)
        )
        metaStore.pruneKeys(notIn: waitingIds)
        return metaStore.all()
            .filter { _, meta in meta.backoffStage < Self.batchOnlyStage && meta.checkBackAt <= now }
            .sorted { $0.value.checkBackAt < $1.value.checkBackAt }
            .map(\.key)
    }

    /// User ignored a recheck -> next stage. No-op for a task with no known delegation meta
    /// (already reviewed/never delegated — nothing to bump).
    func bumpBackoff(taskId: UUID) {
        guard var meta = metaStore.get(taskId) else { return }
        meta.backoffStage = min(meta.backoffStage + 1, Self.batchOnlyStage)
        meta.checkBackAt = meta.backoffStage >= Self.batchOnlyStage
            ? .distantFuture // batch-only: `dueForRecheck`'s stage filter already excludes it: this
                              // just keeps the stored instant from ever comparing "due" again.
            : Date().addingTimeInterval(Self.secondBackoffMinutes * 60)
        metaStore.set(meta, for: taskId)
    }

    /// Signal arrived (from `AppLinkHandler`): move the matched task to needs-review (clear the
    /// waiting condition + `DelegationMeta`, keep the task eligible). NEVER auto-completes —
    /// clearing the `.external` condition only flips it to `satisfied: true`, which makes the task
    /// ELIGIBLE for `nextTask()`/needs-review presentation; it does not touch `status`
    /// (Constitution II). Idempotent: a task with nothing unsatisfied to clear (already reviewed,
    /// or never delegated) is a no-op, matching `TaskStore.clearFirstExternalCondition`'s own
    /// documented no-op behavior for that case.
    func markNeedsReview(taskId: UUID) {
        _ = store.clearFirstExternalCondition(on: taskId)
        metaStore.remove(taskId)
    }

    /// Batch reconcile card content at natural touchpoints (popover open / evening): the waiting
    /// tasks the user should confirm are done/not. Independent of backoff stage — a batch-only
    /// (stage 2) delegation is exactly what this surfaces, since it stopped getting ambient
    /// check-backs.
    func reconcileBatch() -> [UUID] {
        pruneOrphans()
        return store.fetchAll()
            .filter { $0.status != .done && $0.status != .archived }
            .filter { $0.conditions.contains(where: Self.isWaitingOnAI) }
            .map(\.id)
    }

    /// Exposes a delegated task's cwd hint for `AppLinkHandler`'s cwd-based matching step
    /// (app-links.md's matching ladder, step 2). Not itself one of contract A's five listed
    /// methods, but required to implement that ladder without exposing `metaStore` (and its
    /// UserDefaults persistence detail, see file header) outside this file.
    func cwdHint(for taskId: UUID) -> String? {
        metaStore.get(taskId)?.cwdHint
    }

    /// Whether `condition` is an unsatisfied "waiting on AI" delegation gate. `internal` (not
    /// `private`) so `AppLinkHandler` can reuse the exact same recognition rule when building its
    /// own waiting-task candidate list — a single definition avoids the two files drifting apart
    /// on what counts as "waiting".
    static func isWaitingOnAI(_ condition: VolarCore.Condition) -> Bool {
        if case .external(let description, let satisfied) = condition {
            return !satisfied && description.hasPrefix(waitingPrefix)
        }
        return false
    }

    // MARK: - Internals

    private func currentCondition(
        taskId: UUID, matching predicate: (VolarCore.Condition) -> Bool
    ) -> VolarCore.Condition? {
        store.fetchAll().first { $0.id == taskId }?.conditions.first(where: predicate)
    }

    /// Drops any `metaStore` entry whose task no longer exists in `TaskStore` — keeps the local
    /// shadow copy (see file header) from leaking scheduling state for a deleted task forever.
    private func pruneOrphans() {
        let liveIds = Set(store.fetchAll().map(\.id))
        metaStore.pruneKeys(notIn: liveIds)
    }
}

// MARK: - DelegationMetaStore

/// Local, UserDefaults-backed persistence for `DelegationMeta` keyed by task id. See this file's
/// header comment for why this exists instead of writing through `VolarTask.delegation`. Not
/// `Sendable`/actor-isolated itself; safe here only because every access happens synchronously
/// from `DelegationTracker`, which is itself `@MainActor`-isolated.
private final class DelegationMetaStore {
    private let defaults: UserDefaults
    private let key = "app.volar.orchestrator.delegationMeta.v1"

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func get(_ id: UUID) -> DelegationMeta? {
        load()[id.uuidString]
    }

    func set(_ meta: DelegationMeta, for id: UUID) {
        var dict = load()
        dict[id.uuidString] = meta
        persist(dict)
    }

    func remove(_ id: UUID) {
        var dict = load()
        guard dict.removeValue(forKey: id.uuidString) != nil else { return }
        persist(dict)
    }

    /// All persisted entries, keyed by `UUID` (a stored key that fails to parse back to a `UUID` —
    /// which should never happen since only `set(_:for:)` ever writes one — is dropped rather than
    /// crashing; fails closed like every other JSON-blob read path in this codebase, e.g.
    /// `VolarTask.conditions`'s getter).
    func all() -> [UUID: DelegationMeta] {
        Dictionary(uniqueKeysWithValues: load().compactMap { key, value in
            UUID(uuidString: key).map { ($0, value) }
        })
    }

    func pruneKeys(notIn liveIds: Set<UUID>) {
        var dict = load()
        let before = dict.count
        dict = dict.filter { entry in
            guard let id = UUID(uuidString: entry.key) else { return false }
            return liveIds.contains(id)
        }
        if dict.count != before {
            persist(dict)
        }
    }

    private func load() -> [String: DelegationMeta] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: DelegationMeta].self, from: data)) ?? [:]
    }

    private func persist(_ dict: [String: DelegationMeta]) {
        guard let data = try? JSONEncoder().encode(dict) else { return }
        defaults.set(data, forKey: key)
    }
}
