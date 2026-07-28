// Sources/Parsing/IntentParsing.swift — IntentParser protocol, IntentRouter (FM -> Cloud ->
// title-only floor; see the 2026-07-28 comment on `IntentRouter.init`/`parse` for why the old
// Heuristic bottom tier is disconnected, not deleted), and the shared raw-output decode/
// validation helper both FoundationModelParser (T020) and CloudParser (T021) funnel through
// before ever producing a `ParsedTask`.
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
/// title-only floor. ALWAYS returns a usable, non-empty `[ParsedTask]`: any route failure
/// (unavailable, decode violation, transport error, 401/5xx) falls through silently to the next
/// tier; the title-only floor is unconditional and always available. The 10-task cap is enforced
/// here regardless of which tier produced the result (defense in depth — each producer is also
/// expected to cap itself).
///
/// anh Khôi chốt 2026-07-28: `HeuristicNLParser` (Sources/Model/NLParser.swift) used to sit
/// beneath Cloud as a third tier — keyword/regex-guessed deadline/priority/recurrence/conditions
/// when neither FM nor Cloud were available. That tier is now DISCONNECTED, deliberately, not
/// deleted: `HeuristicNLParser`'s code is untouched and still fully present in `NLParser.swift`.
/// When FM and Cloud both fail to produce anything, this router now falls straight to a
/// title-only task (see `titleOnlyTask` below) instead of a heuristic guess. To reconnect it:
/// add back a `heuristic: IntentParser` parameter to `init` (defaulting to `HeuristicNLParser()`)
/// and an `await heuristic.parse(...)` / `await heuristic.breakdown(...)` call ahead of the
/// title-only fallback in `parse`/`breakdown` below — this exact shape is preserved in git
/// history (the commit right before this comment landed) if that's ever wanted again.
@MainActor
final class IntentRouter: IntentParser {
    /// Hard cap, all tiers, all call sites (contract: "Enforces the 10-task cap centrally").
    nonisolated static let maxTaskCap = 10

    /// Which tier actually produced the last successful result — diagnostics only, never PII
    /// (no transcript/title content), safe to log.
    ///
    /// `.heuristic` (2026-07-28: removed) used to name the old keyword/regex floor tier below
    /// Cloud. It is gone, not renamed to `.titleOnly`, because the two are different claims:
    /// `.heuristic` meant "a keyword scan guessed at structure"; `.titleOnly` means "no tier
    /// guessed at anything — the task is exactly, and only, the verbatim transcript as its
    /// title." Confirmed by repo-wide grep before this change that nothing reads `lastRoute`
    /// outside this file yet (see `backlog.md`'s "lastCloudQuotaNote/lastRoute chưa có UI đọc"
    /// note) — so no UI copy needs to change alongside this, but whoever eventually wires a
    /// reader should know `.heuristic` no longer exists as a case.
    enum Route: String, Sendable, Equatable {
        case foundationModel, cloud, titleOnly
        /// Transcript was empty/whitespace-only — `parse` returned `[]` without attempting any
        /// tier at all. Distinct from `.titleOnly`: that case always means "here is a task whose
        /// title is the transcript"; this one means there was no transcript to make a title out
        /// of in the first place.
        case empty
    }

    /// Set at the start of every `parse(...)` call; read by the confirm-card owner afterward.
    /// Default mirrors the pre-any-call floor (no call has happened yet, so nothing was actually
    /// title-only) — same role the old `.heuristic` default played.
    private(set) var lastRoute: Route = .titleOnly
    /// `true` for exactly the duration between a `parse(...)` call that hit Cloud's 429 and the
    /// NEXT `parse(...)` call (reset at the top of every call) — the confirm-card/UI owner reads
    /// this once per parse to show the one-line gentle note (FR-012, parse-proxy.md 429). This is
    /// a side channel: the frozen `IntentParser.parse` return type is `[ParsedTask]` only, so the
    /// "quota" signal can't ride in the return value itself.
    private(set) var lastCloudQuotaNote = false

