// Sources/Reminders/CueFiring.swift — pure decision logic for implementation-intention cues
// (`Model/TaskCue.swift`), the reminder-side half of specs/006-cues-and-waiting/design.md §2
// Việc B. Follows the same convention as `FullScreenEscalationDecision.swift`: no `Date()`, no
// `UserDefaults`, no SwiftData, no I/O of any kind — every already-resolved signal is a plain
// parameter, so this stays trivially unit-testable (`Tests/CueFiringTests.swift`) and callable
// from a background sweep without touching the store.
//
// Cue is a SURFACING layer only (design.md §1) — nothing here can hide a task. This file only
// answers "which cues deserve to interrupt right now" (`firing`) vs. "which cues are still worth
// showing at the next natural touch point" (`pending`); it never mutates anything.
import Foundation

enum CueFiring {
    /// Minimum gap since `lastActiveAt` before a `.wake` cue is allowed to fire. CỐ Ý not tied to
    /// a wall-clock "morning" boundary — ADHD's delayed sleep phase runs ~10x population baseline
    /// (`docs/adhd-research-v1.md` §6), so a fixed clock hour would be wrong for exactly the users
    /// this feature targets. Also deliberately NOT `com.apple.screenIsUnlocked`
    /// (`DistributedNotificationCenter` — UNVERIFIED whether App Sandbox blocks it on Mac, and not
    /// needed for v1 anyway): plain session-gap math needs no extra entitlement and no Mac-only
    /// verification to reason about.
    static let wakeGapHours: Double = 6

    /// Which `.wake` cues deserve to interrupt RIGHT NOW — the only kind this function ever
    /// returns. `.dayEnd`/`.unknown` never "fire": they have no reliable machine-detectable
    /// moment to fire AT (that's exactly why `.unknown` exists — see `CueKind` doc comment), so
    /// forcing them through this gap-based path would mean guessing a moment the user never gave
    /// us, which is how a reminder turns into nagging. Those two kinds are surfaced instead via
    /// `pending(...)` at whatever natural touch point the UI already has (opening the app, viewing
    /// a task) — ambient, not interruptive (design.md §3).
    ///
    /// `lastActiveAt == nil` (very first run this app has ever recorded) is deliberately NOT
    /// treated as a wake: with no prior session to measure a gap against, firing here would be a
    /// guess dressed up as a signal. Silence is the safe default — better to miss one wake greeting
    /// than to guess wrong on literally the first launch.
    ///
    /// `now.timeIntervalSince(lastActiveAt) >= wakeGapHours * 3600` — `>=` (not `>`) is
    /// intentional: a gap of EXACTLY 6h counts as a wake, not "one second more" required.
    ///
    /// A cue past its `expiresAt` is never returned by ANY path in this file — the swallow-proof
    /// floor from `TaskCue`'s own doc comment applies uniformly here.
    ///
    /// Input order (`cues`) is preserved in the output for cues that qualify — this function never
    /// reorders, only filters, mirroring `WaitingMode.decide`'s "filter, don't resort" rule.
    static func firing(
        now: Date,
        lastActiveAt: Date?,
        cues: [(taskId: UUID, cue: TaskCue)]
    ) -> [UUID] {
        guard let lastActiveAt else { return [] }
        guard now.timeIntervalSince(lastActiveAt) >= wakeGapHours * 3600 else { return [] }
        return cues.compactMap { entry in
            guard entry.cue.kind == .wake else { return nil }
            guard now <= entry.cue.expiresAt else { return nil }
            return entry.taskId
        }
    }

    /// Cues still worth showing at a natural touch point (opening the app, viewing a task list).
    /// `.dayEnd`/`.unknown` are NOT gated on age — they have no gap to measure against, so they're
    /// eligible the moment they're created (only ever filtered by `expiresAt`).
    ///
    /// `.wake` IS gated on age here — `now.timeIntervalSince(cue.createdAt) >= wakeGapHours * 3600`
    /// — same threshold `firing` uses, but measured from `createdAt` instead of `lastActiveAt`.
    /// Fixed 2026-08-08 (Opus review): an earlier version returned every unexpired `.wake` cue
    /// unconditionally, reasoning that a machine left running continuously never crosses the 6h
    /// `lastActiveAt` gap so `firing` alone could lose the cue. That reasoning was right about the
    /// problem but wrong about the cure — it fixed a rare case (continuous uptime) by breaking the
    /// common one: say "ngủ dậy thì test feature này" at 23:00, open the popover at 23:01, and the
    /// cue would surface immediately — before the "if" (waking up) has even happened. An
    /// implementation intention is an if-then link; showing the "then" before the "if" is not just
    /// useless, it's noise, and noise is exactly what trains an ADHD user to ignore the app. The
    /// age gate keeps the original goal (a `.wake` cue is never permanently lost even on
    /// continuous uptime — once it turns 6h old it becomes eligible here regardless of
    /// `lastActiveAt`, so `firing`'s gap-based path and this age-based path converge on the same
    /// threshold) without ever showing the cue back to the user in the same sitting they said it.
    ///
    /// This is the read-only "what could I show" query; it does not track "already shown once" —
    /// design.md §3's "nhắc một lần mỗi lần fire" is a caller-side bookkeeping concern (which cue
    /// IDs have already been surfaced this session), out of scope for a pure function with no
    /// state to remember across calls.
    static func pending(
        now: Date,
        cues: [(taskId: UUID, cue: TaskCue)]
    ) -> [UUID] {
        cues.compactMap { entry in
            guard now <= entry.cue.expiresAt else { return nil }
            if entry.cue.kind == .wake {
                guard now.timeIntervalSince(entry.cue.createdAt) >= wakeGapHours * 3600 else { return nil }
            }
            return entry.taskId
        }
    }
}
