// Sources/Views/OnboardingView.swift — 3-step first-run onboarding, ported from
// `design/voci-extras.jsx`'s `VociOnboardingStep`. Native-first: no faux titlebar (a real window
// already has real traffic lights), just the step content + dots + footer. Step advancement here
// is purely cosmetic UI state; real permission requests are Phase 3.
import SwiftUI

struct OnboardingView: View {
    @State private var step: Int
    var onComplete: () -> Void = {}

    @Environment(AppState.self) private var appState

    init(step: Int = 1, onComplete: @escaping () -> Void = {}) {
        _step = State(initialValue: step)
        self.onComplete = onComplete
    }

    private var accentColors: Accent { appState.accent.accent }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                Spacer()
                stepContent
                    .frame(maxWidth: 460, alignment: .leading)
                    .padding(40)
                Spacer()
                footer
            }
            stepDots
                .padding(.top, 20)
                .padding(.trailing, 24)
        }
        .frame(minWidth: 640, minHeight: 440)
        .background(VociColor.bg)
    }

    // MARK: - Step dots

    private var stepDots: some View {
        HStack(spacing: 6) {
            ForEach(1...3, id: \.self) { i in
                Capsule()
                    .fill(i == step ? accentColors.solid : Color.white.opacity(0.15))
                    .frame(width: i == step ? 18 : 6, height: 6)
                    .animation(.easeOut(duration: 0.2), value: step)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("Step \(step) of 3")
                .foregroundStyle(VociColor.textMut)
            Spacer()
            Text("voci.app")
                .foregroundStyle(VociColor.textSec)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .overlay(alignment: .top) {
            Rectangle().fill(VociColor.border).frame(height: 0.5)
        }
    }

    // MARK: - Step content

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case 1: stepOne
        case 2: stepTwo
        default: stepThree
        }
    }

    private func title(_ text: Text) -> some View {
        text
            .font(.system(size: 32, weight: .medium))
            .foregroundStyle(VociColor.textPri)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func subtitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15))
            .foregroundStyle(VociColor.textSec)
            .lineSpacing(4)
            .frame(maxWidth: 420, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Step 1: hotkey intro

    private var stepOne: some View {
        VStack(alignment: .leading, spacing: 0) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [accentColors.solid, accentColors.hover], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 84, height: 84)
                .overlay { VocIcon(.mic, size: 42, color: .white, weight: .regular) }
                .shadow(color: accentColors.glow, radius: 24, y: 10)
                .padding(.bottom, 28)

            HStack(spacing: 8) {
                Text("Press")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(VociColor.textPri)
                KeyBadge("\u{2303}", accent: true)
                KeyBadge("\u{2325}", accent: true)
                KeyBadge("M", accent: true)
                Text(".")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(VociColor.textPri)
            }
            .padding(.bottom, 2)

            title(Text("Speak. Done."))
                .padding(.bottom, 14)

            subtitle("Voci is a voice-first task manager. No typing, no menus — just press the hotkey from anywhere on your Mac and say what you need to do.")
                .padding(.bottom, 30)

            Button {
                withAnimation { step = 2 }
            } label: {
                HStack(spacing: 6) {
                    Text("Get started")
                    Text("\u{2192}")
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .frame(height: 44)
            }
            .buttonStyle(.plain)
            .background(accentColors.solid)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .shadow(color: accentColors.glow, radius: 20, y: 6)
        }
    }

    // MARK: - Step 2: mic permission

    private var stepTwo: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                ForEach(1..<4, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(accentColors.solid.opacity(0.15 / Double(i)), lineWidth: 1)
                        .frame(width: 84 + CGFloat(i) * 12, height: 84 + CGFloat(i) * 12)
                }
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(accentColors.surface)
                    .frame(width: 84, height: 84)
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(accentColors.solid.opacity(0.33), lineWidth: 0.5)
                    }
                    .overlay { VocIcon(.mic, size: 42, color: accentColors.solid, weight: .regular) }
            }
            .frame(width: 84, height: 84)
            .padding(.bottom, 28)

            title(Text("Voci needs your microphone."))
                .padding(.bottom, 14)

            subtitle("Audio is processed on-device using Apple's Speech framework. Nothing is uploaded. Nothing is stored. The waveform stays on your Mac.")
                .padding(.bottom, 30)

            HStack(spacing: 10) {
                Button {
                    Task {
                        _ = await appState.speech.requestAuthorization()
                        withAnimation { step = 3 }
                    }
                } label: {
                    Text("Allow microphone")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .frame(height: 44)
                }
                .buttonStyle(.plain)
                .background(accentColors.solid)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .shadow(color: accentColors.glow, radius: 20, y: 6)

                Button {
                    withAnimation { step = 3 }
                } label: {
                    Text("Not now")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(VociColor.textSec)
                        .padding(.horizontal, 18)
                        .frame(height: 44)
                }
                .buttonStyle(.plain)
                .vociHairline(cornerRadius: 11)
            }
            .padding(.bottom, 22)

            HStack(spacing: 8) {
                Circle().fill(VociColor.done).frame(width: 6, height: 6)
                Text("On-device \u{00B7} No network calls")
            }
            .font(.system(size: 12))
            .foregroundStyle(VociColor.textMut)
        }
    }

    // MARK: - Step 3: try it

    private var stepThree: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                KeyBadge("\u{2303}", accent: true)
                KeyBadge("\u{2325}", accent: true)
                KeyBadge("M", accent: true)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(accentColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(accentColors.solid.opacity(0.27), lineWidth: 0.5)
            )
            .padding(.bottom, 32)

            title(Text("Try it now."))
                .padding(.bottom, 14)

            subtitle("Press the hotkey and say your first task. We'll parse the time, priority, and project for you.")
                .padding(.bottom, 22)

            VStack(alignment: .leading, spacing: 4) {
                Text("TRY SAYING")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(0.7)
                    .foregroundStyle(VociColor.textMut)
                Text("\u{201C}Call John tomorrow at 3pm, high priority\u{201D}")
                    .font(.system(size: 14))
                    .foregroundStyle(VociColor.textPri)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: 460, alignment: .leading)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .vociHairline(cornerRadius: 12)
            .padding(.bottom, 22)

            Button {
                onComplete()
            } label: {
                HStack(spacing: 6) {
                    Text("Start using Voci")
                    Text("\u{2192}")
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .frame(height: 44)
            }
            .buttonStyle(.plain)
            .background(accentColors.solid)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .shadow(color: accentColors.glow, radius: 20, y: 6)
            .padding(.bottom, 10)

            Button {
                onComplete()
            } label: {
                Text("Skip for now")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(VociColor.textSec)
                    .frame(height: 36)
                    .padding(.horizontal, 14)
            }
            .buttonStyle(.plain)
        }
    }
}

#Preview {
    OnboardingView()
        .environment(AppState())
}

#Preview("Step 2") {
    OnboardingView(step: 2)
        .environment(AppState())
}

#Preview("Step 3") {
    OnboardingView(step: 3)
        .environment(AppState())
}
