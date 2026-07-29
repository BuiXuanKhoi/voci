// Sources/Reminders/FullScreenEscalationDecision.swift — pure gate for the full-screen deadline
// takeover, the last rung of Volar's escalation ladder above menu bar -> system notification
// (+ voice). anh Khôi's frozen boundary: ONLY an at-or-after-deadline reminder for a task with a
// REAL deadline may ever reach this rung — a no-deadline "nudge" (`offsetKind == "nudge"`) must
// never leak through, at any cost (that boundary is what keeps this feature from becoming the
// exact notification-blindness problem it's meant to fix).
//
// Convention this repo already follows for reminder math (`ReminderRecord.derive`'s own doc
// comment): pure decision code never reads `Date()` or touches any live system API itself. Every
// already-resolved signal (fresh task status, whether the notification is still sitting
// undismissed in Notification Center, whether the mic is busy, whether Volar itself is capturing,
// whether the user has this turned on) is computed by the IMPURE caller
// (`ReminderScheduler.sweepForFullScreenEscalation`) and handed in as a plain value here, so this
// stays trivially unit-testable (`Tests/FullScreenEscalationDecisionTests.swift`) without touching
// `UNUserNotificationCenter`/CoreAudio/`ModelContext`/`TaskStore` at all.
import Foundation

/// Every already-resolved signal `FullScreenEscalationDecision.shouldEscalate` needs. Each field is
/// exactly one already-answered yes/no or timestamp — deliberately NOT `ReminderRecord`/`TaskItem`
/// themselves, so this type (and the pure function below) has zero dependency on SwiftData/
/// VolarCore's model shapes.
struct EscalationSignals {
    /// `ReminderRecord.isHighUrgency` — true only for an at-or-after-deadline mark
    /// (`ReminderRecord.swift`'s own doc comment). This is the FIRST of two independent guards
    /// against a "nudge" ever escalating (`ReminderRecord.derive`'s no-deadline branch always sets
    /// this `false`, so it alone would already block every nudge) — kept alongside `offsetKind`
    /// below as a deliberate belt-and-suspenders pair, since anh Khôi's contract calls both out by
    /// name as ranting-boundary conditions.
    var isHighUrgency: Bool
    /// `ReminderRecord.offsetKind`. The SECOND, redundant guard: even if some future change ever
    /// let a nudge carry `isHighUrgency == true` by mistake, this field alone still blocks it.
    var offsetKind: String
    /// Fresh (not snapshot) task lifecycle read at decision time — `status != .done && status !=
    /// .archived`.
    var isTaskOpen: Bool
    /// `true` while `UNUserNotificationCenter.getDeliveredNotifications()` still lists this
    /// record's identifier — the only practical "user hasn't interacted with it" signal macOS
    /// exposes (there is no dismiss/ignore callback).
    var stillInNotificationCenter: Bool
    /// The moment this notification was actually shown to the user (or, for a due-but-missed
    /// recovery fire, the moment it was fired) — the reference point `ignoredAfter` counts from.
    var deliveredAt: Date
    /// CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere` on the default input device
    /// (`MicrophoneActivityMonitor`) — best-effort proxy for "on a call/in a meeting". macOS has NO
    /// public, unprivileged API to read Focus/Do Not Disturb status from inside an App Sandbox
    /// (see `ReminderContextGate.swift`'s own header comment for the same limitation) — this is
    /// the one substitute signal available without a restricted entitlement.
    var isMicrophoneInUse: Bool
    /// Volar's own capture panel is mid-recording. Checked independently of `isMicrophoneInUse`
    /// (rather than relying only on the CoreAudio signal) so a takeover never fights the app's own
    /// capture UI — see `ReminderScheduler.isVolarCapturing`'s doc comment for the wiring seam this
    /// depends on (currently unwired; AppState needs one line — flagged in this task's report).
    var isVolarCapturing: Bool
    /// The Settings toggle (§D, `FullScreenEscalationSetting`) — user can opt out entirely.
    var settingEnabled: Bool
}

enum FullScreenEscalationDecision {
    /// Minimum time a delivered notification must sit undismissed before it's treated as
    /// "ignored." Named constant, ONE place — every other file that cares about this window reads
    /// it from here, never a second copy of "5 minutes"/"300 seconds".
    static let ignoredAfter: TimeInterval = 5 * 60

    /// `true` iff every one of the contract's conditions holds, all ANDed together. Pure:
    /// deterministic for identical inputs, `now` is always a parameter (mirrors
    /// `ReminderRecord.derive`'s own convention — never `Date()` read internally).
    static func shouldEscalate(signals: EscalationSignals, now: Date) -> Bool {
        guard signals.settingEnabled else { return false }
        guard signals.isHighUrgency, signals.offsetKind != "nudge" else { return false }
        guard signals.isTaskOpen else { return false }
        guard signals.stillInNotificationCenter else { return false }
        guard now.timeIntervalSince(signals.deliveredAt) >= ignoredAfter else { return false }
        guard !signals.isMicrophoneInUse else { return false }
        guard !signals.isVolarCapturing else { return false }
        return true
    }
}

/// Settings seam (contract §D): the ONE place the UserDefaults key string exists.
/// `SettingsView`'s new row and `ReminderScheduler`'s sweep both read through this enum rather than
/// each holding their own copy of the raw string. This setting is not `AppState`-owned (this task
/// deliberately does not touch `AppState.swift` — see this task's final report), so it gets its
/// own tiny static accessor instead of joining `AppState`'s existing `...Key` constants /
/// `set...` methods pattern.
enum FullScreenEscalationSetting {
    static let key = "volar.fullScreenEscalationEnabled"

    /// Defaults to ON (contract §D — the ranting boundary above already narrows this to
    /// at-or-after-deadline reminders only, so an opt-out default would quietly defeat the whole
    /// point for most users). `UserDefaults.bool(forKey:)` itself defaults a missing key to
    /// `false`, so a plain `.bool(forKey:)` read would silently default OFF for every user who has
    /// never touched this row — reading via `object(forKey:)` instead lets an unset key fall
    /// through to the documented `true` default.
    static var isEnabled: Bool {
        get { (UserDefaults.standard.object(forKey: key) as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
