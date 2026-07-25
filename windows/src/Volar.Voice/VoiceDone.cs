// src/Volar.Voice/VoiceDone.cs — voice-done matcher (Phase 5, feature 002:
// specs/002-workflow-command-center/contracts/phase5-contract.md §A). Port of macOS
// `Volar/Sources/Speech/VoiceDone.swift` (post-review, merge commit `4fa783d` on `window`).
//
// OWNERSHIP: this file owns `VoiceDoneIntent` (+ its three cases) / `VoiceMatch` / `VoiceDoneTask`
// / `VoiceDone` — the frozen seam Wave 3-C's App-wiring codes against (mirrors the Swift header's
// note that AppState.swift/PopoverView.swift code against these exact types). Do not redefine
// these types elsewhere.
//
// Classifies a spoken utterance as a COMPLETION ("xong", "done", "làm xong", "hoàn thành" — the
// SPEAKER's own task is done), a CLEAR-EXTERNAL ("client đã ký", "anh Nam gửi rồi" — an external
// party finished their part of a task's `.external` wait-condition), or neither (falls through to
// normal new-task capture, Phase 3).
//
// Assistive, never authoritative (constitution II — "Never Silently Guess"): this type NEVER
// completes or clears anything itself; it only proposes scored candidates. The caller always
// confirms with the user before mutating a task. A single weak match is never collapsed into an
// auto-completion here (see `SelectCandidates` below) — only an unambiguous, high-confidence,
// UNIQUE match ever shrinks to a one-item list; every other outcome returns either every
// above-floor candidate (so the caller disambiguates) or an explicit empty list (so the caller
// states "no matching task" instead of guessing).
//
// Vietnamese + English, on-device, pure (constitution I/III): no network, no disk, no clock reads
// — output depends solely on `transcript` and `openTasks`, and is deterministic (stable ordering:
// score descending, then `taskId` ascending). Reuses the diacritic+case-fold / "đ/Đ" special-case /
// token-set (Jaccard) fuzzy-scoring convention established by `Volar.Core.ConflictCheck`
// (`NormalizedTitleTokens` / `TitleSimilarity`, itself a port of `Model/NLParser.swift` and
// `VolarCore/ConflictCheck.swift`) rather than inventing a new scheme. The algorithm is
// re-implemented here (not called into `Volar.Core`) because the Swift original does the same —
// `VoiceDone.swift`'s `normalizedTokens` is its own private copy, not a call into
// `ConflictCheck.normalizedTitleTokens` — and because this project must stay free of any
// dependency the App-wiring layer doesn't already need for this seam.
//
// // UNVERIFIED (carried over from the Swift): the Swift original notes it was authored without a
// macOS toolchain and needed a real `swift test` pass before merge; the .NET port carries an
// analogous risk in the opposite direction — .NET's NFD-decomposition diacritic fold (see
// `NormalizedTokens` below) has not been exercised against real Vietnamese ASR output from
// WhisperKit/Groq/whisper.net on Windows. Both platforms fold diacritics for matching purposes,
// but via different mechanisms (ICU `folding(options:locale:)` on Swift vs
// `NormalizationForm.FormD` + stripping `NonSpacingMark` codepoints here), so edge-case Unicode
// input (rare combining sequences, precomposed vs decomposed forms in Whisper's own output) could
// in principle fold differently on the two platforms. Verify with real captured transcripts once
// Wave 3-C wires a live ASR engine in front of this classifier.
//
// CONCURRENCY: there is no C# equivalent of Swift's actor-isolation concern (the Swift header's
// long comment about why the type is deliberately NOT `@MainActor`), but the underlying property
// still holds and is worth stating: `VoiceDone` has no instance state — it is a static class over
// pure functions and `static readonly` data — so it is safe to call from any thread, including a
// UI thread, without synchronization.

using System.Globalization;
using System.Text;

namespace Volar.Voice;

/// <summary>
/// Result of classifying a transcript against the user's current open tasks. Modeled as a closed
/// discriminated union (an <see langword="abstract record"/> with exactly three
/// <see langword="sealed"/> subtypes, mirroring Swift's <c>enum VoiceDoneIntent: Sendable,
/// Equatable</c> with associated values and <see cref="Volar.Core.Condition"/>'s own C# hierarchy
/// convention), matched exhaustively via a <see langword="switch"/> expression rather than a
/// Swift-style <see langword="switch"/> statement over an enum.
/// </summary>
public abstract record VoiceDoneIntent
{
    // `private protected` constructor: only the three sealed subtypes declared in this file may
    // derive from VoiceDoneIntent, keeping the union effectively closed, mirroring
    // Volar.Core.Condition.
    private protected VoiceDoneIntent() { }
}

