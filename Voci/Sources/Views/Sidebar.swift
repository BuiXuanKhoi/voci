// Sources/Views/Sidebar.swift — capture button + Focus nav + on-device footer
// Ported from `design/voci-mac.jsx`'s sidebar column.
import SwiftUI

struct Sidebar: View {
    @Environment(AppState.self) private var appState: AppState

    private var accentColors: Accent { appState.accent.accent }

    var body: some View {
        VStack(spacing: 0) {
            captureButton
                .padding(.horizontal, 10)
                .padding(.top, 12)
                .padding(.bottom, 4)

            keyBadgeRow
                .padding(.bottom, 4)

            focusSectionLabel

            VStack(spacing: 1) {
                SidebarItem(
                    icon: .today,
                    label: "Today",
                    count: appState.openTasks.count,
                    active: true
                ) {}
                SidebarItem(
                    icon: .upcoming,
                    label: "Upcoming",
                    count: 12,
                    active: false
                ) {}
                SidebarItem(
                    icon: .inbox,
                    label: "Inbox",
                    count: 3,
                    active: false
                ) {}
            }
            .padding(.horizontal, 8)

            Spacer(minLength: 0)

            onDeviceFooter
                .padding(.horizontal, 10)
        }
        .padding(.bottom, 12)
        .frame(width: 160)
        .frame(maxHeight: .infinity)
        .background(sidebarBackground)
        .overlay(alignment: .trailing) {
            Rectangle().fill(VociColor.border).frame(width: 0.5)
        }
    }

    @ViewBuilder
    private var sidebarBackground: some View {
        if appState.ambient != .none {
            Rectangle()
                .fill(appState.glass.material)
                .overlay(VociColor.surface.opacity(0.45))
        } else {
            VociColor.surface
        }
    }

    private var captureButton: some View {
        Button {
            appState.toggleCapture()
        } label: {
            HStack(spacing: 7) {
                VocIcon(.mic, size: 13, color: accentColors.solid, weight: .semibold)
                Text(appState.captureState == .recording ? "Tap to stop" : "Tap to speak")
                    .font(.system(size: 12, weight: .medium))
                    .tracking(-0.06)
            }
            .foregroundStyle(accentColors.solid)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
        }
        .buttonStyle(CaptureButtonStyle(accentColor: accentColors.solid))
    }

    private var keyBadgeRow: some View {
        HStack(spacing: 4) {
            KeyBadge("⌃")
            KeyBadge("⌥")
            KeyBadge("M")
        }
        .frame(maxWidth: .infinity)
    }

    private var focusSectionLabel: some View {
        Text("Focus")
            .font(.system(size: 10.5, weight: .medium))
            .tracking(0.735)
            .textCase(.uppercase)
            .foregroundStyle(VociColor.textMut)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 6)
    }

    private var onDeviceFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(accentColors.solid).frame(width: 5, height: 5)
                Text("On-device")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(VociColor.textPri)
            }
            Text("Audio is parsed locally. Nothing leaves your Mac.")
                .font(.system(size: 11))
                .foregroundStyle(VociColor.textSec)
                .lineSpacing(2)
        }
        .padding(10)
        .background(Color.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(VociColor.border, lineWidth: 0.5)
        )
    }
}

/// Gives the "Tap to speak" capture button a press-down highlight (mirrors the prototype's
/// mousedown/up-driven `holdHint` inset glow) using `ButtonStyle`'s own `isPressed` state, rather
/// than a second overlapping gesture recognizer that could compete with the button's tap.
private struct CaptureButtonStyle: ButtonStyle {
    let accentColor: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(accentColor.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(accentColor.opacity(configuration.isPressed ? 0.9 : 0.27), lineWidth: configuration.isPressed ? 1 : 0.5)
            )
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Single sidebar nav row (icon + label + trailing count). Ported from `voci-mac.jsx`'s
/// `SidebarItem`. Private to `Sidebar` — not part of the frozen component surface.
private struct SidebarItem: View {
    let icon: VocIconName
    let label: String
    let count: Int?
    let active: Bool
    let action: () -> Void

    @Environment(AppState.self) private var appState: AppState
    @State private var isHovering = false

    private var accentColors: Accent { appState.accent.accent }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                VocIcon(icon, size: 14, color: active ? accentColors.solid : VociColor.textSec)
                Text(label)
                    .font(.system(size: 13, weight: active ? .medium : .regular))
                    .tracking(-0.065)
                    .foregroundStyle(active ? accentColors.solid : VociColor.textPri)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let count {
                    Text("\(count)")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(active ? accentColors.solid : VociColor.textMut)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .background(active ? accentColors.surface : (isHovering ? Color.white.opacity(0.04) : .clear))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.1), value: isHovering)
    }
}
