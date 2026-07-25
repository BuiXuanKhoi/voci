using System.Text;
using Volar.Core;
using Volar.Domain;
using Xunit;

namespace Volar.Orchestrator.Tests;

public class AppLinkHandlerTests
{
    private static (AppLinkHandler handler, FakeOrchestratorTaskStore store, DelegationTracker delegation) Build()
    {
        var store = new FakeOrchestratorTaskStore();
        var delegation = new DelegationTracker(store);
        var handler = new AppLinkHandler(store, delegation) { Logger = _ => { } };
        return (handler, store, delegation);
    }

    // MARK: - Malformed / non-matching input

    [Fact]
    public void Handle_UnparsableString_IsIgnored()
    {
        var (handler, _, _) = Build();
        handler.Handle("not a url at all");
        Assert.Empty(handler.PendingDisambiguation);
    }

    [Fact]
    public void Handle_WrongScheme_IsIgnored()
    {
        var (handler, store, _) = Build();
        var task = Fixtures.MakeTask(conditions: new Condition[] { Fixtures.WaitingOnAi("build") });
        store.AddTask(task);

        handler.Handle("https://ai-done?cwd=/tmp");

        Assert.Empty(handler.PendingDisambiguation);
        Assert.True(DelegationTracker.IsWaitingOnAI(store.Get(task.Id)!.Value.Conditions[0]));
    }

    [Fact]
    public void Handle_SchemeIsCaseInsensitive()
    {
        var (handler, store, _) = Build();
        var task = Fixtures.MakeTask(conditions: new Condition[] { Fixtures.WaitingOnAi("build") });
        store.AddTask(task);

        handler.Handle("VOLAR://ai-done");

        Assert.False(DelegationTracker.IsWaitingOnAI(store.Get(task.Id)!.Value.Conditions[0]));
    }

    [Fact]
    public void Handle_HostlessUrl_IsIgnored()
    {
        var (handler, _, _) = Build();
        handler.Handle("volar:///no-host-here");
        Assert.Empty(handler.PendingDisambiguation);
    }

    [Fact]
    public void Handle_UnknownHost_IsIgnored()
    {
        var (handler, store, _) = Build();
        var task = Fixtures.MakeTask(conditions: new Condition[] { Fixtures.WaitingOnAi("build") });
        store.AddTask(task);

        handler.Handle("volar://not-a-real-action");

        Assert.True(DelegationTracker.IsWaitingOnAI(store.Get(task.Id)!.Value.Conditions[0]));
        Assert.Empty(handler.PendingDisambiguation);
    }

    // MARK: - ai-done: no waiting tasks

    [Fact]
    public void AiDone_NoWaitingTasks_IsIgnored()
    {
        var (handler, _, _) = Build();
        handler.Handle("volar://ai-done");
        Assert.Empty(handler.PendingDisambiguation);
    }

    // MARK: - ai-done: exactly one waiting -> unambiguous resolve

    [Fact]
    public void AiDone_ExactlyOneWaiting_ResolvesRegardlessOfCwd()
    {
        var (handler, store, _) = Build();
        var task = Fixtures.MakeTask(conditions: new Condition[] { Fixtures.WaitingOnAi("build") });
        store.AddTask(task);

        handler.Handle("volar://ai-done?cwd=/somewhere/unrelated");

        Assert.False(DelegationTracker.IsWaitingOnAI(store.Get(task.Id)!.Value.Conditions[0]));
        Assert.Empty(handler.PendingDisambiguation);
    }

    [Fact]
    public void AiDone_DoneAndArchivedTasks_AreExcludedFromWaitingSet()
    {
        var (handler, store, _) = Build();
        var waiting = Fixtures.MakeTask(id: Fixtures.FixedGuid(1), conditions: new Condition[] { Fixtures.WaitingOnAi("real") });
        var done = Fixtures.MakeTask(id: Fixtures.FixedGuid(2), status: TaskState.Done, conditions: new Condition[] { Fixtures.WaitingOnAi("stale") });
        store.AddTask(waiting);
        store.AddTask(done);

        handler.Handle("volar://ai-done");

        Assert.False(DelegationTracker.IsWaitingOnAI(store.Get(waiting.Id)!.Value.Conditions[0]));
        // The done task's condition is untouched (still "waiting"-shaped) since it was never in the candidate set.
        Assert.True(DelegationTracker.IsWaitingOnAI(store.Get(done.Id)!.Value.Conditions[0]));
    }

    // MARK: - ai-done: cwd prefix matching ladder

