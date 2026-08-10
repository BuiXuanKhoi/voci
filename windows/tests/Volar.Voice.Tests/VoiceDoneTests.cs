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
    public void UtteranceFullyContainedInTitle_CollapsesToOneTap()
    {
        // Renamed/updated from FuzzyTitleAboveFloor_IsSurfacedAsACandidateWithoutCollapsing, which
        // asserted the OLD Jaccard score (3/4 = 0.75, "surfaced but not collapsed"). Under
        // containment scoring that assertion is now simply wrong, not just superseded: every
        // reference token {viet, bao, cao} is fully contained in the title, so coverage is 1.0
        // regardless of the title's extra word "quý" -- containment does not penalize a title for
        // content the user didn't say (that's the whole point of the switch away from Jaccard). With
        // a single open task and 3 matched tokens (so the one-tap distinctiveness guard trivially
        // passes), this is an unambiguous one-tap-eligible match: the user still taps to confirm,
        // "one-tap" only means the candidate list collapses to this single best guess instead of
        // making the user pick among several.
        var task = MakeTask(id: FixedGuid(1), title: "Viết báo cáo quý");
        var openTasks = new[] { task };

        var result = VoiceDone.Classify("viết báo cáo xong rồi", openTasks);

        var complete = Assert.IsType<CompleteIntent>(result);
        var candidate = Assert.Single(complete.Candidates);
        Assert.Equal(task.Id, candidate.TaskId);
        Assert.Equal(1.0, candidate.Score);
    }

    [Fact]
    public void PartialTitleContainment_FallsInTheMiddleTier_SurfacedWithoutCollapsing()
    {
        // Replacement coverage for the 0.5-0.8 "surfaced as a candidate, not collapsed" middle tier
        // that UtteranceFullyContainedInTitle_CollapsesToOneTap (above) no longer exercises.
        // Reference tokens after cue-strip: {bao, cao, sep}. "sep" ("sếp") does NOT appear in
        // taskA's title, but DOES appear in taskB's ("Gửi email cho sếp") -- so its
        // documentFrequency is 1, not 0, and it is NOT dropped as filler the way a truly
        // never-seen word would be (contrast ZeroDocumentFrequencyFillerToken_DoesNotLowerTheScore).
        // With N = 2 open tasks, every one of {bao, cao, sep} has df == 1, so all three tokens carry
        // IDENTICAL idf (= ln(1 + 2/(1+1)) = ln 2):
        //   sumIdfQuery = 3 * ln(2)
        //   taskA matches {bao, cao} (2 of 3 query tokens)  -> coverage = 2*ln(2) / 3*ln(2) = 2/3
        //   taskB matches only {sep} (1 of 3 query tokens)  -> coverage = 1/3, below the 0.5 floor
        // -> taskA alone surfaces, at 2/3 ~= 0.667: squarely inside [0.5, 0.8), not collapsed.
        var taskA = MakeTask(id: FixedGuid(1), title: "Viết báo cáo quý");
        var taskB = MakeTask(id: FixedGuid(2), title: "Gửi email cho sếp");
        var openTasks = new[] { taskA, taskB };

        var result = VoiceDone.Classify("báo cáo sếp xong rồi", openTasks);

        var complete = Assert.IsType<CompleteIntent>(result);
        var candidate = Assert.Single(complete.Candidates);
        Assert.Equal(taskA.Id, candidate.TaskId);
        Assert.Equal(2.0 / 3.0, candidate.Score, precision: 10);
    }

    // NOT updated, deliberately left as-is -- see the session report for why this now fails and is
    // being escalated rather than silently fixed.
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

    // MARK: - IDF containment scoring (replaces Jaccard)
    //
    // Coverage = Σ idf(matched) / Σ idf(query), query pre-filtered to drop any token with
    // documentFrequency == 0 across the open tasks' titles. See VoiceDone.ScoreCandidate /
    // BuildQueryContext for the full formula and its two safety gates.

    [Fact]
    public void BriefUtterance_StillClearsFloorAgainstALongerTitle()
    {
        // The motivating bug this scoring change fixes: a vắn tắt utterance naming only PART of a
        // longer title used to score too low under Jaccard (2/11 ~= 0.18, well under the 0.5
        // floor) because Jaccard penalizes the title's extra words. Containment does not: the
        // reference tokens after cue-strip are {vu, hop, dong}; "vu" has documentFrequency == 0 (it
        // never appears in this task's title) and is dropped, leaving {hop, dong} — both present in
        // the title — for full coverage.
        var task = MakeTask(
            id: FixedGuid(1),
            title: "gọi cho anh Hùng về hợp đồng thuê văn phòng");

        var result = VoiceDone.Classify("xong vụ hợp đồng rồi", [task]);

        var complete = Assert.IsType<CompleteIntent>(result);
        var candidate = Assert.Single(complete.Candidates);
        Assert.Equal(task.Id, candidate.TaskId);
        Assert.True(candidate.Score >= 0.5, $"expected score >= 0.5, got {candidate.Score}");
    }

    [Fact]
    public void ZeroDocumentFrequencyFillerToken_DoesNotLowerTheScore()
    {
        // "lala" appears in no open task's title, so it must be dropped from the query before
        // scoring rather than diluting the coverage denominator — the same utterance scores
        // identically with or without the filler word prepended.
        var task = MakeTask(id: FixedGuid(1), title: "Gọi điện cho khách hàng");

        var withoutFiller = VoiceDone.Classify("gọi điện khách hàng xong", [task]);
        var withFiller = VoiceDone.Classify("lala gọi điện khách hàng xong", [task]);

        var scoreWithoutFiller = Assert.Single(Assert.IsType<CompleteIntent>(withoutFiller).Candidates).Score;
        var scoreWithFiller = Assert.Single(Assert.IsType<CompleteIntent>(withFiller).Candidates).Score;
        Assert.Equal(scoreWithoutFiller, scoreWithFiller);
    }

    [Fact]
    public void CommonTokenSharedAcrossManyOpenTasks_SurfacesAllAsCandidates_NeverOneTap()
    {
        // Updated: this used to assert Empty, back when an absolute evidence floor
        // (MinMatchedWeight) zeroed out a match resting entirely on one common token. That gate was
        // removed (it was deleting legitimate candidates, not just blocking false one-taps -- see
        // the session report) in favor of "wide recall at the candidate tier, narrow only at
        // one-tap": "gọi" appears in all 3 open tasks' titles, so it still carries very little idf
        // weight and the one-tap distinctiveness guard (DistinctiveIdf) still blocks it from
        // collapsing to a single high-confidence pick -- but all 3 tasks now correctly surface as
        // candidates for the user to choose from, instead of the system claiming no match at all.
        var openTasks = new[]
        {
            MakeTask(id: FixedGuid(1), title: "Gọi cho khách A"),
            MakeTask(id: FixedGuid(2), title: "Gọi cho khách B"),
            MakeTask(id: FixedGuid(3), title: "Gọi cho khách C"),
        };

        var result = VoiceDone.Classify("gọi xong rồi", openTasks);

        var complete = Assert.IsType<CompleteIntent>(result);
        Assert.Equal(3, complete.Candidates.Count);
        Assert.All(complete.Candidates, c =>
        {
            Assert.True(c.Score >= 0.5, $"expected c.Score >= 0.5 (candidate floor), got {c.Score}");
            Assert.True(c.Score < 0.8, $"expected c.Score < 0.8 (one-tap must stay blocked), got {c.Score}");
        });
    }

    [Fact]
    public void SingleDistinctiveToken_CanStillReachOneTap()
    {
        // "Thắng" (a proper name) appears in exactly one of three open tasks' titles (df == 1) — a
        // near-unique token is allowed to carry a one-token match all the way to the high-confidence
        // tier, unlike the common-token case above. "ừ" is a filler interjection absent from every
        // title (documentFrequency == 0) and must be dropped without affecting the outcome.
        var target = MakeTask(id: FixedGuid(3), title: "Nhắn tin cho Thắng");
        var openTasks = new[]
        {
            MakeTask(id: FixedGuid(1), title: "Gọi khách hàng A"),
            MakeTask(id: FixedGuid(2), title: "Gọi khách hàng B"),
            target,
        };

        var result = VoiceDone.Classify("ừ thắng xong rồi", openTasks);

        var complete = Assert.IsType<CompleteIntent>(result);
        var candidate = Assert.Single(complete.Candidates);
        Assert.Equal(target.Id, candidate.TaskId);
        Assert.True(candidate.Score >= 0.8, $"expected a high-confidence one-tap score, got {candidate.Score}");
    }

    [Fact]
    public void SingleCommonToken_NeverReachesOneTap_ClampedBelowHighConfidence()
    {
        // "gọi" is shared by 2 of 5 open tasks: common enough to clear the absolute evidence floor
        // (unlike the 3-of-3 case above) but not distinctive enough to trust as a lone one-tap
        // signal, so both candidates must be clamped strictly below the 0.8 high-confidence bar
        // even though their raw (uncapped) coverage would be 1.0.
        var taskA = MakeTask(id: FixedGuid(1), title: "Gọi cho sếp");
        var taskB = MakeTask(id: FixedGuid(2), title: "Gọi cho đối tác");
        var openTasks = new[]
        {
            taskA,
            taskB,
            MakeTask(id: FixedGuid(3), title: "Đặt lịch họp"),
            MakeTask(id: FixedGuid(4), title: "Mua văn phòng phẩm"),
            MakeTask(id: FixedGuid(5), title: "Chuẩn bị tài liệu"),
        };

        var result = VoiceDone.Classify("gọi xong rồi", openTasks);

        var complete = Assert.IsType<CompleteIntent>(result);
        Assert.Equal(2, complete.Candidates.Count);
        Assert.All(complete.Candidates, c =>
        {
            Assert.True(c.Score >= 0.5, $"expected c.Score >= 0.5 (candidate floor), got {c.Score}");
            Assert.True(c.Score < 0.8, $"expected c.Score < 0.8 (one-tap must be blocked), got {c.Score}");
        });
    }

    [Fact]
    public void TiedCoverage_TighterTitleWithLessUnmatchedFillerRanksFirst()
    {
        // Both titles contain every query token, so both reach coverage 1.0 (containment does not
        // penalize a title's extra words) — a genuine tie the old Jaccard formula could not have
        // produced. The tie-break must prefer the SHORTER/tighter title (less of ITS OWN content is
        // unmatched filler), not just fall back to taskId order: the short task is deliberately
        // given the numerically LARGER id, so a naive taskId-ascending tiebreak would rank it
        // second — the match-ratio tiebreak must override that.
        var shortTask = MakeTask(id: FixedGuid(2), title: "Gọi khách");
        var longTask = MakeTask(id: FixedGuid(1), title: "Gọi khách hàng thân thiết");
        var openTasks = new[] { longTask, shortTask };

        var result = VoiceDone.Classify("gọi khách xong rồi", openTasks);

        var complete = Assert.IsType<CompleteIntent>(result);
        Assert.Equal(2, complete.Candidates.Count);
        Assert.All(complete.Candidates, c => Assert.Equal(1.0, c.Score));
        Assert.Equal(shortTask.Id, complete.Candidates[0].TaskId);
        Assert.Equal(longTask.Id, complete.Candidates[1].TaskId);
    }

    [Fact]
    public void CompletelyUnrelatedUtterance_YieldsNoCandidates()
    {
        var openTasks = new[]
        {
            MakeTask(id: FixedGuid(1), title: "Gọi khách hàng"),
            MakeTask(id: FixedGuid(2), title: "Đặt lịch họp"),
        };

        var result = VoiceDone.Classify("mua vé máy bay xong rồi", openTasks);

        var complete = Assert.IsType<CompleteIntent>(result);
        Assert.Empty(complete.Candidates);
    }

    // MARK: - Exact-phrase-containment shortcut (runs before the IDF gates above)

    [Fact]
    public void VerbatimPhraseAgainstTitle_ReachesOneTapDespiteAFillerWord()
    {
        // "cái" is a filler word (documentFrequency == 0, dropped) but the REMAINING reference
        // phrase "hợp đồng thuê văn phòng" appears verbatim, contiguously, inside the task's title
        // — a literal phrase hit, which is floored straight to the one-tap tier regardless of what
        // the token-level IDF coverage alone would have produced.
        var task = MakeTask(id: FixedGuid(1), title: "gọi cho anh Hùng về hợp đồng thuê văn phòng");

        var result = VoiceDone.Classify("xong cái hợp đồng thuê văn phòng rồi", [task]);

        var complete = Assert.IsType<CompleteIntent>(result);
        var candidate = Assert.Single(complete.Candidates);
        Assert.Equal(task.Id, candidate.TaskId);
        Assert.True(candidate.Score >= 0.8, $"expected a one-tap score, got {candidate.Score}");
    }

    [Fact]
    public void SingleTokenLiteralMatch_NeverTriggersThePhraseMatchShortcut()
    {
        // "gọi" alone is trivially a "verbatim phrase" match against both titles (a lone word
        // contains itself), but the phrase-match shortcut requires >= 2 surviving query tokens
        // specifically so a single common word can never ride it to a one-tap: if the shortcut fired
        // here, both candidates would incorrectly jump straight to exactly HighConfidenceThreshold
        // (0.8). With the shortcut correctly withheld, this falls through to the plain IDF path,
        // which (now that MinMatchedWeight is gone -- see
        // CommonTokenSharedAcrossManyOpenTasks_SurfacesAllAsCandidates_NeverOneTap) surfaces both
        // tasks as candidates but clamps them below the one-tap bar via the DistinctiveIdf guard
        // (matchedCount == 1, "gọi" is not distinctive at N == 2).
        var openTasks = new[]
        {
            MakeTask(id: FixedGuid(1), title: "Gọi điện"),
            MakeTask(id: FixedGuid(2), title: "Gọi email"),
        };

        var result = VoiceDone.Classify("gọi xong", openTasks);

        var complete = Assert.IsType<CompleteIntent>(result);
        Assert.Equal(2, complete.Candidates.Count);
        Assert.All(complete.Candidates, c =>
        {
            Assert.True(c.Score >= 0.5, $"expected c.Score >= 0.5, got {c.Score}");
            Assert.True(c.Score < 0.8, $"expected c.Score < 0.8 (phrase-match shortcut must stay blocked), got {c.Score}");
        });
    }

    [Fact]
    public void TiedScore_PhraseMatchCandidateRanksBeforeNonPhraseMatchCandidate()
    {
        // Both titles contain {hop, dong} so both reach IDF coverage 1.0 (a tie) — but only
        // "contiguousTask"'s title contains "hợp đồng" as an unbroken phrase; "nonContiguousTask"
        // has the same two tokens split apart by other words ("Hợp TÁC đồng HÀNH"), so it is not a
        // phrase match. The contiguous/phrase-match candidate must rank first despite having the
        // LOWER match-ratio tiebreak value (computed below) and a taskId that would sort it second —
        // proving phrase-match precedence, not an incidental tiebreak or id order, decides this.
        var contiguousTask = MakeTask(id: FixedGuid(2), title: "Theo dõi hợp đồng thuê");
        var nonContiguousTask = MakeTask(id: FixedGuid(1), title: "Hợp tác đồng hành");
        var openTasks = new[] { nonContiguousTask, contiguousTask };

        var result = VoiceDone.Classify("hợp đồng xong rồi", openTasks);

        var complete = Assert.IsType<CompleteIntent>(result);
        Assert.Equal(2, complete.Candidates.Count);
        Assert.All(complete.Candidates, c => Assert.Equal(1.0, c.Score));
        Assert.Equal(contiguousTask.Id, complete.Candidates[0].TaskId);
        Assert.Equal(nonContiguousTask.Id, complete.Candidates[1].TaskId);
    }

    [Fact]
    public void VerbatimPhraseMatch_WorksAfterDiacriticsAreStrippedFromTheUtterance()
    {
        // Simulates ASR dropping tone marks entirely: the spoken phrase has no diacritics at all,
        // but must still be recognized as a verbatim, contiguous phrase against the (diacritic-
        // bearing) title once both sides go through the same fold.
        var task = MakeTask(id: FixedGuid(1), title: "Ký hợp đồng thuê văn phòng mới");

        var result = VoiceDone.Classify("hop dong thue van phong xong", [task]);

        var complete = Assert.IsType<CompleteIntent>(result);
        var candidate = Assert.Single(complete.Candidates);
        Assert.Equal(task.Id, candidate.TaskId);
        Assert.True(candidate.Score >= 0.8, $"expected a one-tap score, got {candidate.Score}");
    }
}