    private let fm: FoundationModelParser?
    private let cloud: CloudParser?
    private let cloudGate: CloudParseGate?

    /// - Parameters:
    ///   - foundationModel: Defaults to the capability-probed singleton-ish factory — `nil` on
    ///     macOS < 26, non-Apple-Silicon, or when the on-device model itself isn't available
    ///     (probe never crashes; see `FoundationModelParser.makeIfAvailable()`).
    ///   - cloud: `nil` disables the Cloud tier entirely (e.g. no `ParseCredentialProvider`
    ///     composite wired up yet) — router falls straight from FM to the title-only floor.
    ///   - cloudGate: `nil` also disables Cloud (never attempt Cloud without an explicit gate
    ///     that can assert consent).
    ///
    ///   (2026-07-28: this initializer used to also take a `heuristic: IntentParser` parameter,
    ///   defaulting to `HeuristicNLParser()`. Removed along with the tier itself — see the class
    ///   doc comment above for why, and how to bring it back.)
    init(
        foundationModel: FoundationModelParser? = FoundationModelParser.makeIfAvailable(),
        cloud: CloudParser? = nil,
        cloudGate: CloudParseGate? = nil
    ) {
        self.fm = foundationModel
        self.cloud = cloud
        self.cloudGate = cloudGate
    }

    func parse(_ transcript: String, now: Date, openTaskTitles: [String]) async -> [ParsedTask] {
        lastCloudQuotaNote = false
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Nothing to parse. Callers shouldn't invoke this on empty input, but never crash or
            // fabricate a task out of nothing — an empty result here is the one legitimate `[]`.
            // `.empty`, NOT `.titleOnly`: there is no transcript to make a title out of, so this
            // is not the same claim as "the task is exactly the transcript, title-only."
            lastRoute = .empty
            return []
        }

        // R5: openTaskTitles forwarded to a remote/on-device model ONLY on dependency phrasing —
        // applied once here so every tier sees the same (possibly-empty) list.
        let titles = Self.containsDependencyPhrasing(transcript)
            ? Array(openTaskTitles.prefix(100))
            : []

        // Read once per `parse` call (not once per tier) so both tiers below see the exact same
        // number even if a Settings write races between them — negligible in practice, but this is
        // the cheap-and-correct way to write it either way.
        let defaultDurationMinutes = Self.currentDefaultDurationMinutes()

        if let fm {
            let result = await fm.parse(transcript, now: now, openTaskTitles: titles)
            if !result.isEmpty {
                lastRoute = .foundationModel
                // `applyStartTimeDerivation` runs here AND at the Cloud return below — same
                // static function, one implementation, so the two tiers can never diverge on this
                // rule (see the function's own doc comment for the full rationale).
                return Self.applyStartTimeDerivation(Self.cap(result), defaultMinutes: defaultDurationMinutes)
            }
        }

        if let cloud, let cloudGate, await cloudGate.isOptedIn(), await cloudGate.isOnline() {
            switch await cloud.parseDetailed(transcript, now: now, openTaskTitles: titles) {
            case .tasks(let tasks) where !tasks.isEmpty:
                lastRoute = .cloud
                return Self.applyStartTimeDerivation(Self.cap(tasks), defaultMinutes: defaultDurationMinutes)
            case .tasks:
                break // decoded but empty — fall through same as any other Cloud non-result
            case .quotaExceeded:
                lastCloudQuotaNote = true
            case .unavailable:
                break
            }
        }

