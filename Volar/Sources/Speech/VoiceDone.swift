// Sources/Speech/VoiceDone.swift — voice-done matcher (Phase 5, feature 002:
// specs/002-workflow-command-center/contracts/phase5-contract.md §A).
//
// OWNERSHIP (Phase 5, feature 002): this file owns `VoiceDoneIntent` / `VoiceMatch` /
// `VoiceDoneTask` / `VoiceDone` — the frozen seam the App-wiring agent (T036/T037/T038,
// `AppState.swift`/`PopoverView.swift`) codes against. Do not redefine these types elsewhere.
//
// Classifies a spoken utterance as a COMPLETION ("xong", "done", "làm xong", "hoàn thành" — the
// SPEAKER's own task is done), a CLEAR-EXTERNAL ("client đã ký", "anh Nam gửi rồi" — an external
// party finished their part of a task's `.external` wait-condition), or neither (falls through to
// normal new-task capture, Phase 3).
//
// Assistive, never authoritative (constitution II — "Never Silently Guess"): this type NEVER
// completes or clears anything itself; it only proposes scored candidates. The caller always
// confirms with the user before mutating a task. A single weak match is never collapsed into an
// auto-completion here (see `selectCandidates` below) — only an unambiguous, high-confidence,
// UNIQUE match ever shrinks to a one-item list; every other outcome returns either every
// above-floor candidate (so the caller disambiguates) or an explicit empty list (so the caller
// states "no matching task" instead of guessing).
//
// Vietnamese + English, on-device, pure (constitution I/III): no network, no disk, no clock reads
// — output depends solely on `transcript` and `openTasks`, and is deterministic (stable ordering:
// score descending, then `taskId` ascending). Reuses the diacritic+case fold / "đ/Đ" special-case /
// token-set (Jaccard) fuzzy-scoring convention established by `Model/NLParser.swift`
// (`HeuristicNLParser`) and `VolarCore/ConflictCheck.swift` (`normalizedTitleTokens` /
// `titleSimilarity`) rather than inventing a new scheme.
//
// // UNVERIFIED: authored on Windows, no Swift/Xcode toolchain available in this environment.
// Needs a `swift build`/`swift test` pass on macOS before merge (build-env split documented in
// CLAUDE.md). In particular: (a) Swift 6 strict-concurrency acceptance of a stateless `@MainActor
// struct` whose members are all synchronous pure logic, and (b) `String.folding(options:locale:)`
// behavior on real Vietnamese ASR transcripts (spacing/casing quirks WhisperKit/Groq may emit)
// have not been exercised against real audio output.
import Foundation

// MARK: - Frozen seam (phase5-contract.md §A)

/// Result of classifying a transcript against the user's current open tasks.
enum VoiceDoneIntent: Sendable, Equatable {
    /// A "xong/done" phrase was detected. `candidates` may be empty — that specifically means the
    /// phrase was clearly present but nothing in `openTasks` matched, so the caller states "no
    /// matching task" rather than guessing (constitution II), never falling silently back to
    /// `.notACompletion`.
    case complete(candidates: [VoiceMatch])
    /// A "client đã ký" / "anh Nam gửi rồi" style external-condition phrase was detected. Same
    /// empty-candidates convention as `.complete`.
    case clearExternal(candidates: [VoiceMatch])
    /// No completion/clear-external phrase detected at all — falls through to normal new-task
    /// capture (Phase 3).
    case notACompletion
}

/// One scored match against an open task. `score` is the raw token-set (Jaccard) similarity in
/// `[0, 1]` between the utterance (cue words stripped) and either the task's title (`.complete`)
/// or one of its `externalDescriptions` (`.clearExternal`).
struct VoiceMatch: Sendable, Equatable {
    let taskId: UUID
    let title: String
    let score: Double
}

/// The minimal shape `VoiceDone` needs from an open/in-progress task: id + title for
/// `.complete` matching, plus each currently-unsatisfied `.external` condition's description text
/// for `.clearExternal` matching.
struct VoiceDoneTask: Sendable, Equatable {
    let id: UUID
    let title: String
    let externalDescriptions: [String]
}

/// Vietnamese+English aware voice-done matcher. Pure, stateless, deterministic — see file header.
@MainActor
struct VoiceDone {
    func classify(_ transcript: String, openTasks: [VoiceDoneTask]) -> VoiceDoneIntent {
        Self.classifyImpl(transcript, openTasks: openTasks)
    }

    // MARK: - Tuning constants

    /// A single candidate at/above this score is confident enough to collapse the result to a
    /// one-item list (the caller offers a one-tap/one-word confirm). Matches the contract's "~0.8"
    /// high bar.
    private static let highConfidenceThreshold = 0.8
    /// Floor below which a candidate is noise and never surfaced at all. Matches the contract's
    /// "~0.5" disambiguation floor.
    private static let candidateFloor = 0.5

