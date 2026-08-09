// Sources/Model/WaitingMode.swift — pure "waiting mode" holder
// (specs/006-cues-and-waiting/design.md §2 việc C; docs/adhd-research-v1.md §7).
//
// The phenomenon this exists for: a single hard appointment at 1:30pm can wreck an entire
// morning, because the only way an ADHD brain doesn't lose that anchor is to keep rehearsing it
// in conscious foreground the whole time — crowding out every other task (time blindness +
// working-memory load, `docs/adhd-research-v1.md` §7). Volar holding the anchor externally is
// what frees that working memory back up (Barkley-style externalization).
//
// PROXY WARNING (anh Khôi, read before touching this file): Volar has no "appointment" kind.
// `TaskItem.startTime` looks tempting but is INERT — it is only ever set from an urgent utterance
// ("làm ngay lập tức" / "right now") and deliberately does not drive ordering/eligibility/anything
// (`TaskItem.swift`'s own doc comment on `startTime`). The only real hard-instant Volar owns today
// is `deadline`, so this file treats "the earliest upcoming `deadline`" as a stand-in for "the
// next hard anchor of the day". That is a proxy, not a modeling claim that every deadline is an
// appointment — when Volar eventually grows a real `.appointment`/calendar-anchored kind, THIS is
// the file to narrow. Until then: calendar read access was explicitly rejected by anh Khôi on
// 2026-08-07 (`specs/006-cues-and-waiting/design.md` §0.2) — this file must never grow an
// `EventKit`/`EKEvent`/`busyIntervals` dependency to "improve" on the proxy.
//
// Pure-decision convention this repo already follows (`FullScreenEscalationDecision.swift`'s own
// header): no `Date()`, no `UserDefaults`, no SwiftData/`AppState`, no calendar. Every input is a
// plain parameter, including the fallback duration — so this stays unit-testable with hand-built
// `TaskItem` values (`Tests/WaitingModeTests.swift`) with zero UI/store involved.
//
// Ordering discipline (design.md §2, §5 — do not relax): `eligibleOrder` is the order
// `VolarCore.nextTask` already decided. This file only FILTERS that order looking for the first
// task that fits the remaining time — it never re-sorts, re-scores, or otherwise second-guesses
// the engine's own ordering.
import Foundation

enum WaitingMode {
    /// One "waiting mode" reading — the next hard anchor of the day (see proxy warning above) plus
    /// what, if anything, fits in the time before it.
    struct Decision: Sendable, Equatable {
        /// The task whose `deadline` is being held. NEVER equal to `suggestedTaskId` (an anchor
        /// can't suggest itself — see `decide` below).
        let anchorTaskId: UUID
        /// Carried alongside the id purely so callers (menu bar / popover copy) don't need a
        /// second task lookup just to render "Xe đón lúc 1:30 — anchorTitle".
        let anchorTitle: String
        let anchorAt: Date
        /// Whole minutes from `now` to `anchorAt`, floored (`Int(timeInterval / 60)`). Always > 0
        /// — `decide` only ever selects a future anchor (`deadline > now`, strictly).
        let minutesUntil: Int
        /// Real usable budget = `minutesUntil - WaitingMode.bufferMinutes`, floored at 0. The
        /// buffer exists so "suggest a task that fits" never means "arrive at the anchor exactly
        /// as time runs out" — see `bufferMinutes`.
        let fitMinutes: Int
        /// `true` iff the anchor's own id appears in `eligibleOrder` — i.e. `VolarCore.nextTask`
        /// already considers the anchor itself an actionable task right now (not blocked by any
        /// condition). When `true`, `suggestedTaskId` is ALWAYS `nil` — see that field's doc
        /// comment for why, and the Opus review (2026-08-08) that caught the bug this guards.
        let anchorIsEligible: Bool
        /// First task in `eligibleOrder` (engine's own order, untouched) whose duration fits
        /// inside `fitMinutes` — but ONLY computed when `anchorIsEligible == false`.
        ///
        /// BUG THIS GUARDS AGAINST (Opus review, 2026-08-08 — do not "optimize" this back):
        /// task "Nộp báo cáo" has `deadline` 40 minutes out, `durationMinutes = 30`. Naively this
        /// function selects it as the anchor, computes `fitMinutes = 30`, then goes looking for
        /// SOME OTHER task that also takes ~30 minutes and suggests THAT instead — telling the
        /// user to spend the last 30 minutes before their own deadline on a different task
        /// entirely. Root cause: waiting mode exists for APPOINTMENTS — a moment the user must
        /// merely be present for, not execute — but Volar has no appointment kind, so `deadline`
        /// is used as a proxy (see the proxy warning at the top of this file). "Hold the anchor"
        /// is always a valid use of a deadline; "fill the gap before it" is not, whenever the
        /// anchor is itself the very task the user should be doing right now. `anchorIsEligible`
        /// is exactly that signal: if the engine already says the anchor is actionable
        /// (`.todo`/`.inProgress`, not blocked by any condition), the correct suggestion is
        /// always "the anchor itself", which this field can't even express as a *different* id —
        /// so it stays `nil` and the caller is expected to just point at the anchor.
        /// `nil` also covers the ordinary "nothing fits" case (`anchorIsEligible == false` and no
        /// candidate is short enough) — a legitimate, silent answer, not an error.
        let suggestedTaskId: UUID?
    }