    [Fact]
    public void AiDone_CwdPrefixMatch_UniqueMatch_Resolves()
    {
        var (handler, store, delegation) = Build();
        var t1 = Fixtures.MakeTask(id: Fixtures.FixedGuid(1), conditions: new Condition[] { Fixtures.WaitingOnAi("a") });
        var t2 = Fixtures.MakeTask(id: Fixtures.FixedGuid(2), conditions: new Condition[] { Fixtures.WaitingOnAi("b") });
        store.AddTask(t1);
        store.AddTask(t2);
        delegation.Delegate(t1.Id, "a", Fixtures.ReferenceNow, "/Users/k/proj-a");
        delegation.Delegate(t2.Id, "b", Fixtures.ReferenceNow, "/Users/k/proj-b");

        handler.Handle("volar://ai-done?cwd=" + Uri.EscapeDataString("/Users/k/proj-a/sub"));

        Assert.False(DelegationTracker.IsWaitingOnAI(store.Get(t1.Id)!.Value.Conditions[0]));
        Assert.True(DelegationTracker.IsWaitingOnAI(store.Get(t2.Id)!.Value.Conditions[0]));
        Assert.Empty(handler.PendingDisambiguation);
    }

    [Fact]
    public void AiDone_CwdPrefixMatch_IsPathBoundaryAware_NotPlainPrefix()
    {
        // "/Users/k/proj" must not match cwd "/Users/k/project2" (plain hasPrefix would incorrectly
        // match here) — the hint must be followed by an exact end or a path separator.
        var (handler, store, delegation) = Build();
        var t1 = Fixtures.MakeTask(id: Fixtures.FixedGuid(1), conditions: new Condition[] { Fixtures.WaitingOnAi("a") });
        var t2 = Fixtures.MakeTask(id: Fixtures.FixedGuid(2), conditions: new Condition[] { Fixtures.WaitingOnAi("b") });
        store.AddTask(t1);
        store.AddTask(t2);
        delegation.Delegate(t1.Id, "a", Fixtures.ReferenceNow, "/Users/k/proj");
        delegation.Delegate(t2.Id, "b", Fixtures.ReferenceNow, "/Users/k/other");

        handler.Handle("volar://ai-done?cwd=" + Uri.EscapeDataString("/Users/k/project2"));

        // Neither hint boundary-matches -> falls through to the ambient disambiguation card.
        Assert.True(DelegationTracker.IsWaitingOnAI(store.Get(t1.Id)!.Value.Conditions[0]));
        Assert.True(DelegationTracker.IsWaitingOnAI(store.Get(t2.Id)!.Value.Conditions[0]));
        Assert.Equal(2, handler.PendingDisambiguation.Count);
    }

    [Fact]
    public void AiDone_CwdPrefixMatch_MultipleMatches_NarrowsDisambiguationToMatches()
    {
        var (handler, store, delegation) = Build();
        var t1 = Fixtures.MakeTask(id: Fixtures.FixedGuid(1), conditions: new Condition[] { Fixtures.WaitingOnAi("a") });
        var t2 = Fixtures.MakeTask(id: Fixtures.FixedGuid(2), conditions: new Condition[] { Fixtures.WaitingOnAi("b") });
        var t3 = Fixtures.MakeTask(id: Fixtures.FixedGuid(3), conditions: new Condition[] { Fixtures.WaitingOnAi("c") });
        store.AddTask(t1);
        store.AddTask(t2);
        store.AddTask(t3);
        delegation.Delegate(t1.Id, "a", Fixtures.ReferenceNow, "/proj");
        delegation.Delegate(t2.Id, "b", Fixtures.ReferenceNow, "/proj");
        delegation.Delegate(t3.Id, "c", Fixtures.ReferenceNow, "/other");

        handler.Handle("volar://ai-done?cwd=" + Uri.EscapeDataString("/proj/sub"));

        Assert.Equal(2, handler.PendingDisambiguation.Count);
        Assert.Contains(t1.Id, handler.PendingDisambiguation);
        Assert.Contains(t2.Id, handler.PendingDisambiguation);
    }

    [Fact]
    public void AiDone_NoCwdParam_MultipleWaiting_AmbientDisambiguationListsAll()
    {
        var (handler, store, _) = Build();
        var t1 = Fixtures.MakeTask(id: Fixtures.FixedGuid(1), conditions: new Condition[] { Fixtures.WaitingOnAi("a") });
        var t2 = Fixtures.MakeTask(id: Fixtures.FixedGuid(2), conditions: new Condition[] { Fixtures.WaitingOnAi("b") });
        store.AddTask(t1);
        store.AddTask(t2);

        handler.Handle("volar://ai-done");

        Assert.Equal(2, handler.PendingDisambiguation.Count);
    }