/// <summary>
/// A "xong/done" phrase was detected. <see cref="Candidates"/> may be empty — that specifically
/// means the phrase was clearly present but nothing in <c>openTasks</c> matched, so the caller
/// states "no matching task" rather than guessing (constitution II), never falling silently back
/// to <see cref="NotACompletionIntent"/>.
/// </summary>
public sealed record CompleteIntent(IReadOnlyList<VoiceMatch> Candidates) : VoiceDoneIntent;

/// <summary>
/// A "client đã ký" / "anh Nam gửi rồi" style external-condition phrase was detected. Same
/// empty-candidates convention as <see cref="CompleteIntent"/>.
/// </summary>
public sealed record ClearExternalIntent(IReadOnlyList<VoiceMatch> Candidates) : VoiceDoneIntent;

/// <summary>
/// No completion/clear-external phrase detected at all — falls through to normal new-task capture
/// (Phase 3).
/// </summary>
public sealed record NotACompletionIntent : VoiceDoneIntent;

/// <summary>
/// One scored match against an open task. <see cref="Score"/> is the raw token-set (Jaccard)
/// similarity in <c>[0, 1]</c> between the utterance (cue words stripped) and either the task's
/// title (<see cref="CompleteIntent"/>) or one of its external descriptions
/// (<see cref="ClearExternalIntent"/>).
/// </summary>
public sealed record VoiceMatch(Guid TaskId, string Title, double Score);

/// <summary>
/// The minimal shape <see cref="VoiceDone"/> needs from an open/in-progress task: id + title for
/// <see cref="CompleteIntent"/> matching, plus each currently-unsatisfied <c>.external</c>
/// condition's description text for <see cref="ClearExternalIntent"/> matching.
/// </summary>
public sealed record VoiceDoneTask(Guid Id, string Title, IReadOnlyList<string> ExternalDescriptions);

/// <summary>
/// Vietnamese+English aware voice-done matcher. Pure, stateless, deterministic — see file header.
/// <see cref="Classify"/> is the whole public surface.
/// </summary>
public static class VoiceDone
{
    // MARK: - Tuning constants

    /// <summary>
    /// A single candidate at/above this score is confident enough to collapse the result to a
    /// one-item list (the caller offers a one-tap/one-word confirm). Matches the contract's "~0.8"
    /// high bar.
    /// </summary>
    private const double HighConfidenceThreshold = 0.8;

    /// <summary>
    /// Floor below which a candidate is noise and never surfaced at all. Matches the contract's
    /// "~0.5" disambiguation floor.
    /// </summary>
    private const double CandidateFloor = 0.5;

    /// <summary>
    /// Defensive bound on how much of the transcript is tokenized/matched — protects against
    /// adversarial/pathological input (megabyte-scale paste from a runaway ASR feed) doing
    /// unbounded work. Mirrors <c>HeuristicNLParser.maxWorkingLength</c>'s role in
    /// <c>NLParser.swift</c>.
    /// </summary>
    private const int MaxWorkingLength = 4_000;

    /// <summary>
    /// Bounds tokenization cost per string (transcript or a title/external-description), mirroring
    /// <c>ConflictCheck.maxTokensForMatching</c>.
    /// </summary>
    private const int MaxTokens = 64;

    /// <summary>
    /// Bounds per-task <c>ExternalDescriptions</c> scanning so a pathologically long list on one
    /// task snapshot can't blow up matching cost.
    /// </summary>
    private const int MaxExternalDescriptionsPerTask = 20;

    /// <summary>
    /// Bounds an individual external-description string before tokenizing, mirroring
    /// <c>ConflictCheck.maxTitleCharsForMatching</c>'s role for titles.
    /// </summary>
    private const int MaxExternalDescriptionChars = 500;

    // MARK: - Cue phrases