        // anh Khôi chốt 2026-07-28: neither FM nor Cloud produced anything usable — fall straight
        // to the title-only floor instead of the old `HeuristicNLParser` keyword-guess tier (see
        // this class's doc comment above for the full rationale and how to reconnect it;
        // `HeuristicNLParser` itself is untouched in `NLParser.swift`, just no longer wired here).
        //
        // `titleOnlyTask`'s title carries no guess at all — it is the verbatim (trimmed)
        // transcript, which is exactly, not approximately, what the user said. `ParsedTask.title`
        // has no confidence wrapper (it's a plain `String`, documented in `NLParser.swift` as
        // "required; only guaranteed field") so there is no confidence VALUE to pick here; if
        // there were, 1.0 would be correct for the same reason — this isn't a model inferring
        // structure from ambiguous speech, it's the speech itself, unmodified.
        lastRoute = .titleOnly
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
        // anh Khôi chốt 2026-07-28: no more `HeuristicNLParser().breakdown(...)` floor here either
        // (see the class doc comment above `init`). Breakdown has no honest on-device fallback —
        // unlike `parse`'s title-only floor (the transcript itself is always a legitimate task
        // title), there is no non-fabricated way to invent 3...9 step titles without a real model.
        // So: neither tier available/usable -> `[]`, and the caller (`AppState.fetchBreakdown`)
        // is responsible for telling the user this needs cloud rather than showing invented steps.
        return []
    }

    // MARK: - Resolve-completion (T0xx: cloud-only paraphrase rescue for `VoiceDone`'s
    // empty-candidate case)
    //
    // Deliberately a SEPARATE method from `parse` above, not folded into it: `parse` answers "turn
    // this utterance into new tasks"; this answers "which existing task did the user just finish."
    // Different question, different prompt, different failure handling — merging them would
    // degrade both (per this task's own instruction).
    //
    // Cloud-only, no FM/Heuristic tier: FoundationModels and the on-device heuristic parser have
    // nothing to contribute to a semantic-paraphrase match. In fact the HEURISTIC layer here *is*
    // `VoiceDone`'s own Jaccard token-set matcher (`Sources/Speech/VoiceDone.swift`), which already
    // ran, on-device, before the caller (`AppState.resolveCompletionViaCloud`) ever reaches this
    // method — this method only exists for the case that matcher already reported "nothing above
    // the floor." There is no local fallback tier left to try; unavailable Cloud means "no
    // resolution," full stop, and the caller degrades to today's existing "no matching task" UI.
    func resolveCompletion(
        _ transcript: String, now: Date, kind: CloudParser.CompletionKind, candidates: [String]
    ) async -> CloudParser.CompletionResolution {
        // Same cloud opt-in + reachability gate `parse` applies above (R5: explicit one-time
        // privacy consent "regardless of tier" + best-effort reachability) — never sends a
        // transcript or candidate list without both being true, and (like `parse`) `cloud`/
        // `cloudGate` being `nil` (Cloud tier not wired up at all) is treated identically to "not
        // opted in."
        guard let cloud, let cloudGate, await cloudGate.isOptedIn(), await cloudGate.isOnline() else {
            return .unavailable
        }
        // Same defensive cap `parse` applies to `openTaskTitles` before it ever reaches
        // `CloudParser` — belt-and-suspenders alongside `CloudParser.resolveCompletion`'s own
        // internal 100-entry cap, since this is a second, independent call site into that
        // transport.
        let bounded = Array(candidates.prefix(100))
        return await cloud.resolveCompletion(transcript, now: now, kind: kind, candidates: bounded)
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

    // MARK: - Default task duration setting (2026-07-29)
    //
    // anh Khôi chốt 2026-07-29: "cái 30ph là estimate trong setting của user ... task cứ default
    // lấy từ setting ra cho duration task" — the 30-minute figure `applyStartTimeDerivation` below
    // used to hard-code is now a real user-configurable `AppState.defaultTaskDurationMinutes`
    // setting, read here via the same "non-`@MainActor`-reachable static helper reads `UserDefaults`
    // directly" seam `ReminderScheduler.currentGlobalReminderPolicy()` (`Sources/Reminders/
    // ReminderScheduler.swift`) already established for the identical problem (a Settings value
    // `AppState` owns, needed from a call site with no frozen init parameter to thread it through).

    /// Reads the user's default-task-duration setting straight out of `UserDefaults`. Reads
    /// `AppState.defaultTaskDurationMinutesKey` BY NAME, never a duplicated string literal, so this
    /// and `AppState`'s own read in `init` can never drift onto two different keys. Same 5...480
    /// bound and same 30-minute fallback as `AppState.setDefaultTaskDurationMinutes` — including the
    /// `UserDefaults.integer(forKey:)` returns-`0`-for-an-absent-key trap that bound also guards
    /// against.
    nonisolated static func currentDefaultDurationMinutes() -> Int {
        let stored = UserDefaults.standard.integer(forKey: AppState.defaultTaskDurationMinutesKey)
        return (5...480).contains(stored) ? stored : 30
    }

    // MARK: - Emergency-utterance deadline derivation (2026-07-28)
    //
    // anh Khôi chốt 2026-07-28: no new "emergency" task kind/flag. Instead, for an urgent
    // utterance ("làm task disposition code ngay lập tức") both the Cloud (Gemini) and on-device
    // tiers report `priority: 1`, `startTime` = "right now", and DELIBERATELY omit `deadline` (see
    // `supabase/functions/_shared/gemini.ts`'s prompt and this file's `FoundationModelParser`
    // prompt rules — never invent a deadline the user didn't imply). Every other part of the app
    // (sort order, reminders, the confirm card's deadline chip) keys off `deadline`, not
    // `startTime` — this function bridges that gap by deriving a PROVISIONAL deadline so a
    // startTime-only task still behaves like every other task downstream, without ever inventing
    // one for a task that already has a real, user-stated deadline.
    nonisolated static func applyStartTimeDerivation(
        _ tasks: [ParsedTask], defaultMinutes: Int = 30
    ) -> [ParsedTask] {
        tasks.map { task in
            // Only derive when there IS a startTime AND there is NOT already a deadline — a task
            // that states both ("làm ngay, 5 giờ chiều phải xong" -> startTime = now AND
            // deadline = 17:00) keeps its user-stated deadline completely untouched (constitution
            // II: never overwrite/second-guess what the user actually said).
            guard let startTime = task.startTime, task.deadline == nil else { return task }

            // `estimateMinutes` wins over the default when the model/user also gave a duration
            // estimate for the task ("ngay lập tức, chắc mất 45 phút" -> startTime + 45', not the
            // flat 30' default). `ParsedTask.estimateMinutes` is `ParsedValue<Int>?` (confirmed by
            // reading `NLParser.swift`'s `ParsedTask` declaration) — `.value` is already an `Int`
            // of minutes, no unit conversion needed here.
            let minutes = task.estimateMinutes?.value ?? defaultMinutes

            // `Calendar.current.date(byAdding: .minute, value:, to:)` — never raw `TimeInterval`
            // second-math (`startTime.value.addingTimeInterval(Double(minutes) * 60)` would also
            // work numerically today, but adding via `Calendar` is the deliberate, DST-safe choice
            // per this task's instruction). Foundation's contract allows this to return `nil`
            // (calendrical overflow); on `nil` the task is returned completely unmodified rather
            // than crashing or fabricating a deadline from a failed computation.
            guard let derivedDeadline = Calendar.current.date(
                byAdding: .minute, value: minutes, to: startTime.value
            ) else {
                return task
            }

            var derived = task
            // 2026-07-29, anh Khôi chốt — REVERSED from this function's original design, on
            // purpose, so read this before touching either number below:
            //
            // This confidence used to be a deliberately LOW 0.35 — well under `ParsedValue.
            // isUncertain`'s `confidence < 0.7` threshold (`Sources/Model/NLParser.swift:25`) — so
            // the confirm card's deadline chip rendered dashed and required an explicit accept tap
            // before the derived deadline would ever commit, exactly like any other low-confidence
            // attribute (constitution II: never silently commit a guess).
            //
            // That was tried, and it broke the very feature it belongs to: `AppState.resolvedValue`
            // (`Sources/App/AppState.swift`, ~line 3208) drops any `ParsedValue` below 0.7 unless the
            // user explicitly taps to accept it. So a user who said "làm task X ngay lập tức" and
            // then just hit Save — the entire point of an "urgent" utterance being fast — got a task
            // persisted with `deadline == nil`: it never sorted to the top, never got a reminder,
            // never did the one thing this feature exists to do. Requiring an extra confirm tap
            // defeats "ngay lập tức" as thoroughly as fabricating the deadline silently would have.
            //
            // Fix: 0.75 — ABOVE the 0.7 bar, so this auto-commits on a plain Save with zero extra
            // taps — plus `deadlineIsEstimated = true` on the task (see that field's own doc comment
            // in `NLParser.swift`), which is the explicit, separate signal `PopoverView.
            // DeadlineControl` uses to still label the chip as a guess (e.g. "· est") without gating
            // it behind an accept. 0.75, not 1.0: this is still a machine estimate, not something the
            // user said — if a future caller ever needs to distinguish "fully certain" from "quite
            // sure, but a guess," 0.75 already tells that story; 1.0 would falsely claim the former.
            //
            // DO NOT drop this back below 0.7 without also re-solving the `resolvedValue` interaction
            // above — that combination is exactly what silently broke the feature the first time.
            derived.deadline = ParsedValue(value: derivedDeadline, confidence: 0.75)
            derived.deadlineIsEstimated = true

            // 2026-07-29, anh Khôi chốt: also fill in `estimateMinutes` itself when the model/user
            // never gave one — this is the "duration" half of the same setting (`AppState.
            // defaultTaskDurationMinutes`), not a second, independent number. Deliberately the SAME
            // 0.75 confidence as `deadline` right above (not the low, pre-reversal confidence this
            // function used to use — see that comment block) for the identical reason: below 0.7,
            // `AppState.resolvedValue` (`Sources/App/AppState.swift`, ~line 3206) drops any
            // unaccepted `ParsedValue`, so a plain Save would persist the derived deadline but leave
            // `TaskItem.durationMinutes` empty — the estimate chip and the deadline chip would then
            // disagree about how long the task takes, exactly the confusion this single-setting
            // design exists to prevent. When the model/user DID supply an estimate, `minutes` above
            // already equals that value and this branch is skipped entirely — `task.estimateMinutes`
            // (with its own original confidence) is preserved completely untouched, per this
            // function's existing "never second-guess what was already stated" rule.
            if task.estimateMinutes == nil {
                derived.estimateMinutes = ParsedValue(value: minutes, confidence: 0.75)
            }

            return derived
        }
    }

    /// The absolute floor: a task with only a title (the source transcript, trimmed) and the
    /// transcript retained verbatim. Never crashes, never discards.
    nonisolated static func titleOnlyTask(_ transcript: String) -> ParsedTask {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedTask(
            title: trimmed.isEmpty ? transcript : trimmed,
            notes: nil,
            deadline: nil,
            startTime: nil,
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
    /// ISO8601 string. The instant the speaker begins WORKING on the task (distinct from
    /// `deadline`, the instant it must be DONE) — only ever emitted for urgent/"do it right now"
    /// phrasing where the server/on-device model reports `priority: 1` and no `deadline` of its
    /// own; `IntentRouter.applyStartTimeDerivation` derives a provisional `deadline` from this
    /// (2026-07-28, anh Khôi chốt: no new task "kind"/flag for this — just this one extra field).
    var startTime: RawConfidence<String>?
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
        startTime: RawConfidence<String>? = nil,
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
        self.startTime = startTime
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

        // `startTime` goes down the EXACT same path as `deadline` above (same `validConfidence` +
        // `parseISO8601` helpers) — per-attribute fallback (constitution II / this enum's own doc
        // comment): a malformed `startTime` (bad ISO8601 string, or confidence outside 0...1) drops
        // ONLY this field, never the rest of the task.
        let startTime: ParsedValue<Date>? = raw.startTime.flatMap { c in
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
            startTime: startTime,
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
