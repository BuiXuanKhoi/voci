# Feature Specification: nextTask() Selection Engine

**Feature Branch**: `001-nexttask-engine`

**Created**: 2026-07-12

**Status**: Draft

**Input**: User description: "nextTask() engine — deterministic task selector (pure function) powering the single-task menu bar for the Voci macOS app. Source: docs/voci-voice-task-engine-spec.md §3, §6, §6.1, §6.2."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - The one task to do right now (Priority: P1)

A user with many captured tasks opens the app. Instead of a list to scan and choose from,
the menu bar shows **exactly one** task — the single thing the system has determined they
should work on next. The choice is made by a fixed set of rules, so the same set of tasks
always yields the same "next" task, with no randomness and no ambiguity.

**Why this priority**: This is the product's core promise — remove decision paralysis by
never presenting a choice. Without a correct, stable single-task selection there is no
product. Everything else builds on it.

**Independent Test**: Provide a fixed collection of tasks and a reference time; confirm the
engine returns one specific task, and that repeating the call with the same inputs always
returns that same task.

**Acceptance Scenarios**:

1. **Given** several eligible tasks with different priorities and deadlines, **When** the
   next task is requested, **Then** exactly one task is returned according to the ordering
   rules, and never a list.
2. **Given** a task the user already started (in progress) and a higher-priority not-started
   task, **When** the next task is requested, **Then** the in-progress task is chosen (the
   user is not yanked off work they began).
3. **Given** a task whose deadline is today or already overdue and a priority-1 task with no
   deadline, **When** the next task is requested, **Then** the overdue/today task is chosen.
4. **Given** a task whose deadline is tomorrow and a priority-1 task due-less for today,
   **When** the next task is requested, **Then** the deadline-tomorrow task does NOT outrank
   the priority-1 task (only today/overdue deadlines get deadline priority).
5. **Given** two otherwise identical tasks, **When** the next task is requested repeatedly,
   **Then** the same one is returned every time (stable, total-order tiebreak).
6. **Given** no eligible tasks exist, **When** the next task is requested, **Then** nothing
   is returned and the menu bar shows an "add a task" empty state.

---

### User Story 2 - Auto-advance on completion (Priority: P1)

The user finishes the active task and marks it done. The menu bar immediately advances to
the next task the rules select, with a brief "Next: …" transition. The user never returns to
a list or has to choose what to do next — the flow keeps them moving one task at a time.

**Why this priority**: The auto-next moment is a core differentiator. Completing a task and
being handed the next one — with no list, no choosing — is the experience the product sells.

**Independent Test**: Start with a known set of tasks, mark the current active task done, and
confirm the engine now returns the correct next task per the ordering rules.

**Acceptance Scenarios**:

1. **Given** an active task and other eligible tasks, **When** the active task is marked
   done, **Then** the engine recomputes and returns the next correct task.
2. **Given** a task blocked only by the task that was just completed, **When** that
   completion happens, **Then** the previously blocked task becomes eligible and can be the
   new selected task.
3. **Given** the just-completed task was the only eligible task, **When** it is marked done,
   **Then** the engine returns nothing and the empty state is shown.

---

### User Story 3 - Dependency-aware eligibility (Priority: P2)

