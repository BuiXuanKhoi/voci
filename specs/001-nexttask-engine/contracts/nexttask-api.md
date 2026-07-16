# Contract: VolarCore selection API

Public surface of the `VolarCore` module for this feature. This is the behavioral contract the
implementation and tests are written against. Signatures are Swift; semantics are normative.

## Types

```swift
public struct Task: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var title: String
    public var status: TaskStatus
    public var priority: Int?        // 1...4, 1 highest; nil = unset
    public var deadline: Date?       // absolute (UTC)
    public var dependsOn: [UUID]
    public var createdAt: Date
    // memberwise init provided
}

public enum TaskStatus: Sendable, Equatable {
    case todo, inProgress, done, archived
}

public enum DependencyError: Error, Equatable {
    case cycle(from: String, to: String)   // titles, for a human-readable message
    case selfDependency(title: String)
}
```

## Selection

```swift
/// The single task the menu bar should display, or nil if none is eligible.
/// Pure: output depends only on (tasks, now, calendar). No I/O, no side effects.
public func nextTask(
    from tasks: [Task],
    now: Date,
    calendar: Calendar = .current
) -> Task?
```

**Contract**
- **C-S1 (eligibility)**: Only tasks with `status ∈ {.todo, .inProgress}` are considered.
- **C-S2 (blocking)**: A task is excluded while any `dependsOn` id is unresolved. An id is
  *resolved* when its task is `.done`, `.archived`, or absent from `tasks` (deleted).
- **C-S3 (ordering)**: Among eligible tasks, returns the minimum under the tiered order
  (status → today/overdue deadline → priority → createdAt → id-string). See `orderedBefore`.
- **C-S4 (determinism)**: For equal `(tasks, now, calendar)`, the result is identical across
  calls and independent of the order of elements in `tasks`.
- **C-S5 (empty)**: Returns `nil` when no task is eligible (empty input, all done/archived, or
  all blocked).

## Ordering comparator

```swift
/// Strict total order over tasks for a given reference time.
/// Returns true iff `a` should be selected before `b`.
public func orderedBefore(now: Date, calendar: Calendar = .current)
    -> (_ a: Task, _ b: Task) -> Bool
```

**Contract**
- **C-O1**: First-difference-wins across the 5 tiers in `data-model.md`.
- **C-O2 (total order)**: For any distinct `a`, `b`, exactly one of `less(a,b)`, `less(b,a)` is
  true; the relation is irreflexive, asymmetric, and transitive (the id-string tier guarantees
  distinctness). This makes it valid for `Array.min(by:)`.
- **C-O3 (deadline tiering)**: A future (beyond today) deadline does NOT grant tier-2 precedence;
  it ranks as "no near-term deadline" (encodes FR-006 / §6.2 test #7).
- **C-O4 (nil priority)**: `nil` priority ranks after every explicit 1…4.

## Dependency validation

```swift
/// Rejects an edge "source dependsOn target" that would break the DAG invariant.
/// Throws on self-dependency or when adding the edge would close a cycle.
/// Pure: inspects the current snapshot only; never mutates or persists.
public func validateDependency(
    from source: UUID,
    dependsOn target: UUID,
    in tasks: [Task]
) throws

/// Non-throwing predicate used by tests and callers that only need a bool.
public func wouldCreateCycle(
    from source: UUID,
    dependsOn target: UUID,
    in tasks: [Task]
) -> Bool
```

**Contract**
- **C-D1 (self)**: `source == target` → throws `.selfDependency`.
- **C-D2 (cycle)**: If `target` already reaches `source` through existing `dependsOn` edges
  (DFS from `target`), the new edge would close a cycle → throws `.cycle(from:to:)`; the caller
  MUST NOT persist it.
- **C-D3 (valid)**: Otherwise returns normally (no throw); the caller may persist the edge.
- **C-D4 (purity)**: Neither function reads the clock, performs I/O, nor mutates `tasks`.

## Behavioral acceptance mapping

The following behaviors (from spec §6.2 + clarifications) are the contract's release gate; see
`quickstart.md` for how to run them.

| # | Behavior | Contract refs |
|---|---|---|
| 1 | inProgress beats higher-priority todo | C-O1 (tier 1) |
| 2 | Overdue-deadline beats priority-1 no-deadline | C-O1 (tier 2) |
| 3 | Priority-1 blocked by unfinished dep skipped; unblocks on completion | C-S2, C-S3 |
| 4 | Two identical tasks → stable id tiebreak | C-O2 |
| 5 | Cycle insertion A→B→A rejected | C-D2 |
| 6 | Completing a task advances to the dependent task | C-S2, C-S4 |
| 7 | Deadline tomorrow does NOT outrank priority today | C-O3 |
| 8 | All-blocked graph → nil | C-S5 |
| 9 | Archived prerequisite unblocks its dependent | C-S2 |
| 10 | Multiple in-progress → single stable result | C-O2, C-S4 |
