// Sources/Views/SweepView.swift — evening sweep batch card (Phase 5, T038 view half,
// contracts/phase5-contract.md §B). Presented once per day (ISO-day gate is the App-wiring
// agent's job in AppState/PopoverView — T038) for today's still-open/in-progress tasks, read
// back for rapid batch completion (FR-021). Anti-shame per FR-036 + constitution V: no red, no
// overdue/streak badges, no "you didn't finish" copy — "Skip" just means "didn't get to it
// today," carried over silently, same as any other day. Self-contained: reads only the injected
// `items` + three action closures, touches no app state, no persistence, no other files. Sibling
// of `TriageView.swift` — deliberately mirrors its card shell (header/list/footer, glass level,
// row hairline/hover) so the two batch surfaces read as one family.
//
// UNVERIFIED — authored on Windows, no Swift toolchain available here; not compiled or run.
// Needs a Mac build/SwiftUI preview pass before shipping.
import SwiftUI

struct SweepView: View {
    let items: [TaskItem]
    var onComplete: (TaskItem) -> Void = { _ in }
    var onSkip: (TaskItem) -> Void = { _ in }
    var onDismiss: () -> Void = {}

    private let maxListHeight: CGFloat = 420

    var body: some View {
        // Defensive per contract B ("skipped when items empty (presenter guards)"): the caller is
        // expected to not even mount this view for an empty batch, but rendering nothing here
        // (rather than an empty calm-card shell) makes that a non-requirement for correctness —
        // matches TriageView's own empty handling.
        if items.isEmpty {
            EmptyView()
        } else {
            card
        }
    }

    // MARK: - Card

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            list
            footer
        }
        .padding(16)
        .frame(width: 520)
        .volarGlass(level: .heavy, cornerRadius: 16)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("EVENING SWEEP")
                .font(.system(size: 11, weight: .medium))
                .tracking(0.77)
                .foregroundStyle(VolarColor.textMut)
            Text("Let's close out today")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(VolarColor.textPri)
            Text("Quick pass through what's still open. Anything left over just rolls to tomorrow — no harm done.")
                .font(.system(size: 12))
                .foregroundStyle(VolarColor.textSec)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - List

    /// `ScrollView` + `LazyVStack` so an unusually long open-task list still renders bounded work
    /// per frame instead of laying out every row up front (client-exploit / craft self-review
    /// point — same reasoning as `TriageView.list`).
    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(items) { item in
                    SweepRow(item: item, onComplete: onComplete, onSkip: onSkip)
                }
            }
        }
        .frame(maxHeight: maxListHeight)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("\(items.count) task\(items.count == 1 ? "" : "s") open")
                .font(.volarMono(size: 11))
                .foregroundStyle(VolarColor.textMut)
            Spacer(minLength: 8)
            Button {
                onDismiss()
            } label: {
                Text("Done for today")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(VolarColor.textSec)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Row

/// One open task + its two actions, kept as its own view (rather than an inline `ForEach`
/// closure) so each row owns its own hover state without re-evaluating the whole batch card on
/// every mouse move — mirrors `TriageView`'s `TriageRow`.
private struct SweepRow: View {
    let item: TaskItem
    let onComplete: (TaskItem) -> Void
    let onSkip: (TaskItem) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var priorityColor: Color {
        switch item.priority {
        case .high: return VolarColor.high
        case .medium: return VolarColor.med
        case .low: return VolarColor.low
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            titleColumn
            Spacer(minLength: 8)
            actions
        }
        .padding(12)
        .background(isHovering ? VolarColor.cardHover : VolarColor.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .volarHairline(cornerRadius: 12)
        .onHover { hovering in
            if reduceMotion {
                isHovering = hovering
            } else {
                withAnimation(VolarMotion.hover) { isHovering = hovering }
            }
        }
    }

    private var titleColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(priorityColor).frame(width: 5, height: 5)
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(VolarColor.textPri)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let durationLabel = item.durationLabel {
                Text(durationLabel)
                    .font(.volarMono(size: 11))
                    .foregroundStyle(VolarColor.textMut)
            }
        }
    }

    /// Two equally-sized, equally-legitimate outcomes — "Complete" gets a quiet affirmative
    /// (success-sage, never the reserved NOW amber, never red) tint on its icon only; "Skip"
    /// stays fully neutral text, exactly like `TriageView`'s "Drop" (FR-036 — no shame styling,
    /// no destructive/warning treatment for the not-done path).
    private var actions: some View {
        HStack(spacing: 6) {
            Button {
                onComplete(item)
            } label: {
                HStack(spacing: 5) {
                    VolarIcon(.check, size: 10, color: VolarColor.done, weight: .bold)
                    Text("Complete")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(VolarColor.textPri)
                }
                .padding(.horizontal, 12)
                .frame(height: 28)
            }
            .buttonStyle(.plain)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .volarHairline(cornerRadius: 8)
            .accessibilityLabel("Complete — \(item.title)")

            Button {
                onSkip(item)
            } label: {
                Text("Skip")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(VolarColor.textSec)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
            }
            .buttonStyle(.plain)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .volarHairline(cornerRadius: 8)
            .accessibilityLabel("Skip — \(item.title)")
        }
    }
}

// MARK: - Previews

#Preview("Batch") {
    SweepView(
        items: [
            TaskItem(title: "Update onboarding flowchart", priority: .medium, when: .later, durationMinutes: 30),
            TaskItem(title: "Reply to design feedback thread", priority: .low, when: .later),
            TaskItem(title: "Renew SSL certificate", priority: .high, when: .later, durationMinutes: 15),
        ]
    )
    .padding()
    .background(VolarColor.bg)
}

#Preview("Empty") {
    SweepView(items: [])
        .padding()
        .background(VolarColor.bg)
}
