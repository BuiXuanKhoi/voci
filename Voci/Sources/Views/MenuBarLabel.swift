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
    @State private var glow = false

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
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                glow = true
            }
        }
    }

    // MARK: - Idle

    private var idleContent: some View {
        VocIcon(.mic, size: 14, color: Color.white.opacity(0.7), weight: .regular)
    }

    // MARK: - Listening

    private var listeningContent: some View {
        HStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(accentColors.glow)
                    .frame(width: 16, height: 16)
                    .opacity(glow ? 0.15 : 0.4)
                    .blur(radius: 3)
                VocIcon(.mic, size: 14, color: accentColors.solid, weight: .semibold)
            }
            Text("REC")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(accentColors.solid)
                .tracking(0.3)
        }
    }

    // MARK: - Focus lock

    private var focusLockContent: some View {
        HStack(spacing: 5) {
            ZStack(alignment: .bottomTrailing) {
                VocIcon(.mic, size: 14, color: accentColors.solid, weight: .semibold)
                Circle()
                    .fill(accentColors.solid)
                    .frame(width: 6, height: 6)
                    .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 0.5))
                    .shadow(color: accentColors.glow, radius: 3)
                    .offset(x: 2, y: 2)
            }

            if let title = appState.activeTask?.title {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(accentColors.solid)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 120, alignment: .leading)

                Text("\u{00B7}")
                    .font(.system(size: 11))
                    .foregroundStyle(VociColor.textMut)
            }

            Text(timerLabel)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(accentColors.solid)
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
