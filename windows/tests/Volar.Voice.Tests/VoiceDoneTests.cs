using Xunit;
using static Volar.Voice.Tests.Fixtures;

namespace Volar.Voice.Tests;

/// <summary>
/// Coverage for <see cref="VoiceDone.Classify"/> (phase5-contract.md §A): the completion vs
/// clear-external vs neither classification, the confirm-vs-disambiguate threshold rule, the
/// abuse caps (transcript length, external-description count/length), the empty-input edge cases,
/// and the Vietnamese diacritic fold. Mirrors the required-coverage list in
/// specs/003-windows-port/wave3b-parity.md's A1 section.
/// </summary>
public class VoiceDoneTests
{
    // MARK: - Not a completion at all

    [Fact]
    public void NoCuePhrase_ReturnsNotACompletion()
    {
        var openTasks = new[] { MakeTask(id: FixedGuid(1), title: "Mua sữa cho em bé") };

        var result = VoiceDone.Classify("mua sữa cho em bé", openTasks);

        Assert.IsType<NotACompletionIntent>(result);
    }

    [Fact]
    public void BlankTranscript_ReturnsNotACompletion()
    {
        var openTasks = new[] { MakeTask(id: FixedGuid(1), title: "Viết báo cáo") };

        var result = VoiceDone.Classify("   ", openTasks);

        Assert.IsType<NotACompletionIntent>(result);
    }

    [Fact]
    public void EmptyTranscript_ReturnsNotACompletion()
    {
        var result = VoiceDone.Classify(string.Empty, []);

        Assert.IsType<NotACompletionIntent>(result);
    }

    // MARK: - Exact-title completion

    [Fact]
    public void ExactTitleMatch_CollapsesToSingleHighConfidenceCandidate()
    {
        var task = MakeTask(id: FixedGuid(1), title: "Viết báo cáo");
        var openTasks = new[] { task };

        var result = VoiceDone.Classify("viết báo cáo xong rồi", openTasks);

        var complete = Assert.IsType<CompleteIntent>(result);
        var candidate = Assert.Single(complete.Candidates);
        Assert.Equal(task.Id, candidate.TaskId);
        Assert.Equal(1.0, candidate.Score);
    }

    // MARK: - Fuzzy title, above and below the 0.5 floor

    [Fact]
    public void FuzzyTitleAboveFloor_IsSurfacedAsACandidateWithoutCollapsing()
    {
        // Reference tokens (after cue-strip) = {viet, bao, cao}; title tokens = {viet, bao, cao,
        // quy} -> Jaccard = 3/4 = 0.75: above the 0.5 floor but below the 0.8 high-confidence bar.
        var task = MakeTask(id: FixedGuid(1), title: "Viết báo cáo quý");
        var openTasks = new[] { task };

        var result = VoiceDone.Classify("viết báo cáo xong rồi", openTasks);

        var complete = Assert.IsType<CompleteIntent>(result);
        var candidate = Assert.Single(complete.Candidates);
        Assert.Equal(0.75, candidate.Score);
    }

    [Fact]
    public void FuzzyTitleBelowFloor_IsExcludedEntirely()
    {
        // Reference tokens = {viet, bao, cao}; title tokens = {viet, email} -> Jaccard = 1/4 =
        // 0.25: a genuine partial overlap, but below the 0.5 candidate floor.
        var task = MakeTask(id: FixedGuid(1), title: "Viết email");
        var openTasks = new[] { task };

        var result = VoiceDone.Classify("viết báo cáo xong rồi", openTasks);

        var complete = Assert.IsType<CompleteIntent>(result);
        Assert.Empty(complete.Candidates);
    }

    // MARK: - Ambiguous: two candidates tied at high confidence

    [Fact]
    public void TwoTiedHighConfidenceCandidates_DoesNotAutoResolve()
    {
        // Both tasks' titles are exactly the reference tokens -> both score 1.0. Passed in
        // taskId-descending order to also prove the output re-sorts deterministically (score
        // desc, then taskId ascending) rather than preserving input order.
        var lower = MakeTask(id: FixedGuid(1), title: "Báo cáo");
        var higher = MakeTask(id: FixedGuid(2), title: "báo cáo");
        var openTasks = new[] { higher, lower };

        var result = VoiceDone.Classify("báo cáo xong rồi", openTasks);

        var complete = Assert.IsType<CompleteIntent>(result);
        Assert.Equal(2, complete.Candidates.Count);
        Assert.All(complete.Candidates, c => Assert.Equal(1.0, c.Score));
        // Disambiguation list, not a guess: caller sees both, in deterministic taskId-ascending order.
        Assert.Equal(lower.Id, complete.Candidates[0].TaskId);
        Assert.Equal(higher.Id, complete.Candidates[1].TaskId);
    }

    // MARK: - External-condition clearing

    [Fact]
    public void ExternalCue_MatchesAgainstExternalDescriptionsNotTitle()
    {
        // "ký" is itself a cue token and gets stripped from the reference set, so the matching
        // description is deliberately worded without repeating the cue verb.
        var task = MakeTask(
            id: FixedGuid(1),
            title: "Theo dõi hợp đồng",
            externalDescriptions: ["khách hàng"]);
        var openTasks = new[] { task };

        var result = VoiceDone.Classify("khách hàng đã ký rồi", openTasks);

        var clearExternal = Assert.IsType<ClearExternalIntent>(result);
        var candidate = Assert.Single(clearExternal.Candidates);
        Assert.Equal(task.Id, candidate.TaskId);
        Assert.Equal(1.0, candidate.Score);
    }

