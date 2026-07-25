// Sources/Views/Components.swift — shared components (frozen §5): KeyBadge, PriorityBadge,
// TimeBadge, Spinner, ToolButton, SectionHeader. GlassBackground itself lives in Design/Glass.swift.
//
// KeyBadge/TimeBadge/ToolButton/SectionHeader read the active accent from `@Environment(AppState.self)`
// (so their frozen init signatures don't need an extra color parameter). `VolarApp.swift` injects
// `AppState` via `.environment(appState)` at the Window/MenuBarExtra root, so any Phase-2 view
// mounted inside those scenes gets it for free. Standalone `#Preview`s of these components must
// add `.environment(AppState())` themselves, same as the `@EnvironmentObject` convention.
import SwiftUI

/// ⌃ ⌥ Space-style key chip. Ported from `volar-mac.jsx`'s `KeyBadge`.
struct KeyBadge: View {
    let text: String
    var accent: Bool

    @Environment(AppState.self) private var appState: AppState

    init(_ text: String, accent: Bool = false) {
        self.text = text
        self.accent = accent
    }

    private var accentColors: Accent { appState.accent.accent }

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .foregroundStyle(accent ? accentColors.solid : VolarColor.textSec)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(accent ? accentColors.surface : Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(accent ? accentColors.solid.opacity(0.33) : Color.white.opacity(0.10), lineWidth: 0.5)
            )
    }
}

/// Dot + High/Medium/Low pill. Ported from `volar-popover.jsx`'s `PriorityBadge`.
struct PriorityBadge: View {
    let priority: Priority

    init(_ priority: Priority) {
        self.priority = priority
    }

    private var style: (dot: Color, background: Color, foreground: Color, label: String) {
        switch priority {
        case .high:
            return (VolarColor.high, VolarColor.high.opacity(0.14), VolarColor.high, "High")
        case .medium:
            return (VolarColor.med, VolarColor.med.opacity(0.14), VolarColor.med, "Medium")
        case .low:
            return (VolarColor.low, Color.white.opacity(0.05), VolarColor.textSec, "Low")
        }
    }

    var body: some View {
        let s = style
        HStack(spacing: 6) {
            Circle().fill(s.dot).frame(width: 6, height: 6)
            Text(s.label)
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(s.foreground)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(s.background)
        .clipShape(Capsule())
    }
}

/// Accent time pill. Ported from `volar-popover.jsx`'s `TimeBadge`; `filled` mirrors the
/// "isActive" solid-fill variant used in `volar-mac.jsx`'s `TaskRow`.
struct TimeBadge: View {
    let text: String
    var filled: Bool

    @Environment(AppState.self) private var appState: AppState

    init(_ text: String, filled: Bool = false) {
        self.text = text
        self.filled = filled
    }

    private var accentColors: Accent { appState.accent.accent }

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(filled ? Color.white : accentColors.solid)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(filled ? accentColors.solid : accentColors.surface)
            .clipShape(Capsule())
    }
}

/// Rotating ring spinner. Ported from `volar-popover.jsx`'s `Spinner`.
struct Spinner: View {
    let color: Color
    var size: CGFloat = 14

    @State private var isSpinning = false

    init(color: Color, size: CGFloat = 14) {
        self.color = color
        self.size = size
    }

    var body: some View {
        Circle()
            .stroke(color.opacity(0.2), lineWidth: 1.6)
            .overlay(
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .rotationEffect(.degrees(isSpinning ? 360 : 0))
            )
            .frame(width: size, height: size)
            .onAppear {
                withAnimation(.linear(duration: 0.7).repeatForever(autoreverses: false)) {
                    isSpinning = true
                }
            }
    }
}

/// Small square icon button used in the title bar / sidebar. Ported from `volar-mac.jsx`'s
/// `ToolButton` (`accent` = solid accent fill, `tint` = accent-tinted "activeTint" state).
struct ToolButton: View {
    let icon: VolarIconName
    var accent: Bool
    var tint: Bool
    let action: () -> Void

    @Environment(AppState.self) private var appState: AppState
    @State private var isHovering = false

    init(icon: VolarIconName, accent: Bool = false, tint: Bool = false, action: @escaping () -> Void) {
        self.icon = icon
        self.accent = accent
        self.tint = tint
        self.action = action
    }

    private var accentColors: Accent { appState.accent.accent }

    private var foreground: Color {
        if accent { return .white }
        if tint { return accentColors.solid }
        return VolarColor.textSec
    }

    private var background: Color {
        if accent { return isHovering ? accentColors.hover : accentColors.solid }
        if tint { return accentColors.surface }
        return isHovering ? Color.white.opacity(0.08) : .clear
    }

    var body: some View {
        Button(action: action) {
            VolarIcon(icon, size: 14, color: foreground, weight: .regular)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(ToolButtonStyle())
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { isHovering = $0 }
        .animation(VolarMotion.hover, value: isHovering)
    }
}

/// Subtle press-down scale for `ToolButton`, layered via `ButtonStyle` so it composes with the
/// existing hover-driven background/foreground without a second competing gesture recognizer.
private struct ToolButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(VolarMotion.press, value: configuration.isPressed)
    }
}

/// "NOW" / "LATER TODAY" / "COMPLETED" section label with a hairline rule + optional count.
/// Ported from `volar-mac.jsx`'s inline section-header markup.
struct SectionHeader: View {
    let title: String
    let count: Int?
    var accent: Bool

    @Environment(AppState.self) private var appState: AppState

    init(_ title: String, count: Int?, accent: Bool = false) {
        self.title = title
        self.count = count
        self.accent = accent
    }

    private var accentColors: Accent { appState.accent.accent }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .tracking(0.735) // 0.07em at 10.5pt
                .textCase(.uppercase)
                .foregroundStyle(accent ? accentColors.solid : VolarColor.textMut)
            Rectangle()
                .fill(VolarColor.border)
                .frame(height: 0.5)
            if let count {
                Text("\(count)")
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(VolarColor.textMut)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
    }
}
