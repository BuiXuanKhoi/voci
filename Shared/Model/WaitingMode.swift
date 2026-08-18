// Sources/Model/WaitingMode.swift — pure "waiting mode" holder
// (specs/006-cues-and-waiting/design.md §2 việc C; docs/adhd-research-v1.md §7).
//
// The phenomenon this exists for: a single hard appointment at 1:30pm can wreck an entire
// morning, because the only way an ADHD brain doesn't lose that anchor is to keep rehearsing it
// in conscious foreground the whole time — crowding out every other task (time blindness +
// working-memory load, `docs/adhd-research-v1.md` §7). Volar holding the anchor externally is
// what frees that working memory back up (Barkley-style externalization).
//
// ANCHORS ARE DATA, NOT DISCOVERED HERE (anh Khôi lật lại quyết định 2026-08-07 vào 2026-08-19,
// specs/010-calendar-and-hard-deadlines/design.md §0/§2.3): Volar now reads the calendar
// (`CalendarAccess.busyBlocks`) and this file's job changed accordingly — `decide` used to hunt
// for "the earliest upcoming `deadline`" itself as a proxy for "the next hard anchor of the day"
// (task deadlines were the only hard instant Volar had). It no longer hunts for anything: the
// caller now hands in `anchors: [HardAnchor]`, already merged from BOTH task deadlines and
// calendar events, and `decide` just picks the nearest future one. The reason this file still must
// NEVER grow an `EventKit`/`EKEvent`/`Calendar.current` dependency is no longer "Volar can't read
// calendars" (it can, elsewhere) — it's that `decide` has to stay a PURE function so it stays
// unit-testable with hand-built values and so `AppState` (the one place allowed to know about both
// task storage and EventKit) is the only place that ever has to reconcile the two sources.
//
// Pure-decision convention this repo already follows (`FullScreenEscalationDecision.swift`'s own
// header): no `Date()`, no `UserDefaults`, no SwiftData/`AppState`, no calendar, no `import
// EventKit`. Every input is a plain parameter, including the fallback duration and now the anchor
// list itself — so this stays unit-testable with hand-built `TaskItem`/`HardAnchor` values
// (`Tests/WaitingModeTests.swift`) with zero UI/store/EventKit involved.
//
// Ordering discipline (design.md §2, §5 — do not relax): `eligibleOrder` is the order
// `VolarCore.nextTask` already decided. This file only FILTERS that order looking for the first
// task that fits the remaining time — it never re-sorts, re-scores, or otherwise second-guesses
// the engine's own ordering.
import Foundation

enum WaitingMode {
    /// One hard moment in the day the caller wants `decide` to weigh — a task's `deadline`, or a
    /// calendar event's start (`CalendarAccess.BusyBlock`). `decide` treats both uniformly: whoever
    /// is nearest in the future wins the anchor slot. Merging the two sources is `AppState`'s job,
    /// not this file's — see the header comment above.
    struct HardAnchor: Equatable, Sendable {
        enum Source: Equatable, Sendable {
            /// Backed by a real `TaskItem` — carries its id so `decide` can still enforce "an
            /// anchor never suggests itself" and "is the anchor task itself already actionable".
            case deadline(taskID: UUID)
            /// Backed by a calendar event — not a task, so there is no id to exclude/look up.
            case calendar
        }
        let title: String
        let at: Date
        let source: Source
    }

