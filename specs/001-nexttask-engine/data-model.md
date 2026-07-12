# Phase 1 Data Model: nextTask() Selection Engine

Scope: only the value types the pure engine reads. The full persisted `Task` (with reminders,
transcript, completedAt, etc. from source §3) is a superset owned by the persistence feature;
this module needs the selection-relevant subset. Fields below are the engine's contract.

## Entity: `Task` (value type — `struct`, `Sendable`, `Equatable`, `Identifiable`)

| Field | Type | Notes / Rules |
|---|---|---|
| `id` | `UUID` | Stable unique identity. Final tiebreak uses its string form for a total order. |
| `title` | `String` | Carried for messages (e.g. cycle rejection); not used by ordering. |
| `status` | `TaskStatus` | Drives eligibility and tier 1. |
| `priority` | `Int?` | 1…4 (1 highest); `nil` = unset. `nil` sorts after all explicit values (FR-007). |
| `deadline` | `Date?` | Absolute instant (UTC). Tier 2 uses it relative to `now` (D3/D4). `nil` = no deadline. |
| `dependsOn` | `[UUID]` | Prerequisite ids; ALL must be resolved for eligibility (FR-003). |
| `createdAt` | `Date` | Tier 4 tiebreak: earlier first. |

**Validation / invariants**
- `priority`, when non-nil, is expected in 1…4. Values outside the range are tolerated by
  ordering (compared numerically) but are an upstream data error; the engine does not reject them.
- `dependsOn` MUST NOT contain `id` itself (self-dependency) — enforced by dependency validation
  (D6), not by `nextTask()`.
- The set of all `dependsOn` edges across tasks MUST be acyclic — enforced at edge-creation time
  (D6). `nextTask()` assumes this invariant holds.

## Enum: `TaskStatus`

`case todo` · `case inProgress` · `case done` · `case archived`

**Eligibility mapping**
- Eligible for selection: `.todo`, `.inProgress`.
- Not eligible: `.done`, `.archived`.

**Prerequisite-resolution mapping** (a prerequisite counts as resolved when):
- referenced task is `.done`, OR
- referenced task is `.archived`, OR
- referenced id is absent from the snapshot (deleted).
- Still blocking: referenced task is `.todo` or `.inProgress`.

## Ordering key (derived, not stored)

`orderedBefore(now:)` compares two eligible tasks tier by tier; first differing tier decides:

| Tier | Key | Rule |
|---|---|---|
| 1 | status class | `.inProgress` (0) before `.todo` (1). |
| 2 | deadline urgency | Tasks with a today/overdue deadline (relative to `now`) rank before those without; among them, earlier `deadline` first. Future deadlines are treated as "no near-term deadline". |
| 3 | priority | Ascending; `nil` sorts after 4 (i.e. after every explicit priority). |
| 4 | `createdAt` | Earlier first. |
| 5 | `id` (string) | Lexical order — guarantees a strict total order. |

Result of the whole engine: `Task?` (the single minimum under this order), or `nil` when no
task is eligible.

## Error type: `DependencyError`

| Case | Payload | Meaning |
|---|---|---|
| `cycle` | `from: String, to: String` (titles) | Adding "from dependsOn to" would close a cycle; carries titles so the app can render a message like *"'A' đang chờ 'B' — không thể để 'B' chờ ngược lại 'A'."* |
| `selfDependency` | `title: String` | A task cannot depend on itself. |

## Notes on relationships

- `dependsOn` forms a directed graph over `Task.id`; the invariant is that it is a DAG.
- No other entity is required by this feature. `Reminder`, `sourceTranscript`, `completedAt`,
  and the persistence schema are out of scope and intentionally excluded from the engine's `Task`.