    /// <summary>
    /// Phrases indicating the SPEAKER's own task is complete, expressed as their normalized
    /// (folded) token sequences so detection is token-exact rather than raw substring
    /// <c>Contains</c> (substring matching on short cues like "done"/"sent" false-positives inside
    /// unrelated English words — e.g. "abandoned" contains "done", "presentation" contains "sent"
    /// — so this keeps that class of false positive out). Data, not logic: ported verbatim,
    /// same order as the Swift table.
    /// </summary>
    private static readonly IReadOnlyList<IReadOnlyList<string>> CompletionCuePhrases =
        new string[]
        {
            "làm xong", "đã xong", "xong rồi", "hoàn thành", "hoàn tất",
            "xong", "finished", "done", "completed", "complete"
        }
        .Select(NormalizedTokens)
        .Cast<IReadOnlyList<string>>()
        .ToArray();

    /// <summary>
    /// Phrases indicating an EXTERNAL party finished their part (clears a <c>.external</c>
    /// condition) rather than the speaker's own task, same token-sequence convention as above.
    /// Ported verbatim, same order as the Swift table.
    /// </summary>
    private static readonly IReadOnlyList<IReadOnlyList<string>> ExternalCuePhrases =
        new string[]
        {
            "đã ký", "ký rồi", "đã gửi", "gửi rồi", "đã trả lời", "trả lời rồi",
            "signed", "sent", "replied", "responded", "answered"
        }
        .Select(NormalizedTokens)
        .Cast<IReadOnlyList<string>>()
        .ToArray();

    /// <summary>
    /// Flattened set of every token appearing in any cue phrase above. Stripped out of the
    /// transcript's token set before fuzzy-matching against titles/external-descriptions so cue
    /// words ("xong", "rồi", "đã"...) never dilute or pollute the Jaccard overlap.
    /// </summary>
    private static readonly IReadOnlySet<string> CueStripTokens = BuildCueStripTokens();

    private static HashSet<string> BuildCueStripTokens()
    {
        var tokens = new HashSet<string>(StringComparer.Ordinal);
        foreach (var phrase in CompletionCuePhrases)
        {
            tokens.UnionWith(phrase);
        }
        foreach (var phrase in ExternalCuePhrases)
        {
            tokens.UnionWith(phrase);
        }
        return tokens;
    }

    // MARK: - Classification

    /// <summary>
    /// Classifies <paramref name="transcript"/> against <paramref name="openTasks"/>. Pure and
    /// synchronous: no I/O, no logging, no clock reads. See the type's file header for the
    /// completion-vs-clear-external-vs-neither decision and the confirm-vs-disambiguate rule.
    /// </summary>
    public static VoiceDoneIntent Classify(string transcript, IReadOnlyList<VoiceDoneTask> openTasks)
    {
        var bounded = transcript.Length > MaxWorkingLength ? transcript[..MaxWorkingLength] : transcript;
        if (string.IsNullOrWhiteSpace(bounded))
        {
            return new NotACompletionIntent();
        }

        var transcriptTokens = NormalizedTokens(bounded);

        var hasExternalCue = ExternalCuePhrases.Any(phrase => ContainsCuePhrase(phrase, transcriptTokens));
        var hasCompletionCue = CompletionCuePhrases.Any(phrase => ContainsCuePhrase(phrase, transcriptTokens));

        // No recognizable done/clear-external phrase at all -> not our concern, let the normal
        // new-task capture flow handle it (Phase 3).
        if (!hasExternalCue && !hasCompletionCue)
        {
            return new NotACompletionIntent();
        }

        // A compound utterance naming both an external verb ("ký"/"gửi"/"trả lời") and a bare
        // completion word ("xong") is classified as clear-external — the external verb is the
        // more specific signal (a bare "xong" is ambiguous between "my task is done" and "the
        // external thing is done", per the contract's own "X đã xong/gửi/trả lời" example
        // grouping "xong" alongside "gửi"/"trả lời" under clear-external).
        var referenceTokens = new HashSet<string>(
            transcriptTokens.Where(token => !CueStripTokens.Contains(token)),
            StringComparer.Ordinal);

        if (hasExternalCue)
        {
            var candidates = ScoredExternalCandidates(referenceTokens, openTasks);
            return new ClearExternalIntent(SelectCandidates(candidates));
        }
        else
        {
            var candidates = ScoredTitleCandidates(referenceTokens, openTasks);
            return new CompleteIntent(SelectCandidates(candidates));
        }
    }

