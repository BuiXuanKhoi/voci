import Foundation

// UNVERIFIED: authored on Windows, no Swift toolchain available in this environment. Needs a
// `swift build` / `swift test` pass on macOS before merge (see AGENTS/CLAUDE.md build-env split).

/// A capture-time conflict signal detected when adding `candidate` to the current task snapshot
/// (spec.md FR-011c; phase4-contract.md §C). The app renders at most one calm advisory line from
/// whatever `conflicts(forAdding:into:now:calendar:busyIntervals:frogId:)` returns — this is
/// purely advisory (Constitution Principle II): it never blocks capture and never auto-modifies
/// anything.
public enum TaskConflict: Sendable, Equatable {
    /// The candidate's deadline day is already over-committed by existing tasks' estimates plus
    /// calendar-busy time. `existingCount` excludes the candidate; `estimatedMinutes` is the
    /// total (existing + busy + candidate) minutes on that day; `windowEnd` is the end of that
    /// calendar day.
    case deadlineCapacity(existingCount: Int, estimatedMinutes: Int, windowEnd: Date)

    /// The candidate's deadline falls within a small window of an existing urgent
    /// (`.inProgress` / priority-1 / frog) task's deadline.
    case deadlineCollision(withTaskId: UUID, title: String)

    /// The candidate depends (via `.taskDone`) on a task that is itself overdue or stuck behind
    /// its own unsatisfied condition.
    case dependsOnBlocked(taskId: UUID, title: String)

    /// The candidate is high-stakes (priority 1, or a today/overdue deadline) and a different
    /// task is today's chosen "frog" (most important task).
    case competesWithFrog(taskId: UUID, title: String)

    /// The candidate's title fuzzy-matches an existing open task at or above the duplicate
    /// threshold. `score` is the raw similarity in `[0, 1]`.
    case possibleDuplicate(taskId: UUID, title: String, score: Double)
}

// MARK: - Tunable low-noise thresholds
//
// Every threshold below is deliberately conservative — the whole point of this file (per
// phase4-contract.md §C) is that a clean capture, the common case, returns `[]`. See the final
// task report for the reasoning behind each number.

/// A "reasonable working day" for capacity math, in minutes (8h).
private let workdayMinutes = 480

/// Capacity fires once existing + busy + candidate minutes on the deadline day reach this share
/// of a working day (~80%). A single threshold covers both "adding the candidate tips the day
/// over 80%" and "the day is already clearly over-committed": if existing + busy alone already
/// meet or exceed a full working day, that total is trivially also ≥ this (lower) threshold, so
/// no second branch is needed.
private let capacityThresholdMinutes = Int((Double(workdayMinutes) * 0.8).rounded())

/// Per-task estimate cap used only to bound the capacity sum against adversarial input (e.g. a
/// snapshot task carrying `estimateMinutes == .max`); real captures never approach this.
private let perTaskEstimateCapMinutes = 100_000

/// "Small window" for deadline-collision: 2 hours either side of an existing urgent task's
/// deadline.
private let collisionWindowSeconds: TimeInterval = 2 * 60 * 60

/// Fuzzy title-similarity floor for possible-duplicate (Jaccard over normalized token sets).
private let duplicateScoreThreshold = 0.8

/// Bounds applied when tokenizing a title, so an adversarially huge title cannot blow up the
/// duplicate scorer's cost.
private let maxTitleCharsForMatching = 500
private let maxTokensForMatching = 64

