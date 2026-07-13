// Sources/Views/FocusOverlay.swift — fullscreen one-task Focus mode overlay
import SwiftUI

/// Default focus-session length, seconds — mirrors `AppState`'s own `25 * 60` default and the
/// prototype's `totalSecs` prop (there is no separate "total" stored on `AppState`, so this view
/// re-derives the progress fraction against the same constant `startFocus()`/`endFocus()` use).
private let focusTotalSeconds = 25 * 60

/// Fullscreen "one task" focus overlay — ports `voci-focus.jsx`'s `VociFocusOverlay`. Reads all
/// state from `AppState` via the environment (frozen contracts, spec §4) instead of taking props:
/// the app only ever has one `AppState` instance, injected at the scene root.
///
/// Owns its own 1s countdown (see `ticker`/`tick()`) — per spec §4, `AppState.focusSecondsLeft` is
/// plain stored state with no timer driving it; the backlog note "Focus session countdown... left
/// for FocusOverlay.swift at Phase 2" is resolved here.
struct FocusOverlay: View {
    @Environment(AppState.self) private var appState: AppState
    @FocusState private var isFocused: Bool

    /// Stable 1s tick source. `@State` (not a plain `let`) is load-bearing: a `let` would mint a
    /// NEW `Timer.publish` every time the parent re-creates this struct — which happens on every
    /// `AppState` change — restarting the 1-second wait each time, so the countdown stalls
    /// whenever anything else mutates state more often than once per second (e.g. live
    /// transcript partials while capturing during a focus session). `@State` pins the first
    /// publisher for the lifetime of the overlay's identity.
    @State private var ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

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
        .onReceive(ticker) { _ in tick() }
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
            // Heavy dark glass: `.ultraThinMaterial` + a dark tint layered on top, matching the
            // prototype's `rgba(9,10,15,0.78)` over `backdrop-filter: blur(28px)`.
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color(red: 9.0 / 255, green: 10.0 / 255, blue: 15.0 / 255).opacity(0.78))

            VStack(spacing: 0) {
                Text(appState.focusPaused ? "Paused" : "Focus")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(1.98) // 0.18em @ 11pt
                    .textCase(.uppercase)
                    .foregroundStyle(VociColor.textMut)
                    .padding(.bottom, 10)

                Text(formattedTime(appState.focusSecondsLeft))
                    .font(.system(size: 76, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(timerColor)
                    .opacity(appState.focusPaused ? 0.45 : 1)
                    .shadow(color: timerColor.opacity(0.27), radius: 40)
                    .animation(.easeOut(duration: 0.2), value: appState.focusPaused)

                progressHairline
                    .padding(.top, 20)

                taskInfo(task)
                    .padding(.top, 40)

                markDoneButton(task)
                    .padding(.top, 26)
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
                .fill(Color.white.opacity(0.10))
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
                .foregroundStyle(VociColor.textPri)

            HStack(spacing: 8) {
                Circle().fill(priorityColor(task.priority)).frame(width: 5, height: 5)
                Text(priorityLabel(task.priority))
                if let dur = task.durationLabel {
                    Text("·").opacity(0.4)
                    Text(dur)
                }
                if let badge = task.timeBadge {
                    Text("·").opacity(0.4)
                    Text(badge)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(VociColor.textSec)
        }
        .frame(maxWidth: 480)
        .padding(.horizontal, 40)
    }

    private func markDoneButton(_ task: TaskItem) -> some View {
        Button {
            appState.completeFocusTask(task.id)
        } label: {
            HStack(spacing: 8) {
                VocIcon(.check, size: 13, color: .white, weight: .semibold)
                Text("Mark done")
            }
            .font(.system(size: 13, weight: .medium))
            .tracking(-0.065) // -0.005em @ 13pt
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 9)
            .background(accent.solid)
            .clipShape(Capsule())
            .shadow(color: accent.glow.opacity(0.25), radius: 24, y: 4)
        }
        .buttonStyle(.plain)
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
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(VociColor.textSec)
                    .frame(minWidth: 52)
                FocusRoundBtn(icon: .chevron, title: "Next task (→)", disabled: index >= openTasks.count - 1) {
                    goToNext()
                }
            }
            Text("\(openTasks.count) task\(openTasks.count == 1 ? "" : "s") left today")
                .font(.system(size: 11))
                .foregroundStyle(VociColor.textMut)
        }
    }

    // MARK: - Behavior

    /// 1s tick — decrements `appState.focusSecondsLeft` while the session is active and
    /// unpaused, ending the session once it reaches zero (`endFocus()` also resets the counter
    /// back to 25 min, matching `AppState`'s own reset-on-end behavior).
    private func tick() {
        guard appState.focusActive, !appState.focusPaused else { return }
        guard appState.focusSecondsLeft > 0 else {
            appState.endFocus()
            return
        }
        appState.focusSecondsLeft -= 1
        if appState.focusSecondsLeft <= 0 {
            appState.endFocus()
        }
    }

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
        if s <= 60 { return VociColor.high }
        if s <= 300 { return VociColor.med }
        return accent.solid
    }

    private func priorityColor(_ priority: Priority) -> Color {
        switch priority {
        case .high: return VociColor.high
        case .medium: return VociColor.med
        case .low: return VociColor.low
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
/// file — ported from `voci-focus.jsx`'s `FocusRoundBtn`.
private struct FocusRoundBtn: View {
    let icon: VocIconName
    let title: String
    var disabled: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    init(icon: VocIconName, title: String, disabled: Bool = false, action: @escaping () -> Void) {
        self.icon = icon
        self.title = title
        self.disabled = disabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VocIcon(icon, size: 12, color: Color.white.opacity(0.7), weight: .regular)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .background(isHovering && !disabled ? Color.white.opacity(0.12) : Color.white.opacity(0.06))
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white.opacity(0.10), lineWidth: 0.5))
        .opacity(disabled ? 0.3 : 1)
        .disabled(disabled)
        .help(title)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}