    /// One "waiting mode" reading — the next hard anchor of the day (see `HardAnchor`) plus what,
    /// if anything, fits in the time before it.
    struct Decision: Sendable, Equatable {
        /// The task backing this anchor, when `HardAnchor.source == .deadline` — `nil` for a
        /// calendar-sourced anchor, which has no task. NEVER equal to `suggestedTaskId` (a
        /// task-backed anchor can't suggest itself — see `decide` below).
        let anchorTaskId: UUID?
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
        /// `true` iff `anchorTaskId` is non-`nil` AND that id appears in `eligibleOrder` — i.e.
        /// `VolarCore.nextTask` already considers the anchor itself an actionable task right now
        /// (not blocked by any condition). A calendar-sourced anchor (`anchorTaskId == nil`) is
        /// never "eligible" in this sense — it isn't a task the engine has an opinion on. When
        /// `true`, `suggestedTaskId` is ALWAYS `nil` — see that field's doc comment for why, and
        /// the Opus review (2026-08-08) that caught the bug this guards.
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
        /// merely be present for, not execute. "Hold the anchor" is always a valid use of a
        /// deadline; "fill the gap before it" is not, whenever the anchor is itself the very task
        /// the user should be doing right now. `anchorIsEligible`
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
    /// Anchor selection: the `HardAnchor` (from `anchors`, already merged by the caller from task
    /// deadlines + calendar events — see the file header) with the earliest `at` strictly inside
    /// `(now, now + horizonMinutes']` — i.e. `at > now` (equal-to-now does not count as "future")
    /// and `at <= now + horizonMinutes`. No anchor in that window ⇒ `nil`. Silence is the default
    /// here on purpose (design.md §2): an empty horizon must never be dressed up into ambient
    /// noise. `decide` does NOT filter `anchors` by task status or anything else — that filtering
    /// (e.g. excluding `.done`/`.archived` tasks' deadlines) is the caller's job when building the
    /// list, since a calendar-sourced anchor has no status to check in the first place.
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
        anchors: [HardAnchor],
        tasks: [TaskItem],
        eligibleOrder: [UUID],
        defaultDurationMinutes: Int = 30
    ) -> Decision? {
        let horizonEnd = now.addingTimeInterval(TimeInterval(horizonMinutes * 60))

        let anchorCandidates = anchors.filter { $0.at > now && $0.at <= horizonEnd }

        // Earliest `at` wins. `min(by:)` keeps the FIRST minimal element on a tie (stable), which
        // only matters for two anchors sharing the exact same instant — not a case the design
        // calls out, so "first in `anchors` order" is an acceptable, deterministic tiebreak.
        guard let anchor = anchorCandidates.min(by: { $0.at < $1.at }) else {
            return nil
        }

        let anchorTaskId: UUID? = {
            if case let .deadline(taskID) = anchor.source { return taskID }
            return nil
        }()

        let minutesUntil = Int(anchor.at.timeIntervalSince(now) / 60)
        let fitMinutes = max(0, minutesUntil - bufferMinutes)
        let anchorIsEligible = anchorTaskId.map { eligibleOrder.contains($0) } ?? false

        // `reduce(into:)` (first-wins) rather than `Dictionary(uniqueKeysWithValues:)` — the latter
        // traps at runtime if the caller ever hands in a duplicate id, and this function has no
        // business crashing over a caller-side data bug it can't control.
        let tasksById = tasks.reduce(into: [UUID: TaskItem]()) { dict, task in
            if dict[task.id] == nil { dict[task.id] = task }
        }
        var suggestedTaskId: UUID?
        // Anchor already actionable ⇒ never search for a substitute (Opus review 2026-08-08 —
        // see `anchorIsEligible`'s doc comment for the exact bug this skip prevents). The
        // `candidateId != anchorTaskId` guard below is therefore redundant *by construction*
        // whenever this loop runs (anchor not eligible ⇒ its id, if any, can't be in
        // `eligibleOrder` either) — kept anyway as cheap belt-and-suspenders against a future
        // refactor that decouples the two checks.
        if !anchorIsEligible {
            for candidateId in eligibleOrder {
                if let anchorTaskId, candidateId == anchorTaskId { continue }
                guard let candidate = tasksById[candidateId] else { continue }
                let duration = candidate.durationMinutes ?? defaultDurationMinutes
                if duration <= fitMinutes {
                    suggestedTaskId = candidateId
                    break
                }
            }
        }

        return Decision(
            anchorTaskId: anchorTaskId,
            anchorTitle: anchor.title,
            anchorAt: anchor.at,
            minutesUntil: minutesUntil,
            fitMinutes: fitMinutes,
            anchorIsEligible: anchorIsEligible,
            suggestedTaskId: suggestedTaskId
        )
    }
}