/// Detects capture-time conflicts for `candidate` against the current `snapshot`.
///
/// PURE (Constitution Principle III): no I/O, no clock, no calendar read. `now`, `calendar`, and
/// `busyIntervals` are all caller-supplied data — the app passes `Calendar.current` / real busy
/// intervals, tests pass fixed fixtures — so this function never reads a global and always
/// produces the same result for the same inputs, regardless of `snapshot`'s array order.
///
/// Returns HIGH-SIGNAL conflicts only, **at most one per kind** (so a flood of same-kind matches
/// never has to be prioritized downstream — the app's "one calm advisory line" always has a small,
/// stable list to pick from), in the fixed order the `TaskConflict` cases are declared above. An
/// empty result means a clean capture.
public func conflicts(
    forAdding candidate: Task,
    into snapshot: [Task],
    now: Date,
    calendar: Calendar,
    busyIntervals: [DateInterval],
    frogId: UUID?
) -> [TaskConflict] {
    var result: [TaskConflict] = []

    if let capacity = deadlineCapacityConflict(
        candidate: candidate, snapshot: snapshot, now: now, calendar: calendar, busyIntervals: busyIntervals
    ) {
        result.append(capacity)
    }
    if let collision = deadlineCollisionConflict(candidate: candidate, snapshot: snapshot, frogId: frogId) {
        result.append(collision)
    }
    if let blocked = dependsOnBlockedConflict(candidate: candidate, snapshot: snapshot, now: now) {
        result.append(blocked)
    }
    if let frog = competesWithFrogConflict(
        candidate: candidate, snapshot: snapshot, now: now, calendar: calendar, frogId: frogId
    ) {
        result.append(frog)
    }
    if let duplicate = possibleDuplicateConflict(candidate: candidate, snapshot: snapshot) {
        result.append(duplicate)
    }

    return result
}

// MARK: - deadlineCapacity

/// Sums the estimates of existing eligible tasks (via the shared `eligibleTasks(in:now:)` used by
/// `nextTask`) whose deadline falls on the same calendar day as `candidate`'s deadline, plus
/// calendar-busy minutes on that day, plus the candidate's own estimate — and fires only once
/// that total reaches `capacityThresholdMinutes`. Requires at least one existing same-day task
/// (busy-calendar time alone never fires this; the advisory reads "N tasks already due...").
private func deadlineCapacityConflict(
    candidate: Task,
    snapshot: [Task],
    now: Date,
    calendar: Calendar,
    busyIntervals: [DateInterval]
) -> TaskConflict? {
    guard let candidateDeadline = candidate.deadline else { return nil }

    let dayStart = calendar.startOfDay(for: candidateDeadline)
    guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return nil }
    let dayInterval = DateInterval(start: dayStart, end: dayEnd)

    var existingCount = 0
    var existingMinutes = 0
    for task in eligibleTasks(in: snapshot, now: now) {
        guard task.id != candidate.id, let deadline = task.deadline else { continue }
        guard calendar.isDate(deadline, inSameDayAs: candidateDeadline) else { continue }
        existingCount += 1
        existingMinutes += clampedEstimateMinutes(task.estimateMinutes)
    }

    // Busy-calendar time alone (with no existing same-day tasks) is not high-signal enough to
    // warrant an advisory — keep the noise floor tied to actual competing tasks.
    guard existingCount > 0 else { return nil }

    var busyMinutes = 0
    for interval in busyIntervals {
        guard let overlap = dayInterval.intersection(with: interval) else { continue }
        // `overlap` is clipped to a single day, so its duration is inherently bounded (<= 24h)
        // regardless of how the caller constructed `interval` — no per-item overflow risk.
        busyMinutes += Int((overlap.duration / 60).rounded())
    }

    let candidateMinutes = clampedEstimateMinutes(candidate.estimateMinutes)
    let totalMinutes = existingMinutes + busyMinutes + candidateMinutes

    guard totalMinutes >= capacityThresholdMinutes else { return nil }

    return .deadlineCapacity(existingCount: existingCount, estimatedMinutes: totalMinutes, windowEnd: dayEnd)
}

/// Clamps a (possibly absent, possibly adversarial) estimate into `[0, perTaskEstimateCapMinutes]`
/// so a single malformed task (negative, or `Int.max`) cannot skew or overflow the capacity sum.
private func clampedEstimateMinutes(_ minutes: Int?) -> Int {
    guard let minutes else { return 0 }
    return min(max(minutes, 0), perTaskEstimateCapMinutes)
}