    /// <summary>
    /// True when <paramref name="phraseTokens"/> appears as a contiguous run inside
    /// <paramref name="tokens"/> (subsequence-of-length-<c>phraseTokens.Count</c> equality check).
    /// Cue phrase lists are short (~10 entries) and <paramref name="tokens"/> is bounded by
    /// <see cref="MaxTokens"/>, so the worst case is a small, fixed amount of work — no
    /// catastrophic-regex-style blowup.
    /// </summary>
    private static bool ContainsCuePhrase(IReadOnlyList<string> phraseTokens, IReadOnlyList<string> tokens)
    {
        if (phraseTokens.Count == 0 || phraseTokens.Count > tokens.Count)
        {
            return false;
        }
        if (phraseTokens.Count == 1)
        {
            return tokens.Contains(phraseTokens[0]);
        }
        for (var start = 0; start <= tokens.Count - phraseTokens.Count; start++)
        {
            var matches = true;
            for (var offset = 0; offset < phraseTokens.Count; offset++)
            {
                if (tokens[start + offset] != phraseTokens[offset])
                {
                    matches = false;
                    break;
                }
            }
            if (matches)
            {
                return true;
            }
        }
        return false;
    }

    // MARK: - Candidate scoring

    /// <summary>
    /// Scores every open task's title against <paramref name="referenceTokens"/> (the utterance
    /// with cue words stripped), keeping only tasks at/above <see cref="CandidateFloor"/>. An empty
    /// <paramref name="referenceTokens"/> (e.g. the whole utterance WAS the cue phrase, like a bare
    /// "xong") always yields no candidates — this is the "done-phrase present but nothing matched"
    /// case the contract requires to surface as empty candidates rather than a guess.
    /// </summary>
    private static List<VoiceMatch> ScoredTitleCandidates(
        IReadOnlySet<string> referenceTokens, IReadOnlyList<VoiceDoneTask> openTasks)
    {
        var results = new List<VoiceMatch>();
        if (referenceTokens.Count == 0)
        {
            return results;
        }
        foreach (var task in openTasks)
        {
            var score = Jaccard(referenceTokens, NormalizedTokenSet(task.Title));
            if (score < CandidateFloor)
            {
                continue;
            }
            results.Add(new VoiceMatch(task.Id, task.Title, score));
        }
        return results;
    }

    /// <summary>
    /// Scores every open task's <c>ExternalDescriptions</c> against <paramref
    /// name="referenceTokens"/>, taking each task's BEST-matching description as that task's
    /// candidate score (a task is a single candidate for disambiguation purposes even if it has
    /// several unsatisfied external conditions).
    /// </summary>
    private static List<VoiceMatch> ScoredExternalCandidates(
        IReadOnlySet<string> referenceTokens, IReadOnlyList<VoiceDoneTask> openTasks)
    {
        var results = new List<VoiceMatch>();
        if (referenceTokens.Count == 0)
        {
            return results;
        }
        foreach (var task in openTasks)
        {
            var best = 0.0;
            foreach (var description in task.ExternalDescriptions.Take(MaxExternalDescriptionsPerTask))
            {
                var bounded = description.Length > MaxExternalDescriptionChars
                    ? description[..MaxExternalDescriptionChars]
                    : description;
                var score = Jaccard(referenceTokens, NormalizedTokenSet(bounded));
                if (score > best)
                {
                    best = score;
                }
            }
            if (best < CandidateFloor)
            {
                continue;
            }
            results.Add(new VoiceMatch(task.Id, task.Title, best));
        }
        return results;
    }

    /// <summary>
    /// Applies the confirm-vs-disambiguate threshold rule (phase5-contract.md §A / constitution
    /// II): a SINGLE candidate at/above <see cref="HighConfidenceThreshold"/> is confident and
    /// unambiguous enough to collapse to a one-item list (the caller offers a one-tap/one-word
    /// confirm). Anything else — zero high-confidence candidates, OR two-or-more tied at high
    /// confidence — returns every candidate at/above the floor so the caller disambiguates instead
    /// of guessing. Stable ordering: score descending, then <c>taskId</c> string ascending (mirrors
    /// <c>ConflictChecker</c>'s id-ordinal tiebreak), so output is deterministic for identical input
    /// regardless of <c>openTasks</c>' original order.
    /// </summary>
    private static IReadOnlyList<VoiceMatch> SelectCandidates(List<VoiceMatch> candidates)
    {
        if (candidates.Count == 0)
        {
            return [];
        }
        var sorted = candidates
            .OrderByDescending(match => match.Score)
            .ThenBy(match => match.TaskId.ToString(), StringComparer.Ordinal)
            .ToList();
        var highConfidence = sorted.Where(match => match.Score >= HighConfidenceThreshold).ToList();
        return highConfidence.Count == 1 ? highConfidence : sorted;
    }

