// Sources/Views/MicFAB.swift — floating mic capture button (plan §2.2/§4.2, agent A4, T1).
//
// Ported from `design/volar-mobile.jsx`'s `MicButton`. Tap-to-toggle, NOT hold-to-talk (plan
// §2.2: "Khác bản Mac: hold-to-talk đổi thành tap-to-toggle" — holding a finger through a whole
// sentence blocks the screen on a phone). Drives `AppState.toggleCapture()` directly; no local
// capture-state machine here (`AppState.captureState` is the only source of truth — see
// `Shared/App/AppState.swift`).
//
// `RootTabView` (agent A2) renders this bare, `MicFAB()`, with no closure parameters.
import SwiftUI

/// 72pt (`IOSMetrics.fabSize`) circular mic/stop toggle. Fill is `appState.accent.accent.solid`
/// (ice blue) — NEVER mint (`VolarColor.nowAccent*` is reserved for the single NOW task, plan §4/
/// task brief rule 3). Halo is a radial `accent.glow` gradient, brighter while pressed (mirrors
/// the jsx `pressed` opacity swap 0.55 -> 1). Press scale 0.94 via `VolarMotion.press`.
struct MicFAB: View {
    @Environment(AppState.self) private var appState: AppState
    @State private var isPressed = false

    private var isRecording: Bool { appState.captureState == .recording }

    var body: some View {
        let accent = appState.accent.accent

        Button {
            appState.toggleCapture()
        } label: {
            ZStack {
                halo(accent: accent)
                dial(accent: accent)
                VolarIcon(isRecording ? .stop : .mic, size: 30, color: .white, weight: .regular)
            }
            // `IOSMetrics.fabSize` is already 72 (> `minTouch` 44), so the visible dial itself
            // satisfies the ≥44×44 touch-target rule with no extra invisible padding needed.
            .frame(width: IOSMetrics.fabSize, height: IOSMetrics.fabSize)
        }
        .buttonStyle(.plain)
        .scaleEffect(isPressed ? 0.94 : 1)
        .animation(VolarMotion.press, value: isPressed)
        .animation(VolarMotion.state, value: isRecording)
        // Press-state tracking for the halo/scale feedback, layered on top of `Button`'s own tap
        // gesture. `simultaneousGesture` (rather than a plain `.gesture`) is what keeps this from
        // stealing the tap — both recognize independently, matching the common SwiftUI
        // press-decoration pattern. // UNVERIFIED: not build/run-tested on this machine (Windows,
        // no Xcode) — the interaction between a `Button`'s implicit tap gesture and a
        // `simultaneousGesture(DragGesture(minimumDistance: 0))` on the exact same view is a
        // well-known pattern but hasn't been exercised in this repo before; if it turns out to
        // suppress taps on-device, replace with a custom `ButtonStyle` that reads
        // `configuration.isPressed` and pipes it into the halo via `.environment`.
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .accessibilityLabel(isRecording ? "Stop recording" : "Start voice capture")
        .accessibilityAddTraits(.isButton)
    }

    /// Radial `accent.glow` halo behind the dial. `allowsHitTesting(false)` so it never steals the
    /// tap from the dial itself.
    private func halo(accent: Accent) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [accent.glow, .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: IOSMetrics.fabSize * 0.75
                )
            )
            .frame(width: IOSMetrics.fabSize + 24, height: IOSMetrics.fabSize + 24)
            .opacity(isPressed ? 1 : 0.55)
            .allowsHitTesting(false)
    }

    /// The solid dial: `accent.solid` fill, hairline inner highlight (`VolarColor.veil`, never
    /// `Color.white.opacity(...)`), drop shadow tinted with `accent.glow`.
    private func dial(accent: Accent) -> some View {
        Circle()
            .fill(accent.solid)
            .overlay(
                Circle().strokeBorder(VolarColor.veil(0.25), lineWidth: 0.5)
            )
            .shadow(color: accent.glow, radius: 20, x: 0, y: 8)
    }
}

#Preview("Idle") {
    let state = AppState()
    return MicFAB()
        .environment(state)
        .padding(60)
        .background(VolarColor.bg)
}

#Preview("Recording") {
    let state = AppState()
    state.captureState = .recording
    return MicFAB()
        .environment(state)
        .padding(60)
        .background(VolarColor.bg)
}