// MARK: - deadlineCollision

/// Finds the closest existing urgent (`.inProgress` / priority-1 / frog) open task whose deadline
/// falls within `collisionWindowSeconds` of the candidate's deadline. At most one match is
/// returned (nearest by time delta, then id-lexical tiebreak) to stay low-noise.
private func deadlineCollisionConflict(
    candidate: Task,
    snapshot: [Task],
    frogId: UUID?
) -> TaskConflict? {
    guard let candidateDeadline = candidate.deadline else { return nil }

    var best: (task: Task, delta: TimeInterval)?
    for task in snapshot {
        guard task.id != candidate.id else { continue }
        guard task.status == .todo || task.status == .inProgress else { continue }
        guard let deadline = task.deadline else { continue }
        let isUrgent = task.status == .inProgress || task.priority == 1 || task.id == frogId
        guard isUrgent else { continue }

        let delta = abs(deadline.timeIntervalSince(candidateDeadline))
        guard delta <= collisionWindowSeconds else { continue }

        guard let currentBest = best else {
            best = (task, delta)
            continue
        }
        if delta < currentBest.delta
            || (delta == currentBest.delta && task.id.uuidString < currentBest.task.id.uuidString) {
            best = (task, delta)
        }
    }

    guard let match = best else { return nil }
    return .deadlineCollision(withTaskId: match.task.id, title: match.task.title)
}

// MARK: - dependsOnBlocked

/// Scans the candidate's `.taskDone` conditions (in declaration order, first match wins) for a
/// referenced task that is either overdue (past its own deadline, still open) or itself stuck
/// behind an unsatisfied condition. An absent or already-done/archived reference is satisfied,
/// per `Condition.isSatisfied`'s existing resolution mapping, and never flagged here.
private func dependsOnBlockedConflict(
    candidate: Task,
    snapshot: [Task],
    now: Date
) -> TaskConflict? {
    guard !candidate.conditions.isEmpty else { return nil }

    // Built with explicit loops (not `Dictionary(uniqueKeysWithValues:)`) so a snapshot with
    // duplicate ids can't crash this lookup; last occurrence for a given id wins, matching the
    // convention in `NextTask.swift`.
    var statusByID: [UUID: TaskStatus] = [:]
    var taskByID: [UUID: Task] = [:]
    statusByID.reserveCapacity(snapshot.count)
    taskByID.reserveCapacity(snapshot.count)
    for task in snapshot {
        statusByID[task.id] = task.status
        taskByID[task.id] = task
    }

    for condition in candidate.conditions {
        guard case .taskDone(let refId) = condition else { continue }
        guard let ref = taskByID[refId] else { continue } // absent from snapshot = satisfied
        guard ref.status == .todo || ref.status == .inProgress else { continue } // done/archived = satisfied

        let isOverdue = ref.deadline.map { $0 < now } ?? false
        let isStuck = !ref.conditions.allSatisfy { $0.isSatisfied(statusByID: statusByID, now: now) }

        if isOverdue || isStuck {
            return .dependsOnBlocked(taskId: ref.id, title: ref.title)
        }
    }
    return nil
}

// MARK: - competesWithFrog

/// Fires when the candidate is itself high-stakes (explicit priority 1, or a today/overdue
/// deadline) and a *different*, still-open task is the caller-designated "frog" for the day.
private func competesWithFrogConflict(
    candidate: Task,
    snapshot: [Task],
    now: Date,
    calendar: Calendar,
    frogId: UUID?
) -> TaskConflict? {
    guard let frogId, frogId != candidate.id else { return nil }

    let candidateIsHighStakes = candidate.priority == 1
        || isTodayOrOverdueDeadline(candidate.deadline, now: now, calendar: calendar)
    guard candidateIsHighStakes else { return nil }

    guard let frog = snapshot.first(where: { $0.id == frogId }) else { return nil }
    guard frog.status == .todo || frog.status == .inProgress else { return nil }

    return .competesWithFrog(taskId: frog.id, title: frog.title)
}

