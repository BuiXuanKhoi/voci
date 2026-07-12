# Voci — Voice Task Engine Specification

**Version:** 1.0 · **Target:** macOS 26+ (Apple Silicon), Swift / SwiftUI
**Scope:** Voice capture → structured task parsing (schedule, priority, dependency) → conditional reminder engine → next-task selection.
**Audience:** AI coding agent implementing inside the existing Voci codebase.

---

## 1. Product context

Voci is a voice-first, ADHD-first task manager for macOS. Global hotkey `⌃⌥Space` opens quick capture; the menu bar shows exactly **one** active task. This spec covers the voice → task intelligence layer:

1. Parse natural speech (Vietnamese + English) into a structured task.
2. Support **deadlines**, **conditional reminders** ("remind me at 10 if not done"), **priorities**, and **dependencies** ("do this after X").
3. A **reminder engine** that checks task state at fire time and escalates until done.
4. A deterministic **`nextTask()`** selector that powers the single-task menu bar and auto-advances when a task completes.

Design principles: never silently guess; every parsed attribute is confirmable in one click; the selection logic is a pure, unit-tested function; all voice audio stays on device.

---

## 2. Voice pipeline

```
Hotkey ⌃⌥Space
  → Record (max 60s, VAD auto-stop after 1.5s silence)
  → ASR (on-device: SpeechAnalyzer/SpeechTranscriber; fallback WhisperKit)
  → Intent parser (LLM, structured output — see §4 and §9)
  → ParsedTask (validated via Codable; reject on schema violation)
  → Confirm chips UI (§7)
  → Persist (SwiftData/SQLite) → schedule reminders (§5) → recompute nextTask (§6)
```

- ASR language: auto-detect between `vi-VN` and `en-US`; user can pin a language in Settings.
- If ASR confidence is low or transcript is empty → show transcript editor instead of failing silently.
- **Never execute or persist raw LLM output.** Decode into `ParsedTask` (Codable). Any decode failure → fall back to "title-only task" with the raw transcript as title, and surface a subtle "couldn't parse details" hint.

---

## 3. Task schema

```swift
struct Task: Codable, Identifiable {
    let id: UUID
    var title: String
    var status: TaskStatus            // .todo, .inProgress, .done, .archived
    var priority: Int?                // 1 (highest) ... 4, nil = unset
    var deadline: Date?               // hard cut-off ("trước 10h" / "before 10")
    var dependsOn: [UUID]             // must all be .done before this task is eligible
    var reminders: [Reminder]
    var createdAt: Date
    var completedAt: Date?
    var sourceTranscript: String?     // original voice transcript, for debugging/correction analytics
}

struct Reminder: Codable, Identifiable {
    let id: UUID
    var fireAt: Date
    var condition: ReminderCondition  // .always, .ifIncomplete
    var escalation: EscalationPolicy  // .none, .nag(interval: TimeInterval)  e.g. nag every 15 min
    var state: ReminderState          // .scheduled, .fired, .snoozed(until: Date), .cancelled, .satisfied
}
```

### LLM output schema (what the parser must return)

```json
{
  "title": "Viết slide demo",
  "priority": 1,
  "deadline": "2026-07-12T10:00:00+07:00",
  "reminders": [
    { "time": "2026-07-12T10:00:00+07:00", "condition": "if_incomplete", "escalation": "nag_15m" }
  ],
  "depends_on": { "ref_text": "task báo cáo", "resolved_task_id": "UUID-or-null" },
  "confidence": { "deadline": 0.92, "depends_on": 0.4 }
}
```

Rules:
- All fields except `title` are optional/nullable.
- `deadline` ≠ reminder. "trước 10h" / "by 10" → `deadline`. "nhắc lúc 10h" / "remind me at 10" → `reminders[]`. "nhắc lúc 10h nếu chưa xong" → reminder with `condition: if_incomplete`. The parser prompt MUST include contrastive examples of these three.
- Confidence per field. Any field with confidence `< 0.7` renders as an "uncertain" chip (§7).

---

## 4. Intent parsing rules

### 4.1 Time resolution
- Relative phrases resolve against device local time and timezone at parse time.
- Bare hour ("10h", "at 10"): if that time today is already past → next occurrence (tomorrow). Vietnamese "10h" may mean 10:00 or 22:00 → default 10:00, but if 10:00 is past and 22:00 is upcoming today, prefer 22:00; always show the resolved time as a chip.
- "sáng/chiều/tối" (morning/afternoon/evening) map: sáng=09:00, chiều=15:00, tối=20:00 unless an explicit hour is given.
- Store all dates in UTC; render in local timezone. On system timezone change, re-render only (fire times stay absolute).

