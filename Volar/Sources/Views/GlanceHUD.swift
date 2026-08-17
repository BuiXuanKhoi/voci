// Sources/Views/GlanceHUD.swift — ⌃⌥N "what am I doing?", answered without leaving the app you're in.
//
// THE PROBLEM: you're 20 minutes into something in another app and your brain asks "wait, what was
// I supposed to be doing?". Opening Volar's window to check is an app switch — the exact loop the
// project's own ADHD research names as a structural failure of every task tool. Glance cuts it: a
// small card over whatever you're in, one sentence, gone.
//
// THREE RULES THAT DECIDE EVERYTHING BELOW:
//  1. It must not steal the keyboard. In peek the panel never becomes key, so a half-typed line in
//     your editor stays half-typed. Only the pinned mode — which you asked for by tapping — takes
//     key status, and only so Esc/Return work. This is why `CapturePanelController` grew an
//     `activates:` flag rather than Glance reusing capture's focus-stealing `show()`.
//  2. It is read-only. No checkbox, no menu, no drag. Showing more than one "next" item would turn
//     an answer into a decision, which is precisely what the stuck brain cannot do right now.
//  3. It never appears on its own. No nudge, no reminder, no countdown. A surface that shows up
//     uninvited becomes a notification, and notifications get turned off.
//
// HONESTY NOTE vs. the design mockup: the artifact's eyebrow reads "NOW · 14:32 ELAPSED". There is
// no such number in this app — tasks have no start timestamp, only a deadline — so it is not shown.
// Inventing an elapsed counter would be fabricating data on the one surface whose entire job is to
// tell you the truth in one second. The eyebrow carries the focus countdown when a session is
// running (a real number) and nothing otherwise.
//
// PALETTE: uses `VolarColor` as it stands today (dark-only Graphite). The "Volar Paper" dual-theme
// pass has not landed; when it does and those tokens become dynamic, this view follows for free
// because it names tokens and never a literal. Do not hardcode a light-mode color here first.
//
// UNVERIFIED: written on Windows with no Swift toolchain. Not compiled, not run.
import SwiftUI
import AppKit

// MARK: - Controller

/// Owns whether Glance is on screen and in which mode. Deliberately a small object of its own
/// rather than five more properties on the 6600-line `AppState`: none of this is app state, it is
/// window state, and nothing outside macOS has any use for it.
@MainActor
@Observable
final class GlanceController {
    enum Mode: Equatable {
        /// Not on screen.
        case hidden
        /// Held ⌃⌥N — visible while the key is down, gone on release. No key focus, no shortcuts
        /// shown, zero decisions to make. This is the mode the feature exists for.
        case peek
        /// Tapped ⌃⌥N — stays until dismissed. Takes key focus so Esc/Return work.
        case pinned
    }

    private(set) var mode: Mode = .hidden

    /// Below this, a press counts as a tap (pin); at or above it, a hold (peek). 250ms is the
    /// conventional macOS press-vs-hold boundary and is comfortably above key-repeat latency.
    static let holdThreshold: Duration = .milliseconds(250)
    /// A pinned card gives up on its own rather than sitting over your work forever if you walk
    /// away. Long enough to read twice.
    static let pinnedTimeout: Duration = .seconds(12)

    private var pressedAt: ContinuousClock.Instant?
    private var autoHide: _Concurrency.Task<Void, Never>?

    /// ⌃⌥N down. A press while already pinned means "close it" — the second tap of a
    /// tap-to-open/tap-to-close pair.
    func hotkeyDown() {
        if mode == .pinned {
            pressedAt = nil
            hide()
            return
        }
        pressedAt = ContinuousClock.now
        show(.peek)
    }