    /// How far ahead we're willing to hold an anchor. Deadlines further out than this are
    /// tomorrow's problem, not "don't lose this in the next few hours" — matching the design's
    /// pinned value (`design.md` §2).
    static let horizonMinutes = 240

    /// Minutes reserved before the anchor itself — no suggested task is allowed to run right up
    /// to the deadline with zero margin. Pinned value from `design.md` §2.
    static let bufferMinutes = 10

    /// Decide today's waiting-mode reading, or `nil` if there is nothing to hold.
    ///
    /// Anchor selection: the `.todo`/`.inProgress` task (never `.done`/`.archived`) with the
    /// earliest `deadline` strictly inside `(now, now + horizonMinutes']` — i.e. `deadline > now`
    /// (equal-to-now does not count as "future") and `deadline <= now + horizonMinutes`. No anchor
    /// in that window ⇒ `nil`. Silence is the default here on purpose (design.md §2): an empty
    /// horizon must never be dressed up into ambient noise.
    ///
    /// Suggestion: walks `eligibleOrder` — the order `VolarCore.nextTask` already produced —
    /// front to back, and returns the FIRST task (excluding the anchor itself) whose
    /// `durationMinutes ?? defaultDurationMinutes` fits inside `fitMinutes` — but ONLY when
    /// `anchorIsEligible == false` (see that field's doc comment: when the anchor is itself
    /// actionable right now, the correct answer is always "do the anchor", never a substitute).
    /// This search is deliberately NOT "the shortest task that fits" — re-sorting by duration
    /// would mean silently overruling the engine's own priority/deadline ordering, which this
    /// file is never allowed to do. Nothing fits ⇒ `suggestedTaskId == nil`, but the `Decision`
    /// (anchor + minutesUntil + fitMinutes) is still returned — an empty fit is a fact worth
    /// holding ("còn 12 phút, chưa có việc nào khít"), not a reason to say nothing at all.
    ///
    /// CALLER CONTRACT for `eligibleOrder`: this must be the engine's FULL eligible list, not a
    /// truncated top-N. `anchorIsEligible` is derived by membership-testing the anchor's id
    /// against this exact array — a caller that hands in a shortened list can make an
    /// actually-actionable anchor look ineligible, which flips this function back into
    /// suggesting a gap-filler task against the user's own deadline (exactly the bug this file
    /// exists to prevent, see `anchorIsEligible`'s doc comment). Truncating is the dangerous
    /// direction; there is no safe way to shorten this input.
    static func decide(
        now: Date,
        tasks: [TaskItem],
        eligibleOrder: [UUID],
        defaultDurationMinutes: Int = 30
    ) -> Decision? {
        let horizonEnd = now.addingTimeInterval(TimeInterval(horizonMinutes * 60))

        // Resolve deadline into a non-optional up front so nothing downstream force-unwraps it.
        let anchorCandidates: [(task: TaskItem, deadline: Date)] = tasks.compactMap { task in
            guard task.status != .done, task.status != .archived else { return nil }
            guard let deadline = task.deadline else { return nil }
            guard deadline > now, deadline <= horizonEnd else { return nil }
            return (task, deadline)
        }

        // Earliest deadline wins. `min(by:)` keeps the FIRST minimal element on a tie (stable),
        // which only matters for two tasks sharing the exact same instant — not a case the design
        // calls out, so "first in `tasks` order" is an acceptable, deterministic tiebreak.
        guard let anchor = anchorCandidates.min(by: { $0.deadline < $1.deadline }) else {
            return nil
        }

        let minutesUntil = Int(anchor.deadline.timeIntervalSince(now) / 60)
        let fitMinutes = max(0, minutesUntil - bufferMinutes)
        let anchorIsEligible = eligibleOrder.contains(anchor.task.id)

        // `reduce(into:)` (first-wins) rather than `Dictionary(uniqueKeysWithValues:)` — the latter
        // traps at runtime if the caller ever hands in a duplicate id, and this function has no
        // business crashing over a caller-side data bug it can't control.
        let tasksById = tasks.reduce(into: [UUID: TaskItem]()) { dict, task in
            if dict[task.id] == nil { dict[task.id] = task }
        }
        var suggestedTaskId: UUID?
        // Anchor already actionable ⇒ never search for a substitute (Opus review 2026-08-08 —
        // see `anchorIsEligible`'s doc comment for the exact bug this skip prevents). The
        // `candidateId != anchor.task.id` guard below is therefore redundant *by construction*
        // whenever this loop runs (anchor not eligible ⇒ its id can't be in `eligibleOrder`
        // either) — kept anyway as cheap belt-and-suspenders against a future refactor that
        // decouples the two checks.
        if !anchorIsEligible {
            for candidateId in eligibleOrder {
                guard candidateId != anchor.task.id else { continue }
                guard let candidate = tasksById[candidateId] else { continue }
                let duration = candidate.durationMinutes ?? defaultDurationMinutes
                if duration <= fitMinutes {
                    suggestedTaskId = candidateId
                    break
                }
            }
        }

        return Decision(
            anchorTaskId: anchor.task.id,
            anchorTitle: anchor.task.title,
            anchorAt: anchor.deadline,
            minutesUntil: minutesUntil,
            fitMinutes: fitMinutes,
            anchorIsEligible: anchorIsEligible,
            suggestedTaskId: suggestedTaskId
        )
    }
}
