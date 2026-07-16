// Sources/Views/MenuBarLabel.swift — the actual MenuBarExtra label, ported from
// `design/voci-extras.jsx`'s `VociMenuBar`. Three states driven by AppState: idle (plain mic),
// listening (`captureState == .recording`, accent mic + "REC"), and focus lock (`focusActive`,
// mic + accent dot + truncated active-task title + mono countdown). Kept compact for the actual
// menu-bar bar (no glass panel / fake system icons — those were only there to stage the artboard
// in the prototype).
import Foundation
import SwiftUI

struct MenuBarLabel: View {
    @Environment(AppState.self) private var appState

    private var accentColors: Accent { appState.accent.accent }

    var body: some View {
        Group {
            if appState.focusActive {
                focusLockContent
            } else if appState.captureState == .recording {
                listeningContent
            } else {
                idleContent
            }
        }
    }

    // MARK: - Idle

    // Studio Dark: calm/quiet at rest — muted secondary-text tone rather than a raw white, so the
    // idle glyph recedes in the menu bar instead of reading as "on". UNVERIFIED (not rendered).
    private var idleContent: some View {
        VocIcon(.mic, size: 14, color: VociColor.textSec, weight: .regular)
    }

    // MARK: - Listening

    // Recording/capture indicator — intentionally still driven by `appState.accent` (the user's
    // selectable accent, preserved binding), NOT the reserved `nowAccent` spotlight: this badge
    // means "capturing audio", not "this is the NOW task". Only the font face moves to the
    // `vociMono` instrument token for Studio Dark fidelity. UNVERIFIED (not rendered).
    private var listeningContent: some View {
        HStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(accentColors.glow)
                    .frame(width: 16, height: 16)
                    .opacity(0.3)
                    .blur(radius: 3)
                VocIcon(.mic, size: 14, color: accentColors.solid, weight: .semibold)
            }
            Text("REC")
                .font(Font.vociMono(size: 10.5, weight: .medium))
                .foregroundStyle(accentColors.solid)
                .tracking(0.3)
        }
    }

    // MARK: - Focus lock

    // This IS the single NOW/active task, so the small lock badge (mic + dot) is the one place in
    // the menu bar allowed to carry the reserved warm `nowAccent` — used sparingly on the badge
    // only, never washed across the title. The title itself stays calm/legible primary text; the
    // countdown is an instrument readout (mono face, cool `instrument` tone) per Theme.swift's own
    // "timers" example under §05. No looping/breathing animation added — static only, per the
    // historical AppKit layout-thrash removal. UNVERIFIED (not rendered).
    private var focusLockContent: some View {
        HStack(spacing: 5) {
            ZStack(alignment: .bottomTrailing) {
                VocIcon(.mic, size: 14, color: VociColor.nowAccent, weight: .semibold)
                Circle()
                    .fill(VociColor.nowAccent)
                    .frame(width: 6, height: 6)
                    .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 0.5))
                    .shadow(color: VociColor.nowGlow, radius: 3)
                    .offset(x: 2, y: 2)
            }

            if let title = appState.activeTask?.title {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(VociColor.textPri)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 120, alignment: .leading)

                Text("\u{00B7}")
                    .font(.system(size: 11))
                    .foregroundStyle(VociColor.textMut)
            }

            Text(timerLabel)
                .font(Font.vociMono(size: 11, weight: .medium))
                .foregroundStyle(VociColor.instrument)
                .monospacedDigit()
        }
    }

    private var timerLabel: String {
        let seconds = max(appState.focusSecondsLeft, 0)
        let minutes = seconds / 60
        let remainder = seconds % 60
        return String(format: "%02d:%02d", minutes, remainder)
    }
}

#Preview("Idle") {
    MenuBarLabel()
        .environment(AppState())
        .padding()
        .background(Color.black)
}

#Preview("Focus lock") {
    let appState = AppState()
    appState.focusActive = true
    appState.focusSecondsLeft = 2538
    return MenuBarLabel()
        .environment(appState)
        .padding()
        .background(Color.black)
}
