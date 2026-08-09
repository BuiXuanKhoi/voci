# Contract: VolarCore v2 Public API

Consumers: the Volar app target only. Pure Swift, no dependencies, platform-agnostic.
Supersedes `specs/001-nexttask-engine/contracts/nexttask-api.md` where they overlap;
ordering semantics are inherited unchanged.

## Types

```swift
public struct Task: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var title: String
    public var status: TaskStatus            // .todo, .inProgress, .done, .archived
    public var priority: Int?                // 1...4, nil = unset
    public var deadline: Date?               // ordering + reminders only
    public var conditions: [Condition]       // eligibility only
    public var estimateMinutes: Int?
    public var parentId: UUID?
    public let createdAt: Date
}

public enum Condition: Sendable, Equatable {
    case taskDone(UUID)
    case afterDate(Date)
    case external(description: String, satisfied: Bool)
}

public enum DependencyError: Error, Equatable {
    case cycle(from: String, to: String)     // titles, human-readable message preserved
    case selfDependency(title: String)
}
```

## Functions (all pure — no I/O, no clock, no globals)

```swift
/// The single task to do next, or nil. Deterministic total order (001 tiers unchanged).
/// New in v2: eligibility honors conditions and parent-of-open-child exclusion.
/// == eligibleTasksOrdered(from:now:calendar:).first (literal implementation, not just an
/// agreed-upon invariant — see that function below).
public func nextTask(from snapshot: [Task], now: Date, calendar: Calendar) -> Task?

/// Strict total order over eligible tasks (unchanged tiers).
extension Task { public func orderedBefore(_ other: Task, now: Date, calendar: Calendar) -> Bool }

/// 006-cues-and-waiting (2026-08-09): every eligible task, ordered by the same total order
/// nextTask selects its winner from — for callers (e.g. a "waiting mode" holder) that need the
/// FULL ranking, not just the top pick. `nextTask` is defined in terms of this, so they cannot
/// diverge.
public func eligibleTasksOrdered(from snapshot: [Task], now: Date, calendar: Calendar) -> [Task]

/// 006-cues-and-waiting (2026-08-09): the unordered eligible set — same eligibility rule as
/// `nextTask`/`eligibleTasksOrdered`, membership only. Was package-internal; made public so app
/// code never has to hand-copy this rule to get at it.
public func eligibleTasks(in snapshot: [Task], now: Date) -> [Task]

/// Validates adding `condition` to task `id` within `snapshot`.
/// Throws only for .taskDone payloads that would create a cycle or self-reference.
public func validateCondition(adding condition: Condition,
                              to id: UUID,
                              in snapshot: [Task]) throws

/// Ids of tasks eligible in `after` but not in `before` (auto-unblock notifications).
public func eligibilityDiff(before: [Task], after: [Task], now: Date) -> [UUID]

/// Earliest strictly-future .afterDate in the snapshot (resurface scheduling), or nil.
public func nextResurfaceDate(in snapshot: [Task], after now: Date) -> Date?
```

## Behavioral guarantees (release-gated by tests)

1. Identical `(snapshot, now, calendar)` → identical results, regardless of array order.
2. `calendar` is an explicit, no-default input the caller supplies (app: `Calendar.current`;
   tests: a fixed calendar) — the engine never reads `Calendar.current` or any other global
   itself, so `nextTask`/`orderedBefore` stay pure/deterministic (Constitution Principle III)
   while still classifying "today" using the caller's real-world calendar/time zone.
3. A task with any unsatisfied condition is never returned by `nextTask`.
4. `.taskDone` resolution: done/archived/absent = satisfied; todo/inProgress = blocking.
5. A parent with ≥1 open child is never returned; its eligible child can be.
6. `validateCondition` never persists anything and never mutates inputs; rejection carries
   both task titles.
7. `eligibilityDiff` returns ids only for status/condition-driven changes — pure set logic.
8. Complexity: selection O(n log n); cycle check O(V+E); no allocation explosions at n=500.
9. (006-cues-and-waiting) `nextTask(from:now:calendar:) == eligibleTasksOrdered(from:now:calendar:)
   .first` for every `(snapshot, now, calendar)` — enforced by `nextTask` literally being
   implemented in terms of `eligibleTasksOrdered`, not merely tested to agree with it.

## Test suite contract (gate)

- All 001 §6.2 cases re-expressed with `conditions` (dependsOn → .taskDone) MUST pass unchanged.
- New required cases: afterDate future/past boundary (exact `now` equality = satisfied);
  external satisfied/unsatisfied; mixed-condition AND semantics; parent-exclusion;
  `eligibleTasksOrdered(...).first == nextTask(...)` on empty/single/mixed-condition-and-parent-
  child snapshots (`EligibleTasksOrderedTests.swift`);
  parent-cycle via parentId rejected at persistence (app-layer test); eligibilityDiff on
  complete/uncomplete; nextResurfaceDate with none/several future dates; determinism under
  shuffle at n=500.
