# Phase 1 Data Model: Voci v2 — Workflow Command Center

Two layers, one direction of flow: the **persisted layer** (SwiftData, app target) maps into
the **engine layer** (pure value types, `VociCore`) at call time. The engine never sees
persistence; the app never re-implements eligibility.

## Engine layer (`VociCore` — pure, Sendable, Equatable)

### `Task` (value type — replaces the 001 shape)

| Field | Type | Notes / Rules |
|---|---|---|
| `id` | `UUID` | Stable identity; final ordering tiebreak (string form). |
| `title` | `String` | For messages (cycle rejection, disambiguation); not used in ordering. |
| `status` | `TaskStatus` | `.todo / .inProgress / .done / .archived` — unchanged from 001. |
| `priority` | `Int?` | 1…4 (1 highest), `nil` sorts last — unchanged. |
| `deadline` | `Date?` | Drives ORDERING tier 2 (near-term urgency) + reminders. Never gates eligibility. |
| `conditions` | `[Condition]` | Gates ELIGIBILITY. Replaces 001's `dependsOn`. AND semantics. |
| `estimateMinutes` | `Int?` | Not used by v2 ordering; read by app (quick-win, focus overlay). Carried in engine Task for the future `availableMinutes` mode. |
| `parentId` | `UUID?` | Breakdown child → parent. Engine rule: a task that is a parent of any open task is not directly selectable. |
| `createdAt` | `Date` | Ordering tier 4 — unchanged. |

### `Condition` (enum)

| Case | Payload | Satisfied when |
|---|---|---|
| `.taskDone` | `UUID` | Referenced task `.done` / `.archived` / absent from snapshot. Blocking while `.todo`/`.inProgress`. (Same resolution mapping as 001 FR-003.) |
| `.afterDate` | `Date` | `now >= date`. |
| `.external` | `description: String, satisfied: Bool` | `satisfied == true`. Engine never mutates it. |

**Eligibility**: `status ∈ {todo, inProgress}` ∧ all conditions satisfied ∧ not a parent of an
open child. **Ordering tiers unchanged from 001**: status class → deadline urgency (today/overdue
vs rest, relative to `now`) → priority → createdAt → id. Still a strict total order.

**Graph invariant**: `.taskDone` edges across the snapshot form a DAG. `validateCondition`
(replaces `validateDependency`) rejects self-reference and any cycle (DFS over `.taskDone`
edges only) with the same human-readable `DependencyError` as 001.

### Engine public API (delta vs 001)

- `nextTask(from:now:)` — signature unchanged; eligibility internals updated.
- `orderedBefore(now:)` — unchanged.
- `validateCondition(adding:to:in:) throws` — generalizes `validateDependency`; only
  `.taskDone` payloads can throw cycle/self errors, other condition kinds always pass.
- New pure helpers the app layer consumes (all side-effect-free):
  - `eligibilityDiff(before:after:now:) -> [UUID]` — tasks newly eligible after a snapshot
    change (feeds auto-unblock notifications, FR-015).
  - `nextResurfaceDate(in:after:) -> Date?` — earliest future `.afterDate` across the snapshot
    (feeds the resurface scheduler, FR-017).

## Persisted layer (SwiftData, app target)

### `VociTask` (@Model — extends existing `TaskItem` shape)

Engine fields above, plus:

| Field | Type | Notes |
|---|---|---|
| `notes` | `String?` | Free text. |
| `sourceTranscript` | `String?` | Verbatim utterance; always kept for voice-created tasks (FR-001). |
| `kind` | `TaskKind` (`.task/.review`) | UI treatment only. |
| `recurrence` | `Recurrence?` | Leaf tasks only — validation rejects on parents (edge case). |
| `reminderOverride` | `ReminderPolicy?` | `nil` → global default policy. |
| `resumeNote` | `String?` | "Save game" note, surfaced on re-entry (FR-042). |
| `switchAwayCount` | `Int` | Đổi-gió counter; ≥3 triggers one-time breakdown suggestion (FR-030). |
| `completedAt` | `Date?` | Latest completion instant (history lives in `CompletionEvent`). |
| `delegation` | `DelegationMeta?` | Present while delegated-to-AI (US4). |

### `Recurrence` (enum, Codable)

`daily · weekly · monthly · every(days: Int)`. Reset-in-place on completion: reopen; shift
`deadline` and every `.afterDate` payload to the next occurrence **anchored to the original
schedule**; reset `.external` to unsatisfied; append `CompletionEvent`. Completion-moment
override may re-anchor that one cycle to the completion date (FR-006). State machine:
`open → done(moment) → open(next occurrence)` — never terminal unless recurrence removed.

### `ReminderPolicy` (struct, Codable)

`offsets: [TimeInterval]` relative to deadline (default global: −86400, −3600, 0) ·
`repeatEvery: TimeInterval?` ("every 30 minutes"). Global default lives in settings;
per-task override on the task.

### `CompletionEvent` (@Model — immutable, append-only)

| Field | Type | Notes |
|---|---|---|
| `id` | `UUID` | |
| `taskId` | `UUID` | May dangle after task deletion — by design. |
| `titleSnapshot` | `String` | Display without joins. |
| `parentIdSnapshot` | `UUID?` | Rollup grouping even if parent later deleted. |
| `estimateSnapshot` | `Int?` | For time-review surfaces. |
| `completedAt` | `Date` | UTC instant. |

Source of truth for: accomplishment views (rollup rules FR-035), streaks (upward-only),
weekly narrative (FR-037). Event-shaped by design for v3 sync (user direction).

### `DelegationMeta` (struct on task, Codable)

`label: String` (what was delegated) · `checkBackAt: Date` · `backoffStage: Int` (0→10′,
1→30′, ≥2→batch-only) · `cwdHint: String?` (from signal, matches project folder) ·
`delegatedAt: Date`. Lifecycle: created on delegate → cleared when the external condition is
satisfied (signal or manual) → task becomes "needs review" (surfaced by eligibility).

### `ParseCorrection` (@Model — constitution V logging)

`attribute · parsedValue · correctedValue · transcript · createdAt`. Local-only, never egressed.

### Reminder scheduling records

`ReminderRecord` (@Model): `taskId · fireAt · offsetKind · state (scheduled/delivered/satisfied)`.
Rebuilt into `UNNotificationRequest`s on launch/wake; fire-time re-check loads task fresh
(constitution IV). Only nearest N pending system requests kept (64-request system cap).

## Parsing contract (`ParsedTask` — unchanged principle, extended shape)

`title` (required) + optional: `notes, deadline, estimateMinutes, priority, reminderOverride,
recurrence, conditions[] (taskDone by fuzzy title reference → resolved via picker if <0.7
confidence), kind, subtasks[] (breakdown), followUpReview: Bool`. Max 10 tasks per utterance
(FR-012). Every attribute carries a confidence; <0.7 renders as uncertain chip and is never
auto-committed (constitution II). Decode failure anywhere → title-only + transcript.

## Validation rules (enforced at persistence boundary)

1. `.taskDone` insertion → cycle/self check via `VociCore.validateCondition` (reject with
   human-readable message).
2. `recurrence != nil` ⇒ task has no children.
3. `parentId` must reference an existing task; parent cannot be its own descendant (cycle
   check over parent links).
4. Deleting a task: strip its id from every other task's `.taskDone` conditions AND null
   children's `parentId`; notify once if this flips a task's blocked state (001 backlog FR-013
   item — absorbed into this feature).
5. Completing last open child ⇒ auto-complete parent (append both events).
6. Max 10 tasks materialized per utterance/batch confirm.
