// Sources/Views/DiffRow.swift — Cursor-borrowed accept/reject diff row (design-spec.md §4.1,
// backlog task_refs_v1). One field's old -> new change, rendered the way Cursor shows a proposed
// code diff: a struck-out old value giving way to a highlighted new one, under a small uppercase
// field label. Used exclusively by `PopoverView`'s `.existing`-target update card
// (`confirmUpdateCard`, `// MARK: - task_refs_v1`, ~line 850) to make "a spoken utterance changed
// an existing task" legible as a real diff instead of the old bare "old → new" chip label.
import SwiftUI

/// Deliberately NOT model-aware — every parameter is a plain, already-formatted `String` (or
/// `nil`). Turning a `Date`/`Priority`/estimate into display text stays the CALLER's job:
/// `PopoverView` already owns that single source of truth (`// MARK: - Chip label formatting`,
/// ~line 1257 — `priorityLabel`, `DeadlineControl.deadlineLabel`, the `.dateTime` format specifiers
/// used throughout that file) and this view must never grow a second, competing copy of it.
///
/// **No red, ever — by design, not oversight.** Cursor's own diff view colors removed lines red and
/// added lines green. This app has a standing, frozen rule (design-spec.md §0 luật 2; backlog
/// task_refs_v1 decision (b): "updates KHÔNG BAO GIỜ auto-commit... không dùng đỏ"): red
/// (`VolarColor.destruct`) is reserved for irreversible destructive actions (the Delete button) and
/// MUST NEVER mark task state — an old value being replaced is not destructive, it is simply
/// superseded, and coloring it red would read as failure/shame to exactly the ADHD users this app
/// exists for (constitution FR-036, "no red/shame styling"). The diff is still legible without red:
/// the strikethrough itself is the PRIMARY encoding ("this is gone"); the muted-vs-bright contrast
/// between the two lines is the second layer. Color only ever ADDS a third signal on the NEW side
/// (sage `VolarColor.done`, "this is what's landing") — there is deliberately no equivalent color
/// on the old side, and there must never be one. If a diff ever reads as hard to parse, reach for
/// weight/spacing/border — not red.
struct DiffRow: View {
    let label: String
    /// `nil` when the field had no previous value (being set for the first time) — renders as a
    /// single new-value row with no strikethrough and no empty "old" line, same "no dash-arrow-to-
    /// nothing" convention `DeadlineControl`'s own "Add time" state already uses elsewhere in
    /// `PopoverView.swift`.
    let oldValue: String?
    let newValue: String
    /// Numbers read as measurements (a deadline/start-time readout) get `Font.volarMono` +
    /// `.monospacedDigit()` per design-spec.md §2; a text label like a priority name does not — the
    /// caller decides per field, this view only applies whichever face it's told to.
    var mono: Bool = false
    /// True while the new value is an uncertain (<0.7 confidence) machine guess the caller has not
    /// yet marked accepted (constitution II: never silently committed). Purely a VISUAL switch —
    /// swaps the new-value box from the solid sage fill to the same dashed-border/"?" language
    /// `Chip` already uses elsewhere on this card, so a still-pending diff reads as pending at a
    /// glance. Accepting/dismissing the value is the CALLER's job (wired in `PopoverView`, off
    /// `AppState.acceptUpdateField`/`dismissUpdateField`) — this view never reads or calls into
    /// `AppState`, and carries no tap handling of its own.
    var pending: Bool = false

    init(label: String, oldValue: String?, newValue: String, mono: Bool = false, pending: Bool = false) {
        self.label = label
        self.oldValue = oldValue
        self.newValue = newValue
        self.mono = mono
        self.pending = pending
    }

    private func valueFont(weight: Font.Weight) -> Font {
        mono ? Font.volarMono(size: 12, weight: weight) : .system(size: 12, weight: weight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .tracking(0.7) // 0.07em at 10pt — matches `SectionHeader`'s uppercase field label
                .textCase(.uppercase)
                .foregroundStyle(VolarColor.textMut)

            if let oldValue {
                Text(oldValue)
                    .font(valueFont(weight: .regular))
                    .monospacedDigit()
                    .strikethrough(pattern: .solid, color: VolarColor.veil(0.25))
                    .foregroundStyle(VolarColor.textMut)
            }

            newValueView
        }
    }

    @ViewBuilder
    private var newValueView: some View {
        if pending {
            HStack(spacing: 5) {
                Text("?").font(.system(size: 10, weight: .bold))
                Text(newValue).font(valueFont(weight: .medium))
            }
            .monospacedDigit()
            .foregroundStyle(VolarColor.textSec)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(VolarColor.textMut, style: StrokeStyle(lineWidth: 0.5, dash: [3, 2]))
            )
        } else {
            Text(newValue)
                .font(valueFont(weight: .medium))
                .monospacedDigit()
                .foregroundStyle(VolarColor.done)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(VolarColor.done.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }
}

#Preview("DiffRow states") {
    VStack(alignment: .leading, spacing: 14) {
        DiffRow(label: "Deadline", oldValue: "Aug 7, 3:00 PM", newValue: "Aug 8, 9:00 AM", mono: true)
        DiffRow(label: "Priority", oldValue: "Medium priority", newValue: "High priority")
        DiffRow(label: "Start", oldValue: nil, newValue: "Aug 7, 5:00 PM", mono: true)
        DiffRow(label: "Deadline", oldValue: "Aug 7, 3:00 PM", newValue: "Aug 8, 9:00 AM", mono: true, pending: true)
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(VolarColor.bg)
}