### 4.2 Priority
- "ưu tiên số 1 / số một", "priority 1", "top priority", "quan trọng nhất" → `priority: 1`.
- "quan trọng" without a number → `priority: 2`.
- No mention → `priority: nil` (do NOT default to a number; nil sorts after explicit priorities).

### 4.3 Dependency ("làm sau khi xong X" / "after X is done")
- The parser receives, in its context, a candidate list of up to 20 most-recent non-done tasks: `[{id, title}]`.
- It must pick `resolved_task_id` from that list only. If no candidate clears confidence 0.7 → `resolved_task_id: null` and the UI shows a picker chip: `Sau khi xong: [Báo cáo Q3?] ▾`.
- **Never silently attach a dependency the user didn't confirm when confidence < 0.7.**

### 4.4 Multi-attribute utterances
One utterance may contain title + deadline + priority + dependency + reminder. Parse all; each becomes its own chip. Parsing errors on one attribute must not discard the others.

---

## 5. Conditional reminder engine

### 5.1 Why not plain `UNUserNotificationCenter`
Static scheduled notifications can't check task state at fire time. Voci runs a persistent menu bar process → use an internal scheduler.

### 5.2 Architecture
- `ReminderScheduler` (actor): maintains a min-heap of upcoming `fireAt` instants; one `DispatchSourceTimer`/`Task.sleep` armed for the earliest.
- All reminders persist in SwiftData/SQLite; the heap is rebuilt from storage on every launch.
- At fire time:
  1. Reload the task from storage (fresh state).
  2. `condition == .ifIncomplete` and task is `.done`/`.archived` → mark reminder `.satisfied`, no notification.
  3. Otherwise fire (see escalation) and mark `.fired`.

### 5.3 Escalation ladder (`nag` policy)
```
t0        : local notification (UNUserNotificationCenter, actually delivered now)
t0 + 15m  : menu bar item pulses (subtle animation) + repeat notification
t0 + 30m  : focus popup — small floating window, always-on-top, two buttons: [Done] [Snooze 15m]
repeat every `interval` until: task done, reminder snoozed, or user dismisses for the day
```
- Snooze sets `state = .snoozed(until:)` and re-inserts into the heap.
- Rationale: single fire-and-forget notifications get reflex-dismissed by ADHD users; the ladder is the product.

### 5.4 Sleep / wake / restart recovery
- On wake (`NSWorkspace.didWakeNotification`) and on app launch: scan storage for reminders with `fireAt < now` and `state == .scheduled` → evaluate condition NOW and fire immediately if still due. Missed reminders are a critical bug class for this audience; cover with tests.
- On task completion: mark all its `.ifIncomplete` reminders `.satisfied` and cancel pending nags.
- On task deletion: cascade-cancel its reminders; remove its id from every other task's `dependsOn`.

---

## 6. `nextTask()` — deterministic selection

Pure function. No I/O, no side effects. This is the brain of the single-task menu bar; it must be the most-tested code in the app.

```swift
/// Returns the task the menu bar should display, or nil if none eligible.
func nextTask(from tasks: [Task], now: Date) -> Task? {
    let eligible = tasks.filter { task in
        task.status == .todo || task.status == .inProgress
    }.filter { task in
        // blocked if any dependency is not done
        task.dependsOn.allSatisfy { depId in
            tasks.first(where: { $0.id == depId })?.status == .done
        }
    }
    return eligible.min(by: orderedBefore(now: now))
}
```