/// Same "today or overdue relative to `now`" classification as `NextTask.swift`'s
/// `isNearTermDeadline`, reimplemented locally (that helper is file-private there) using the
/// same caller-injected `calendar` so this stays pure.
private func isTodayOrOverdueDeadline(_ deadline: Date?, now: Date, calendar: Calendar) -> Bool {
    guard let deadline else { return false }
    if deadline < now { return true }
    return calendar.isDate(deadline, inSameDayAs: now)
}

// MARK: - possibleDuplicate

/// Finds the highest-scoring existing open task whose title fuzzy-matches the candidate's at or
/// above `duplicateScoreThreshold`, using a simple token-set (Jaccard) similarity over
/// diacritic- and case-folded titles. Dependency-free, Vietnamese-diacritic-aware (folds "Đọc" ~
/// "doc" the same way as ASCII casefolding).
private func possibleDuplicateConflict(
    candidate: Task,
    snapshot: [Task]
) -> TaskConflict? {
    let candidateTokens = Set(normalizedTitleTokens(candidate.title))
    guard !candidateTokens.isEmpty else { return nil }

    var best: (task: Task, score: Double)?
    for task in snapshot {
        guard task.id != candidate.id else { continue }
        guard task.status == .todo || task.status == .inProgress else { continue }

        let score = titleSimilarity(candidateTokens: candidateTokens, otherTitle: task.title)
        guard score >= duplicateScoreThreshold else { continue }

        guard let currentBest = best else {
            best = (task, score)
            continue
        }
        if score > currentBest.score
            || (score == currentBest.score && task.id.uuidString < currentBest.task.id.uuidString) {
            best = (task, score)
        }
    }

    guard let match = best else { return nil }
    return .possibleDuplicate(taskId: match.task.id, title: match.task.title, score: match.score)
}

/// Normalizes and tokenizes a title for fuzzy matching: diacritic- and case-fold (so "Đọc sách"
/// and "doc sach" tokenize identically), then split on any non-letter/non-number boundary.
/// Bounded on both input length and token count so an adversarially huge title cannot make this
/// (or the O(n) scan that calls it once per snapshot task) expensive.
private func normalizedTitleTokens(_ title: String) -> [String] {
    let bounded = title.count > maxTitleCharsForMatching ? String(title.prefix(maxTitleCharsForMatching)) : title
    let folded = bounded.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "vi_VN"))
    // `.diacriticInsensitive` folding decomposes base+combining-mark diacritics (the Vietnamese
    // tone marks, and letters like ô/ơ/ư whose modifier is a canonically-decomposable combining
    // mark) down to their ASCII base letter. It does NOT touch "đ"/"Đ": that is an atomic Latin
    // letter-with-stroke with no Unicode decomposition mapping (a different phoneme, not a
    // diacritic), so it survives folding untouched. Map it explicitly so "Đọc" and "doc"
    // tokenize identically.
    let strokeNormalized = folded.replacingOccurrences(of: "đ", with: "d")
        .replacingOccurrences(of: "Đ", with: "d")
    let tokens = strokeNormalized.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    return tokens.count > maxTokensForMatching ? Array(tokens.prefix(maxTokensForMatching)) : tokens
}

/// Jaccard similarity (`|intersection| / |union|`) between `candidateTokens` and `otherTitle`'s
/// normalized token set. A title that tokenizes to nothing (empty/punctuation-only) never
/// matches — no divide-by-zero, no degenerate empty-vs-empty "match".
private func titleSimilarity(candidateTokens: Set<String>, otherTitle: String) -> Double {
    let otherTokens = Set(normalizedTitleTokens(otherTitle))
    guard !otherTokens.isEmpty else { return 0 }
    let intersection = candidateTokens.intersection(otherTokens).count
    let union = candidateTokens.union(otherTokens).count
    guard union > 0 else { return 0 }
    return Double(intersection) / Double(union)
}
