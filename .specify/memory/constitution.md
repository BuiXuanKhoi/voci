<!--
SYNC IMPACT REPORT
Version change: (template, unversioned) → 1.0.0
Bump rationale: Initial ratification — first concrete constitution replacing the
unfilled template. MAJOR baseline set to 1.0.0.

Modified principles: All five template placeholders defined for the first time:
  [PRINCIPLE_1] → I. On-Device Privacy First (NON-NEGOTIABLE)
  [PRINCIPLE_2] → II. Never Silently Guess — Confirmable Intelligence
  [PRINCIPLE_3] → III. Deterministic, Pure, Test-Gated Core (NON-NEGOTIABLE)
  [PRINCIPLE_4] → IV. Reliable Reminder Delivery
  [PRINCIPLE_5] → V. ADHD-First, Glance-and-Dismiss UX

Added sections:
  - Technology & Model Constraints (was [SECTION_2])
  - Development Workflow & Quality Gates (was [SECTION_3])
  - Governance (filled)

Removed sections: none.

Templates requiring updates:
  ✅ .specify/templates/plan-template.md — Constitution Check gate references
     this file generically; no hard-coded principle names to change.
  ✅ .specify/templates/spec-template.md — no constitution-specific tokens; aligned.
  ✅ .specify/templates/tasks-template.md — task categories cover test-first and
     recovery work; aligned with Principle III & IV.
  ✅ .specify/templates/commands/*.md — none reference outdated principle names.

Follow-up TODOs: none. RATIFICATION_DATE set to first adoption on 2026-07-12.
-->

# Voci Constitution

Voci is a voice-first, ADHD-first task manager for macOS. This constitution governs the
voice → task intelligence layer and every artifact built on top of it. It is authoritative:
where this document and any other practice conflict, this document wins.

## Core Principles

### I. On-Device Privacy First (NON-NEGOTIABLE)

Voice audio MUST NEVER leave the user's Mac. In the default configuration both the ASR
workload (speech → text) and the intent-parsing workload (text → schema) run fully
on-device. The marketing and privacy-policy promise — *"Your voice never leaves your Mac"* —
MUST remain literally true at all times.

- Raw audio MUST NOT be transmitted, uploaded, logged off-device, or cached in any
  network-reachable store under any code path.
- The ONLY data permitted to leave the device is transcript **text**, and ONLY on the
  cloud AI-Breakdown / cloud-parser path, and ONLY when the user has the AI Pro tier AND
  has explicitly opted in. Absent both conditions, no text leaves the device.
- Every new feature that touches audio, transcripts, or model calls MUST document its data
  egress in review; a feature with undocumented egress MUST NOT merge.

Rationale: Privacy is the product's core trust promise for a deeply personal input
(the user's voice). One leak breaks the promise permanently.

### II. Never Silently Guess — Confirmable Intelligence

The system MUST NOT act on an inferred attribute the user has not been given a chance to
confirm. Parsing is assistive, never authoritative.

- Every parsed attribute (deadline, reminder, priority, dependency) MUST be surfaced as a
  one-click-confirmable chip before it takes effect.
- Any field with confidence `< 0.7` MUST render as an "uncertain" chip (dashed border, `?`)
  and MUST NOT be silently committed — most critically, a dependency below 0.7 MUST NOT be
  auto-attached; the UI MUST show a picker instead.
- Raw LLM output MUST NEVER be executed or persisted. It MUST be decoded into the validated
  `ParsedTask` (Codable). Any decode/schema violation MUST fall back to a title-only task
  carrying the raw transcript, with a subtle "couldn't parse details" hint — never a silent
  failure and never a crash.
- A parsing error on one attribute MUST NOT discard the others.

Rationale: Wrong-but-confident automation erodes trust faster than doing less. Glanceable
confirmation keeps the user in control while preserving speed.

### III. Deterministic, Pure, Test-Gated Core (NON-NEGOTIABLE)

`nextTask()` and its ordering (`orderedBefore`) are the brain of the single-task menu bar.
They MUST be pure functions: no I/O, no side effects, output determined solely by inputs.

- Ordering MUST be a total order with a stable UUID tiebreak so output is deterministic for
  identical inputs.
- `dependsOn` edges MUST form a DAG. Every edge insertion MUST run cycle detection; a cycle
  MUST be rejected with a human-readable message and MUST NEVER be persisted.
- The minimum `nextTask()` unit-test suite (spec §6.2, all 8 cases) is a **release gate**:
  it MUST pass before any build ships. This is the most-tested code in the app.

Rationale: The auto-advance, no-list, no-decision moment is the core differentiator; it is
only trustworthy if the selection logic is provably deterministic and exhaustively tested.

### IV. Reliable Reminder Delivery

A reminder that should fire MUST fire. Missed reminders are treated as a critical bug class
for this audience, not a cosmetic defect.

- Reminders MUST persist durably (SwiftData/SQLite) and the scheduler heap MUST be rebuilt
  from storage on every launch — no reminder may exist only in memory.
- At fire time the task MUST be reloaded fresh from storage; an `.ifIncomplete` reminder on
  an already-done/archived task MUST resolve to `.satisfied` with no notification.
- Sleep/wake, app-not-running, and restart recovery MUST re-evaluate overdue `.scheduled`
  reminders and fire immediately if still due. These recovery paths MUST be covered by
  automated tests.
- Completion, deletion, and dependency-target deletion MUST cascade correctly (satisfy
  reminders, cancel nags, strip `dependsOn` references) with no orphaned state.

Rationale: The escalation ladder is the product for ADHD users; a reminder that silently
vanishes defeats the entire reason the app exists.

### V. ADHD-First, Glance-and-Dismiss UX

The interface MUST minimize decisions and cognitive load. The menu bar shows exactly **one**
active task; the app auto-advances on completion rather than presenting a list to choose from.

- The post-capture confirm step MUST be glance-and-dismiss (chips + `Enter` to save),
  NEVER a multi-field form.
- No flow may reintroduce decision paralysis (task lists to pick from, mandatory
  multi-step wizards) in place of the single-task / auto-next model.
- Every user correction (`attribute`, `parsed_value`, `corrected_value`, `transcript`) MUST
  be logged locally as the dataset for improving parsing — without violating Principle I.

Rationale: The target user's constraint is executive function, not feature count. Every
removed decision is a feature.

## Technology & Model Constraints

- **Platform**: macOS 26+ on Apple Silicon; Swift / SwiftUI; a persistent menu-bar process.
- **ASR (default)**: on-device `SpeechAnalyzer` / `SpeechTranscriber`; fallback WhisperKit
  (`small`/`medium`) for macOS < 26 or unsupported hardware.
- **Intent parsing (default)**: Apple Foundation Models (on-device ~3B) with `@Generable`
  guided generation so output is schema-constrained by construction. Fallback: a bundled
  small instruct model via MLX with grammar-constrained JSON, shipped as an optional
  ~2GB download, NOT in the base bundle.
- **Cloud (upgrade only)**: AI Breakdown and cloud parsing run on a cloud API (Claude/GPT),
  gated to the AI Pro tier and subject to Principle I. Intent parsing MUST sit behind an
  `IntentParsing` protocol with distinct `LocalFoundationModelParser` and `CloudParser`
  implementations; local is the default route.
- All dates MUST be stored in UTC and rendered in local timezone; fire times are absolute
  instants unaffected by timezone/DST changes (compute via `Calendar` with explicit zone).

## Development Workflow & Quality Gates

- **Test-first on the core**: `nextTask()`/ordering (§6.2) and reminder recovery paths
  (§5.4) MUST have their tests written and passing before the corresponding feature is
  considered done. These are non-negotiable gates, not optional coverage.
- **Ship the smallest correct slice**: implement the smallest version of spec §2–§7 that
  passes the §6.2 suite before adding scope. YAGNI applies; v1 non-goals (voice editing,
  recurring/RRULE, cross-device sync, Windows port, location reminders) MUST stay out of v1.
- **Deferred work is tracked**: any postponed item, TODO, edge case, or tech debt MUST be
  recorded in `backlog.md` at the project root in the same session it is discovered.
- **Review compliance**: every change MUST be checked against these principles. A change
  that violates a principle MUST either be revised or justified in the plan's Complexity
  Tracking table before merge.

## Governance

This constitution supersedes all other development practices for Voci. Compliance is
expected in every plan, spec, task set, and code review.

- **Amendments** require: a written rationale, a version bump per the policy below, update
  of the Sync Impact Report at the top of this file, and propagation to any dependent
  templates (`plan`, `spec`, `tasks`, command docs).
- **Versioning policy** (semantic):
  - **MAJOR**: backward-incompatible governance change or removal/redefinition of a
    principle.
  - **MINOR**: a new principle/section added, or materially expanded guidance.
  - **PATCH**: clarifications, wording, or non-semantic refinements.
- **Compliance review**: PRs and design reviews MUST verify adherence to the NON-NEGOTIABLE
  principles (I, III) explicitly. Complexity that deviates from a principle MUST be
  justified in the plan's Complexity Tracking table or the change is rejected.
- **Runtime guidance**: agent and contributor runtime guidance lives in `CLAUDE.md` and the
  spec at `docs/voci-voice-task-engine-spec.md`; those documents MUST NOT contradict this
  constitution.

**Version**: 1.0.0 | **Ratified**: 2026-07-12 | **Last Amended**: 2026-07-12
