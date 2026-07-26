// VolarIOS/Sources/Views/MobileTaskCard.swift — one task, two sizes.
// Ported from `design/volar-mobile.jsx`'s `MobileTaskCard` (specs/004-ios-port/plan.md §2.1/§4).
// Behavioral reference (checkbox/tap/context semantics, not layout): `Volar/Sources/Views/TaskRow.swift`.
//
// MINT AUDIT (frozen design contract — see this feature's final report for the full 6-point
// self-review): the ONLY mint (`VolarColor.nowAccent*`) on this view is, for `.hero` only,
// (a) the "UP NEXT" eyebrow text and (b) the `.volarSpotlight()` glow/vignette + the hero card's
// own outline (`VolarColor.nowRing`). The checkbox fill/stroke, done-state color, and priority dot
// all use the app-wide ice-blue accent (`appState.accent.accent`) or the no-red priority ramp —
// never mint — even when the card is `.hero`. A `.regular` card never renders any mint at all.
import SwiftUI

/// Which of the two `MobileTaskCard` layouts to render — mirrors the prototype's `big: Bool` prop,
/// as an enum per the task brief ("your call, document it"): `.hero` reads clearer than a bare
/// `Bool` at every call site (`MobileTaskCard(task: t, size: .hero) { ... }`) and leaves room for a
/// third size later without a breaking signature change.
enum TaskCardSize: Equatable, Sendable {
    /// The single NOW task — `IOSMetrics.nowCardRadius`, "UP NEXT" mint eyebrow, `IOSMetrics.nowTitle`,
    /// mint spotlight background. At most one of these should exist on screen at a time.
    case hero
    /// An ordinary list row (Later today / Completed) — `IOSMetrics.cardRadius`, `VolarColor.card`
    /// fill, `VolarColor.border` hairline, `IOSMetrics.rowTitle`.
    case regular
}

/// One task, rendered as either the NOW hero card or an ordinary list row. Both variants share the
/// same leading checkbox (44×44pt hit target per §4.1) / title (strikethrough + `textMut` once
/// done) / meta row (time badge, priority dot + label, duration) — only sizing, fill, and the mint
/// spotlight differ.
struct MobileTaskCard: View {
    let task: TaskItem
    var size: TaskCardSize = .regular
    let onToggle: () -> Void

    @Environment(AppState.self) private var appState: AppState

    private var isHero: Bool { size == .hero }
    private var accentColors: Accent { appState.accent.accent }

    private var priorityColor: Color {
        switch task.priority {
        case .high: return VolarColor.high
        case .medium: return VolarColor.med
        case .low: return VolarColor.low
        }
    }

    private var priorityLabel: String {
        switch task.priority {
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }

    /// Matches `TaskRow.rawTimeLabel` (macOS reference): once a task is done, `TaskItem.timeBadge`
    /// goes `nil` by design (it's an open-task-only derived field), so a completed row falls back to
    /// the raw formatted deadline instead of dropping the time entirely.
    private var rawTimeLabel: String? {
        guard let deadline = task.deadline else { return nil }
        return deadline.formatted(.dateTime.hour().minute())
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            checkbox
            content
        }
        .padding(.horizontal, IOSMetrics.cardPadH)
        // Hero padding is a fixed value (mirrors `TodayView.nowSpotlight`'s own fixed
        // `.padding(.vertical, 44)` on macOS — the NOW spotlight isn't density-scaled there
        // either); an ordinary row's vertical padding IS density-aware, consuming the frozen
        // `IOSMetrics.rowPadY(_:)` contract the same way `TaskRow.swift` consumes
        // `appState.density.rowPadY` on macOS.
        .padding(.vertical, isHero ? 16 : IOSMetrics.rowPadY(appState.density))
        .background(isHero ? accentColors.surface : VolarColor.card)
        .clipShape(
            RoundedRectangle(cornerRadius: isHero ? IOSMetrics.nowCardRadius : IOSMetrics.cardRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: isHero ? IOSMetrics.nowCardRadius : IOSMetrics.cardRadius, style: .continuous)
                .stroke(isHero ? VolarColor.nowRing : VolarColor.border, lineWidth: 0.5)
        )
        // Mint spotlight glow — hero only. `SpotlightBackground` (Theme.swift) already no-ops when
        // `isActive: false`, so this line is safe to leave unconditional.
        .volarSpotlight(isActive: isHero)
    }