    [Fact]
    public void AiDone_Base64EncodedCwd_IsDecodedForMatching()
    {
        var (handler, store, delegation) = Build();
        var t1 = Fixtures.MakeTask(id: Fixtures.FixedGuid(1), conditions: new Condition[] { Fixtures.WaitingOnAi("a") });
        var t2 = Fixtures.MakeTask(id: Fixtures.FixedGuid(2), conditions: new Condition[] { Fixtures.WaitingOnAi("b") });
        store.AddTask(t1);
        store.AddTask(t2);
        delegation.Delegate(t1.Id, "a", Fixtures.ReferenceNow, "/Users/k/proj-a");
        delegation.Delegate(t2.Id, "b", Fixtures.ReferenceNow, "/Users/k/proj-b");

        var encodedCwd = Convert.ToBase64String(Encoding.UTF8.GetBytes("/Users/k/proj-a"));
        handler.Handle("volar://ai-done?cwd=" + Uri.EscapeDataString(encodedCwd));

        Assert.False(DelegationTracker.IsWaitingOnAI(store.Get(t1.Id)!.Value.Conditions[0]));
        Assert.True(DelegationTracker.IsWaitingOnAI(store.Get(t2.Id)!.Value.Conditions[0]));
    }

    [Fact]
    public void AiDone_MalformedBase64Cwd_FallsBackToRawValue_NeverCrashes()
    {
        var (handler, store, delegation) = Build();
        var t1 = Fixtures.MakeTask(id: Fixtures.FixedGuid(1), conditions: new Condition[] { Fixtures.WaitingOnAi("a") });
        var t2 = Fixtures.MakeTask(id: Fixtures.FixedGuid(2), conditions: new Condition[] { Fixtures.WaitingOnAi("b") });
        store.AddTask(t1);
        store.AddTask(t2);
        delegation.Delegate(t1.Id, "a", Fixtures.ReferenceNow, "/proj");

        // "!!!not-base64!!!" fails to decode -> falls back to the raw string, which matches nothing
        // -> safe fallthrough to the ambient disambiguation card, never a crash or a wrong resolve.
        var ex = Record.Exception(() => handler.Handle("volar://ai-done?cwd=" + Uri.EscapeDataString("!!!not-base64!!!")));

        Assert.Null(ex);
        Assert.Equal(2, handler.PendingDisambiguation.Count);
    }

    // MARK: - ai-done: test/probe receipt-only

    [Theory]
    [InlineData("test")]
    [InlineData("probe")]
    public void AiDone_TestOrProbeFlag_IsReceiptOnly_NeverResolves(string flagName)
    {
        var (handler, store, _) = Build();
        var task = Fixtures.MakeTask(conditions: new Condition[] { Fixtures.WaitingOnAi("build") });
        store.AddTask(task);

        handler.Handle($"volar://ai-done?{flagName}=1");

        Assert.True(DelegationTracker.IsWaitingOnAI(store.Get(task.Id)!.Value.Conditions[0]));
        Assert.Empty(handler.PendingDisambiguation);
    }

    // MARK: - Disambiguation resolution

    [Fact]
    public void ResolveDisambiguation_ValidCandidate_MarksNeedsReviewAndClearsPending()
    {
        var (handler, store, _) = Build();
        var t1 = Fixtures.MakeTask(id: Fixtures.FixedGuid(1), conditions: new Condition[] { Fixtures.WaitingOnAi("a") });
        var t2 = Fixtures.MakeTask(id: Fixtures.FixedGuid(2), conditions: new Condition[] { Fixtures.WaitingOnAi("b") });
        store.AddTask(t1);
        store.AddTask(t2);
        handler.Handle("volar://ai-done");
        Assert.Equal(2, handler.PendingDisambiguation.Count);

        handler.ResolveDisambiguation(t1.Id);

        Assert.False(DelegationTracker.IsWaitingOnAI(store.Get(t1.Id)!.Value.Conditions[0]));
        Assert.True(DelegationTracker.IsWaitingOnAI(store.Get(t2.Id)!.Value.Conditions[0]));
        Assert.Empty(handler.PendingDisambiguation);
    }

