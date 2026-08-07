// Sources/Views/FocusOverlay.swift — fullscreen one-task Focus mode overlay
import SwiftUI

/// Default focus-session length, seconds — mirrors `AppState`'s own `25 * 60` default and the
/// prototype's `totalSecs` prop (there is no separate "total" stored on `AppState`, so this view
/// re-derives the progress fraction against the same constant `startFocus()`/`endFocus()` use).
private let focusTotalSeconds = 25 * 60

/// Fullscreen "one task" focus overlay — ports `volar-focus.jsx`'s `VolarFocusOverlay`. Reads all
/// state from `AppState` via the environment (frozen contracts, spec §4) instead of taking props:
/// the app only ever has one `AppState` instance, injected at the scene root.
///
/// FIX B: display-only — the 1s countdown itself is now owned by `AppState` (`focusTimer`/
/// `focusTick()`, started from `startFocus()`), not this view. It used to own a `Timer.publish`
/// ticker locally, which stopped firing the instant this overlay's window closed (e.g. the user
/// switched away), freezing `focusSecondsLeft` and the menu-bar countdown, and never auto-ending
/// the session. This view now just reads `appState.focusSecondsLeft` like any other stored value.
struct FocusOverlay: View {
    @Environment(AppState.self) private var appState: AppState
    @FocusState private var isFocused: Bool

    private var accent: Accent { appState.accent.accent }

