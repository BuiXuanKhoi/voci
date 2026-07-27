# VolarCore

The pure, dependency-free task-scheduling engine behind Volar's "what should I do right now"
menu-bar surface. Originally scoped by `specs/001-nexttask-engine/`; extended (not replaced) by
`specs/002-workflow-command-center/`, which is the current plan for the app that consumes this
package — see that plan's "Engine layer" section in `data-model.md` for the product-level
rationale behind the types below.

**Written on Windows, UNVERIFIED.** This entire package — including the change from 001's
`dependsOn: [UUID]` to the `Condition`-based model described below — was written without access to
a Swift/Xcode toolchain and has never been compiled or run. `swift test` has not actually been
executed against this code; treat the test suite as "written to the contract," not "known green,"
until it has run on a Mac.

## The one design rule: pure, deterministic, no I/O

Every public function in this package is a pure function of its arguments. Nothing here reads the
system clock, touches the filesystem or network, or mutates its inputs — `now` is always a `Date`
the caller passes in, and (see below) `calendar` is always a `Calendar` the caller passes in, never
`Date()` or `Calendar.current` read from inside the engine. For identical inputs, every function in
this package returns identical output, regardless of call order or the array order of a `[Task]`
snapshot. This is deliberate (Constitution Principle III, "Deterministic, Pure, Test-Gated Core"):
it's what makes the engine trivially unit-testable and safe to call from any thread, and it is the
reason the app layer's job is to translate its persisted model (e.g. a SwiftData `@Model`) into
these value types and call in — never the other way around.

## Public types

- **`Task`** (`Sendable`, `Equatable`, `Identifiable`) — a pure, immutable-shaped snapshot of a
  task: `id`, `title`, `status`, `priority: Int?` (1...4, 1 highest, `nil` = unset), `deadline:
  Date?` (absolute instant), `conditions: [Condition]`, `estimateMinutes: Int?`, `parentId: UUID?`,
  `createdAt`. This is intentionally a subset of the app's fully persisted task — only the fields
  eligibility/ordering/conflict-detection need.
- **`TaskStatus`** — `.todo`, `.inProgress`, `.done`, `.archived`. Only `.todo`/`.inProgress` are
  ever eligible for selection.
- **`Condition`** — an eligibility gate on a task; a task's `conditions` combine with AND semantics
  (see `Condition.swift`):
  - `.taskDone(UUID)` — satisfied once the referenced task is `.done`, `.archived`, or absent from
    the snapshot (deleted). Still-open (`.todo`/`.inProgress`) blocks.
  - `.afterDate(Date)` — satisfied once `now >= date` (equality counts).
  - `.external(description:satisfied:)` — an externally tracked gate the engine never flips itself;
    satisfied iff the caller already set `satisfied: true`.

  **This replaces 001's `dependsOn: [UUID]`.** The 001 contract (linked below) still documents the
  older `dependsOn` / `validateDependency` shape; the code today uses `conditions` /
  `validateCondition` instead, with `.taskDone` filling the role `dependsOn` used to. Where the two
  disagree, this README and the code are current; the 001 contract is the historical record of
  where the engine started.
- **`DependencyError`** (`Error`, `Equatable`) — `.cycle(from: String, to: String)` and
  `.selfDependency(title: String)`, thrown by `validateCondition`. Payloads carry human-readable
  titles (not raw ids) so the app can surface the error message directly.
- **`TaskConflict`** (`Sendable`, `Equatable`) — capture-time advisory signals returned by
  `conflicts(forAdding:into:now:calendar:busyIntervals:frogId:)` (added for feature 002, no 001
  equivalent): `.deadlineCapacity`, `.deadlineCollision`, `.dependsOnBlocked`, `.competesWithFrog`,
  `.possibleDuplicate`. These are purely advisory — the engine never blocks capture or
  auto-modifies anything because of them.

## Entry points

```swift
public func nextTask(from snapshot: [Task], now: Date, calendar: Calendar) -> Task?
```
The single task the menu bar should show right now, or `nil` if none is eligible. A task is
eligible when: its `status` is `.todo`/`.inProgress`, every one of its `conditions` is satisfied,
and it is not itself the `parentId` of some other still-open task (a breakdown parent is never
directly selectable while it has open children). Among eligible tasks, the result is the minimum
under `Task.orderedBefore(_:now:calendar:)`.