    [Fact]
    public void ResolveDisambiguation_UnknownCandidate_IsNoOp()
    {
        var (handler, store, _) = Build();
        var t1 = Fixtures.MakeTask(id: Fixtures.FixedGuid(1), conditions: new Condition[] { Fixtures.WaitingOnAi("a") });
        var t2 = Fixtures.MakeTask(id: Fixtures.FixedGuid(2), conditions: new Condition[] { Fixtures.WaitingOnAi("b") });
        store.AddTask(t1);
        store.AddTask(t2);
        handler.Handle("volar://ai-done");
        var before = handler.PendingDisambiguation;

        handler.ResolveDisambiguation(Fixtures.FixedGuid(99));

        Assert.Equal(before, handler.PendingDisambiguation);
        Assert.True(DelegationTracker.IsWaitingOnAI(store.Get(t1.Id)!.Value.Conditions[0]));
        Assert.True(DelegationTracker.IsWaitingOnAI(store.Get(t2.Id)!.Value.Conditions[0]));
    }

    [Fact]
    public void DismissDisambiguation_ClearsPendingWithoutTouchingAnyTask()
    {
        var (handler, store, _) = Build();
        var t1 = Fixtures.MakeTask(id: Fixtures.FixedGuid(1), conditions: new Condition[] { Fixtures.WaitingOnAi("a") });
        var t2 = Fixtures.MakeTask(id: Fixtures.FixedGuid(2), conditions: new Condition[] { Fixtures.WaitingOnAi("b") });
        store.AddTask(t1);
        store.AddTask(t2);
        handler.Handle("volar://ai-done");

        handler.DismissDisambiguation();

        Assert.Empty(handler.PendingDisambiguation);
        Assert.True(DelegationTracker.IsWaitingOnAI(store.Get(t1.Id)!.Value.Conditions[0]));
        Assert.True(DelegationTracker.IsWaitingOnAI(store.Get(t2.Id)!.Value.Conditions[0]));
    }

    // MARK: - capture

    [Fact]
    public void Capture_MissingTextParam_DoesNotInvokeOnCapture()
    {
        var (handler, _, _) = Build();
        var invoked = false;
        handler.OnCapture = (_, _) => invoked = true;

        handler.Handle("volar://capture");

        Assert.False(invoked);
    }

    [Fact]
    public void Capture_EmptyTextAfterTrim_DoesNotInvokeOnCapture()
    {
        var (handler, _, _) = Build();
        var invoked = false;
        handler.OnCapture = (_, _) => invoked = true;

        handler.Handle("volar://capture?text=" + Uri.EscapeDataString("   \n\t  "));

        Assert.False(invoked);
    }

    [Fact]
    public void Capture_NoHookWired_IsDroppedSafely()
    {
        var (handler, _, _) = Build();
        var ex = Record.Exception(() => handler.Handle("volar://capture?text=hello"));
        Assert.Null(ex);
    }

    [Fact]
    public void Capture_Valid_InvokesOnCaptureWithDecodedTextAndSource()
    {
        var (handler, _, _) = Build();
        string? capturedText = null;
        string? capturedSource = null;
        handler.OnCapture = (text, source) => { capturedText = text; capturedSource = source; };

        handler.Handle("volar://capture?text=" + Uri.EscapeDataString("buy milk & eggs") + "&source=" + Uri.EscapeDataString("share-sheet"));

        Assert.Equal("buy milk & eggs", capturedText);
        Assert.Equal("share-sheet", capturedSource);
    }

    [Fact]
    public void Capture_NoSourceParam_PassesNullSource()
    {
        var (handler, _, _) = Build();
        string? capturedSource = "not-null-yet";
        handler.OnCapture = (_, source) => capturedSource = source;

        handler.Handle("volar://capture?text=hello");

        Assert.Null(capturedSource);
    }

    [Fact]
    public void Capture_TextLongerThan2000Chars_IsTruncated()
    {
        var (handler, _, _) = Build();
        string? capturedText = null;
        handler.OnCapture = (text, _) => capturedText = text;
        var longText = new string('x', 3000);

        handler.Handle("volar://capture?text=" + Uri.EscapeDataString(longText));

        Assert.NotNull(capturedText);
        Assert.Equal(2000, capturedText!.Length);
    }

    [Fact]
    public void Capture_SourceLongerThan200Chars_IsTruncated()
    {
        var (handler, _, _) = Build();
        string? capturedSource = null;
        handler.OnCapture = (_, source) => capturedSource = source;
        var longSource = new string('y', 500);

        handler.Handle("volar://capture?text=hi&source=" + Uri.EscapeDataString(longSource));

        Assert.NotNull(capturedSource);
        Assert.Equal(200, capturedSource!.Length);
    }
}
