import Foundation

/// A single eligibility gate on a `Task`. A task's `conditions` combine with AND semantics: the
/// task is eligible only once *every* condition is satisfied (see `NextTask.swift`). Unlike
/// `deadline`, conditions never influence ordering — only eligibility.
public enum Condition: Sendable, Equatable {
    /// Satisfied when the referenced task is `.done`, `.archived`, or absent from the snapshot
    /// entirely (deleted). Blocking while the referenced task is `.todo`/`.inProgress`. Same
    /// resolution mapping as 001 FR-003 — see `TaskStatus`'s doc comment.
    case taskDone(UUID)

    /// Satisfied when `now >= date` — exact equality counts as satisfied, not just strictly
    /// later instants.
    case afterDate(Date)

    /// An externally-tracked condition (e.g. "waiting on a delegated reply"). The engine never
    /// mutates `satisfied` itself; it is satisfied iff the caller has already flipped it.
    case external(description: String, satisfied: Bool)
}

extension Condition {
    /// Whether this condition currently holds, given a precomputed `id -> status` lookup over
    /// the snapshot and the reference instant `now`. Pure: no I/O, no clock reads.
    ///
    /// `public` (specs/009-light-mode-list-v2/design.md): the UI layer needs to answer this exact
    /// question too (`TaskRow`'s blocked/waiting chip, §5.6.3) — keeping this `internal` would
    /// force a second hand-copied implementation outside the engine, which is precisely how
    /// `AppState.eligibleOrder` drifted from `eligibleTasks` once before (backlog.md). One
    /// definition, two callers.
    public func isSatisfied(statusByID: [UUID: TaskStatus], now: Date) -> Bool {
        switch self {
        case .taskDone(let id):
            guard let status = statusByID[id] else {
                // Absent from the snapshot: deleted, therefore satisfied.
                return true
            }
            return status == .done || status == .archived
        case .afterDate(let date):
            return now >= date
        case .external(_, let satisfied):
            return satisfied
        }
    }
}