    /// Defensive bound on how much of the transcript is tokenized/matched — protects against
    /// adversarial/pathological input (megabyte-scale paste from a runaway ASR feed) doing
    /// unbounded work. Mirrors `HeuristicNLParser.maxWorkingLength`'s role in `NLParser.swift`.
    private static let maxWorkingLength = 4_000
    /// Bounds tokenization cost per string (transcript or a title/external-description), mirroring
    /// `ConflictCheck.maxTokensForMatching`.
    private static let maxTokens = 64
    /// Bounds per-task `externalDescriptions` scanning so a pathologically long list on one task
    /// snapshot can't blow up matching cost.
    private static let maxExternalDescriptionsPerTask = 20
    /// Bounds an individual external-description string before tokenizing, mirroring
    /// `ConflictCheck.maxTitleCharsForMatching`'s role for titles.
    private static let maxExternalDescriptionChars = 500

    // MARK: - Cue phrases

    /// Phrases indicating the SPEAKER's own task is complete, expressed as their normalized
    /// (folded) token sequences so detection is token-exact rather than raw substring `contains`
    /// (substring matching on short cues like "done"/"sent" false-positives inside unrelated
    /// English words — e.g. "abandoned" contains "done", "presentation" contains "sent" — so this
    /// keeps that class of false positive out).
    private static let completionCuePhrases: [[String]] = [
        "làm xong", "đã xong", "xong rồi", "hoàn thành", "hoàn tất",
        "xong", "finished", "done", "completed", "complete"
    ].map(normalizedTokens)

    /// Phrases indicating an EXTERNAL party finished their part (clears a `.external` condition)
    /// rather than the speaker's own task, same token-sequence convention as above.
    private static let externalCuePhrases: [[String]] = [
        "đã ký", "ký rồi", "đã gửi", "gửi rồi", "đã trả lời", "trả lời rồi",
        "signed", "sent", "replied", "responded", "answered"
    ].map(normalizedTokens)

    /// Flattened set of every token appearing in any cue phrase above. Stripped out of the
    /// transcript's token set before fuzzy-matching against titles/external-descriptions so cue
    /// words ("xong", "rồi", "đã"...) never dilute or pollute the Jaccard overlap.
    private static let cueStripTokens: Set<String> = {
        var tokens = Set<String>()
        for phrase in completionCuePhrases + externalCuePhrases {
            tokens.formUnion(phrase)
        }
        return tokens
    }()

    // MARK: - Classification

    private static func classifyImpl(_ transcript: String, openTasks: [VoiceDoneTask]) -> VoiceDoneIntent {
        let bounded = transcript.count > maxWorkingLength ? String(transcript.prefix(maxWorkingLength)) : transcript
        guard !bounded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .notACompletion }

        let transcriptTokens = normalizedTokens(bounded)

        let hasExternalCue = externalCuePhrases.contains { containsCuePhrase($0, in: transcriptTokens) }
        let hasCompletionCue = completionCuePhrases.contains { containsCuePhrase($0, in: transcriptTokens) }

        // No recognizable done/clear-external phrase at all → not our concern, let the normal
        // new-task capture flow handle it (Phase 3).
        guard hasExternalCue || hasCompletionCue else { return .notACompletion }

        // A compound utterance naming both an external verb ("ký"/"gửi"/"trả lời") and a bare
        // completion word ("xong") is classified as clear-external — the external verb is the
        // more specific signal (a bare "xong" is ambiguous between "my task is done" and "the
        // external thing is done", per the contract's own "X đã xong/gửi/trả lời" example
        // grouping "xong" alongside "gửi"/"trả lời" under clear-external).
        let referenceTokens = Set(transcriptTokens.filter { !cueStripTokens.contains($0) })

