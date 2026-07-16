# Implementation Plan: nextTask() Selection Engine

**Branch**: `001-nexttask-engine` | **Date**: 2026-07-12 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/001-nexttask-engine/spec.md`

## Summary

Implement the deterministic `nextTask()` selection engine that powers Volar's single-task
menu bar. Given an immutable snapshot of tasks and a reference time, it returns the one task
the user should do next — or `nil` — via a pure, side-effect-free, total-order comparator.
The engine also owns dependency-graph integrity: it validates every new dependency edge and
rejects any that would create a cycle. The technical approach isolates this logic in a
standalone, dependency-free Swift package module (`VolarCore`) so it can be exhaustively unit
tested independently of SwiftUI, SwiftData, and the clock — directly satisfying constitution
Principle III (Deterministic, Pure, Test-Gated Core).

## Technical Context

**Language/Version**: Swift 6.x (strict concurrency), targeting the macOS 26 / Xcode 26 toolchain

**Primary Dependencies**: None beyond the Swift standard library and Foundation (`UUID`,
`Date`, `Calendar`). No SwiftUI, no SwiftData, no third-party packages in this module.

**Storage**: N/A for the engine. It operates on an in-memory value-type snapshot (`[Task]`)
supplied by the caller. Persistence (SwiftData/SQLite → `Task` snapshot mapping) is a separate
feature and out of scope here.

**Testing**: Swift Testing (`import Testing`, `@Test`/`#expect`) as the primary framework;
XCTest acceptable as fallback. The §6.2 suite plus the two clarified cases (archived
prerequisite, multiple in-progress) are the release gate.

**Target Platform**: macOS 26+ on Apple Silicon. The engine itself is platform-agnostic pure
Swift and will build/test on any Swift 6 toolchain.

**Project Type**: Single desktop app; this feature is an internal library module (`VolarCore`)
consumed by the app target.

**Performance Goals**: Selection completes in well under 1 ms for a realistic personal task
list (hundreds of active tasks). Complexity: eligibility + sort is O(n log n); dependency
resolution lookups use an id→status map for O(1) access; cycle detection is O(V+E) DFS.

**Constraints**: Pure function (no I/O, no global clock read, no randomness); output determined
solely by inputs; comparator MUST be a strict total order so results are stable and reproducible
across runs and input orderings.

**Scale/Scope**: Single-user personal task manager; expected low hundreds of active tasks,
tiny dependency graph. No concurrency inside the engine (it is a synchronous pure function).

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Applicability | Assessment |
|---|---|---|
| I. On-Device Privacy First (NON-NEGOTIABLE) | Trivially satisfied | Pure in-memory computation; no audio, no network, no persistence, zero data egress. |
| II. Never Silently Guess | Partial | Engine performs no inference/guessing. Dependency-cycle rejection surfaces a human-readable message (never silently drops or auto-resolves). PASS. |
| III. Deterministic, Pure, Test-Gated Core (NON-NEGOTIABLE) | Directly implements | This feature IS the principle: `nextTask()`/`orderedBefore` pure + total order; DAG invariant with cycle rejection; §6.2 suite is the release gate. PASS by design. |
| IV. Reliable Reminder Delivery | Not applicable | Reminder engine is a separate feature; the selection engine holds no reminder state. |
| V. ADHD-First, Glance-and-Dismiss UX | Satisfied | Returns a single `Task?` (never a list); enables auto-advance by design. No UX regression introduced. |

**Result**: PASS — no violations. Complexity Tracking table below is empty (nothing to justify).

**Post-design re-check (after Phase 1)**: The chosen design — a dependency-free `VolarCore`
package, value-type `Task` snapshot, and an injectable `Calendar` — strengthens Principle III
(purity/determinism/testability) and introduces no new violations. Gate remains PASS.

## Project Structure

### Documentation (this feature)

```text
specs/001-nexttask-engine/
├── plan.md              # This file (/speckit-plan output)
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output
│   └── nexttask-api.md   # Public API + behavioral contract for VolarCore
└── spec.md              # Feature specification (from /speckit-specify + /speckit-clarify)
```

### Source Code (repository root)

The pure selection logic lives in a standalone Swift package module, decoupled from the app's
UI and persistence layers so it stays testable and side-effect-free (Principle III). The macOS
app target depends on `VolarCore`.

```text
VolarCore/                         # Swift package: pure domain logic (no UI, no persistence)
├── Package.swift
├── Sources/
│   └── VolarCore/
│       ├── Task.swift            # Task value type, TaskStatus, TaskPriority helpers
│       ├── NextTask.swift        # nextTask(from:now:) + orderedBefore(now:)
│       └── DependencyGraph.swift # validateDependency / wouldCreateCycle (DFS)
└── Tests/
    └── VolarCoreTests/
        ├── NextTaskTests.swift        # §6.2 cases #1,2,4,7,8 + multiple-in-progress
        ├── EligibilityTests.swift     # §6.2 cases #3,6 + archived/deleted prerequisite
        └── DependencyGraphTests.swift # §6.2 case #5 (cycle rejection) + valid-edge accept

Volar/                             # Existing macOS app target (SwiftUI + SwiftData)
└── ...                           # Consumes VolarCore; maps @Model -> Task snapshot before calling nextTask
```

**Structure Decision**: Introduce a dependency-free `VolarCore` Swift package holding the value
type `Task` and the pure engine. The app maps its SwiftData `@Model` objects into `Task`
snapshots at call time. This keeps `nextTask()` a pure function of its inputs — the precondition
for the exhaustive, deterministic test suite the constitution mandates — and prevents SwiftUI /
SwiftData / clock access from leaking into the core.

## Complexity Tracking

> No constitution violations. No complexity to justify.

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| — | — | — |
