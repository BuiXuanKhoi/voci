# Contract: Phase 4 (reminders + spoken delivery + conflict advisory) — frozen seams

Parallel agents code against THIS, not each other's files. Won't fully compile until all land +
Mac verify; the contract keeps them consistent. Owner named per symbol.

## A. Reminder subsystem — OWNED BY the Reminders agent (`Voci/Sources/Reminders/` + `Model/ReminderRecord.swift`)

```swift
// ReminderRecord.swift — @Model
@Model final class ReminderRecord {
    var id: UUID
    var taskId: UUID
    var fireAt: Date
    var offsetKind: String        // "-1d" / "-1h" / "at" / "override" / "resurface" / "unblocked"
    var state: String             // "scheduled" / "delivered" / "satisfied"
    var isHighUrgency: Bool       // drives the voice escalation rung
    // init with sane defaults
}

// ReminderScheduler.swift — @MainActor
@MainActor final class ReminderScheduler {
    init(store: TaskStore, voice: VoiceReminderChannel, gate: ReminderContextGate)
    func rebuildFromStorage()                 // call on launch + NSWorkspace.didWakeNotification
    func scheduleReminders(for task: VociTask) // derive fire times from deadline × (policy|override)
    func cancelReminders(taskId: UUID)
    func handleFire(recordId: UUID)           // reload task fresh; suppress if done/archived; else deliver
    func scheduleResurface(at: Date, taskId: UUID)   // FR-017 afterDate
    func notifyUnblocked(taskIds: [UUID])            // FR-015 one per newly-ready
    func offerReschedule(taskId: UUID)               // FR-016 overdue
}
```

Escalation: visual notification always fires (UNUserNotificationCenter). Voice is ADDITIONAL and
HIGH-rung only: speak when `isHighUrgency` OR a prior visual went unacknowledged, AND
`VoiceDeliveryMode != .visualOnly`, AND `gate.shouldSuppressVoice(now:) == false`. Nearest-N
pending system requests (64 cap); refill on delivery/launch. Fire-time reload from store fresh
(constitution IV). Persist all records; rebuild on every launch/wake.

## B. Spoken channel + gate — OWNED BY the Reminders agent

```swift
@MainActor final class VoiceReminderChannel {
    init(playback: VoicePlayback)   // reuse existing Sources/Speech/VoicePlayback.swift (AVSpeechSynthesizer)
    func speak(_ text: String)      // one calm sentence
    func speakReminder(title: String, timing: String, isSensitive: Bool)
    // isSensitive == true → speak a generic phrase ("You have a reminder"), never the title
}

@MainActor final class ReminderContextGate {
    func shouldSuppressVoice(now: Date) -> Bool
    // true when: a calendar event marks the user busy now (busyIntervals injected — [] until P3),
    // a call/mic capture is active (check SpeechCapture/AVAudioSession state), screen is being
    // shared, Do Not Disturb is on, or other audio is playing. Fail toward SUPPRESSED when unsure.
}
```

`VoiceDeliveryMode` (enum `visualOnly` / `visualPlusVoice` (default) / `voiceOnly`) lives in a
settings source read by the scheduler; the App-wiring agent adds the setting UI + persistence.

## C. Conflict engine — OWNED BY the Conflict agent (`VociCore/Sources/VociCore/ConflictCheck.swift`)

```swift
public enum TaskConflict: Sendable, Equatable {
    case deadlineCapacity(existingCount: Int, estimatedMinutes: Int, windowEnd: Date)
    case deadlineCollision(withTaskId: UUID, title: String)
    case dependsOnBlocked(taskId: UUID, title: String)
    case competesWithFrog(taskId: UUID, title: String)
    case possibleDuplicate(taskId: UUID, title: String, score: Double)
}

/// PURE (constitution III): no I/O, no clock, no calendar read. busyIntervals injected.
/// Returns HIGH-SIGNAL conflicts only (empty == clean capture). Deterministic total behavior.
public func conflicts(forAdding candidate: Task, into snapshot: [Task], now: Date,
                      calendar: Calendar, busyIntervals: [DateInterval], frogId: UUID?) -> [TaskConflict]
```

Signal thresholds (keep NOISE LOW — only surface what an ADHD user would thank you for):
capacity fires only when the candidate's deadline day is already ≥ ~80% committed; collision only
vs `.inProgress`/priority-1/frog; duplicate only at fuzzy score ≥ ~0.8; depends-on-blocked only
when the referenced task is overdue or itself has an unsatisfied blocking condition.

## D. Triage view — OWNED BY the Triage agent (`Voci/Sources/Views/TriageView.swift`)

```swift
struct TriageView: View {
    let items: [TaskItem]
    var onKeep: (TaskItem) -> Void
    var onBreakdown: (TaskItem) -> Void
    var onDefer: (TaskItem) -> Void
    var onDrop: (TaskItem) -> Void
    // batch card, calm, NO red/badges (FR-018 + FR-036 anti-shame). Presented by AppState.
}
```

## E. App wiring — OWNED BY the App-wiring agent (`AppState.swift`, `VociApp.swift`, `SettingsView.swift`, `PopoverView.swift`, `VociTask.swift`)
Constructs the scheduler (B/A), runs `eligibilityDiff`→`notifyUnblocked` after mutations (FR-015),
schedules resurface via `nextResurfaceDate` (FR-017), registers notification categories in VociApp,
adds `VoiceDeliveryMode` setting + `VociTask.isSensitive`, presents `TriageView` on the weekly
schedule, and — for conflict (T074) — after parse/before save calls `conflicts(...)` and renders
ONE calm advisory line on the confirm card (ignore-with-Enter; never blocks; never auto-modifies).

## Non-negotiables (all agents)
Constitution I (voice TTS on-device, no egress; gate fails to suppressed), II (advisory never
auto-acts), IV (durable reminders, rebuild-from-storage, fire-time fresh reload, recovery tested),
V (glance-and-dismiss, no shame styling). Swift 6 strict concurrency; macOS 14 floor. Windows:
cannot build — mark `// UNVERIFIED`. Do not commit/branch/edit backlog/tasks/other specs.
