// Sources/Views/SweepView.swift — evening sweep batch card (Phase 5, T038 view half,
// contracts/phase5-contract.md §B). Presented once per day (ISO-day gate is the App-wiring
// agent's job in AppState/PopoverView — T038) for today's still-open/in-progress tasks, read
// back for rapid batch completion (FR-021). Anti-shame per FR-036 + constitution V: no red, no
// overdue/streak badges, no "you didn't finish" copy — "Skip" just means "didn't get to it
// today," carried over silently, same as any other day. Sibling of `TriageView.swift` —
// deliberately mirrors its card shell (header/list/footer, glass level, row hairline/hover) so
// the two batch surfaces read as one family.
//
// specs/010-calendar-and-hard-deadlines/design.md §3.0/§3.2/§3.3 — "Skip … no harm done" is a
// LIE for a `.hard` deadline (one an outside party enforces, e.g. a tax filing): the app can
// roll a user's own PLAN to tomorrow, it cannot roll the actual deadline. So `.hard` rows get
// "Change due date" instead of "Skip" (§3.2 row 4), which opens the task in the main-window
// detail panel where the deadline is actually editable — this view is no longer fully
// self-contained for that one path: `SweepRow` reads `AppState.openDetail(_:)` (already injected
// via `.environment(appState)` at both call sites, VolarApp.swift/AppState.swift doc-comment) to
// do that, rather than inventing a new unwired closure. `.soft` rows are completely unchanged.
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
        .volarGlass(level: .standard, cornerRadius: 16)
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
            // design.md §3.3 — rung (b): one sentence correct for every batch, soft-only or
            // mixed, instead of two branches to keep in sync. It never claims a blanket "no harm
            // done": soft items genuinely do roll forward on their own; anything with an outside
            // deadline genuinely does need the user to move it. Both clauses are always true
            // regardless of what's actually in `items` today, so no per-render branching needed.
            Text("Quick pass through what's still open. Soft items you skip roll to tomorrow on their own — anything with an outside deadline stays put until you move it yourself.")
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
                    SweepRow(item: item, onComplete: onComplete, onSkip: onSkip, onDismiss: onDismiss)
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
                .monospacedDigit()
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
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppState.self) private var appState
    @State private var isHovering = false

    /// design.md §3.1 — `deadlineKind` is meaningless without a `deadline`; same guard the model
    /// comment itself calls for, so a `.hard`-tagged task with its deadline since cleared reads
    /// as an ordinary skip-able row here, not a stuck "Change due date" row with nothing to edit.
    private var isHardDeadline: Bool {
        item.deadline != nil && item.deadlineKind == .hard
    }

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
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .volarHairline(cornerRadius: 8)
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
                    .monospacedDigit()
                    .foregroundStyle(VolarColor.textMut)
            }
        }
    }

    /// Two equally-sized, equally-legitimate outcomes — "Complete" gets a quiet affirmative
    /// (success-sage, never the reserved NOW amber, never red) tint on its icon only; the second
    /// slot stays fully neutral text either way (FR-036 — no shame styling, no destructive/
    /// warning treatment for the not-done path): "Skip" for `.soft` (exactly like `TriageView`'s
    /// "Drop"), "Change due date" for `.hard` (design.md §3.2 row 4 — the app has no "roll to
    /// tomorrow, no harm done" affordance for a deadline it doesn't own).
    private var actions: some View {
        HStack(spacing: 6) {
            completeButton
            if isHardDeadline {
                changeDueDateButton
            } else {
                skipButton
            }
        }
    }

    private var completeButton: some View {
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
            // Vùng bấm phủ đúng vùng nhìn thấy (luật anh Khôi chốt 2026-08-09).
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(VolarColor.veil(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .volarHairline(cornerRadius: 8)
        .accessibilityLabel("Complete — \(item.title)")
    }

    private var skipButton: some View {
        Button {
            onSkip(item)
        } label: {
            Text("Skip")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(VolarColor.textSec)
                .padding(.horizontal, 12)
                .frame(height: 28)
                // Vùng bấm phủ đúng vùng nhìn thấy (luật anh Khôi chốt 2026-08-09).
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(VolarColor.veil(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .volarHairline(cornerRadius: 8)
        .accessibilityLabel("Skip — \(item.title)")
    }

    /// design.md §3.2 row 4 / §3.3 — no auto-advance of the date: this only opens the task in
    /// the main-window detail panel (`AppState.openDetail`, already public, already injected into
    /// this view's environment at both call sites) where `deadline` is actually editable
    /// (`TaskDetailView`'s `DateBufferControl`). Dismisses the sweep sheet first so the panel
    /// underneath is visible — same neutral text-only treatment as `skipButton`, no warning/
    /// destructive styling (FR-036, still applies to the not-yet-resolved path).
    private var changeDueDateButton: some View {
        Button {
            appState.openDetail(item.id)
            onDismiss()
        } label: {
            Text("Change due date")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(VolarColor.textSec)
                .padding(.horizontal, 12)
                .frame(height: 28)
                // Vùng bấm phủ đúng vùng nhìn thấy (luật anh Khôi chốt 2026-08-09).
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(VolarColor.veil(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .volarHairline(cornerRadius: 8)
        .accessibilityLabel("Change due date — \(item.title)")
    }
}

// MARK: - Previews

#Preview("Batch") {
    // `SweepRow.changeDueDateButton` (design.md §3.2 row 4) reads `AppState` via `@Environment`
    // now, same as `TaskDetailView`'s preview — must inject one here too or the preview crashes
    // on the missing-environment fatalError, not just fail to compile.
    SweepView(
        items: [
            TaskItem(title: "Update onboarding flowchart", priority: .medium, when: .later, durationMinutes: 30),
            TaskItem(title: "Reply to design feedback thread", priority: .low, when: .later),
            TaskItem(title: "Renew SSL certificate", priority: .high, when: .later, durationMinutes: 15),
            TaskItem(title: "File Q3 VAT return", priority: .high, when: .later, deadline: Date().addingTimeInterval(3600), deadlineKind: .hard),
        ]
    )
    .environment(AppState(tasks: SampleData.tasks))
    .padding()
    .background(VolarColor.bg)
}

#Preview("Empty") {
    SweepView(items: [])
        .environment(AppState(tasks: SampleData.tasks))
        .padding()
        .background(VolarColor.bg)
}