Deterministic ordering (`orderedBefore`), first difference wins:
1. `.inProgress` before `.todo` (don't yank a task the user already started).
2. Deadline due **today or overdue**, earliest first (nil deadlines last in this tier).
3. Explicit priority ascending (nil after 4).
4. Earlier `createdAt`.
5. UUID lexical order (total-order tiebreak → stable output).

On task completion: recompute and **auto-advance** the menu bar to the new `nextTask()` with a brief transition ("Next: …"). This auto-next moment is a core differentiator — no list, no choosing, no decision paralysis.

### 6.1 Dependency graph invariants
- `dependsOn` edges form a DAG. On every edge insertion run cycle detection (DFS from the new edge's target; graph is tiny, O(V+E) is fine).
- Cycle detected → reject the edge with a human-readable message ("'A' đang chờ 'B' — không thể để 'B' chờ ngược lại 'A'."). Never persist a cycle.

### 6.2 Required unit tests (minimum)
1. inProgress task beats higher-priority todo.
2. Overdue-deadline task beats priority-1 task with no deadline.
3. Priority-1 task blocked by an unfinished dependency is skipped; unblocks when dependency completes.
4. Two identical tasks → stable order via UUID tiebreak.
5. Cycle insertion A→B→A rejected.
6. Completing a task cascades: dependent task becomes the new nextTask.
7. Deadline tomorrow does NOT outrank priority today (only today/overdue enters tier 2).
8. All-blocked graph → returns nil (menu bar shows "Add a task" state).

---

## 7. Confirm chips UI

After parsing, the capture window shows the title plus one chip per extracted attribute:

```
Viết slide demo
[⏰ Deadline: 10:00 hôm nay ✎] [🔔 Nhắc 10:00 nếu chưa xong ✎] [🔥 P1 ✎] [⛓ Sau: Báo cáo Q3 ▾]
[Enter = Save]        [Esc = Discard]
```

- One click/tap on a chip opens an inline editor; `Enter` saves everything as shown. The whole confirm step must be glance-and-dismiss, never a form.
- Low-confidence chips render with a dashed border and `?`.
- Log every user correction (`attribute`, `parsed_value`, `corrected_value`, `transcript`) locally — this is the dataset for improving prompts and deciding when local parsing is good enough.

---

## 8. Edge cases checklist

| Case | Behavior |
|---|---|
| Machine asleep past fireAt | Fire on wake if condition still holds (§5.4) |
| App not running at fireAt | Rebuild heap on launch; fire missed reminders immediately |
| Timezone change mid-flight | Absolute instants unchanged; re-render local times |
| Task deleted with pending reminders | Cascade cancel; strip from other tasks' `dependsOn` |
| Dependency target deleted | Treat as satisfied; notify user once |
| Utterance with only a time, no task ("nhắc tôi lúc 3h") | Create task titled from remaining words or prompt for title |
| Two reminders same instant | Coalesce into one notification listing both |
| `deadline` in the past at creation | Chip renders red "đã quá hạn?" — user confirms or edits |
| DST transitions | Store UTC; compute fireAt via `Calendar` with explicit timezone |

---

## 9. Model strategy — local first, API as upgrade

Two AI workloads with very different requirements:

| Workload | Requirement | v1 engine |
|---|---|---|
| **A. ASR** (speech → text) | On-device, fast, vi+en | `SpeechAnalyzer`/`SpeechTranscriber` (macOS 26 on-device). Fallback: WhisperKit (whisper `small`/`medium`) |
| **B. Intent parsing** (text → schema) | Structured, narrow, schema-bound | **Apple Foundation Models** framework (on-device ~3B) with `@Generable` guided generation — output is schema-constrained by construction |
| **C. AI Breakdown** (task → subtasks, quality prose) | Higher reasoning quality | Cloud API (Claude/GPT) — **AI Pro tier only** ($5/mo) |

Implementation notes:
- Wrap B behind a protocol `IntentParsing` with two implementations: `LocalFoundationModelParser` and `CloudParser`. Route: local by default; if local returns low aggregate confidence or fails validation → optionally retry via cloud **only if** user has AI Pro AND has opted in. Transcript text only — never raw audio — leaves the device, and only on this path.
- Fallback for macOS < 26 or unsupported hardware: WhisperKit for ASR + a bundled small instruct model (e.g. Qwen 3B class) via MLX with grammar-constrained JSON output. Ship as optional download (~2GB), not in the base bundle.
- Privacy line for marketing and for the privacy policy: *"Your voice never leaves your Mac."* Keep it true: workload A and B fully local in the default configuration.

---

## 10. Non-goals for v1 (explicitly out of scope)

- Natural-language *editing* of existing tasks by voice ("dời task báo cáo sang mai") — v1.1.
- Recurring tasks / RRULE.
- Cross-device sync.
- Windows port (see model-strategy assessment in project notes; revisit post-launch).
- Location-based reminders.

Ship the smallest version of §2–§7 that passes the §6.2 test suite. Every week of additional scope is a week Todoist Ramble gets closer.