```swift
extension Task {
    public func orderedBefore(_ other: Task, now: Date, calendar: Calendar) -> Bool
}
```
The strict total order `nextTask` selects by: first-difference-wins across five tiers — (1)
in-progress before todo, (2) a today-or-overdue deadline before no near-term deadline (a deadline
further in the future does **not** grant this tier), (3) explicit priority ascending with `nil`
last, (4) earlier `createdAt`, (5) lexical `id.uuidString` as the final tiebreak that guarantees
totality. See the doc comment in `NextTask.swift` for the full tier-by-tier reasoning.

```swift
public func validateCondition(adding condition: Condition, to id: UUID, in snapshot: [Task]) throws
public func wouldCreateCycle(from source: UUID, dependsOn target: UUID, in snapshot: [Task]) -> Bool
```
Call `validateCondition` before persisting a new `.taskDone` condition: it throws
`.selfDependency` for a self-reference and `.cycle` if the edge would close a loop in the existing
`.taskDone` graph (only `.taskDone` conditions carry a graph edge — `.afterDate`/`.external` never
throw). `wouldCreateCycle` is the non-throwing predicate it's built on, exposed directly for
callers that just need a bool. Cycle detection happens at condition-creation time so `nextTask`'s
hot path can assume the `.taskDone` graph is already acyclic.

```swift
public func conflicts(
    forAdding candidate: Task, into snapshot: [Task], now: Date, calendar: Calendar,
    busyIntervals: [DateInterval], frogId: UUID?
) -> [TaskConflict]
```
Capture-time conflict detection (`ConflictCheck.swift`). Returns at most one `TaskConflict` per
case, in the fixed declaration order above; an empty array means a clean capture, which is meant to
be the common case — every threshold in the file is deliberately conservative low-noise.

```swift
public func eligibilityDiff(before: [Task], after: [Task], now: Date) -> [UUID]
public func nextResurfaceDate(in snapshot: [Task], after now: Date) -> Date?
```
`Snapshots.swift`'s two helpers for the app's notification layer: `eligibilityDiff` reports ids
that became newly eligible between two snapshots (feeds auto-unblock notifications), and
`nextResurfaceDate` finds the earliest still-future `.afterDate` anywhere in a snapshot (feeds the
resurface scheduler). Both reuse the same eligibility rule `nextTask` uses internally, so there is
exactly one place that rule lives.

## Why `calendar` is an explicit parameter, not `Calendar.current`

`nextTask` and `orderedBefore` take `calendar: Calendar` with **no default value** — every caller
must pass one explicitly. This is not incidental API design; it's a fix for a real bug. An earlier
version of this engine's "is this deadline today?" check (tier 2 of the ordering) resolved "today"
against a fixed/UTC-anchored calendar instead of the caller's local one. For a user in UTC+7, a
deadline set for this evening could fall on the *next* UTC calendar day, so the engine would
classify it as "no near-term deadline" and rank it below tasks that were actually less urgent —
silently wrong output for a big share of non-UTC users, and the kind of bug that's invisible in a
test suite that only exercises UTC. The fix is to make `calendar` caller-supplied data, exactly
like `now`: the app passes `Calendar.current` (the user's real calendar/timezone), tests pass a
fixed calendar for reproducibility, and the engine itself never reaches for a global — which keeps
`nextTask`/`orderedBefore` pure per the one design rule above, while letting "today" mean whatever
the caller's local day actually is.

## Running the tests

```sh
cd VolarCore
swift test
```

The suite lives in `Tests/VolarCoreTests/` (`EligibilityTests`, `NextTaskTests`,
`DependencyGraphTests`, `ConflictCheckTests`, `AutoAdvanceTests`, `SnapshotTests`, plus shared
`Fixtures.swift`) and is written to the contract below. As noted at the top of this file, it has
not been run yet — the toolchain to run it doesn't exist in this Windows dev environment.

## Contract

`specs/001-nexttask-engine/contracts/nexttask-api.md` is the original behavioral contract for the
selection API (`nextTask`, `orderedBefore`, dependency validation) and the 10-behavior acceptance
table the tests are gated on. It predates the `Condition`/`conflicts`/`parentId`/`estimateMinutes`
additions described above, which belong to `specs/002-workflow-command-center/` instead — read both
if you need the full history of how this package got to its current shape.