    // MARK: - Checkbox (22pt/20pt visual circle, 44×44pt tappable per §4.1)

    private var checkbox: some View {
        Button(action: onToggle) {
            Circle()
                .strokeBorder(task.done ? accentColors.solid : VolarColor.veil(0.32), lineWidth: 1.5)
                .background(Circle().fill(task.done ? accentColors.solid : .clear))
                .frame(width: isHero ? 22 : 20, height: isHero ? 22 : 20)
                .overlay {
                    if task.done {
                        VolarIcon(.check, size: 13, color: .white, weight: .bold)
                    }
                }
        }
        .buttonStyle(.plain)
        // `.top` alignment keeps the visible circle where the design puts it (flush with the title's
        // top) while the tappable area grows symmetrically outward to the required 44pt.
        .frame(width: IOSMetrics.minTouch, height: IOSMetrics.minTouch, alignment: .top)
        .contentShape(Rectangle())
        .animation(VolarMotion.press, value: task.done)
    }

    // MARK: - Title + meta

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isHero {
                Text("UP NEXT")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(0.77) // 0.07em @ 11pt, matches the prototype's eyebrow
                    .foregroundStyle(VolarColor.nowAccent)
            }

            Text(task.title)
                .font(isHero ? IOSMetrics.nowTitle : IOSMetrics.rowTitle)
                .tracking(-0.15) // ~-0.01em at these sizes
                .foregroundStyle(task.done ? VolarColor.textMut : VolarColor.textPri)
                .strikethrough(task.done, pattern: .solid, color: VolarColor.veil(0.25))
                .lineLimit(isHero ? 3 : 2)
                .fixedSize(horizontal: false, vertical: true)

            metaRow
        }
    }

    private var metaRow: some View {
        HStack(spacing: 8) {
            if let timeBadge = task.timeBadge {
                timeBadgeView(timeBadge)
            } else if task.done, let rawTimeLabel {
                Text(rawTimeLabel)
                    .font(IOSMetrics.meta)
                    .monospacedDigit()
                    .foregroundStyle(VolarColor.textMut)
            }

            HStack(spacing: 5) {
                Circle().fill(priorityColor).frame(width: 5, height: 5)
                // Matches `TaskRow`'s macOS behavior (not the prototype, which never relabels
                // priority once done): once a task is done its priority slot reads "Done" instead —
                // `TaskRow.swift`'s `priorityLabel` computed property does the same substitution.
                Text(task.done ? "Done" : priorityLabel)
            }

            if let durationLabel = task.durationLabel {
                Text("· \(durationLabel)")
            }
        }
        .font(IOSMetrics.meta)
        .foregroundStyle(VolarColor.textSec)
        .lineLimit(1)
    }

    /// The prototype gives the hero card's time badge a different fill (translucent veil + solid
    /// white text) than a regular row's (accent-tinted capsule) — `Shared/Views/Components.swift`'s
    /// `TimeBadge(_:filled:)` only models the LATTER (its `filled: true` case is solid-accent-fill +
    /// white text, not veil-fill), so the hero variant is a small local view; the regular case
    /// reuses `TimeBadge` unfilled as-is, since that's an exact match (`accent.surface` bg /
    /// `accent.solid` text).
    @ViewBuilder
    private func timeBadgeView(_ text: String) -> some View {
        if isHero {
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(VolarColor.veil(0.10))
                .clipShape(Capsule())
        } else {
            TimeBadge(text)
        }
    }
}