    // MARK: - Normalization (same convention as ConflictCheck.NormalizedTitleTokens)

    /// <summary>
    /// Diacritic- and case-fold (so "Đã xong" and "da xong" tokenize identically), then split on
    /// any non-letter/non-digit boundary. Bounded on both input length and token count so
    /// adversarially huge input cannot make this (or any O(n) scan that calls it once per task)
    /// expensive.
    /// </summary>
    /// <remarks>
    /// The Swift original folds via <c>String.folding(options: [.diacriticInsensitive,
    /// .caseInsensitive], locale: Locale(identifier: "vi_VN"))</c> then replaces the atomic
    /// "đ"/"Đ" (a letter-with-stroke with no Unicode diacritic decomposition, unlike ô/ơ/ư/tone
    /// marks) — i.e. it DOES fold diacritics away, which is what makes "bao cao" match "báo cáo"
    /// when Whisper drops tone marks. This port reproduces that with .NET's own idiom instead of
    /// attempting to call into ICU: Unicode NFD decomposition splits base letters from their
    /// combining diacritical marks, then stripping Unicode category <c>NonSpacingMark</c> (Mn)
    /// codepoints folds them away without touching "đ" (which survives decomposition untouched,
    /// so it is mapped explicitly, post-lowercasing). Identical algorithm to
    /// <c>Volar.Core.ConflictCheck.NormalizedTitleTokens</c> — re-implemented here rather than
    /// referenced because the Swift original does the same (its own private copy, not a call into
    /// <c>ConflictCheck.normalizedTitleTokens</c>).
    /// </remarks>
    private static List<string> NormalizedTokens(string text)
    {
        var bounded = text.Length > MaxWorkingLength ? text[..MaxWorkingLength] : text;

        var decomposed = bounded.Normalize(NormalizationForm.FormD);
        var stripped = new StringBuilder(decomposed.Length);
        foreach (var ch in decomposed)
        {
            if (CharUnicodeInfo.GetUnicodeCategory(ch) == UnicodeCategory.NonSpacingMark)
            {
                continue;
            }
            stripped.Append(ch);
        }

        var folded = stripped.ToString().ToLowerInvariant().Replace('đ', 'd');

        var tokens = new List<string>();
        var current = new StringBuilder();
        foreach (var ch in folded)
        {
            if (char.IsLetterOrDigit(ch))
            {
                current.Append(ch);
            }
            else if (current.Length > 0)
            {
                tokens.Add(current.ToString());
                current.Clear();
            }
        }
        if (current.Length > 0)
        {
            tokens.Add(current.ToString());
        }

        return tokens.Count > MaxTokens ? tokens.Take(MaxTokens).ToList() : tokens;
    }

    private static HashSet<string> NormalizedTokenSet(string text) =>
        new(NormalizedTokens(text), StringComparer.Ordinal);

    /// <summary>
    /// Jaccard similarity (<c>|intersection| / |union|</c>) — identical formula to
    /// <c>ConflictChecker.TitleSimilarity</c>. Either side being empty (a title/description that
    /// tokenizes to nothing, or an utterance that was entirely cue words) never matches — no
    /// divide-by-zero, no degenerate empty-vs-empty "match".
    /// </summary>
    private static double Jaccard(IReadOnlySet<string> a, IReadOnlySet<string> b)
    {
        if (a.Count == 0 || b.Count == 0)
        {
            return 0;
        }
        var intersection = 0;
        foreach (var token in a)
        {
            if (b.Contains(token))
            {
                intersection++;
            }
        }
        var union = a.Count + b.Count - intersection;
        if (union == 0)
        {
            return 0;
        }
        return (double)intersection / union;
    }
}