    var body: some View {
        let openTasks = appState.openTasks

        Group {
            if openTasks.isEmpty {
                // Mirrors the JSX `if (!task) return null;` guard.
                EmptyView()
            } else {
                let clampedIndex = min(max(appState.focusIndex, 0), openTasks.count - 1)
                overlayContent(task: openTasks[clampedIndex], openTasks: openTasks, index: clampedIndex)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onKeyPress(.leftArrow) {
            goToPrevious()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            goToNext()
            return .handled
        }
    }

    // MARK: - Layout

    private func overlayContent(task: TaskItem, openTasks: [TaskItem], index: Int) -> some View {
        ZStack {
            // Heavy dark glass: `.ultraThinMaterial` + a dark tint layered on top. Tint uses the
            // `bg` token (not a hardcoded literal) so it tracks the palette automatically; see
            // `FullScreenTakeoverWindow.swift` for the matching treatment.
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(VolarColor.bg.opacity(0.78))

            VStack(spacing: 0) {
                Text(appState.focusPaused ? "Paused" : "Focus")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(1.98) // 0.18em @ 11pt
                    .textCase(.uppercase)
                    .foregroundStyle(VolarColor.textMut)
                    .padding(.bottom, 10)

                Text(formattedTime(appState.focusSecondsLeft))
                    .font(Font.volarMono(size: 76, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(timerColor)
                    .opacity(appState.focusPaused ? 0.45 : 1)
                    .shadow(color: timerColor.opacity(0.27), radius: 40)
                    .animation(VolarMotion.hover, value: appState.focusPaused)

                progressHairline
                    .padding(.top, 20)

                taskInfo(task)
                    .padding(.top, 40)

                focusPrimaryActions(task)
                    .padding(.top, 26)

                // FR-030: the one-time "want to split this up?" invite, whenever one's pending —
                // shared with `TodayView`'s hero card (same `AppState.switchBreakdownSuggestion`),
                // see `SwitchBreakdownSuggestionBanner` at the bottom of this file.
                if let suggestion = appState.switchBreakdownSuggestion {
                    SwitchBreakdownSuggestionBanner(task: suggestion)
                        .padding(.top, 18)
                }

                // "Stuck?" (anh Khôi, 2026-07-29): the "dread" reason's message/fallback banner,
                // the "too_big" reason's single next-action banner, and the "cant_start" reason's
                // 2-minute timer — shared with `TodayView`'s hero card exactly like the breakdown-
                // invite banner right above — same wording, same state, never two implementations.
                // None of the three renders anything while idle.
                if let dreadTask = appState.stuckDreadTask, dreadTask.id == task.id,
                   appState.stuckDreadState != .idle {
                    StuckDreadBanner(task: dreadTask)
                        .padding(.top, 18)
                }
                if let nextActionTask = appState.stuckNextActionTask, nextActionTask.id == task.id,
                   appState.stuckNextActionState != .idle {
                    StuckNextActionBanner(task: nextActionTask)
                        .padding(.top, 18)
                }
                if appState.stuckTimerActive {
                    StuckTimerBanner()
                        .padding(.top, 18)
                }
            }

            VStack {
                HStack {
                    Spacer()
                    topRightButtons
                }
                Spacer()
                bottomNav(openTasks: openTasks, index: index)
            }
            .padding(14)
        }
    }

    private var progressHairline: some View {
        let total: CGFloat = 240
        let frac = min(max(Double(appState.focusSecondsLeft) / Double(focusTotalSeconds), 0), 1)
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1)
                .fill(VolarColor.veil(0.10))
                .frame(width: total, height: 2)
            RoundedRectangle(cornerRadius: 1)
                .fill(timerColor)
                .frame(width: total * frac, height: 2)
        }
        .animation(.linear(duration: 1), value: appState.focusSecondsLeft)
    }

    private func taskInfo(_ task: TaskItem) -> some View {
        VStack(spacing: 10) {
            Text(task.title)
                .font(.system(size: 23, weight: .medium))
                .tracking(-0.345) // -0.015em @ 23pt
                .multilineTextAlignment(.center)
                .foregroundStyle(VolarColor.textPri)

            HStack(spacing: 8) {
                Circle().fill(priorityColor(task.priority)).frame(width: 5, height: 5)
                Text(priorityLabel(task.priority))
                if let dur = task.durationLabel {
                    Text("·").opacity(0.4)
                    Text(dur)
                        .font(Font.volarMono(size: 12))
                        .monospacedDigit()
                }
                if let badge = task.timeBadge {
                    Text("·").opacity(0.4)
                    Text(badge)
                        .font(Font.volarMono(size: 12))
                        .monospacedDigit()
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(VolarColor.textSec)

            // UNVERIFIED: authored on Windows, no Swift/Xcode toolchain here — this block through
            // `switchButton` below has not been compiled, run, or seen on screen. Needs a Mac visual
            // pass (see final report's verify checklist) before shipping.
            //
            // Re-entry context (FR-030's "last step, resume note, transcript" list): whatever this
            // task already carries resurfaces here every time it's the one in focus — including the
            // moment you come back to it after switching away — so you can pick the thread back up.
            // Uses only data `TaskItem` already has (`sourceTranscript`/`resumeNote`/`parentId`-
            // linked children); no new field. Shown unconditionally whenever present, not gated
            // behind a "was this specifically switched away" flag — there is no such flag to gate on
            // without new state, and showing real context is harmless on a first visit too.
            if let progress = stepProgress(for: task) {
                (
                    Text("\(progress.done)").font(Font.volarMono(size: 11.5).monospacedDigit())
                    + Text(" of ").font(.system(size: 11.5))
                    + Text("\(progress.total)").font(Font.volarMono(size: 11.5).monospacedDigit())
                    + Text(" steps done").font(.system(size: 11.5))
                )
                    .foregroundStyle(VolarColor.textMut)
            }
            if let resumeNote = task.resumeNote, !resumeNote.isEmpty {
                Text(resumeNote)
                    .font(.system(size: 12))
                    .foregroundStyle(VolarColor.textMut)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.top, 2)
            }
            if let transcript = task.sourceTranscript, !transcript.isEmpty {
                Text("\u{201C}\(transcript)\u{201D}")
                    .font(.system(size: 12))
                    .italic()
                    .foregroundStyle(VolarColor.textMut)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: 480)
        .padding(.horizontal, 40)
    }

    /// Breakdown-step progress for a task with children ("N of M steps done"), or `nil` when it has
    /// none — derived entirely from existing data (`TaskItem.parentId`/`status`), no new field.
    private func stepProgress(for task: TaskItem) -> (done: Int, total: Int)? {
        let children = appState.tasks.filter { $0.parentId == task.id }
        guard !children.isEmpty else { return nil }
        return (children.filter(\.done).count, children.count)
    }

    /// "Mark done", "Switch", and "Stuck?" side by side, equal footing — per anh Khôi's contract,
    /// neither Switch nor Stuck is a secondary/hidden action; each stands next to Done exactly
    /// like this. Tapping "Stuck?" must feel exactly as ordinary as tapping "Done" (no red, no
    /// icon, no urgency styling) — this app's no-shame tone (`SweepView.swift`).
    private func focusPrimaryActions(_ task: TaskItem) -> some View {
        HStack(spacing: 10) {
            markDoneButton(task)
            switchButton
            stuckButton(task)
        }
    }

    private func markDoneButton(_ task: TaskItem) -> some View {
        Button {
            appState.completeFocusTask(task.id)
        } label: {
            HStack(spacing: 8) {
                VolarIcon(.check, size: 13, color: .white, weight: .semibold)
                Text("Mark done")
            }
            .font(.system(size: 13, weight: .medium))
            .tracking(-0.065) // -0.005em @ 13pt
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 9)
            .background(accent.solid)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .shadow(color: accent.glow.opacity(0.25), radius: 24, y: 4)
        }
        .buttonStyle(.plain)
    }

    /// Switch ("đổi gió") — equal in standing to "Mark done" right next to it, never a menu item.
    /// Deliberately plain/neutral styling (no accent fill, no icon, no red): this is a completely
    /// normal thing to tap, not a warning or an admission of anything. Disabled (not hidden) when
    /// there's genuinely nowhere else to send focus, matching `bottomNav`'s existing prev/next
    /// disabled-at-the-bound convention right below.
    private var switchButton: some View {
        Button {
            appState.switchFocusTask()
        } label: {
            Text("Switch")
                .font(.system(size: 13, weight: .medium))
                .tracking(-0.065) // -0.005em @ 13pt
                .foregroundStyle(VolarColor.textPri)
                .padding(.horizontal, 20)
                .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .background(VolarColor.card)
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(VolarColor.border, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .opacity(appState.canSwitchFocusTask ? 1 : 0.4)
        .disabled(!appState.canSwitchFocusTask)
        .help("Move on to something else — this task isn't done, it just steps out for now.")
    }

    /// "Stuck?" (anh Khôi, 2026-07-29) — same neutral capsule styling as `switchButton` right
    /// above (no accent fill, no icon, no warning color): a completely ordinary thing to tap.
    /// Opens a small popover with the three plainly-worded reasons (`StuckReasonPicker`, shared
    /// with `TodayView`'s hero card, defined at the bottom of this file); the popover's open/closed
    /// state is entirely driven by `AppState.stuckPickerTask`, never a locally-owned `@State` bool
    /// — same "AppState is the one source of truth" convention every other piece of state in this
    /// view already follows.
    private func stuckButton(_ task: TaskItem) -> some View {
        Button {
            appState.openStuckPicker(for: task)
        } label: {
            Text("Stuck?")
                .font(.system(size: 13, weight: .medium))
                .tracking(-0.065) // -0.005em @ 13pt
                .foregroundStyle(VolarColor.textPri)
                .padding(.horizontal, 20)
                .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .background(VolarColor.card)
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(VolarColor.border, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .popover(isPresented: Binding(
            get: { appState.stuckPickerTask?.id == task.id },
            set: { presented in if !presented { appState.dismissStuckPicker() } }
        )) {
            StuckReasonPicker(task: task)
        }
        .help("Name what kind of stuck this is — different kinds need different fixes.")
    }

    private var topRightButtons: some View {
        HStack(spacing: 6) {
            FocusRoundBtn(
                icon: appState.focusPaused ? .play : .pause,
                title: appState.focusPaused ? "Resume" : "Pause"
            ) {
                appState.toggleFocusPause()
            }
            FocusRoundBtn(icon: .x, title: "End session") {
                appState.endFocus()
            }
        }
    }

    private func bottomNav(openTasks: [TaskItem], index: Int) -> some View {
        VStack(spacing: 7) {
            HStack(spacing: 14) {
                FocusRoundBtn(icon: .back, title: "Previous task (←)", disabled: index <= 0) {
                    goToPrevious()
                }
                Text("\(index + 1) of \(openTasks.count)")
                    .font(Font.volarMono(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(VolarColor.textSec)
                    .frame(minWidth: 52)
                FocusRoundBtn(icon: .chevron, title: "Next task (→)", disabled: index >= openTasks.count - 1) {
                    goToNext()
                }
            }
            (
                Text("\(openTasks.count)").font(Font.volarMono(size: 11).monospacedDigit())
                + Text(" task\(openTasks.count == 1 ? "" : "s") left today").font(.system(size: 11))
            )
                .foregroundStyle(VolarColor.textMut)
        }
    }

    // MARK: - Behavior

    private func goToPrevious() {
        appState.focusIndex = max(0, appState.focusIndex - 1)
    }

    private func goToNext() {
        let lastIndex = max(appState.openTasks.count - 1, 0)
        appState.focusIndex = min(lastIndex, appState.focusIndex + 1)
    }

    private func formattedTime(_ seconds: Int) -> String {
        let clamped = max(seconds, 0)
        return String(format: "%d:%02d", clamped / 60, clamped % 60)
    }

    private var timerColor: Color {
        let s = appState.focusSecondsLeft
        if s <= 60 { return VolarColor.high }
        if s <= 300 { return VolarColor.med }
        return accent.solid
    }

    private func priorityColor(_ priority: Priority) -> Color {
        switch priority {
        case .high: return VolarColor.high
        case .medium: return VolarColor.med
        case .low: return VolarColor.low
        }
    }

    private func priorityLabel(_ priority: Priority) -> String {
        switch priority {
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }
}

/// Small round glass icon button used for the pause/stop and prev/next controls. Private to this
/// file — ported from `volar-focus.jsx`'s `FocusRoundBtn`.
private struct FocusRoundBtn: View {
    let icon: VolarIconName
    let title: String
    var disabled: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    init(icon: VolarIconName, title: String, disabled: Bool = false, action: @escaping () -> Void) {
        self.icon = icon
        self.title = title
        self.disabled = disabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VolarIcon(icon, size: 12, color: Color.white.opacity(0.7), weight: .regular)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .background(isHovering && !disabled ? VolarColor.veil(0.12) : VolarColor.veil(0.06))
        .clipShape(Circle())
        .overlay(Circle().stroke(VolarColor.veil(0.10), lineWidth: 0.5))
        .opacity(disabled ? 0.3 : 1)
        .disabled(disabled)
        .help(title)
        .onHover { isHovering = $0 }
        .animation(VolarMotion.hover, value: isHovering)
    }
}

/// FR-030's one-time "this looks like more than one step — split it up?" invite, shown after a
/// task's (never-displayed) `switchAwayCount` first crosses the threshold
/// (`AppState.maybeOfferBreakdown`). Deliberately NOT `private` — both `FocusOverlay` and
/// `TodayView`'s hero card render the exact same banner off the exact same
/// `AppState.switchBreakdownSuggestion`, so the copy/behavior can't drift between the two places
/// Switch is offered.
///
/// A single plain question, not a comment on the user: no "you keep avoiding this", no streak, no
/// red/warning styling. Declining ("Not now") just closes it — `AppState.switchBreakdownOffered`
/// already recorded this task as offered the moment the banner appeared, so it never asks again for
/// this task, even on a 4th/5th switch.
struct SwitchBreakdownSuggestionBanner: View {
    @Environment(AppState.self) private var appState: AppState
    let task: TaskItem

    var body: some View {
        HStack(spacing: 10) {
            Text("\u{201C}\(task.title)\u{201D} looks like it might be more than one step. Split it up?")
                .font(.system(size: 12.5))
                .foregroundStyle(VolarColor.textSec)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            Button("Not now") {
                appState.dismissSwitchBreakdownSuggestion()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(VolarColor.textMut)

            Button("Split it up") {
                appState.acceptSwitchBreakdownSuggestion()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(VolarColor.textPri)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 480)
        .background(VolarColor.card)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(VolarColor.border, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - "Stuck?" (anh Khôi, 2026-07-29)
//
// Three views, shared verbatim between `FocusOverlay` (above) and `TodayView`'s hero card, exactly
// like `SwitchBreakdownSuggestionBanner` right above — one definition each, so wording/behavior can
// never drift between the two places "Stuck?" appears. UNVERIFIED — authored on Windows, no Swift/
// Xcode toolchain here; needs a Mac visual pass (see final report's verify checklist).

/// Popover content for the "Stuck?" button: three plainly-worded reasons, one tap each. Deliberately
/// plain, first-person, human sentences — the raw `StuckReason` case names ("too_big"/"dread"/
/// "cant_start") never appear as user-facing text anywhere. No icons, no color-coding by "severity"
/// — all three are equally ordinary things to feel, matching this app's no-shame tone
/// (`SweepView.swift`).
struct StuckReasonPicker: View {
    @Environment(AppState.self) private var appState
    let task: TaskItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            reasonRow("This feels like more than one task.") {
                appState.chooseStuckReason(.tooBig, for: task)
            }
            reasonRow("This one feels heavy to even look at.") {
                appState.chooseStuckReason(.dread, for: task)
            }
            reasonRow("I can't get myself moving at all.") {
                appState.chooseStuckReason(.cantStart, for: task)
            }
        }
        .padding(8)
        .frame(width: 270)
    }

    private func reasonRow(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(VolarColor.textPri)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
    }
}

/// Shared card chrome for every "Stuck?" banner (`StuckDreadBanner`, `StuckTimerBanner`,
/// `StuckNextActionBanner` — anh Khôi, 2026-07-29: "tái dùng được thì tái dùng, đừng dựng banner
/// thứ ba trùng lặp") — one `RoundedRectangle`/padding/stroke definition instead of three copies,
/// so a future visual tweak can never drift between them. Purely a layout helper — no state, no
/// behavior, and extracting it changes NOTHING about how `StuckDreadBanner`/`StuckTimerBanner`
/// already looked or behaved (same padding/background/overlay/clipShape values as before, just
/// named once).
private func stuckCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    content()
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 480)
        .background(VolarColor.card)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(VolarColor.border, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
}

/// The "dread" reason's response: a short, specific message (or, absent any model, a static honest
/// fallback) plus a single "start the 2-minute action" button. Reads `appState.stuckDreadState`
/// directly rather than taking content as a parameter — single source of truth, same convention
/// `SwitchBreakdownSuggestionBanner` establishes for reading `appState.switchBreakdownSuggestion`
/// directly instead of being handed a copy.
struct StuckDreadBanner: View {
    @Environment(AppState.self) private var appState
    let task: TaskItem

    var body: some View {
        Group {
            switch appState.stuckDreadState {
            case .idle:
                EmptyView()
            case .loading:
                loadingBody
            case .loaded(let message):
                messageBody(message)
            case .fallback:
                messageBody(AppState.stuckDreadFallbackMessage)
            }
        }
    }

    private var loadingBody: some View {
        stuckCard {
            HStack {
                Text("Thinking\u{2026}")
                    .font(.system(size: 12.5))
                    .foregroundStyle(VolarColor.textMut)
                Spacer(minLength: 8)
            }
        }
    }

    private func messageBody(_ message: String) -> some View {
        stuckCard {
            HStack(alignment: .top, spacing: 10) {
                Text(message)
                    .font(.system(size: 12.5))
                    .foregroundStyle(VolarColor.textSec)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 6) {
                    Button("Start (2 min)") {
                        appState.acceptStuckDreadAction()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(VolarColor.textPri)

                    Button("Close") {
                        appState.dismissStuckDread()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(VolarColor.textMut)
                }
            }
        }
    }
}

/// The "too_big" reason's response (anh Khôi, 2026-07-29 REDESIGN — see `AppState
/// .StuckNextActionState`'s doc comment for why this no longer opens `TaskBreakdownView` directly
/// as its first move): ONE next physical action, or — when nothing was found — a neutral "couldn't
/// find one" line that is NEVER a fabricated static suggestion (unlike `StuckDreadBanner`'s
/// `.fallback` case; see that state's own doc comment for why the two are deliberately NOT the
/// same shape). Either way, a lighter secondary button still opens the FULL existing breakdown
/// flow for anyone who wants the whole plan, not just the next step — shown in every non-idle
/// state, never conditioned on whether the quick answer itself succeeded.
struct StuckNextActionBanner: View {
    @Environment(AppState.self) private var appState
    let task: TaskItem

    var body: some View {
        Group {
            switch appState.stuckNextActionState {
            case .idle:
                EmptyView()
            case .loading:
                loadingBody
            case .loaded(let message):
                loadedBody(message)
            case .unavailable:
                unavailableBody
            }
        }
    }

    private var loadingBody: some View {
        stuckCard {
            HStack {
                Text("Thinking\u{2026}")
                    .font(.system(size: 12.5))
                    .foregroundStyle(VolarColor.textMut)
                Spacer(minLength: 8)
            }
        }
    }

    private func loadedBody(_ message: String) -> some View {
        stuckCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Text(message)
                        .font(.system(size: 12.5))
                        .foregroundStyle(VolarColor.textSec)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 8)

                    VStack(alignment: .trailing, spacing: 6) {
                        Button("Start (2 min)") {
                            appState.acceptStuckNextActionAction()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(VolarColor.textPri)

                        Button("Close") {
                            appState.dismissStuckNextAction()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(VolarColor.textMut)
                    }
                }
                seeFullPlanButton
            }
        }
    }

    private var unavailableBody: some View {
        stuckCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    // Neutral, honest unavailability — no suggested content at all (see
                    // `AppState.StuckNextActionState.unavailable`'s doc comment for why this must
                    // never carry a substantive fallback the way `StuckDreadBanner`'s does).
                    Text("No single next step to suggest right now.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(VolarColor.textMut)
                    Spacer(minLength: 8)
                    Button("Close") {
                        appState.dismissStuckNextAction()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(VolarColor.textMut)
                }
                seeFullPlanButton
            }
        }
    }

    /// Secondary, lighter-weight escape hatch to the FULL existing breakdown flow — never a second
    /// implementation of it (`AppState.openFullPlanFromStuck` just calls the existing, unchanged
    /// `openBreakdown(for:)`). Shown in every non-idle state.
    private var seeFullPlanButton: some View {
        Button("See full plan") {
            appState.openFullPlanFromStuck(for: task)
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .regular))
        .foregroundStyle(VolarColor.textMut)
    }
}

/// The "cant_start" reason's response: a plain 2-minute countdown, permission to do absolutely
/// anything — not bound to any specific task (see `AppState.startStuckCantStartTimer`'s doc
/// comment for why this is its own small timer, not `startFocus()`/`FocusOverlay`'s own countdown
/// display). No progress ring, no task title, no chip row — deliberately bare, since the entire
/// point is "it doesn't matter what you do."
struct StuckTimerBanner: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        stuckCard {
            HStack(spacing: 10) {
                Text(formattedTime(appState.stuckTimerSecondsLeft))
                    .font(Font.volarMono(size: 13, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(VolarColor.textPri)
                Text("Two minutes. Anything counts.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(VolarColor.textSec)
                Spacer(minLength: 8)
                Button("Stop") {
                    appState.endStuckCantStartTimer()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(VolarColor.textMut)
            }
        }
    }

    private func formattedTime(_ seconds: Int) -> String {
        let clamped = max(seconds, 0)
        return String(format: "%d:%02d", clamped / 60, clamped % 60)
    }
}