        if hasExternalCue {
            let candidates = scoredExternalCandidates(referenceTokens: referenceTokens, openTasks: openTasks)
            return .clearExternal(candidates: selectCandidates(candidates))
        } else {
            let candidates = scoredTitleCandidates(referenceTokens: referenceTokens, openTasks: openTasks)
            return .complete(candidates: selectCandidates(candidates))
        }
    }

    /// True when `phraseTokens` appears as a contiguous run inside `tokens` (subsequence-of-length
    /// `phraseTokens.count` equality check). Cue phrase lists are short (~10 entries) and `tokens`
    /// is bounded by `maxTokens`, so the worst case is a small, fixed amount of work — no
    /// catastrophic-regex-style blowup.
    private static func containsCuePhrase(_ phraseTokens: [String], in tokens: [String]) -> Bool {
        guard !phraseTokens.isEmpty, phraseTokens.count <= tokens.count else { return false }
        if phraseTokens.count == 1 { return tokens.contains(phraseTokens[0]) }
        for start in 0...(tokens.count - phraseTokens.count) {
            if Array(tokens[start..<(start + phraseTokens.count)]) == phraseTokens { return true }
        }
        return false
    }

    // MARK: - Candidate scoring

    /// Scores every open task's title against `referenceTokens` (the utterance with cue words
    /// stripped), keeping only tasks at/above `candidateFloor`. An empty `referenceTokens` (e.g.
    /// the whole utterance WAS the cue phrase, like a bare "xong") always yields no candidates —
    /// this is the "done-phrase present but nothing matched" case the contract requires to surface
    /// as empty candidates rather than a guess.
    private static func scoredTitleCandidates(referenceTokens: Set<String>, openTasks: [VoiceDoneTask]) -> [VoiceMatch] {
        guard !referenceTokens.isEmpty else { return [] }
        var results: [VoiceMatch] = []
        for task in openTasks {
            let score = jaccard(referenceTokens, normalizedTokenSet(task.title))
            guard score >= candidateFloor else { continue }
            results.append(VoiceMatch(taskId: task.id, title: task.title, score: score))
        }
        return results
    }

    /// Scores every open task's `externalDescriptions` against `referenceTokens`, taking each
    /// task's BEST-matching description as that task's candidate score (a task is a single
    /// candidate for disambiguation purposes even if it has several unsatisfied external
    /// conditions).
    private static func scoredExternalCandidates(referenceTokens: Set<String>, openTasks: [VoiceDoneTask]) -> [VoiceMatch] {
        guard !referenceTokens.isEmpty else { return [] }
        var results: [VoiceMatch] = []
        for task in openTasks {
            var best = 0.0
            for description in task.externalDescriptions.prefix(maxExternalDescriptionsPerTask) {
                let bounded = description.count > maxExternalDescriptionChars
                    ? String(description.prefix(maxExternalDescriptionChars))
                    : description
                let score = jaccard(referenceTokens, normalizedTokenSet(bounded))
                if score > best { best = score }
            }
            guard best >= candidateFloor else { continue }
            results.append(VoiceMatch(taskId: task.id, title: task.title, score: best))
        }
        return results
    }

    /// Applies the confirm-vs-disambiguate threshold rule (phase5-contract.md §A / constitution
    /// II): a SINGLE candidate at/above `highConfidenceThreshold` is confident and unambiguous
    /// enough to collapse to a one-item list (the caller offers a one-tap/one-word confirm).
    /// Anything else — zero high-confidence candidates, OR two-or-more tied at high confidence —
    /// returns every candidate at/above the floor so the caller disambiguates instead of guessing.
    /// Stable ordering: score descending, then `taskId` string ascending (mirrors
    /// `ConflictCheck.swift`'s id-lexical tiebreak), so output is deterministic for identical
    /// input regardless of `openTasks`' original order.
    private static func selectCandidates(_ candidates: [VoiceMatch]) -> [VoiceMatch] {
        guard !candidates.isEmpty else { return [] }
        let sorted = candidates.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.taskId.uuidString < rhs.taskId.uuidString
        }
        let highConfidence = sorted.filter { $0.score >= highConfidenceThreshold }
        if highConfidence.count == 1 {
            return highConfidence
        }
        return sorted
    }

    // MARK: - Normalization (same convention as ConflictCheck.normalizedTitleTokens)

    /// Diacritic- and case-fold (so "Đã xong" and "da xong" tokenize identically), then split on
    /// any non-letter/non-number boundary. Bounded on both input length and token count so
    /// adversarially huge input cannot make this (or any O(n) scan that calls it once per task)
    /// expensive. Identical formula to `ConflictCheck.normalizedTitleTokens` — see that file's
    /// comment for why "đ"/"Đ" needs an explicit post-fold replace (it has no Unicode diacritic
    /// decomposition, unlike ô/ơ/ư/tone marks).
    private static func normalizedTokens(_ text: String) -> [String] {
        let bounded = text.count > maxWorkingLength ? String(text.prefix(maxWorkingLength)) : text
        let folded = bounded.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "vi_VN"))
        let strokeNormalized = folded.replacingOccurrences(of: "đ", with: "d")
            .replacingOccurrences(of: "Đ", with: "d")
        let tokens = strokeNormalized.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return tokens.count > maxTokens ? Array(tokens.prefix(maxTokens)) : tokens
    }

    private static func normalizedTokenSet(_ text: String) -> Set<String> {
        Set(normalizedTokens(text))
    }

    /// Jaccard similarity (`|intersection| / |union|`) — identical formula to
    /// `ConflictCheck.titleSimilarity`. Either side being empty (a title/description that
    /// tokenizes to nothing, or an utterance that was entirely cue words) never matches — no
    /// divide-by-zero, no degenerate empty-vs-empty "match".
    private static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let intersection = a.intersection(b).count
        let union = a.union(b).count
        guard union > 0 else { return 0 }
        return Double(intersection) / Double(union)
    }
}
