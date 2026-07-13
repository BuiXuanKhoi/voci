// Sources/Views/TodayView.swift — main window content: sidebar + Today list + greeting + frog/focus pill
// Ported from `design/voci-mac.jsx`'s `VociMacApp`. Owns the overlay stack (popover, focus, ambient).
import SwiftUI

struct TodayView: View {
    @Environment(AppState.self) private var appState: AppState

    /// Local-only stand-in for the prototype's `useAmbientSound().playing` state. Real ambient
    /// audio playback is owned by Phase-2C's `AmbientSound.swift`; the frozen `AppState` surface
    /// has no ambient-sound toggle, so this button is a UI-only placeholder pending that wiring
    /// (see deviations in the handoff notes).
    @State private var ambientSoundPlaying = false

    private var accentColors: Accent { appState.accent.accent }

    var body: some View {
        ZStack {
            if appState.ambient != .none {
                AmbientBackground(mode: appState.ambient, imageURL: appState.customImageURL, intensity: 0.7)
                    .ignoresSafeArea()
            }

            HStack(spacing: 0) {
                Sidebar()
                mainColumn
            }

            if appState.captureState != .idle {
                Color.black.opacity(0.32)
                    .ignoresSafeArea()
                    .onTapGesture { appState.cancelCapture() }
                PopoverView()
            }

            if appState.focusActive {
                FocusOverlay()
            }
        }
        .overlay(alignment: .topTrailing) {
            if let banner = appState.reminderBanner {
                NotificationView(
                    title: banner.title,
                    timing: banner.timing,
                    onDone: { appState.dismissBanner() },
                    onSnooze: { appState.dismissBanner() },
                    onReschedule: { appState.dismissBanner() }
                )
                .padding(.top, 44)
                .padding(.trailing, 20)
                .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                .zIndex(20)
                .task(id: appState.reminderBanner?.id) {
                    guard appState.reminderBanner != nil else { return }
                    try? await Task.sleep(for: .seconds(5))
                    appState.dismissBanner()
                }
            }
        }
        .animation(VociMotion.state, value: appState.reminderBanner)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                ToolButton(icon: ambientSoundPlaying ? .volume : .volumeOff, tint: ambientSoundPlaying) {
                    ambientSoundPlaying.toggle()
                }
                ToolButton(icon: .waveform) {
                    appState.readDayAloud()
                }
                ToolButton(icon: .search) {}
                ToolButton(icon: .plus, accent: true) {
                    appState.startCapture()
                }
            }
        }
    }

    // MARK: - Main column

    private var mainColumn: some View {
        VStack(spacing: 0) {
            greetingHeader
                .padding(.horizontal, 28)
                .padding(.top, 20)
                .padding(.bottom, 8)

            if appState.openTasks.isEmpty {
                EmptyTodayCard()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !appState.nowTasks.isEmpty {
                            SectionHeader("Now", count: appState.nowTasks.count, accent: true)
                            VStack(spacing: appState.density.rowGap) {
                                ForEach(appState.nowTasks) { task in
                                    TaskRow(task: task, isActive: task.id == appState.activeTask?.id)
                                        .transition(rowTransition)
                                }
                            }
                        }

                        if !appState.laterTasks.isEmpty {
                            SectionHeader("Later today", count: appState.laterTasks.count)
                                .padding(.top, appState.density.sectionGap)
                            VStack(spacing: appState.density.rowGap) {
                                ForEach(appState.laterTasks) { task in
                                    TaskRow(task: task, isActive: false)
                                        .transition(rowTransition)
                                }
                            }
                        }

                        if !appState.doneTasks.isEmpty {
                            SectionHeader("Completed", count: appState.doneTasks.count)
                                .padding(.top, appState.density.sectionGap)
                            VStack(spacing: appState.density.rowGap) {
                                ForEach(appState.doneTasks) { task in
                                    TaskRow(task: task, isActive: false)
                                        .transition(rowTransition)
                                }
                            }
                        }

                        hotkeyFooter
                            .padding(.top, 22)
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 8)
                    .padding(.bottom, 18)
                    .animation(VociMotion.list, value: appState.tasks)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(mainBackground)
    }

    @ViewBuilder
    private var mainBackground: some View {
        if appState.ambient != .none {
            Color.black.opacity(0.30)
        } else {
            VociColor.bg
        }
    }

    // MARK: - Greeting header

    private var greetingHeader: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Today")
                    .font(.system(size: 26, weight: .medium))
                    .tracking(-0.52)
                    .foregroundStyle(VociColor.textPri)
                Text("\(todayDateLabel) · \(appState.openTasks.count) open · \(appState.doneTasks.count) done")
                    .font(.system(size: 12.5))
                    .tracking(-0.0625)
                    .foregroundStyle(VociColor.textSec)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            if appState.focusActive {
                runningFocusPill
            } else {
                frogPill
            }
        }
    }

    private var todayDateLabel: String {
        Date.now.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    private var runningFocusPill: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(accentColors.solid)
                .frame(width: 5, height: 5)
                .shadow(color: accentColors.glow, radius: 4)
                .opacity(appState.focusPaused ? 1 : (pulseTick ? 0.35 : 1))
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                        pulseTick = true
                    }
                }

            Text(appState.frogTask?.title ?? "Focus")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(VociColor.textPri)
                .lineLimit(1)
                .frame(maxWidth: 180, alignment: .leading)

            Text(fmtClock(appState.focusSecondsLeft))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .tracking(0.26)
                .foregroundStyle(accentColors.solid)

            Button {
                appState.toggleFocusPause()
            } label: {
                VocIcon(appState.focusPaused ? .play : .pause, size: 10, color: VociColor.textPri)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .background(Color.white.opacity(0.08))
            .clipShape(Circle())

            Button {
                appState.endFocus()
            } label: {
                VocIcon(.stop, size: 9, color: VociColor.textSec)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .background(Color.white.opacity(0.08))
            .clipShape(Circle())
        }
        .font(.system(size: 11.5))
        .foregroundStyle(VociColor.textSec)
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(accentColors.surface)
        .clipShape(Capsule())
        .overlay(
            Capsule().stroke(accentColors.solid.opacity(0.27), lineWidth: 0.5)
        )
        .shadow(color: accentColors.glow.opacity(0.25), radius: 22)
    }

    private var frogPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(VociColor.high)
                .frame(width: 5, height: 5)
                .shadow(color: VociColor.high.opacity(0.5), radius: 3)

            HStack(spacing: 4) {
                Text("Frog").fontWeight(.medium).foregroundStyle(VociColor.textPri)
                Text("· \(appState.frogTask?.title ?? "Ship the auth fix")")
            }

            Button {
                appState.startFocus()
            } label: {
                HStack(spacing: 5) {
                    VocIcon(.play, size: 8, color: .white)
                    Text("Focus")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
            }
            .buttonStyle(.plain)
            .background(accentColors.solid)
            .clipShape(Capsule())
        }
        .font(.system(size: 11.5))
        .foregroundStyle(VociColor.textSec)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(Color(voci: 0xFF6B6B, opacity: 0.10))
        .clipShape(Capsule())
        .overlay(
            Capsule().stroke(Color(voci: 0xFF6B6B, opacity: 0.20), lineWidth: 0.5)
        )
    }

    // MARK: - Hotkey footer

    private var hotkeyFooter: some View {
        HStack(spacing: 10) {
            VocIcon(.mic, size: 13, color: accentColors.solid, weight: .semibold)
            Text("Press")
            KeyBadge("⌃", accent: true)
            KeyBadge("⌥", accent: true)
            KeyBadge("M", accent: true)
            Text("and speak to add a task by voice.")
        }
        .font(.system(size: 12))
        .foregroundStyle(VociColor.textSec)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(accentColors.solid.opacity(0.33), style: StrokeStyle(lineWidth: 0.5, dash: [4, 3]))
        )
    }

    /// Drives the running-focus pill's pulsing dot. Kept as an `@State` on the view (rather than
    /// `AppState`) since it's pure presentation, not app state.
    @State private var pulseTick = false

    private func fmtClock(_ seconds: Int) -> String {
        "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }

    /// Shared insert/remove transition for `TaskRow`s across the Now/Later/Completed sections —
    /// new rows drop in from just above, removed rows fade out and settle slightly smaller.
    private var rowTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: -6)),
            removal: .opacity.combined(with: .scale(scale: 0.97))
        )
    }
}

/// "All clear." empty state shown when there are no open tasks. Ported from `voci-mac.jsx`'s
/// `EmptyToday`. Private to `TodayView` — not part of the frozen component surface.
private struct EmptyTodayCard: View {
    @Environment(AppState.self) private var appState: AppState

    private var accentColors: Accent { appState.accent.accent }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(accentColors.surface)
                    .frame(width: 64, height: 64)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(accentColors.solid.opacity(0.20), lineWidth: 0.5)
                    )
                    .shadow(color: accentColors.glow.opacity(0.30), radius: 30)
                VocIcon(.mic, size: 28, color: accentColors.solid, weight: .light)
            }

            Text("All clear.")
                .font(.system(size: 22, weight: .medium))
                .tracking(-0.33)
                .foregroundStyle(VociColor.textPri)

            HStack(spacing: 4) {
                Text("Press")
                KeyBadge("⌃")
                KeyBadge("⌥")
                KeyBadge("M")
                Text("when you need to remember something.")
            }
            .font(.system(size: 13.5))
            .foregroundStyle(VociColor.textSec)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 300)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
