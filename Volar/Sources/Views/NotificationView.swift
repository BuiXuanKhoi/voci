// Sources/Views/NotificationView.swift — in-app notification banner artboard, ported from
// `design/volar-extras.jsx`'s `VolarNotification`. Parameterized (title/timing/Done/Snooze/
// Reschedule) with defaults matching the original sample copy so `#Preview` stays valid. Phase 3
// mounts it as an overlay banner on `TodayView` driven by `AppState.reminderBanner`, triggered
// manually via the menu-bar "Preview reminder" item (`AppState.showReminderPreview()`). Real
// reminders delivered via `UNUserNotificationCenter` on the actual task deadline are still
// pending — see backlog.
import SwiftUI

struct NotificationView: View {
    var title: String = "Customer call — Acme onboarding"
    var timing: String = "In 15 minutes · 2:00 PM"
    var onDone: () -> Void = {}
    var onSnooze: () -> Void = {}
    var onReschedule: () -> Void = {}

    @Environment(AppState.self) private var appState
    private var accentColors: Accent { appState.accent.accent }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(colors: [accentColors.solid, accentColors.hover], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 38, height: 38)
                    .overlay { VolarIcon(.mic, size: 20, color: .white, weight: .regular) }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Volar")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(VolarColor.textPri)
                        Text("\u{00B7} now")
                            .font(.system(size: 11))
                            .foregroundStyle(VolarColor.textSec)
                    }
                    Text("Coming up: \(title)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(VolarColor.textPri)
                        .lineLimit(2)
                    Text(timing)
                        .font(.system(size: 12))
                        .foregroundStyle(VolarColor.textSec)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                actionButton("Done", solid: false, action: onDone)
                actionButton("Snooze 10 min", solid: false, action: onSnooze)
                actionButton("Reschedule", solid: true, action: onReschedule)
            }
            .padding(.top, 2)
        }
        .padding(14)
        .frame(width: 380)
        .volarGlass(level: .heavy, tint: Color(volar: 0x282828), cornerRadius: 14)
    }

    private func actionButton(_ label: String, solid: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(solid ? accentColors.solid : VolarColor.textPri)
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
