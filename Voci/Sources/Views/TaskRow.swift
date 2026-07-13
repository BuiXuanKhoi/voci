// Sources/Views/TaskRow.swift — single task row (checkbox, title, priority/dur/frog subrow, time badge)
// Ported from `design/voci-mac.jsx`'s `TaskRow`.
import SwiftUI

struct TaskRow: View {
    let task: TaskItem
    let isActive: Bool

    @Environment(AppState.self) private var appState: AppState
    @State private var isHovering = false

    init(task: TaskItem, isActive: Bool) {
        self.task = task
        self.isActive = isActive
    }

    private var accentColors: Accent { appState.accent.accent }

    private var priorityColor: Color {
        switch task.priority {
        case .high: return VociColor.high
        case .medium: return VociColor.med
        case .low: return VociColor.low
        }
    }

    private var priorityLabel: String {
        switch task.priority {
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }

    /// Mirrors the prototype's `task.time` — the raw formatted deadline time shown (muted) once a
    /// task is done, independent of `timeBadge` (which is only ever populated for open tasks).
    private var rawTimeLabel: String? {
        guard let deadline = task.deadline else { return nil }
        return deadline.formatted(.dateTime.hour().minute())
    }

    private var rowBackground: Color {
        if isActive { return accentColors.surface }
        return isHovering ? VociColor.cardHover : VociColor.card
    }

    private var rowBorderColor: Color {
        isActive ? accentColors.solid.opacity(0.25) : VociColor.border
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            checkbox
            titleAndSubrow
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, appState.density.rowPadY)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(rowBorderColor, lineWidth: 0.5)
        )
        .overlay(
            // Extra inner hairline while active, mirroring the prototype's
            // `boxShadow: inset 0 0 0 0.5px accent30` treatment.
            Group {
                if isActive {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(accentColors.solid.opacity(0.19), lineWidth: 0.5)
                        .padding(0.5)
                }
            }
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        // Row tap opens the detail sheet (Phase 1); the checkbox above is its own `Button` and
        // consumes its own tap first, so toggling done never also opens the sheet.
        .onTapGesture { appState.openDetail(task.id) }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(.easeOut(duration: 0.12), value: isActive)
        .contextMenu {
            Button("Break down into steps…") { appState.showBreakdown = true }
            Button(task.done ? "Mark not done" : "Mark done") { appState.toggleDone(task.id) }
            Divider()
            Button("Delete", role: .destructive) { appState.deleteTask(task.id) }
        }
    }

    private var checkbox: some View {
        Button {
            appState.toggleDone(task.id)
        } label: {
            Circle()
                .strokeBorder(task.done ? accentColors.solid : Color.white.opacity(0.28), lineWidth: 1.5)
                .background(Circle().fill(task.done ? accentColors.solid : .clear))
                .frame(width: 17, height: 17)
                .overlay {
                    if task.done {
                        VocIcon(.check, size: 11, color: .white, weight: .bold)
                    }
                }
        }
        .buttonStyle(.plain)
        .padding(.top, 1)
    }

    private var titleAndSubrow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                if task.frog && !task.done {
                    Circle()
                        .fill(VociColor.high)
                        .frame(width: 5, height: 5)
                        .shadow(color: VociColor.high.opacity(0.5), radius: 3)
                }
                Text(task.title)
                    .font(.system(size: 13, weight: task.done ? .regular : .medium))
                    .tracking(-0.065)
                    .strikethrough(task.done, pattern: .solid, color: Color.white.opacity(0.25))
                    .foregroundStyle(task.done ? VociColor.textMut : VociColor.textPri)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            HStack(spacing: 8) {
                Circle().fill(priorityColor).frame(width: 5, height: 5)
                Text(task.done ? "Done" : priorityLabel)
                if let durationLabel = task.durationLabel, !task.done {
                    Text("·").opacity(0.4)
                    Text(durationLabel)
                }
                if task.frog && !task.done {
                    Text("·").opacity(0.4)
                    Text("Frog")
                        .fontWeight(.medium)
                        .tracking(0.22)
                        .foregroundStyle(VociColor.high)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(VociColor.textSec)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if let timeBadge = task.timeBadge, !task.done {
            TimeBadge(timeBadge, filled: isActive)
        } else if task.done, let rawTimeLabel {
            Text(rawTimeLabel)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(VociColor.textMut)
        }
    }
}
