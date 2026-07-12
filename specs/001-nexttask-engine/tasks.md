# Tasks: nextTask() Selection Engine

**Input**: Design documents from `/specs/001-nexttask-engine/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/nexttask-api.md, quickstart.md

**Tests**: REQUIRED for this feature. Constitution Principle III (Deterministic, Pure,
Test-Gated Core) and spec §6.2 make the test suite a **release gate** — tasks follow a
test-first flow: write the story's tests, watch them FAIL, then implement until green.

**Organization**: Grouped by user story (priority order) so each is an independently testable
increment. All paths are relative to repo root.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different file, no dependency on an incomplete task)
- **[Story]**: US1–US4, mapping to the spec's user stories

## Path Conventions

Single Swift package `VociCore/` at repo root (see plan.md → Project Structure):
`VociCore/Sources/VociCore/…`, `VociCore/Tests/VociCoreTests/…`.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Create the dependency-free Swift package skeleton.

- [ ] T001 Create the `VociCore` Swift package layout at repo root: `VociCore/Package.swift`, `VociCore/Sources/VociCore/`, `VociCore/Tests/VociCoreTests/`
- [ ] T002 Configure `VociCore/Package.swift`: `swift-tools-version:6.0`, `platforms: [.macOS(.v26)]`, a library target `VociCore` (no dependencies) and a test target `VociCoreTests` using Swift Testing

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The value model and test helpers every user story depends on.

**⚠️ CRITICAL**: No user-story work can begin until this phase is complete.

- [ ] T003 Implement the `Task` value type and `TaskStatus` enum in `VociCore/Sources/VociCore/Task.swift` per data-model.md (fields: `id`, `title`, `status`, `priority: Int?`, `deadline: Date?`, `dependsOn: [UUID]`, `createdAt`; conform `Sendable, Equatable, Identifiable`; public memberwise init)
- [ ] T004 Add deterministic test fixtures in `VociCore/Tests/VociCoreTests/Fixtures.swift`: a `makeTask(...)` builder with sensible defaults, a fixed reference `now`, and a fixed Gregorian `Calendar` (explicit timezone) so all tests are reproducible (depends on T003)

**Checkpoint**: Model + fixtures ready — user stories can begin.

---

## Phase 3: User Story 1 - The one task to do right now (Priority: P1) 🎯 MVP

**Goal**: A pure `nextTask(from:now:calendar:)` that returns the single correct task via the
5-tier total-order comparator, or `nil` when none is eligible (status-only eligibility).

**Independent Test**: Feed a fixed task set + reference time; assert the returned task matches
the tier rules and is identical across repeated/shuffled-input runs.

### Tests for User Story 1 (write first, ensure they FAIL) ⚠️

- [ ] T005 [US1] Write ordering & determinism tests in `VociCore/Tests/VociCoreTests/NextTaskTests.swift` covering §6.2 #1 (in-progress beats higher-priority to-do), #2 (overdue beats priority-1 no-deadline), #7 (deadline-tomorrow does NOT outrank priority-today), #4 (identical tasks → stable `id` tiebreak), FR-007 (a `nil`-priority task sorts AFTER an explicit priority-4 task), clarify #10 (multiple in-progress → single stable result), and empty/all-done input → `nil`; include an input-order-shuffle assertion for SC-001

### Implementation for User Story 1

- [ ] T006 [US1] Implement `orderedBefore(now:calendar:) -> (Task, Task) -> Bool` in `VociCore/Sources/VociCore/NextTask.swift` — first-difference-wins over the 5 tiers (status → today/overdue deadline → priority → createdAt → `id` string), with a `nil`-priority-last helper and a today/overdue classifier using the injected `calendar` (contract C-O1..C-O4)
- [ ] T007 [US1] Implement `nextTask(from:now:calendar: .current) -> Task?` in `VociCore/Sources/VociCore/NextTask.swift` using status-only eligibility (`.todo`/`.inProgress`) and `eligible.min(by: orderedBefore(now:calendar:))` (contract C-S1, C-S3, C-S5; depends on T006)
- [ ] T008 [US1] Run T005 tests; make all pass, hardening the comparator's strict-total-order guarantees (irreflexive/asymmetric/transitive) so `min(by:)` is well-defined (depends on T007)

**Checkpoint**: US1 fully functional — deterministic single-task selection works standalone (MVP).

---

## Phase 4: User Story 2 - Auto-advance on completion (Priority: P1)

**Goal**: Marking the active task done makes the next call to `nextTask()` return the next
correct task. At engine level this is re-invocation after a status change; the menu-bar
recompute/animation is app-side and out of scope for `VociCore`.

**Independent Test**: Given a set where the active task is now `.done`, assert `nextTask()`
returns the next eligible task; when it was the only eligible task, assert `nil`.

### Tests for User Story 2 (write first, ensure they FAIL/PASS as noted) ⚠️

- [ ] T009 [US2] Write auto-advance tests in `VociCore/Tests/VociCoreTests/AutoAdvanceTests.swift` — completing the active task (flip status to `.done`) yields the next correct `nextTask()`; sole-eligible task completed → `nil` (US2 acceptance scenarios 1 & 3)

### Implementation for User Story 2

- [ ] T010 [US2] Confirm US2 needs no new engine code (re-invoking `nextTask()` already excludes `.done`); add a doc comment in `VociCore/Sources/VociCore/NextTask.swift` noting recompute/transition is the app's responsibility, and make T009 green (depends on T007)

**Checkpoint**: US1 + US2 both pass independently.

---

## Phase 5: User Story 3 - Dependency-aware eligibility (Priority: P2)

**Goal**: A task is skipped while any prerequisite is unresolved, and becomes eligible once all
prerequisites are resolved (done / archived / deleted).

**Independent Test**: A task depending on an unfinished task is never selected; marking the
prerequisite `.done` (or `.archived`, or deleting it) lets the dependent be selected.

### Tests for User Story 3 (write first, ensure they FAIL) ⚠️

- [ ] T011 [US3] Write eligibility tests in `VociCore/Tests/VociCoreTests/EligibilityTests.swift` covering §6.2 #3 (priority-1 blocked by unfinished dep skipped; unblocks when dep `.done`), #6 (completing a task cascades → dependent becomes the new `nextTask()`), #8 (all-blocked graph → `nil`), clarify #9 (archived prerequisite unblocks), and deleted-prerequisite unblocks

### Implementation for User Story 3

- [ ] T012 [US3] Extend eligibility in `VociCore/Sources/VociCore/NextTask.swift`: build a `[UUID: TaskStatus]` map once per call; treat a prerequisite as resolved when its task is `.done`, `.archived`, or absent (deleted); a task is eligible only if ALL `dependsOn` are resolved (contract C-S2; FR-003/FR-013; depends on T007)
- [ ] T013 [US3] Run T011 tests; make all pass and confirm US1/US2 tests still green (depends on T012)

**Checkpoint**: US1 + US2 + US3 pass independently.

---

## Phase 6: User Story 4 - Reject dependency cycles (Priority: P3)

**Goal**: Adding a dependency edge that would close a cycle (or a self-edge) is rejected with a
human-readable error and never persisted; the selection hot path may assume a DAG.

**Independent Test**: Add A→B, then attempt B→A → rejected; attempt a self-edge → rejected; a
valid non-closing edge → accepted.

### Tests for User Story 4 (write first, ensure they FAIL) ⚠️

- [ ] T014 [US4] Write cycle-detection tests in `VociCore/Tests/VociCoreTests/DependencyGraphTests.swift` covering §6.2 #5 (A→B then B→A rejected), a longer chain A→B→C then C→A rejected, self-dependency rejected, and a valid edge accepted (no throw)

### Implementation for User Story 4

- [ ] T015 [US4] Implement `DependencyError` and `validateDependency(from:dependsOn:in:) throws` + `wouldCreateCycle(from:dependsOn:in:) -> Bool` in `VociCore/Sources/VociCore/DependencyGraph.swift` — reject self-edge (`.selfDependency`); DFS from `target` over existing `dependsOn` edges, and if `source` is reachable throw `.cycle(from:to:)` carrying titles (contract C-D1..C-D4; FR-011/FR-012)
- [ ] T016 [US4] Run T014 tests; make all pass (depends on T015)

**Checkpoint**: All four user stories independently functional.

---

## Phase 7: Polish & Cross-Cutting Concerns

**Purpose**: Validate the full release gate and document the public surface.

- [ ] T017 [P] Run the full suite (`cd VociCore && swift test`) and confirm all 10 release-gate scenarios in quickstart.md are green; run twice to spot-check determinism (SC-001)
- [ ] T018 [P] Document the `VociCore` public API in `VociCore/README.md`, linking to `specs/001-nexttask-engine/contracts/nexttask-api.md`
- [ ] T019 Integration note: when the Voci app target exists, add `VociCore` as a package dependency and mark the call site where SwiftData `@Model` objects are mapped to `Task` snapshots before `nextTask()` (mapping implementation is a separate feature)

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: no dependencies.
- **Foundational (Phase 2)**: depends on Setup; BLOCKS all user stories.
- **User Stories (Phase 3–6)**: all depend on Foundational. US1 is the MVP.
- **Polish (Phase 7)**: depends on the desired user stories being complete.

### User Story Dependencies

- **US1 (P1)**: after Foundational. Establishes `orderedBefore` + `nextTask` — the base others build on.
- **US2 (P1)**: after US1 (reuses `nextTask`; no new engine logic).
- **US3 (P2)**: after US1 (extends the eligibility predicate in `NextTask.swift`). Independent test file.
- **US4 (P3)**: after Foundational; independent of US1–US3 (separate file `DependencyGraph.swift`) — could be built in parallel with US1–US3.

### Within Each User Story

- Test task first (write, ensure FAIL) → implementation → run/green.
- US1 and US3 both edit `NextTask.swift`, so they are **sequential** (US1 before US3), not parallel.

### Parallel Opportunities

- **US4 is fully parallelizable** with US1/US2/US3: it only touches `DependencyGraph.swift` +
  `DependencyGraphTests.swift`. A second developer can do T014→T016 while another does US1–US3.
- Polish T017 and T018 are `[P]` (different targets: test run vs README).
- Note: tests within a single story share one test file, so they are authored as one task
  (not internally parallel) to avoid same-file conflicts.

---

## Parallel Example

```bash
# After Foundational (T001–T004), two tracks can run concurrently:
# Track A (selection):   T005 → T006 → T007 → T008  (US1) → T009 → T010 (US2) → T011 → T012 → T013 (US3)
# Track B (dep graph):   T014 → T015 → T016         (US4, independent file)
```

---

## Implementation Strategy

### MVP First (User Story 1 only)

1. Phase 1 Setup → 2. Phase 2 Foundational → 3. Phase 3 US1 → **STOP & VALIDATE**: deterministic
   single-task selection passes its tests. This is a demoable MVP for the menu bar.

### Incremental Delivery

1. Setup + Foundational → foundation ready.
2. US1 → deterministic selection (MVP). 3. US2 → auto-advance. 4. US3 → dependency blocking.
5. US4 → cycle safety. Each increment keeps prior tests green.

### Constitution gate

The build is not shippable until T017 confirms all 10 §6.2 + clarification scenarios pass
(Principle III release gate).

---

## Notes

- `[P]` = different file, no incomplete dependency. `[Story]` = traceability to spec user stories.
- Verify each story's tests FAIL before implementing it (test-first, per constitution).
- Commit after each task or logical group.
- Avoid: marking same-file tasks `[P]`, cross-story dependencies that break independence.

## Task Summary

- **Total tasks**: 19 (T001–T019)
- **Setup**: 2 · **Foundational**: 2 · **US1**: 4 · **US2**: 2 · **US3**: 3 · **US4**: 3 · **Polish**: 3
- **MVP scope**: T001–T008 (Setup + Foundational + US1)
- **Parallel**: US4 (T014–T016) alongside US1–US3; polish T017/T018
