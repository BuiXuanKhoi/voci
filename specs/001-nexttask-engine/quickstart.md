# Quickstart: nextTask() Selection Engine

A validation guide to prove the engine works end-to-end. Implementation code lives in
`tasks.md` / the implementation phase — this file only shows how to build, run, and confirm.

## Prerequisites

- macOS with the Xcode 26 / Swift 6 toolchain (`swift --version` → 6.x).
- The `VolarCore` Swift package present at repo root (see `plan.md` → Project Structure).

## Build & test

From the package directory:

```bash
cd VolarCore
swift build
swift test                     # runs the full VolarCore suite
swift test --filter NextTask   # just the selection cases, while iterating
```

Or from Xcode: open the workspace, select the `VolarCore` scheme, `⌘U`.

## Success criteria (release gate)

The build passes and **all** of the following behavioral tests are green. These map 1:1 to the
contract table in `contracts/nexttask-api.md` and spec §6.2 + the 2026-07-12 clarifications:

| # | Test intent | Expected result |
|---|---|---|
| 1 | An in-progress task vs a higher-priority to-do task | in-progress task selected |
| 2 | Overdue-deadline task vs priority-1 task with no deadline | overdue task selected |
| 3 | Priority-1 task blocked by an unfinished prerequisite | blocked task skipped; becomes selected after the prerequisite is marked `.done` |
| 4 | Two tasks identical on all tiers | same task returned every run (id-string tiebreak) |
| 5 | Add edge A→B then attempt B→A | `validateDependency` throws `.cycle`; nothing persisted |
| 6 | Complete the current task that blocked another | dependent becomes the new `nextTask()` |
| 7 | Deadline-tomorrow task vs priority-today task | priority task selected (tomorrow does not outrank) |
| 8 | Every task blocked by an unfinished prerequisite | `nextTask()` returns `nil` |
| 9 | Sole prerequisite becomes `.archived` (not done) | dependent unblocks and can be selected |
| 10 | Two in-progress tasks | one deterministic, stable task returned (never a flip-flop) |

Determinism spot-check (SC-001): run `swift test` twice and/or shuffle fixture input order in a
test — the selected task MUST be identical.

## Manual smoke (optional, in a scratch executable or REPL)

```swift
import VolarCore
import Foundation

let now = Date(timeIntervalSince1970: 1_752_300_000)  // fixed reference time for reproducibility
let cal = Calendar(identifier: .gregorian)            // inject a fixed calendar in tests

let a = Task(id: UUID(), title: "Báo cáo Q3", status: .inProgress,
             priority: 3, deadline: nil, dependsOn: [], createdAt: now)
let b = Task(id: UUID(), title: "Viết slide", status: .todo,
             priority: 1, deadline: nil, dependsOn: [], createdAt: now)

print(nextTask(from: [a, b], now: now, calendar: cal)?.title as Any)  // -> "Báo cáo Q3" (tier 1)
```

## What this does NOT cover

- Persistence, SwiftData `@Model` → `Task` snapshot mapping (separate feature).
- Voice capture, parsing, reminder engine, menu-bar UI / auto-advance animation.
- These consume `nextTask()` but are validated by their own specs.
