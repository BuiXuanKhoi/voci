// Sources/Views/TaskDetailView.swift — task detail sheet: full description + read-aloud + actions.
// Phase 1: opened by tapping a `TaskRow`. Shows the task's `details` (the full sentence captured
// when the task was created by voice — blank for tasks that never went through that flow) and a
// "Read description" button that reuses `AppState.speakDetails(of:)`. Reads the live task off
// `AppState.detailTask` (rather than taking one as a param) so toggling done / editing elsewhere
// is reflected immediately while the sheet is open.
import SwiftUI

struct TaskDetailView: View {
    @Environment(AppState.self) private var appState

    private var accentColors: Accent { appState.accent.accent }

    var body: some View {
        if let task = appState.detailTask {
            content(for: task)
        } else {
            // Sheet is mid-dismiss (or detailTaskID got cleared out from under us) — nothing to show.
            EmptyView()
        }
    }

    private func content(for task: TaskItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            header(task)
            metaRow(task)
            descriptionSection(task)
            actions(task)
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 520)
        .volarGlass(level: .heavy, cornerRadius: 16)
    }

    // MARK: - Header

    private func header(_ task: TaskItem) -> some View {
        HStack(spacing: 8) {
            if task.frog && !task.done {
                Circle()
                    .fill(VolarColor.high)
                    .frame(width: 6, height: 6)
                    .shadow(color: VolarColor.high.opacity(0.5), radius: 3)
            }
            Text(task.title)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(VolarColor.textPri)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Meta row (priority · deadline · duration · status) — labels mirror `TaskRow`.

    private func priorityColor(_ task: TaskItem) -> Color {
        switch task.priority {
        case .high: return VolarColor.high
        case .medium: return VolarColor.med
        case .low: return VolarColor.low
        }
    }

    private func priorityLabel(_ task: TaskItem) -> String {
        switch task.priority {
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }

    private func metaRow(_ task: TaskItem) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(priorityColor(task)).frame(width: 6, height: 6)
                Text(priorityLabel(task))
            }
            if let deadline = task.deadline {
                Text("\u{00B7}").opacity(0.4)
                Text(deadline.formatted(.dateTime.hour().minute()))
            }
            if let durationLabel = task.durationLabel {
                Text("\u{00B7}").opacity(0.4)
                Text(durationLabel)
            }
            Text("\u{00B7}").opacity(0.4)
            Text(task.done ? "Done" : "Open")
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(VolarColor.textSec)
    }

    // MARK: - Description

    private func descriptionSection(_ task: TaskItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DESCRIPTION")
                .font(.system(size: 11, weight: .medium))
                .tracking(0.77)
                .foregroundStyle(VolarColor.textMut)

            ScrollView {
                Group {
                    if task.details.isEmpty {
                        Text("No description")
                            .foregroundStyle(VolarColor.textMut.opacity(0.7))
                    } else {
                        Text(task.details)
                            .foregroundStyle(VolarColor.textSec)
                    }
                }
                .font(.system(size: 14))
                .lineSpacing(5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .frame(maxHeight: .infinity)
            .background(VolarColor.card)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .volarHairline(cornerRadius: 12)

            readButton(task)
        }
        .frame(maxHeight: .infinity)
    }

    private func readButton(_ task: TaskItem) -> some View {
        Button {
            appState.speakDetails(of: task)
        } label: {
            HStack(spacing: 8) {
                VolarIcon(.volume, size: 13, color: accentColors.solid, weight: .regular)
                Text("Read description")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(accentColors.solid)
            .padding(.horizontal, 12)
            .frame(height: 30)
        }
        .buttonStyle(.plain)
        .background(accentColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(accentColors.solid.opacity(0.2), lineWidth: 0.5)
        )
    }

    // MARK: - Actions

    private func actions(_ task: TaskItem) -> some View {
        HStack(spacing: 8) {
            Button {
                appState.closeDetail()
            } label: {
                Text("Close")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(VolarColor.textPri)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
            }
            .buttonStyle(.plain)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .volarHairline(cornerRadius: 9)

            Button(role: .destructive) {
                appState.deleteTask(task.id)
                appState.closeDetail()
            } label: {
                Text("Delete")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(VolarColor.high)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
            }
            .buttonStyle(.plain)
            .background(VolarColor.high.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(VolarColor.high.opacity(0.25), lineWidth: 0.5)
            )

            Spacer(minLength: 0)

            Button {
                appState.toggleDone(task.id)
            } label: {
                Text(task.done ? "Mark not done" : "Mark done")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 34)
            }
            .buttonStyle(.plain)
            .background(accentColors.solid)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .shadow(color: accentColors.glow, radius: 12, y: 4)
        }
    }
}

#Preview {
    let appState = AppState(tasks: SampleData.tasks)
    appState.detailTaskID = SampleData.tasks.first?.id
    return TaskDetailView()
        .environment(appState)
}
