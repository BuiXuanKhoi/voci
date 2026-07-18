// Sources/Views/TaskBreakdownView.swift — AI task-breakdown artboard, ported from
// `design/volar-extras.jsx`'s `VolarTaskBreakdown`. Steps are still static/sample content by
// design — wiring a real breakdown generator into VolarCore/NLParser is a later phase — but the
// sheet is now live: Phase 3 mounts it from `TaskRow`'s "Break down into steps…" context-menu
// item, and "Save all as tasks" persists the sample step titles as real `TaskItem`s via
// `AppState.saveBreakdown(_:)`.
import SwiftUI

struct TaskBreakdownView: View {
    private struct Step: Identifiable {
        var id: Int { number }
        let number: Int
        let label: String
        let duration: String
    }

    private let steps: [Step] = [
        Step(number: 1, label: "Open Framer", duration: "10 min"),
        Step(number: 2, label: "Draft headline + subhead", duration: "5 min"),
        Step(number: 3, label: "Drop in demo screenshot", duration: "10 min"),
        Step(number: 4, label: "Test email signup form", duration: "10 min"),
        Step(number: 5, label: "Publish + share link", duration: "5 min"),
    ]
    private let totalLabel = "40 min"

    var onSave: ([String]) -> Void = { _ in }
    var onClose: () -> Void = {}

    @Environment(AppState.self) private var appState
    private var accentColors: Accent { appState.accent.accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            stepsCard
            summary
            Spacer(minLength: 0)
            actions
        }
        .padding(16)
        .frame(width: 480, height: 540)
        .volarGlass(level: .heavy, cornerRadius: 16)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("BREAKING DOWN")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(0.77)
                    .foregroundStyle(VolarColor.textMut)
                Text("\u{201C}Launch landing page\u{201D}")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(VolarColor.textPri)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                VolarIcon(.sparkle, size: 11, color: accentColors.solid, weight: .regular)
                Text("AI")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(accentColors.solid)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(accentColors.surface)
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(accentColors.solid.opacity(0.2), lineWidth: 0.5)
            )
        }
    }

    // MARK: - Steps card

    private var stepsCard: some View {
        VStack(spacing: 2) {
            ForEach(steps) { step in
                stepRow(step)
            }
        }
        .padding(6)
        .background(VolarColor.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .volarHairline(cornerRadius: 12)
    }

    private func stepRow(_ step: Step) -> some View {
        HStack(spacing: 12) {
            VStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { _ in
                    Rectangle().fill(VolarColor.textSec).frame(width: 12, height: 1)
                }
            }
            .opacity(0.35)

            Text("\(step.number)")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(accentColors.solid)
                .frame(width: 22, height: 22)
                .background(accentColors.surface)
                .clipShape(Circle())
                .overlay(Circle().stroke(accentColors.solid.opacity(0.2), lineWidth: 0.5))

            Text(step.label)
                .font(.system(size: 13))
                .foregroundStyle(VolarColor.textPri)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(step.duration)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(VolarColor.textSec)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.white.opacity(0.04))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(VolarColor.border, lineWidth: 0.5))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }

    // MARK: - Summary

    private var summary: some View {
        HStack {
            (
                Text("Total: ")
                    .foregroundStyle(VolarColor.textSec)
                + Text(totalLabel)
                    .foregroundStyle(VolarColor.textPri)
                + Text(" \u{00B7} \(steps.count) sub-tasks")
                    .foregroundStyle(VolarColor.textSec)
            )
            .font(.system(size: 12))
            Spacer()
            Text("Drag to reorder \u{00B7} click to edit")
                .font(.system(size: 12))
                .foregroundStyle(VolarColor.textMut)
        }
        .padding(.horizontal, 6)
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    // Real per-step editing lands with the AI-breakdown generator; for now, "Edit"
                    // just dismisses like Cancel.
                    onClose()
                } label: {
                    Text("Edit")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(VolarColor.textPri)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                }
                .buttonStyle(.plain)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .volarHairline(cornerRadius: 9)

                Button {
                    onClose()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(VolarColor.textPri)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                }
                .buttonStyle(.plain)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .volarHairline(cornerRadius: 9)

                // FIX G: the 5 steps above are hard-coded sample content ("Open Framer", "Draft
                // headline + subhead", ...) — this button used to persist them as real tasks via
                // `onSave`/`AppState.saveBreakdown`, silently adding sample junk to the user's list
                // regardless of which task's context menu opened this sheet. Disabled (with an
                // explanatory caption below) until a real breakdown generator actually produces
                // per-task steps; `AppState.saveBreakdown` itself is untouched so wiring this back
                // up later is a one-line change (drop `.disabled`).
                Button {
                    onSave(steps.map(\.label))
                } label: {
                    HStack(spacing: 8) {
                        Text("Save all as tasks")
                        Text("\u{21A9}").opacity(0.85)
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                }
                .buttonStyle(.plain)
                .background(accentColors.solid)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .shadow(color: accentColors.glow, radius: 12, y: 4)
                .disabled(true)
            }
            Text("Breakdown generator coming soon")
                .font(.system(size: 11))
                .foregroundStyle(VolarColor.textMut)
        }
    }
}

#Preview {
    TaskBreakdownView()
        .environment(AppState())
}
