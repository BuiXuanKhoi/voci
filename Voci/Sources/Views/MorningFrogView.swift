// Sources/Views/MorningFrogView.swift — "Good morning" daily-frog modal, ported from
// `design/voci-extras.jsx`'s `VociMorningFrog`. Candidates are sourced live from
// `appState.openTasks` (title + "urgent" flag when priority == .high) instead of the prototype's
// static sample list. Picking a candidate only updates local selection state here — actually
// setting a task's `frog` flag needs a new AppState mutator, which is out of scope for this
// Phase-2 view (see the `// Phase 3` note below); no new AppState methods are added.
import SwiftUI

struct MorningFrogView: View {
    @State private var picked: UUID?

    @Environment(AppState.self) private var appState

    private var accentColors: Accent { appState.accent.accent }

    var body: some View {
        ZStack {
            // Dimmed background suggestion (the real Today window sits behind this modal).
            LinearGradient(colors: [VociColor.bg, VociColor.surface], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            modal
                .frame(maxWidth: 460)
                .padding(.horizontal, 40)
        }
        .frame(minWidth: 560, minHeight: 480)
    }

    private var modal: some View {
        VStack(spacing: 16) {
            Text("Good morning.")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(VociColor.textPri)

            Text("What's the one task that, if you finished it today, would make today a win?")
                .font(.system(size: 16))
                .foregroundStyle(VociColor.textPri)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            voiceCTA
                .padding(.top, 4)

            divider

            candidateList

            Button {
                // Skip today — dismissal is owned by whatever presents this modal (Phase 3).
            } label: {
                Text("Skip today")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(VociColor.textMut)
                    .frame(height: 32)
                    .padding(.horizontal, 14)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 32)
        .padding(.top, 36)
        .padding(.bottom, 24)
        .vociGlass(level: .heavy, cornerRadius: 16)
    }

    // MARK: - Voice CTA

    @State private var pulse = false

    private var voiceCTA: some View {
        Button {
            // Phase 3: wire to the real hold-to-talk gesture (HotkeyManager / SpeechCapture);
            // this artboard button is visual only.
        } label: {
            HStack(spacing: 10) {
                VocIcon(.mic, size: 16, color: accentColors.solid, weight: .regular)
                Text("Hold")
                    .font(.system(size: 14, weight: .medium))
                KeyBadge("Space", accent: true)
                Text("to answer")
                    .font(.system(size: 14, weight: .medium))
            }
            .foregroundStyle(accentColors.solid)
            .padding(.horizontal, 22)
            .frame(height: 48)
        }
        .buttonStyle(.plain)
        .background(accentColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(accentColors.solid.opacity(0.27), lineWidth: 0.5)
        )
        .shadow(color: accentColors.glow.opacity(pulse ? 0.55 : 0), radius: pulse ? 14 : 0)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private var divider: some View {
        HStack(spacing: 10) {
            Rectangle().fill(VociColor.border).frame(height: 0.5)
            Text("or")
                .font(.system(size: 11))
                .foregroundStyle(VociColor.textMut)
            Rectangle().fill(VociColor.border).frame(height: 0.5)
        }
    }

    // MARK: - Candidates

    private var candidateList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PICK FROM YOUR LIST")
                .font(.system(size: 11, weight: .medium))
                .tracking(0.77)
                .foregroundStyle(VociColor.textMut)
                .padding(.horizontal, 8)
                .padding(.bottom, 2)

            if appState.openTasks.isEmpty {
                Text("Nothing open today \u{2014} enjoy it.")
                    .font(.system(size: 13))
                    .foregroundStyle(VociColor.textSec)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            } else {
                ForEach(appState.openTasks) { candidate in
                    candidateRow(candidate)
                }
            }
        }
    }

    private func candidateRow(_ candidate: TaskItem) -> some View {
        let selected = picked == candidate.id
        return HStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(selected ? accentColors.solid : Color.white.opacity(0.28), lineWidth: 1.5)
                    .background(Circle().fill(selected ? accentColors.solid : Color.clear))
                    .frame(width: 14, height: 14)
                if selected {
                    VocIcon(.check, size: 9, color: .white, weight: .bold)
                }
            }

            Text(candidate.title)
                .font(.system(size: 13))
                .foregroundStyle(VociColor.textPri)
                .lineLimit(1)

            Spacer(minLength: 8)

            if candidate.priority == .high {
                HStack(spacing: 5) {
                    Circle().fill(VociColor.high).frame(width: 5, height: 5)
                    Text("urgent")
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(VociColor.high)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(VociColor.high.opacity(0.12))
                .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(selected ? accentColors.surface : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(selected ? accentColors.solid.opacity(0.27) : .clear, lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            picked = candidate.id
            // Phase 3: once AppState exposes a "set frog" mutator, call it here so the picked
            // candidate becomes today's frog task, e.g. `appState.setFrog(candidate.id)`. Not
            // added in this pass — the frozen §4 AppState surface isn't extended by Phase-2 views.
        }
    }
}

#Preview {
    MorningFrogView()
        .environment(AppState())
}
