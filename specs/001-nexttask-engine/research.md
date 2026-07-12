# Phase 0 Research: nextTask() Selection Engine

All Technical Context items were resolved from the spec and source engineering doc; there are
no open `NEEDS CLARIFICATION` markers. This document records the design decisions and the
alternatives weighed.

## D1 — Pure value-type snapshot vs. operating on SwiftData `@Model`

- **Decision**: The engine operates on an immutable value type `Task` (a `struct`) passed in as
  `[Task]`. The app layer maps its SwiftData `@Model` objects into `Task` snapshots immediately
  before calling `nextTask()`.
- **Rationale**: Constitution Principle III requires `nextTask()` to be a pure function. SwiftData
  `@Model` classes are reference types with lazy faulting and implicit context/thread affinity —
  reading them can trigger I/O and is not reproducible. A value snapshot makes the function a
  deterministic function of its inputs and trivially unit-testable with hand-built fixtures.
- **Alternatives considered**:
  - *Operate directly on `@Model`*: rejected — couples the core to persistence, breaks purity,
    and makes deterministic tests fragile.
  - *Generic `protocol Schedulable`*: deferred — a protocol abstraction adds indirection with no
    current second conformer. Revisit only if a second task representation appears (YAGNI).

## D2 — Comparator shape: strict total order via first-difference tiers

- **Decision**: Implement `orderedBefore(now:) -> (Task, Task) -> Bool` as a first-difference-wins
  comparison over 5 tiers (status, today/overdue deadline, priority, createdAt, id). The final
  tier compares `id` (UUID) as a string, guaranteeing a **strict total order** over distinct
  tasks. Selection uses `eligible.min(by: orderedBefore(now:))`.
- **Rationale**: A strict total order is exactly the precondition `min(by:)` needs and is what
  makes output stable and reproducible regardless of input ordering (spec FR-004, FR-008, SC-001).
  `min(by:)` is O(n) and avoids the cost/instability of a full sort.
- **Alternatives considered**:
  - *`sorted(by:).first`*: rejected — O(n log n) and, if the comparator were only a partial order,
    Swift's sort is not guaranteed stable; the total-order tiebreak makes both approaches equal in
    result but `min(by:)` is cheaper and intention-revealing.
  - *Tuple/`Comparable` key extraction*: attractive but awkward because tier 2 depends on `now`
    (today/overdue is relative), so the comparator must be a closure capturing `now` rather than a
    static `Comparable` conformance.

## D3 — "Today / overdue" evaluation and timezone determinism

- **Decision**: Tier 2 classifies a deadline relative to the supplied `now`: **overdue** if
  `deadline < now`; **today** if `deadline` falls on the same local calendar day as `now`. Day-
  boundary math uses a `Calendar` that defaults to `Calendar.current` but is **injectable** for
  tests (e.g. `nextTask(from:now:calendar:)` with a default argument).
- **Rationale**: Source §4.1 stores instants in UTC and renders/evaluates in local time. Injecting
  the `Calendar` keeps the function deterministic under test (fixed timezone) while defaulting to
  the user's real calendar in production. Both `now` and `calendar` are inputs → still pure.
- **Alternatives considered**:
  - *Read `Calendar.current` internally with no injection*: rejected — makes "today" tests depend
    on the machine's timezone, undermining determinism.
  - *Pass a timezone instead of a Calendar*: rejected — `Calendar` already carries timezone plus
    day-boundary rules (incl. DST) needed by source §8.

## D4 — Deadline tiering semantics (test #7 guardrail)

- **Decision**: Only today-or-overdue deadlines participate in tier 2; a future (tomorrow+)
  deadline is treated as "no near-term deadline" for tiering and therefore does not outrank an
  explicit priority. Within tier 2, present deadlines sort earliest-first; tasks without a
  today/overdue deadline sort after those that have one.
- **Rationale**: Directly encodes spec FR-006 and §6.2 test #7 ("deadline tomorrow does NOT
  outrank priority today").

## D5 — Prerequisite resolution (eligibility)

- **Decision**: A task is eligible iff its status is `.todo`/`.inProgress` AND every prerequisite
  id is **resolved**. A prerequisite is resolved when the referenced task is `.done`, is
  `.archived`, or is absent from the snapshot (deleted). Resolution is computed via an
  `[UUID: TaskStatus]` map built once per call for O(1) lookups; a missing id is treated as
  resolved.
- **Rationale**: Encodes clarified FR-003/FR-013. Treating archived and deleted prerequisites as
  resolved prevents permanently stranding dependents (Session 2026-07-12 clarifications). The
  id→status map keeps eligibility O(n) overall.
- **Alternatives considered**:
  - *Only `.done` resolves (literal source snippet)*: rejected during `/speckit-clarify` — strands
    dependents when a prerequisite is archived.

## D6 — Dependency cycle detection

- **Decision**: Before persisting a new edge "source dependsOn target", run DFS from `target`
  over the existing `dependsOn` edges; if `source` is reachable, adding the edge would close a
  cycle → reject. Expose `func validateDependency(from:dependsOn:in:) throws` that throws
  `DependencyError.cycle` (carrying titles for a human-readable message) and a pure
  `func wouldCreateCycle(from:dependsOn:in:) -> Bool` used by tests. A self-edge
  (source == target) is a trivial cycle and is rejected.
- **Rationale**: Source §6.1 (DFS from new edge target, O(V+E), never persist a cycle) and spec
  FR-011/FR-012. Cycle checking happens at edge-creation time so `nextTask()` may assume an
  acyclic graph and never needs cycle handling in the hot path.
- **Alternatives considered**:
  - *Detect cycles lazily during selection*: rejected — would require the hot path to handle an
    invalid state the invariant forbids, and gives the user no actionable rejection message.

## D7 — Testing framework

- **Decision**: Use **Swift Testing** (`import Testing`, `@Test`, `#expect`, parameterized tests)
  as the primary framework; XCTest is an acceptable fallback if toolchain constraints require it.
- **Rationale**: Swift Testing is the modern default on the Xcode 26 / Swift 6 toolchain, and its
  parameterized `@Test(arguments:)` cases fit the tabular §6.2 scenarios cleanly. The engine's
  purity means no async/mocking machinery is needed.

## D8 — Priority representation

- **Decision**: `priority: Int?` on the 1…4 scale (1 highest); `nil` means unset and a dedicated
  helper sorts `nil` after every explicit value. No default numeric substitution.
- **Rationale**: Spec FR-007 and source §4.2 — absence of priority must not be treated as a number.
