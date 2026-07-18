// Sources/Parsing/IntentParsing.swift — IntentParser protocol, IntentRouter (FM -> Cloud ->
// Heuristic), and the shared raw-output decode/validation helper both FoundationModelParser
// (T020) and CloudParser (T021) funnel through before ever producing a `ParsedTask`.
//
// Frozen seam: `specs/002-workflow-command-center/contracts/parsing-contract.md`. `ParsedTask`,
// `ParsedValue<T>`, `ParsedCondition`, `Recurrence`, `ReminderPolicy`, `TaskKind` are owned
// elsewhere (NLParser agent / Phase-2) and referenced HERE BY NAME ONLY — nothing in this file
// redefines them. This file will not compile standalone until `Volar/Sources/Model/NLParser.swift`
// lands the v2 `ParsedTask` shape and an `IntentParser`-conforming `HeuristicNLParser` — that is
// expected for this round (see task brief). Windows: cannot build here — every FM-specific claim
// is separately marked `// UNVERIFIED` in `FoundationModelParser.swift`; this file itself has no
// FM-specific API calls to verify.
import Foundation

// MARK: - IntentParser protocol (frozen contract)

/// One utterance -> 1...10 tasks, or one parent title -> 3...9 breakdown step titles. Implemented
/// by `FoundationModelParser`, `CloudParser`, and (elsewhere) `HeuristicNLParser`. Never throws for
/// content reasons — a parser that can't produce anything usable returns `[]` and lets
/// `IntentRouter` fall through to the next tier (constitution II: a parsing failure degrades,
/// never crashes, never silently drops the whole utterance).
protocol IntentParser: Sendable {
    func parse(_ transcript: String, now: Date, openTaskTitles: [String]) async -> [ParsedTask]
    func breakdown(title: String, notes: String?) async -> [String]
}

// MARK: - Cloud opt-in / reachability gate (injected — owned by Settings/AppState/StoreKit agent)

/// Whether Cloud is even allowed to be *attempted* this call. Quota (429) is a per-call SERVER
/// verdict handled inside `CloudParser`/`IntentRouter`, not this gate — this only covers the two
/// preconditions research.md R5 requires before any network request is made: explicit one-time
/// privacy consent (constitution I — text egress requires consent regardless of tier) and basic
/// reachability (avoid a doomed round-trip while offline).
///
/// ASSUMPTION for the reviewer to check against the StoreKit/Settings work: this protocol is
/// deliberately minimal (two booleans, no tier/entitlement info) — tier selection (paid JWS vs
/// free device token) lives entirely inside whatever concrete `ParseCredentialProvider` is
/// injected into `CloudParser` (see `CloudParser.swift`), not here. `IntentRouter` only asks "may
/// I try Cloud at all right now."
protocol CloudParseGate: Sendable {
    /// One-time explicit privacy consent has been granted (never assume true; absent consent,
    /// Cloud must never be attempted even if a valid credential exists).
    func isOptedIn() async -> Bool
    /// Best-effort network reachability. `true` when unknown/unable to determine (a real request
    /// will fail cleanly and fall through anyway — this is purely an optimization to skip an
    /// obviously-doomed request, not a security gate).
    func isOnline() async -> Bool
}

// MARK: - IntentRouter (T019)

/// Routes FM (on-device, if available) -> Cloud (opted-in + online, credential available) ->
/// Heuristic, per research.md R5. ALWAYS returns a usable, non-empty `[ParsedTask]`: any route
/// failure (unavailable, decode violation, transport error, 401/5xx) falls through silently to
/// the next tier; Heuristic is the floor and is unconditionally available. The 10-task cap is
/// enforced here regardless of which tier produced the result (defense in depth — each producer
/// is also expected to cap itself).
@MainActor
final class IntentRouter: IntentParser {
    /// Hard cap, all tiers, all call sites (contract: "Enforces the 10-task cap centrally").
    nonisolated static let maxTaskCap = 10

    /// Which tier actually produced the last successful result — diagnostics only, never PII
    /// (no transcript/title content), safe to log.
    enum Route: String, Sendable, Equatable {
        case foundationModel, cloud, heuristic
    }

