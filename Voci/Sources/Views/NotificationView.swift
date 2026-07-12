// Sources/Views/NotificationView.swift — in-app notification artboard, ported from
// `design/voci-extras.jsx`'s `VociNotification`. Static design surface with sample copy; real
// reminders are delivered via `UNUserNotificationCenter` in Phase 3 — this view is just the
// visual reference / optional in-app preview.
import SwiftUI

struct NotificationView: View {
    @Environment(AppState.self) private var appState
    private var accentColors: Accent { appState.accent.accent }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(colors: [accentColors.solid, accentColors.hover], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 38, height: 38)
                    .overlay { VocIcon(.mic, size: 20, color: .white, weight: .regular) }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Voci")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(VociColor.textPri)
                        Text("\u{00B7} now")
                            .font(.system(size: 11))
                            .foregroundStyle(VociColor.textSec)
                    }
                    Text("Coming up: Customer call \u{2014} Acme onboarding")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(VociColor.textPri)
                        .lineLimit(2)
                    Text("In 15 minutes \u{00B7} 2:00 PM")
                        .font(.system(size: 12))
                        .foregroundStyle(VociColor.textSec)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                actionButton("Done", solid: false)
                actionButton("Snooze 10 min", solid: false)
                actionButton("Reschedule", solid: true)
            }
            .padding(.top, 2)
        }
        .padding(14)
        .frame(width: 380)
        .vociGlass(level: .heavy, tint: Color(voci: 0x282828), cornerRadius: 14)
    }

    private func actionButton(_ label: String, solid: Bool) -> some View {
        Button {
            // Static artboard — Done/Snooze/Reschedule wire into UNUserNotificationCenter
            // actions in Phase 3.
        } label: {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(solid ? accentColors.solid : VociColor.textPri)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
        }
        .buttonStyle(.plain)
        .background(solid ? accentColors.surface : Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(solid ? accentColors.solid.opacity(0.27) : Color.white.opacity(0.06), lineWidth: 0.5)
        )
    }
}

#Preview {
    NotificationView()
        .environment(AppState())
        .padding()
        .background(Color.black)
}