    [Fact]
    public void CompoundUtterance_WithBothCompletionAndExternalCue_PrefersExternal()
    {
        // "xong" (bare completion cue) alongside "gửi rồi" (external cue) -> external wins per the
        // Swift comment: a bare "xong" is ambiguous, the external verb is the more specific signal.
        var task = MakeTask(
            id: FixedGuid(1),
            title: "Theo dõi hợp đồng",
            externalDescriptions: ["khách hàng"]);
        var openTasks = new[] { task };

        var result = VoiceDone.Classify("khách hàng gửi rồi xong", openTasks);

        Assert.IsType<ClearExternalIntent>(result);
    }

    // MARK: - Cue phrase present, no candidate

    [Fact]
    public void BareCuePhrase_WithNoReferenceTokens_YieldsEmptyCandidatesNotNotACompletion()
    {
        // The whole utterance IS the cue phrase -> referenceTokens is empty -> the contract's
        // "done-phrase present but nothing matched" case: empty candidates, NOT NotACompletion.
        var openTasks = new[] { MakeTask(id: FixedGuid(1), title: "Viết báo cáo") };

        var result = VoiceDone.Classify("xong", openTasks);

        var complete = Assert.IsType<CompleteIntent>(result);
        Assert.Empty(complete.Candidates);
    }

    [Fact]
    public void EmptyOpenTasks_YieldsEmptyCandidatesNotNotACompletion()
    {
        var result = VoiceDone.Classify("báo cáo xong rồi", []);

        var complete = Assert.IsType<CompleteIntent>(result);
        Assert.Empty(complete.Candidates);
    }

    // MARK: - Abuse caps

    [Fact]
    public void TranscriptBeyondMaxWorkingLength_IsTruncatedBeforeCueDetection()
    {
        // "test " repeated 800 times is exactly 4000 chars (the cap), landing on a token boundary
        // so the truncation is clean; the cue phrase appended after that point is dropped entirely
        // by the bound, so it must never be detected.
        var filler = string.Concat(Enumerable.Repeat("test ", 900)); // 4500 chars
        var transcript = filler + "xong";
        Assert.True(transcript.Length > 4_000);

        var result = VoiceDone.Classify(transcript, [MakeTask(id: FixedGuid(1), title: "test")]);

        Assert.IsType<NotACompletionIntent>(result);
    }

    [Fact]
    public void TaskWithMoreThanTwentyExternalDescriptions_OnlyFirstTwentyAreScored()
    {
        var descriptions = new List<string>();
        descriptions.AddRange(Enumerable.Repeat("không liên quan", 20));
        // The 21st description would score 1.0 against the reference tokens if it were
        // considered; it must not be, because it falls beyond the 20-item cap.
        descriptions.Add("khách hàng");

        var task = MakeTask(id: FixedGuid(1), title: "Theo dõi hợp đồng", externalDescriptions: descriptions);
        var openTasks = new[] { task };

        var result = VoiceDone.Classify("khách hàng đã ký rồi", openTasks);

        var clearExternal = Assert.IsType<ClearExternalIntent>(result);
        Assert.Empty(clearExternal.Candidates);
    }

    // MARK: - Vietnamese diacritics

    [Fact]
    public void TranscriptWithDiacritics_MatchesTitleWithDiacritics()
    {
        var task = MakeTask(id: FixedGuid(1), title: "Báo cáo");
        var result = VoiceDone.Classify("báo cáo xong rồi", [task]);

        var complete = Assert.IsType<CompleteIntent>(result);
        var candidate = Assert.Single(complete.Candidates);
        Assert.Equal(1.0, candidate.Score);
    }

    [Fact]
    public void TranscriptWithoutDiacritics_StillMatchesTitleWithDiacritics()
    {
        // Simulates WhisperKit/Groq dropping tone marks: the ASR transcript has no diacritics at
        // all, but the task title (typed by the user) does. The fold must bridge that gap.
        var task = MakeTask(id: FixedGuid(1), title: "Báo cáo");
        var result = VoiceDone.Classify("bao cao xong roi", [task]);

        var complete = Assert.IsType<CompleteIntent>(result);
        var candidate = Assert.Single(complete.Candidates);
        Assert.Equal(1.0, candidate.Score);
    }

    [Fact]
    public void DStroke_FoldsToPlainD()
    {
        // "đ"/"Đ" has no Unicode diacritic decomposition (an atomic letter-with-stroke), so it
        // needs the explicit post-fold replace this test exercises directly.
        var task = MakeTask(id: FixedGuid(1), title: "Đọc sách");
        var result = VoiceDone.Classify("doc sach xong", [task]);

        var complete = Assert.IsType<CompleteIntent>(result);
        var candidate = Assert.Single(complete.Candidates);
        Assert.Equal(1.0, candidate.Score);
    }

    // MARK: - English cue phrases

    [Fact]
    public void EnglishCompletionCue_IsDetected()
    {
        var task = MakeTask(id: FixedGuid(1), title: "Write the quarterly report");
        var result = VoiceDone.Classify("write the quarterly report done", [task]);

        var complete = Assert.IsType<CompleteIntent>(result);
        Assert.Single(complete.Candidates);
    }

    [Fact]
    public void EnglishExternalCue_IsDetected()
    {
        var task = MakeTask(
            id: FixedGuid(1),
            title: "Follow up on the contract",
            externalDescriptions: ["the client"]);
        var result = VoiceDone.Classify("the client signed", [task]);

        Assert.IsType<ClearExternalIntent>(result);
    }
}