    /// Set at the start of every `parse(...)` call; read by the confirm-card owner afterward.
    private(set) var lastRoute: Route = .heuristic
    /// `true` for exactly the duration between a `parse(...)` call that hit Cloud's 429 and the
    /// NEXT `parse(...)` call (reset at the top of every call) — the confirm-card/UI owner reads
    /// this once per parse to show the one-line gentle note (FR-012, parse-proxy.md 429). This is
    /// a side channel: the frozen `IntentParser.parse` return type is `[ParsedTask]` only, so the
    /// "quota" signal can't ride in the return value itself.
    private(set) var lastCloudQuotaNote = false

    private let fm: FoundationModelParser?
    private let cloud: CloudParser?
    private let cloudGate: CloudParseGate?
    private let heuristic: IntentParser

    /// - Parameters:
    ///   - foundationModel: Defaults to the capability-probed singleton-ish factory — `nil` on
    ///     macOS < 26, non-Apple-Silicon, or when the on-device model itself isn't available
    ///     (probe never crashes; see `FoundationModelParser.makeIfAvailable()`).
    ///   - cloud: `nil` disables the Cloud tier entirely (e.g. no `ParseCredentialProvider`
    ///     composite wired up yet) — router falls straight from FM to Heuristic.
    ///   - cloudGate: `nil` also disables Cloud (never attempt Cloud without an explicit gate
    ///     that can assert consent).
    ///   - heuristic: The floor. Defaults to the existing `HeuristicNLParser` (Sources/Model/
    ///     NLParser.swift) — injectable for tests.
    init(
        foundationModel: FoundationModelParser? = FoundationModelParser.makeIfAvailable(),
        cloud: CloudParser? = nil,
        cloudGate: CloudParseGate? = nil,
        heuristic: IntentParser = HeuristicNLParser()
    ) {
        self.fm = foundationModel
        self.cloud = cloud
        self.cloudGate = cloudGate
        self.heuristic = heuristic
    }

    func parse(_ transcript: String, now: Date, openTaskTitles: [String]) async -> [ParsedTask] {
        lastCloudQuotaNote = false
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Nothing to parse. Callers shouldn't invoke this on empty input, but never crash or
            // fabricate a task out of nothing — an empty result here is the one legitimate `[]`.
            lastRoute = .heuristic
            return []
        }

        // R5: openTaskTitles forwarded to a remote/on-device model ONLY on dependency phrasing —
        // applied once here so every tier sees the same (possibly-empty) list.
        let titles = Self.containsDependencyPhrasing(transcript)
            ? Array(openTaskTitles.prefix(100))
            : []

        if let fm {
            let result = await fm.parse(transcript, now: now, openTaskTitles: titles)
            if !result.isEmpty {
                lastRoute = .foundationModel
                return Self.cap(result)
            }
        }

        if let cloud, let cloudGate, await cloudGate.isOptedIn(), await cloudGate.isOnline() {
            switch await cloud.parseDetailed(transcript, now: now, openTaskTitles: titles) {
            case .tasks(let tasks) where !tasks.isEmpty:
                lastRoute = .cloud
                return Self.cap(tasks)
            case .tasks:
                break // decoded but empty — fall through same as any other Cloud non-result
            case .quotaExceeded:
                lastCloudQuotaNote = true
            case .unavailable:
                break
            }
        }