    /// ⌃⌥N up. Held long enough → this was a peek, so it ends with the key. Otherwise it was a tap
    /// and the card stays pinned.
    ///
    /// `pressedAt == nil` means the key-up belongs to the press that just CLOSED a pinned card, so
    /// there is nothing left to decide.
    func hotkeyUp() {
        guard let pressedAt else { return }
        self.pressedAt = nil
        let held = pressedAt.duration(to: ContinuousClock.now)
        if held >= Self.holdThreshold {
            hide()
        } else {
            show(.pinned)
        }
    }

    func hide() {
        autoHide?.cancel()
        autoHide = nil
        mode = .hidden
    }

    private func show(_ next: Mode) {
        autoHide?.cancel()
        autoHide = nil
        mode = next
        guard next == .pinned else { return }
        autoHide = _Concurrency.Task { [weak self] in
            try? await _Concurrency.Task.sleep(for: Self.pinnedTimeout)
            guard !_Concurrency.Task.isCancelled else { return }
            self?.hide()
        }
    }
}

// MARK: - View

struct GlanceHUD: View {
    @Environment(AppState.self) private var appState
    let controller: GlanceController

    private var isPinned: Bool { controller.mode == .pinned }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // Calendar beats the next task for this slot. If something starts in 12 minutes, that
            // IS the next thing — naming a task instead would be the single most misleading thing
            // this card could say. Only one line ever shows; two would make it a list.
            if let event = upcomingEvent {
                Divider().overlay(VolarColor.border)
                eventRow(event)
            } else if let next = nextTask {
                Divider().overlay(VolarColor.border)
                nextRow(next)
            }
            if isPinned {
                Divider().overlay(VolarColor.border)
                keyHints
            }
            if appState.focusActive {
                progressBar
            }
        }
        .frame(width: 340, alignment: .leading)
        .background(VolarColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(VolarColor.borderHi, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
        // Esc and Return only exist while pinned — in peek the panel isn't key, so a shortcut here
        // would be dead weight the user can see but not use.
        .background(shortcutCarriers)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Circle()
                    .fill(headerDotColor)
                    .frame(width: 6, height: 6)
                Text(eyebrowText)
                    .font(.volar(size: 10.5, weight: .semibold))
                    .foregroundStyle(VolarColor.textMut)
                    .textCase(.uppercase)
                    .monospacedDigit()
            }
            Text(titleText)
                .font(.volar(size: 17, weight: activeTask == nil ? .medium : .semibold))
                .foregroundStyle(activeTask == nil ? VolarColor.textSec : VolarColor.textPri)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
            if !metaText.isEmpty {
                Text(metaText)
                    .font(.volar(size: 11.5))
                    .foregroundStyle(isOverdue ? VolarColor.reschedule : VolarColor.textSec)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 15)
        .padding(.top, 13)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The "spotlight" — a wash behind the answer, not a border around it. Only drawn when there
        // IS a NOW task: nothing running means nothing to light up.
        .background(activeTask == nil ? Color.clear : VolarColor.nowGlowSoft)
    }

    private func nextRow(_ task: TaskItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("NEXT")
                .font(.volar(size: 9.5, weight: .semibold))
                .foregroundStyle(VolarColor.textMut)
            Text(shortLine(for: task))
                .font(.volar(size: 11.5))
                .foregroundStyle(VolarColor.textSec)
                .lineLimit(1)
                .truncationMode(.tail)
                .monospacedDigit()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 8)
    }

    /// An imminent calendar event. Uses `instrument` (ice blue) — the token that means
    /// "information", never the mint spotlight, which stays reserved for the one NOW task.
    private func eventRow(_ event: CalendarAccess.UpcomingEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(event.minutesAway <= 0 ? "NOW" : "IN \(event.minutesAway)M")
                .font(.volar(size: 9.5, weight: .semibold))
                .foregroundStyle(VolarColor.instrument)
                .monospacedDigit()
            Text(event.title)
                .font(.volar(size: 11.5))
                .foregroundStyle(VolarColor.textSec)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 8)
    }

    private var keyHints: some View {
        HStack(spacing: 12) {
            hint("return", activeTask == nil ? "Start" : "Focus")
            hint("⌃⌥M", "Speak")
            hint("esc", "Close")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 7)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.volar(size: 9.5, weight: .medium))
                .foregroundStyle(VolarColor.textSec)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(VolarColor.veil(0.06), in: RoundedRectangle(cornerRadius: 4))
            Text(label)
                .font(.volar(size: 10.5))
                .foregroundStyle(VolarColor.textMut)
        }
    }

    /// The focus session, as a bar rather than a second number competing with the eyebrow's.
    private var progressBar: some View {
        GeometryReader { geo in
            let total = Double(25 * 60)
            let done = max(0, min(1, (total - Double(appState.focusSecondsLeft)) / total))
            ZStack(alignment: .leading) {
                Rectangle().fill(VolarColor.veil(0.05))
                Rectangle().fill(VolarColor.nowAccent).frame(width: geo.size.width * done)
            }
        }
        .frame(height: 2)
    }

    /// Invisible buttons that carry Esc/Return — the same "zero-size button carries the shortcut"
    /// trick `TextCaptureView.escCancelButton` already uses in this codebase.
    @ViewBuilder
    private var shortcutCarriers: some View {
        if isPinned {
            ZStack {
                Button("") { controller.hide() }
                    .keyboardShortcut(.cancelAction)
                Button("") {
                    if !appState.focusActive { appState.startFocus() }
                    controller.hide()
                }
                .keyboardShortcut(.defaultAction)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
        }
    }

    // MARK: Content

    /// The same property `TodayView`'s hero card and the menu bar read, so Glance can never name a
    /// different task than the rest of the app.
    private var activeTask: TaskItem? { appState.dashboardActiveTask }

    /// Exactly one. Two would make this a list, and a list is a decision.
    private var nextTask: TaskItem? {
        guard activeTask != nil else { return nil }
        return appState.openTasks.first { $0.id != activeTask?.id }
    }

    /// Read live rather than cached: Glance is on screen for a second or two at a time, and a stale
    /// "in 12 minutes" is worse than none. The 45-minute window is the horizon at which a meeting
    /// actually changes what you should pick up — beyond that it is noise on a one-second surface.
    ///
    /// Excludes Volar's own mirror calendar; see `CalendarAccess.nextEvent` for why that matters.
    private var upcomingEvent: CalendarAccess.UpcomingEvent? {
        appState.calendarAccess.nextEvent(
            within: 45 * 60,
            excludingCalendarID: appState.calendarSync.volarCalendarID
        )
    }

    private var isOverdue: Bool {
        guard let deadline = activeTask?.deadline else { return false }
        return deadline < Date()
    }

    private var headerDotColor: Color {
        if activeTask != nil { return VolarColor.nowAccent }
        return appState.openTasks.isEmpty ? VolarColor.done : VolarColor.textMut
    }

    private var eyebrowText: String {
        guard activeTask != nil else {
            return appState.openTasks.isEmpty ? "Today" : "Nothing running"
        }
        guard appState.focusActive else { return "Now" }
        return "Now · \(max(0, appState.focusSecondsLeft) / 60)m left"
    }

    private var titleText: String {
        if let task = activeTask { return task.title }
        return appState.openTasks.isEmpty ? "All clear." : "Nothing started yet."
    }

    private var metaText: String {
        guard let task = activeTask else {
            guard let first = appState.openTasks.first else { return "" }
            return "Press return to start — \(first.title)"
        }
        guard let deadline = task.deadline else { return "" }
        let time = deadline.formatted(date: .omitted, time: .shortened)
        // Overdue is stated, never scolded — no red, no exclamation mark (Theme.swift's anti-shame
        // rule; `reschedule` is the token that exists for exactly this).
        return isOverdue ? "Overdue \(time)" : "Due \(time)"
    }

    private func shortLine(for task: TaskItem) -> String {
        guard let deadline = task.deadline else { return task.title }
        return "\(task.title) · \(deadline.formatted(date: .omitted, time: .shortened))"
    }
}