A user captures a task that should only happen after another task is finished ("do this after
the report is done"). Until every prerequisite is complete, that task is never surfaced as the
next task. Once the last prerequisite is done, it becomes eligible automatically.

**Why this priority**: Surfacing a task the user cannot yet act on breaks trust in the
single-task model. Blocking keeps the surfaced task always actionable.

**Independent Test**: Create a task depending on an unfinished task; confirm it is never
selected. Mark the prerequisite done; confirm the dependent task can now be selected.

**Acceptance Scenarios**:

1. **Given** a priority-1 task that depends on an unfinished task, **When** the next task is
   requested, **Then** the blocked task is skipped in favor of an eligible one.
2. **Given** a task with multiple prerequisites where some are still open, **When** the next
   task is requested, **Then** the task remains blocked until ALL prerequisites are done.
3. **Given** every task in the set is blocked by an unfinished prerequisite, **When** the
   next task is requested, **Then** nothing is returned (empty state).
4. **Given** a task that depends on another task which is later deleted, **When** the next
   task is requested, **Then** the deleted prerequisite is treated as satisfied (it no longer
   blocks) and the user is notified once about the change.

---

### User Story 4 - Reject dependency cycles (Priority: P3)

A user tries to make task A wait on task B when B already waits on A (directly or through a
chain). The system refuses to create that relationship and explains why in plain language,
so the task graph can never reach a state where nothing is ever eligible.

**Why this priority**: A cycle would make selection undefined and could strand the user with
no actionable task. It is a correctness safeguard rather than a daily-use feature, hence P3,
but it must never be skipped.

**Independent Test**: Attempt to add a dependency edge that closes a loop; confirm it is
rejected with a human-readable message and the relationship is not saved.

**Acceptance Scenarios**:

1. **Given** task A already depends on task B, **When** the user tries to make B depend on A,
   **Then** the edge is rejected with a readable message and no dependency is stored.
2. **Given** a longer chain A → B → C, **When** the user tries to make C depend on A,
   **Then** the cycle is detected and rejected.
3. **Given** a valid new dependency that does not close a loop, **When** it is added, **Then**
   it is accepted and stored.

---

### Edge Cases

- **Empty task set**: No tasks at all → nothing selected, empty state shown.
- **All tasks done/archived**: No eligible tasks → nothing selected.
- **All eligible tasks blocked**: Every candidate has an unfinished prerequisite → nothing
  selected.
- **Identical tasks**: Two tasks equal on every ordering dimension → resolved by a stable
  total-order tiebreak so output never flickers between runs.
- **Deadline in the past (overdue)**: Treated in the today/overdue tier, earliest first.
- **Deadline in the future beyond today**: Does not receive deadline precedence; sorts as if
  it had no near-term deadline for tier purposes.
- **Deleted prerequisite**: Its id is removed from every dependent's prerequisite list and
  treated as satisfied; user notified once.
- **Mixed unset attributes**: Tasks with no priority sort after all explicitly prioritized
  tasks; tasks with no near-term deadline sort after today/overdue ones within their tier.

## Requirements *(mandatory)*

### Functional Requirements

#### Selection & eligibility

- **FR-001**: The engine MUST return at most one task (the "next task") for a given set of
  tasks and a given reference time, or nothing when no task is eligible.
- **FR-002**: A task MUST be considered eligible only if its status is "to do" or
  "in progress" (tasks that are done or archived are never eligible).
- **FR-003**: A task MUST be excluded from selection if any of its prerequisites is not yet
  done; it becomes eligible only when ALL prerequisites are done.
- **FR-004**: Selection MUST be a pure computation: the same tasks and the same reference
  time MUST always produce the same result, with no side effects and no dependence on
  external state, ordering of input, or randomness.

#### Deterministic ordering (first difference wins)

- **FR-005**: Among eligible tasks, ordering MUST apply the following tiers in order, using
  the first tier that distinguishes two tasks:
  1. In-progress tasks rank before to-do tasks.
  2. Tasks whose deadline is today or overdue rank next, earliest deadline first; tasks with
     no today/overdue deadline rank after these within this tier.
  3. Explicit priority ascending (1 is highest); tasks with no priority rank after priority 4.
  4. Earlier creation time first.
  5. A stable total-order identifier tiebreak (e.g. lexical order of the task id).
- **FR-006**: A deadline in the future beyond today MUST NOT grant deadline precedence; only
  today or overdue deadlines participate in the deadline tier.
- **FR-007**: Tasks with no explicit priority MUST sort after every task that has an explicit
  priority (1–4); the absence of a priority MUST NOT be treated as a numeric value.
- **FR-008**: The ordering MUST be a total order so that any two distinct tasks always have a
  defined relative order, guaranteeing a single stable result.

#### Auto-advance

- **FR-009**: When the active task is marked done, the engine MUST recompute selection and
  surface the newly selected next task.
- **FR-010**: Completing a task MUST cause any task blocked solely by it to become eligible
  in the recomputed selection.

#### Dependency graph integrity

- **FR-011**: Prerequisite relationships MUST form a directed acyclic graph; the system MUST
  detect and reject any new relationship that would create a cycle.
- **FR-012**: A rejected cyclic relationship MUST NOT be stored, and the user MUST receive a
  human-readable explanation of why it was rejected.
- **FR-013**: When a task is deleted, its identifier MUST be removed from every other task's
  prerequisite list and treated as satisfied, and the user MUST be notified once when this
  changes a task's blocked state.

#### Empty state

- **FR-014**: When no eligible task exists (no tasks, all done/archived, or all blocked), the
  engine MUST return nothing so the menu bar can present an "add a task" state.

### Key Entities *(include if feature involves data)*

- **Task**: A unit of work. Attributes relevant to selection: a unique identifier; a status
  (to do / in progress / done / archived); an optional explicit priority (1 highest … 4);
  an optional deadline; a set of prerequisite task identifiers that must all be done before it
  is eligible; and a creation timestamp. Other attributes (title, reminders, transcript) exist
  but do not affect selection.
- **Selection result**: The single chosen task, or "none", for a given set of tasks at a given
  reference time.
- **Dependency edge**: A "this task waits on that task" relationship between two tasks; the set
  of all edges must remain acyclic.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: For any fixed set of tasks and reference time, repeated selections return the
  identical task 100% of the time (fully deterministic, zero variance across runs and across
  input orderings).
- **SC-002**: All eight mandatory selection scenarios from the source specification (§6.2) are
  covered by automated tests and pass: in-progress beats higher-priority to-do; overdue beats
  priority-1 no-deadline; blocked priority-1 is skipped and unblocks on completion; identical
  tasks resolve via stable tiebreak; cycle insertion is rejected; completing a task advances to
  the dependent task; deadline-tomorrow does not outrank priority-today; all-blocked returns
  none.
- **SC-003**: The user is never shown more than one task to choose from at the selection point;
  the surfaced task is always immediately actionable (never blocked by an unfinished
  prerequisite).
- **SC-004**: Completing the active task advances to the next correct task without the user
  making any additional choice.
- **SC-005**: No dependency cycle can ever be stored; 100% of cycle-forming relationship
  attempts are rejected with an explanatory message.
- **SC-006**: Selection feels instant to the user (no perceptible delay) for a realistic
  personal task list.

## Assumptions

- "Today" and "overdue" are evaluated against the provided reference time using the user's
  local calendar day; a deadline is "today" if it falls on the same local calendar date as the
  reference time, and "overdue" if it is strictly before the reference time.
- The engine receives the full current set of tasks and a reference time as inputs; it does not
  read storage or the clock itself (callers supply the reference time), which is what makes it
  deterministic and testable.
- Priority is an integer scale 1 (highest) through 4; "no priority" is a distinct unset state,
  not a number.
- Cycle detection runs at the moment a dependency relationship is created/edited, not during
  selection; by the time selection runs the graph is already guaranteed acyclic.
- Auto-advance and the "Next: …" transition are user-facing behaviors driven by re-invoking the
  selection after a state change; the visual transition styling is out of scope for this engine
  spec.
- Notifying the user "once" about a deleted prerequisite is handled by the surrounding app; this
  spec only requires that the deleted prerequisite stops blocking and the relationship is
  cleaned up.
- Persistence, voice capture, parsing, and the reminder engine are separate features; this spec
  covers only eligibility, ordering, auto-advance recomputation, and dependency-graph integrity.