        lastRoute = .heuristic
        // R5: every tier sees the SAME (possibly-empty) `titles` list computed once above — this
        // was previously hardcoded to `[]` here, silently starving the heuristic tier (the ONLY
        // tier available on macOS 14/15) of dependency-matching context and capping its
        // taskDone-condition confidence below the 0.7 auto-resolve bar (see
        // `dependencyConfidence` in `NLParser.swift`).
        let heuristicResult = await heuristic.parse(transcript, now: now, openTaskTitles: titles)
        if !heuristicResult.isEmpty {
            return Self.cap(heuristicResult)
        }
        // Defensive floor: even the always-available heuristic returned nothing (shouldn't
        // normally happen). Never discard the utterance — constitution II.
        return [Self.titleOnlyTask(transcript)]
    }

    func breakdown(title: String, notes: String?) async -> [String] {
        if let fm {
            let steps = await fm.breakdown(title: title, notes: notes)
            if Self.isValidBreakdown(steps) { return steps }
        }
        if let cloud, let cloudGate, await cloudGate.isOptedIn(), await cloudGate.isOnline() {
            let steps = await cloud.breakdown(title: title, notes: notes)
            if Self.isValidBreakdown(steps) { return steps }
        }
        return await heuristic.breakdown(title: title, notes: notes)
    }

    // MARK: - Cap + floor helpers
    //
    // `nonisolated` on these `static func`s is deliberate, not decorative: `IntentRouter` is
    // `@MainActor`, but `CloudParser`/`FoundationModelParser` are NOT (they run their network/FM
    // work off the main actor) and call these helpers directly (`IntentRouter.cap(...)`,
    // `IntentRouter.isValidBreakdown(...)`) without `await`. Each is a pure function over
    // `Sendable` values touching no actor-isolated state, so `nonisolated` is sound — without it,
    // Swift 6 strict concurrency would require every call site to `await`, or these calls would
    // fail to compile at all from a non-`@MainActor` context. `maxTaskCap` needs `nonisolated` for
    // the same reason: a `static let` declared inside a `@MainActor` type inherits that isolation
    // (only statics at global/file scope, outside an isolated type, are implicitly `nonisolated`),
    // so without it the off-main callers hit "cannot be accessed from outside of the actor".

    nonisolated static func cap(_ tasks: [ParsedTask]) -> [ParsedTask] {
        Array(tasks.prefix(maxTaskCap))
    }

    nonisolated static func isValidBreakdown(_ steps: [String]) -> Bool {
        (3...9).contains(steps.count)
            && steps.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// The absolute floor: a task with only a title (the source transcript, trimmed) and the
    /// transcript retained verbatim. Never crashes, never discards.
    nonisolated static func titleOnlyTask(_ transcript: String) -> ParsedTask {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedTask(
            title: trimmed.isEmpty ? transcript : trimmed,
            notes: nil,
            deadline: nil,
            estimateMinutes: nil,
            priority: nil,
            reminderOverride: nil,
            recurrence: nil,
            kind: .task,
            conditions: [],
            subtasks: [],
            followUpReview: false,
            sourceTranscript: transcript
        )
    }

    // MARK: - Dependency-phrasing detector (R5)

    /// Best-effort keyword/regex detector for "sau khi", "xong … thì", "after", "when … done" —
    /// deliberately simple (per task brief: "provide a small detector or accept a flag"). False
    /// negatives just mean `openTaskTitles` isn't forwarded (parser falls back to no cross-task
    /// linking, never a crash); false positives just forward a harmless title list.
    nonisolated static func containsDependencyPhrasing(_ transcript: String) -> Bool {
        let lower = transcript.lowercased()
        if lower.contains("sau khi") { return true }
        if lower.range(of: #"\bxong\b[^.!?]{0,40}\bthì\b"#, options: .regularExpression) != nil {
            return true
        }
        if lower.range(of: #"\bafter\b"#, options: .regularExpression) != nil { return true }
        if lower.range(of: #"\bwhen\b[^.!?]{0,40}\bdone\b"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }
}

// MARK: - Shared raw wire shape (untrusted) + decode-validation helper

/// Wraps a raw model-reported value with its raw model-reported confidence — mirrors
/// `ConfidenceValue<T>` in `supabase/functions/_shared/schema.ts` (the ALREADY-IMPLEMENTED server
/// wire response for `/functions/v1/parse`). `CloudParser` decodes JSON directly into
/// `RawConfidence<T>`; `FoundationModelParser` constructs it manually from `@Generable` output
/// (each on-device field paired with a model-self-reported confidence). Both funnel into the same
/// `ParsedTaskValidation.validate` below — one validation code path for both remote tiers.
struct RawConfidence<T: Sendable>: Sendable {
    var value: T
    var confidence: Double
}
extension RawConfidence: Decodable where T: Decodable {}

struct RawParsedCondition: Sendable {
    /// "taskDone" | "afterDate" | "external"
    var kind: String
    var referenceTitle: String?
    /// ISO8601 string.
    var date: String?
    var description: String?
}
extension RawParsedCondition: Decodable {}

struct RawParsedRecurrence: Sendable {
    /// "daily" | "weekly" | "monthly" | "every"
    var type: String
    var everyDays: Int?
}
extension RawParsedRecurrence: Decodable {}

struct RawParsedReminderOverride: Sendable {
    var offsetsMinutes: [Double]
    var repeatEveryMinutes: Double?
}
extension RawParsedReminderOverride: Decodable {}

struct RawParsedSubtask: Sendable {
    var title: RawConfidence<String>
    var estimateMinutes: RawConfidence<Double>
}
extension RawParsedSubtask: Decodable {}

/// The untrusted, wire-shaped task both Cloud and FM produce before validation. Mirrors
/// `ParsedTaskOut` in `supabase/functions/_shared/schema.ts` field-for-field. NEVER used
/// directly by app code beyond this file's validator — it exists only to be converted into a
/// validated `ParsedTask` by `ParsedTaskValidation.validate`.
struct RawParsedTask: Sendable {
    var title: RawConfidence<String>
    var notes: RawConfidence<String>?
    /// ISO8601 string.
    var deadline: RawConfidence<String>?
    var estimateMinutes: RawConfidence<Double>?
    var priority: RawConfidence<Int>?
    var recurrence: RawConfidence<RawParsedRecurrence>?
    var reminderOverride: RawConfidence<RawParsedReminderOverride>?
    var conditions: [RawConfidence<RawParsedCondition>]?
    /// "task" | "review"
    var kind: RawConfidence<String>?
    var subtasks: [RawParsedSubtask]?
    var followUpReview: RawConfidence<Bool>?

    init(
        title: RawConfidence<String>,
        notes: RawConfidence<String>? = nil,
        deadline: RawConfidence<String>? = nil,
        estimateMinutes: RawConfidence<Double>? = nil,
        priority: RawConfidence<Int>? = nil,
        recurrence: RawConfidence<RawParsedRecurrence>? = nil,
        reminderOverride: RawConfidence<RawParsedReminderOverride>? = nil,
        conditions: [RawConfidence<RawParsedCondition>]? = nil,
        kind: RawConfidence<String>? = nil,
        subtasks: [RawParsedSubtask]? = nil,
        followUpReview: RawConfidence<Bool>? = nil
    ) {
        self.title = title
        self.notes = notes
        self.deadline = deadline
        self.estimateMinutes = estimateMinutes
        self.priority = priority
        self.recurrence = recurrence
        self.reminderOverride = reminderOverride
        self.conditions = conditions
        self.kind = kind
        self.subtasks = subtasks
        self.followUpReview = followUpReview
    }
}
extension RawParsedTask: Decodable {}

/// Converts untrusted `RawParsedTask` values into validated `ParsedTask`s (constitution II: "Raw
/// LLM output MUST NEVER be executed or persisted. It MUST be decoded into the validated
/// `ParsedTask`... Any decode/schema violation MUST fall back to a title-only task... A parsing
/// error on one attribute MUST NOT discard the others").
///
/// Two-tier fallback, matching the constitution's wording precisely:
///   1. **Per-attribute**: a malformed/out-of-range field (bad ISO8601 string, confidence outside
///      0...1, priority outside 1...4, empty condition description, etc.) drops ONLY that field —
///      every other attribute on the task is preserved.
///   2. **Per-task title**: if `title` itself is unusable (empty after trimming), the task becomes
///      title-only using the ORIGINAL transcript as its title (never a blank/garbage title).
/// A tier-wide failure (the raw array itself couldn't be decoded at all, e.g. malformed JSON) is
/// NOT handled here — that's reported by the producer (`CloudParser`/`FoundationModelParser`) as
/// "unavailable", so `IntentRouter` falls through to the NEXT tier (which can usually do better
/// than a bare title stub) rather than this helper manufacturing one low-quality task itself.
enum ParsedTaskValidation {
    /// Fresh formatters per call, deliberately not shared `static let`s: `ISO8601DateFormatter`
    /// is a mutable reference type Foundation hasn't marked `Sendable`, and this is called from
    /// multiple non-`@MainActor` contexts (`CloudParser`, `FoundationModelParser`) as well as the
    /// `@MainActor` router — a shared instance would be a Swift 6 strict-concurrency risk for a
    /// cost that's negligible against a parse call's actual work.
    static func parseISO8601(_ string: String) -> Date? {
        if let date = ISO8601DateFormatter().date(from: string) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions.insert(.withFractionalSeconds)
        return fractional.date(from: string)
    }

    /// 0...1 inclusive; any other value (including NaN) is a schema violation -> field dropped.
    private static func validConfidence(_ value: Double) -> Bool {
        value.isFinite && (0...1).contains(value)
    }

    static func validateAll(_ raws: [RawParsedTask], sourceTranscript: String) -> [ParsedTask] {
        raws.map { validate($0, sourceTranscript: sourceTranscript) }
    }

    static func validate(_ raw: RawParsedTask, sourceTranscript: String) -> ParsedTask {
        let trimmedTitle = raw.title.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmedTitle.isEmpty
            ? sourceTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            : trimmedTitle

        let notes: String? = raw.notes.flatMap { c in
            let trimmed = c.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        let deadline: ParsedValue<Date>? = raw.deadline.flatMap { c in
            guard validConfidence(c.confidence), let date = parseISO8601(c.value) else { return nil }
            return ParsedValue(value: date, confidence: c.confidence)
        }

        let estimateMinutes: ParsedValue<Int>? = raw.estimateMinutes.flatMap { c in
            // `Int(_:)` on a `Double` TRAPS when the value is out of `Int`'s representable range
            // (e.g. a well-formed 200 response with `estimateMinutes: 1e300` — the server only
            // validates `isFinite && > 0`, not any upper bound). `Int(exactly:)` returns `nil`
            // instead of trapping, and the `1...1440` bound (mirrors this file's own reminder/
            // heuristic estimate caps — 24h) rejects any in-range-for-Int but nonsensical duration
            // the same way a schema violation is rejected everywhere else in this function: drop
            // only this field, keep the rest of the task (constitution II).
            guard validConfidence(c.confidence), c.value.isFinite, c.value > 0,
                  let est = Int(exactly: c.value.rounded()), (1...1440).contains(est)
            else { return nil }
            return ParsedValue(value: est, confidence: c.confidence)
        }

        let priority: ParsedValue<Int>? = raw.priority.flatMap { c in
            guard validConfidence(c.confidence), (1...4).contains(c.value) else { return nil }
            return ParsedValue(value: c.value, confidence: c.confidence)
        }

        let recurrence: ParsedValue<Recurrence>? = raw.recurrence.flatMap { c in
            guard validConfidence(c.confidence) else { return nil }
            let mapped: Recurrence?
            switch c.value.type {
            case "daily": mapped = .daily
            case "weekly": mapped = .weekly
            case "monthly": mapped = .monthly
            case "every":
                if let days = c.value.everyDays, days > 0 {
                    mapped = .every(days: days)
                } else {
                    mapped = nil
                }
            default: mapped = nil
            }
            guard let mapped else { return nil }
            return ParsedValue(value: mapped, confidence: c.confidence)
        }

        let reminderOverride: ParsedValue<ReminderPolicy>? = raw.reminderOverride.flatMap { c in
            guard validConfidence(c.confidence) else { return nil }
            let offsets = c.value.offsetsMinutes.filter { $0.isFinite }.map { $0 * 60 }
            guard !offsets.isEmpty else { return nil }
            var repeatEvery: TimeInterval?
            if let minutes = c.value.repeatEveryMinutes, minutes.isFinite, minutes > 0 {
                repeatEvery = minutes * 60
            }
            let policy = ReminderPolicy(offsets: offsets, repeatEvery: repeatEvery)
            return ParsedValue(value: policy, confidence: c.confidence)
        }

        let conditions: [ParsedCondition] = (raw.conditions ?? []).compactMap { c in
            guard validConfidence(c.confidence) else { return nil }
            switch c.value.kind {
            case "taskDone":
                guard let ref = c.value.referenceTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !ref.isEmpty else { return nil }
                return .taskDone(titleQuery: ref, confidence: c.confidence)
            case "afterDate":
                guard let dateString = c.value.date, let date = parseISO8601(dateString) else { return nil }
                return .afterDate(date, confidence: c.confidence)
            case "external":
                guard let desc = c.value.description?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !desc.isEmpty else { return nil }
                return .external(description: desc, confidence: c.confidence)
            default:
                return nil
            }
        }

        let kind: TaskKind = {
            guard let kindValue = raw.kind?.value else { return .task }
            return kindValue == "review" ? .review : .task
        }()

        // Contract's `subtasks: [String]` carries titles only (no per-step confidence/estimate) —
        // drop empty titles, cap defensively against a hostile/buggy producer flooding this list.
        let subtasks: [String] = (raw.subtasks ?? [])
            .map { $0.title.value.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(20)
            .map { $0 }

        let followUpReview = raw.followUpReview?.value ?? false

        return ParsedTask(
            title: title,
            notes: notes,
            deadline: deadline,
            estimateMinutes: estimateMinutes,
            priority: priority,
            reminderOverride: reminderOverride,
            recurrence: recurrence,
            kind: kind,
            conditions: conditions,
            subtasks: subtasks,
            followUpReview: followUpReview,
            sourceTranscript: sourceTranscript
        )
    }
}
