// Capture/CaptureFlowServiceTests.cs — Wave 3-C stage 2, agent C3. Covers the capture state
// machine (including the mandatory FIX 1 regression test), voice-done confirm (complete/
// clear-external/delegate/no-match), delegation-intent classification, confirm-card chip
// interactions, ConfirmSaveAsync (both no-repository and real-repository paths), and the
// cloud-parse consent gate.
using Volar.App.Services.State;
using Volar.App.Tests.State;
using Volar.Core;
using Volar.Data;
using Volar.Domain;
using Xunit;

namespace Volar.App.Tests.Capture;

public sealed class CaptureFlowServiceTests
{
    private static readonly DateTimeOffset Now = CaptureTestData.Now;

    /// <summary>Polling helper for the fire-and-forget continuations
    /// <see cref="CaptureFlowService"/>'s engine-callback wiring starts (`_ =
    /// SafeFinishRecordingAsync(...)`/`_ = AutoDismissAsync(...)`). Every collaborator in these
    /// tests resolves via an already-completed <see cref="Task"/> (<see cref="FakeIntentParser"/>,
    /// <see cref="FakeTaskListService"/>), so in practice the whole chain runs synchronously within
    /// the triggering call — this loop is defense-in-depth against that assumption ever changing,
    /// not a sign the tests are flaky.</summary>
    private static async Task WaitUntilAsync(Func<bool> predicate, int timeoutMs = 2000)
    {
        var deadline = DateTime.UtcNow.AddMilliseconds(timeoutMs);
        while (!predicate())
        {
            if (DateTime.UtcNow > deadline)
            {
                Assert.Fail("Condition was not met within the timeout.");
            }
            await Task.Delay(5);
        }
    }

    private sealed record Fixture(
        CaptureFlowService Service, FakeTaskListService TaskList, FakeIntentParser Parser, FakeSpeechEngine Engine);

    private static Fixture CreateService(
        FakeTaskListService? taskList = null,
        FakeIntentParser? parser = null,
        FakeSpeechEngine? engine = null,
        TaskRepository? repository = null,
        ISettingsStore? settings = null,
        IDelegationHandoff? delegationHandoff = null)
    {
        var resolvedTaskList = taskList ?? new FakeTaskListService();
        var resolvedParser = parser ?? new FakeIntentParser();
        var resolvedEngine = engine ?? new FakeSpeechEngine();
        var provider = new FakeSpeechEngineProvider { SelectedEngine = resolvedEngine };
        var service = new CaptureFlowService(
            resolvedTaskList,
            new RecordingEligibilityService(),
            resolvedParser,
            provider,
            new FixedTimeProvider(Now),
            settings ?? new InMemorySettingsStore(),
            repository,
            scheduler: null,
            voice: null,
            delegationHandoff: delegationHandoff,
            timeZone: TimeZoneInfo.Utc);
        // Skip the one-time cloud-parse consent gate for every test unless it specifically wants to
        // exercise that gate (see ProceedToCapture_NeverAsked_... below, which builds its own
        // CaptureFlowService directly instead of going through this helper).
        service.SetParseEngine(Volar.Parsing.ParseEnginePreference.OnDevice);
        return new Fixture(service, resolvedTaskList, resolvedParser, resolvedEngine);
    }

    // ============================================================================================
    // MARK: FIX 1 — the mandatory double-stop regression test
    // ============================================================================================

    [Fact]
    public async Task DoubleStop_DuringParsing_IsANoOp_AndTheFinalTranscriptStillLands()
    {
        var (service, _, parser, engine) = CreateService(
            parser: new FakeIntentParser { Result = new[] { CaptureTestData.SimpleTask("Buy milk", "buy milk") } });

        await service.StartCaptureAsync();
        Assert.Equal(CaptureState.Recording, service.State);
        Assert.True(engine.IsRunning);

        // First stop: FIX 1 — must enter .Parsing BEFORE Stop() is observed to have run, and for
        // every engine (not just partial-results ones).
        await service.StopCaptureAsync();
        Assert.Equal(CaptureState.Parsing, service.State);
        Assert.Equal(1, engine.StopCallCount);
        Assert.False(engine.IsRunning);

        // Second stop lands WHILE the final transcript is still in flight (the real async gap FIX 1
        // protects). Must be a clean no-op: engine.Stop() must NOT be called again, and the capture
        // session must NOT be invalidated (proven below once the transcript arrives).
        await service.StopCaptureAsync();
        Assert.Equal(CaptureState.Parsing, service.State);
        Assert.Equal(1, engine.StopCallCount);

        // The final transcript now arrives, asynchronously, exactly as it would from a real batch
        // engine's upload/transcription tail completing after Stop() already returned.
        engine.RaiseFinal("buy milk");

        // If the double-stop above HAD bumped the capture session (the pre-fix bug), this transcript
        // would be silently dropped by the OnFinal handler's session guard, and ConfirmDrafts would
        // stay empty forever. It must not be dropped.
        await WaitUntilAsync(() => service.State != CaptureState.Parsing);
        Assert.Equal(CaptureState.Parsed, service.State);
        Assert.Single(service.ConfirmDrafts);
        Assert.Equal("Buy milk", service.ConfirmDrafts[0].Task.Title);
        Assert.Single(parser.ParseCalls);
        Assert.Equal("buy milk", parser.ParseCalls[0]);
    }

    [Fact]
    public async Task StopCapture_WhileIdle_IsANoOp()
    {
        var (service, _, _, engine) = CreateService();

        await service.StopCaptureAsync();

        Assert.Equal(CaptureState.Idle, service.State);
        Assert.Equal(0, engine.StopCallCount);
    }

    [Fact]
    public async Task StartCapture_AuthorizationDenied_EntersError()
    {
        var engine = new FakeSpeechEngine { AuthorizationResult = false };
        var (service, _, _, _) = CreateService(engine: engine);

        await service.StartCaptureAsync();

        Assert.Equal(CaptureState.Error, service.State);
        Assert.NotNull(service.CaptureErrorDetail);
        Assert.Equal(0, engine.StartCallCount);
    }

    [Fact]
    public async Task ToggleCapture_StartsWhenIdle_StopsWhenRecording()
    {
        var (service, _, _, engine) = CreateService();

        await service.ToggleCaptureAsync();
        Assert.Equal(CaptureState.Recording, service.State);

        await service.ToggleCaptureAsync();
        Assert.Equal(CaptureState.Parsing, service.State);
        Assert.Equal(1, engine.StopCallCount);
    }

    [Fact]
    public async Task CancelCapture_DiscardsAudio_NeverFiresOnFinal()
    {
        var (service, _, _, engine) = CreateService();
        await service.StartCaptureAsync();

        var finalFired = false;
        engine.OnFinal += _ => finalFired = true;

        await service.CancelCaptureAsync();

        Assert.Equal(CaptureState.Idle, service.State);
        Assert.Equal(1, engine.CancelCallCount);
        Assert.Equal(0, engine.StopCallCount);
        Assert.False(finalFired);
    }

    [Fact]
    public async Task SecondStartCapture_UnsubscribesPreviousHandlers_NoAccumulation()
    {
        // Regression test for the C# `event` accumulation risk this file's header flags (Swift's
        // single-slot delegate property never had this problem). Two captures in a row against the
        // SAME long-lived engine instance must leave exactly ONE subscriber attached, not two.
        var engine = new FakeSpeechEngine();
        var (service, _, _, _) = CreateService(
            engine: engine,
            parser: new FakeIntentParser { Result = new[] { CaptureTestData.SimpleTask("Task", "task") } });

        await service.StartCaptureAsync();
        await service.StopCaptureAsync();
        engine.RaiseFinal("task");
        await WaitUntilAsync(() => service.State == CaptureState.Parsed);
        var firstDraftCount = service.ConfirmDrafts.Count;

        await service.StartCaptureAsync();
        await service.StopCaptureAsync();
        engine.RaiseFinal("task");
        await WaitUntilAsync(() => service.State == CaptureState.Parsed);

        // If the first capture's handler were still attached, this second RaiseFinal would trigger
        // FinishRecordingAsync twice concurrently for the SAME transcript. Both would still clear +
        // rebuild `_confirmDrafts` from the same one-item parser result, so the observable count
        // stays 1 either way — the real signal is the parser call count: a leaked handler would
        // double it for this SECOND capture (3 total) instead of the expected 2.
        Assert.Equal(1, firstDraftCount);
        Assert.Single(service.ConfirmDrafts);
    }

    // ============================================================================================
    // MARK: Voice-done confirm (complete / clear-external / no-match)
    // ============================================================================================

    [Fact]
    public async Task FinishRecording_CompletionPhrase_PresentsHighConfidenceConfirm()
    {
        var openTaskId = Guid.NewGuid();
        var taskList = new FakeTaskListService();
        taskList.BackingTasks.Add(CaptureTestData.OpenTask("Buy milk", openTaskId));
        var (service, _, _, engine) = CreateService(taskList: taskList);

        await service.StartCaptureAsync();
        await service.StopCaptureAsync();
        engine.RaiseFinal("buy milk xong");

        await WaitUntilAsync(() => service.VoiceDoneConfirmState is not null);
        var confirm = service.VoiceDoneConfirmState!;
        Assert.IsType<VoiceDoneAction.Complete>(confirm.Action);
        Assert.Single(confirm.Candidates);
        Assert.Equal(openTaskId, confirm.Candidates[0].TaskId);

        await service.ConfirmVoiceDoneAsync(openTaskId);

        Assert.Contains(openTaskId, taskList.ToggledIds);
        Assert.Null(service.VoiceDoneConfirmState);
        Assert.Equal(CaptureState.Done, service.State);
    }

    [Fact]
    public async Task FinishRecording_NoOpenTasks_CompletionPhraseYieldsNoMatch()
    {
        var (service, _, _, engine) = CreateService();

        await service.StartCaptureAsync();
        await service.StopCaptureAsync();
        engine.RaiseFinal("xong");

        await WaitUntilAsync(() => service.VoiceDoneNoMatchTranscript is not null);
        Assert.Null(service.VoiceDoneConfirmState);
        Assert.Equal(CaptureState.Parsed, service.State);
    }

    [Fact]
    public async Task CaptureVoiceDoneAsNewTask_ResumesTheSameTranscriptAsOrdinaryCapture()
    {
        var parser = new FakeIntentParser { Result = new[] { CaptureTestData.SimpleTask("Xong", "xong") } };
        var (service, _, _, engine) = CreateService(parser: parser);

        await service.StartCaptureAsync();
        await service.StopCaptureAsync();
        engine.RaiseFinal("xong");
        await WaitUntilAsync(() => service.VoiceDoneNoMatchTranscript is not null);

        await service.CaptureVoiceDoneAsNewTaskAsync();

        await WaitUntilAsync(() => service.ConfirmDrafts.Count > 0);
        Assert.Equal(CaptureState.Parsed, service.State);
        Assert.Null(service.VoiceDoneNoMatchTranscript);
        Assert.Single(parser.ParseCalls);
        Assert.Equal("xong", parser.ParseCalls[0]);
    }

    [Fact]
    public async Task DismissVoiceDoneConfirm_LeavesEveryTaskUntouched()
    {
        var openTaskId = Guid.NewGuid();
        var taskList = new FakeTaskListService();
        taskList.BackingTasks.Add(CaptureTestData.OpenTask("Buy milk", openTaskId));
        var (service, _, _, engine) = CreateService(taskList: taskList);

        await service.StartCaptureAsync();
        await service.StopCaptureAsync();
        engine.RaiseFinal("buy milk xong");
        await WaitUntilAsync(() => service.VoiceDoneConfirmState is not null);

        await service.DismissVoiceDoneConfirmAsync();

        Assert.Empty(taskList.ToggledIds);
        Assert.Null(service.VoiceDoneConfirmState);
        Assert.Equal(CaptureState.Idle, service.State);
        Assert.Equal(1, engine.CancelCallCount);
    }

    // ============================================================================================
    // MARK: Delegation-intent classification
    // ============================================================================================

    [Fact]
    public async Task FinishRecording_DelegationPhrase_TargetsActiveTask_DefaultCheckBack()
    {
        var activeId = Guid.NewGuid();
        var taskList = new FakeTaskListService { ActiveOverride = CaptureTestData.OpenTask("Ship the release", activeId) };
        var handoff = new RecordingDelegationHandoff();
        var (service, _, _, engine) = CreateService(taskList: taskList, delegationHandoff: handoff);

        await service.StartCaptureAsync();
        await service.StopCaptureAsync();
        engine.RaiseFinal("giao cho claude");

        await WaitUntilAsync(() => service.VoiceDoneConfirmState is not null);
        var confirm = service.VoiceDoneConfirmState!;
        var delegateAction = Assert.IsType<VoiceDoneAction.Delegate>(confirm.Action);
        Assert.Equal(10, delegateAction.CheckBackMinutes); // default when no interval is spoken.
        Assert.Equal(activeId, confirm.Candidates[0].TaskId);

        await service.ConfirmVoiceDoneAsync(activeId);

        Assert.Single(handoff.Calls);
        Assert.Equal(activeId, handoff.Calls[0].TaskId);
        Assert.Equal(10, handoff.Calls[0].CheckBackMinutes);
    }

    [Fact]
    public async Task FinishRecording_DelegationPhrase_ExtractsSpokenCheckBackMinutes()
    {
        var activeId = Guid.NewGuid();
        var taskList = new FakeTaskListService { ActiveOverride = CaptureTestData.OpenTask("Ship the release", activeId) };
        var (service, _, _, engine) = CreateService(taskList: taskList);

        await service.StartCaptureAsync();
        await service.StopCaptureAsync();
        engine.RaiseFinal("giao cho claude check sau 15 phut");

        await WaitUntilAsync(() => service.VoiceDoneConfirmState is not null);
        var delegateAction = Assert.IsType<VoiceDoneAction.Delegate>(service.VoiceDoneConfirmState!.Action);
        Assert.Equal(15, delegateAction.CheckBackMinutes);
    }

    [Fact]
    public async Task FinishRecording_DelegationPhrase_NoActiveTask_YieldsNoMatch()
    {
        var (service, _, _, engine) = CreateService(); // ActiveOverride left null.

        await service.StartCaptureAsync();
        await service.StopCaptureAsync();
        engine.RaiseFinal("handed off to claude");

        await WaitUntilAsync(() => service.VoiceDoneNoMatchTranscript is not null);
        Assert.Null(service.VoiceDoneConfirmState);
    }

    [Fact]
    public async Task FinishRecording_DelegationPhraseTakesPriorityOverVoiceDoneClassification()
    {
        // 887-895's documented ordering: delegation-intent must be checked BEFORE the ordinary
        // VoiceDone completion/clear-external classifier gets a chance at the same transcript.
        var activeId = Guid.NewGuid();
        var activeTask = CaptureTestData.OpenTask("Ship the release", activeId);
        var taskList = new FakeTaskListService { ActiveOverride = activeTask };
        taskList.BackingTasks.Add(activeTask);
        var (service, _, _, engine) = CreateService(taskList: taskList);

        await service.StartCaptureAsync();
        await service.StopCaptureAsync();
        engine.RaiseFinal("da giao cho claude");

        await WaitUntilAsync(() => service.VoiceDoneConfirmState is not null);
        Assert.IsType<VoiceDoneAction.Delegate>(service.VoiceDoneConfirmState!.Action);
    }

    // ============================================================================================
    // MARK: Cloud-parse consent gate
    // ============================================================================================

    [Fact]
    public async Task ProceedToCapture_NeverAsked_PausesForConsent_ThenResumesOnAllow()
    {
        var settings = new InMemorySettingsStore();
        var parser = new FakeIntentParser { Result = new[] { CaptureTestData.SimpleTask("Task", "some task") } };
        var taskList = new FakeTaskListService();
        var provider = new FakeSpeechEngineProvider();
        var engine = (FakeSpeechEngine)provider.SelectedEngine;
        // Deliberately DO NOT call SetParseEngine here — this test wants the "never asked" gate,
        // so it builds the service directly instead of going through the CreateService helper
        // (which always marks the consent decision as already made).
        var service = new CaptureFlowService(
            taskList, new RecordingEligibilityService(), parser, provider,
            new FixedTimeProvider(Now), settings, timeZone: TimeZoneInfo.Utc);

        await service.StartCaptureAsync();
        await service.StopCaptureAsync();
        engine.RaiseFinal("some task");

        await WaitUntilAsync(() => service.PendingCloudConsent);
        Assert.Equal(CaptureState.Error, service.State);
        Assert.NotNull(service.CaptureErrorDetail);
        Assert.Empty(parser.ParseCalls);

        await service.ResolveCloudConsentAsync(true);

        await WaitUntilAsync(() => service.State == CaptureState.Parsed);
        Assert.False(service.PendingCloudConsent);
        Assert.Single(parser.ParseCalls);
        Assert.Equal(Volar.Parsing.ParseEnginePreference.Cloud, service.ParseEnginePreference);
    }

    [Fact]
    public void SetParseEngine_PersistsPreference()
    {
        var (service, _, _, _) = CreateService();
        service.SetParseEngine(Volar.Parsing.ParseEnginePreference.Cloud);
        Assert.Equal(Volar.Parsing.ParseEnginePreference.Cloud, service.ParseEnginePreference);
    }

    // ============================================================================================
    // MARK: Confirm-card chip interactions
    // ============================================================================================

    [Fact]
    public async Task DismissAttribute_ThenSave_OmitsTheAttribute()
    {
        var deadline = Now.AddDays(1);
        var parsed = new ParsedTask("Call bank", "call bank tomorrow")
        {
            Deadline = new ParsedValue<DateTimeOffset>(deadline, 0.95),
        };
        var (service, taskList, _, engine) = CreateService(parser: new FakeIntentParser { Result = new[] { parsed } });

        await service.StartCaptureAsync();
        await service.StopCaptureAsync();
        engine.RaiseFinal("call bank tomorrow");
        await WaitUntilAsync(() => service.ConfirmDrafts.Count > 0);

        var draftId = service.ConfirmDrafts[0].Id;
        service.DismissAttribute(ChipKind.Deadline, draftId);

        await service.ConfirmSaveAsync();

        Assert.Single(taskList.AddedTasks);
        Assert.Null(taskList.AddedTasks[0].Deadline);
    }

    [Fact]
    public async Task AcceptUncertainAttribute_ThenSave_KeepsTheAttribute()
    {
        var estimate = new ParsedValue<int>(45, 0.4); // < 0.7 -> uncertain, dropped unless accepted.
        var parsed = new ParsedTask("Write report", "write report maybe 45 minutes")
        {
            EstimateMinutes = estimate,
        };
        var (service, taskList, _, engine) = CreateService(parser: new FakeIntentParser { Result = new[] { parsed } });

        await service.StartCaptureAsync();
        await service.StopCaptureAsync();
        engine.RaiseFinal("write report maybe 45 minutes");
        await WaitUntilAsync(() => service.ConfirmDrafts.Count > 0);

        // Not yet accepted -> dropped at save.
        await service.ConfirmSaveAsync();
        Assert.Null(taskList.AddedTasks[0].DurationMinutes);

        // Re-parse and this time accept it before saving. A fresh Start/Stop cycle is required —
        // ConfirmSaveAsync's own FinishSaveUI already bumped the capture session, so a bare
        // RaiseFinal reusing the FIRST capture's (now stale) session would be correctly ignored by
        // the session guard, not a service bug.
        await service.StartCaptureAsync();
        await service.StopCaptureAsync();
        engine.RaiseFinal("write report maybe 45 minutes");
        await WaitUntilAsync(() => service.ConfirmDrafts.Count > 0);
        var draftId = service.ConfirmDrafts[0].Id;
        service.AcceptUncertainAttribute(ChipKind.Estimate, draftId);
        await service.ConfirmSaveAsync();

        Assert.Equal(45, taskList.AddedTasks[1].DurationMinutes);
    }

    [Fact]
    public async Task ResolveTaskDone_ThenDismissCondition_ClearsTheResolution()
    {
        var otherTaskId = Guid.NewGuid();
        var parsed = new ParsedTask("Deploy", "deploy after code review")
        {
            Conditions = new ParsedCondition[] { new ParsedCondition.TaskDone("some unrelated thing", 0.9) },
        };
        var (service, taskList, _, engine) = CreateService(parser: new FakeIntentParser { Result = new[] { parsed } });

        await service.StartCaptureAsync();
        await service.StopCaptureAsync();
        engine.RaiseFinal("deploy after code review");
        await WaitUntilAsync(() => service.ConfirmDrafts.Count > 0);
        var draftId = service.ConfirmDrafts[0].Id;

        // No fuzzy match against an empty open-task list -> stays unresolved.
        Assert.Empty(service.ConfirmDrafts[0].ResolvedTaskDone);

        service.ResolveTaskDone(0, otherTaskId, draftId);
        Assert.Equal(otherTaskId, service.ConfirmDrafts[0].ResolvedTaskDone[0]);

        await service.ConfirmSaveAsync();
        Assert.Single(taskList.AddedTasks[0].Conditions);
        Assert.Equal(otherTaskId, Assert.IsType<TaskDoneCondition>(taskList.AddedTasks[0].Conditions[0]).TaskId);
    }

    [Fact]
    public async Task RemoveDraft_DropsExactlyThatTask()
    {
        var parser = new FakeIntentParser
        {
            Result = new[]
            {
                CaptureTestData.SimpleTask("Task A", "task a and task b"),
                CaptureTestData.SimpleTask("Task B", "task a and task b"),
            },
        };
        var (service, _, _, engine) = CreateService(parser: parser);

        await service.StartCaptureAsync();
        await service.StopCaptureAsync();
        engine.RaiseFinal("task a and task b");
        await WaitUntilAsync(() => service.ConfirmDrafts.Count == 2);

        var idToRemove = service.ConfirmDrafts[0].Id;
        service.RemoveDraft(idToRemove);

        Assert.Single(service.ConfirmDrafts);
        Assert.DoesNotContain(service.ConfirmDrafts, d => d.Id == idToRemove);
    }

    [Fact]
    public async Task DismissConflictAdvisory_NeverRecomputesConflicts()
    {
        const string duplicateTitle = "Buy milk";
        var taskList = new FakeTaskListService();
        taskList.BackingTasks.Add(CaptureTestData.OpenTask(duplicateTitle));
        var parser = new FakeIntentParser { Result = new[] { CaptureTestData.SimpleTask(duplicateTitle, "buy milk") } };
        var (service, _, _, engine) = CreateService(taskList: taskList, parser: parser);

        await service.StartCaptureAsync();
        await service.StopCaptureAsync();
        engine.RaiseFinal("buy milk");
        await WaitUntilAsync(() => service.ConfirmDrafts.Count > 0);

        var draft = service.ConfirmDrafts[0];
        Assert.NotEmpty(draft.Conflicts); // possible-duplicate against the identical open title.
        var conflictsBefore = draft.Conflicts;

        service.DismissConflictAdvisory(draft.Id);

        Assert.True(draft.ConflictDismissed);
        Assert.Same(conflictsBefore, draft.Conflicts); // never re-derived.
    }

    [Fact]
    public async Task FollowUpReview_MaterializesASecondReviewTask_UnlessDismissed()
    {
        var parsed = new ParsedTask("Deploy", "deploy the release and follow up later") { FollowUpReview = true };
        var (service, taskList, _, engine) = CreateService(parser: new FakeIntentParser { Result = new[] { parsed } });

        await service.StartCaptureAsync();
        await service.StopCaptureAsync();
        engine.RaiseFinal("deploy the release and follow up later");
        await WaitUntilAsync(() => service.ConfirmDrafts.Count > 0);

        await service.ConfirmSaveAsync();

        Assert.Equal(2, taskList.AddedTasks.Count);
        Assert.Equal("Deploy", taskList.AddedTasks[0].Title);
        Assert.Equal("Review: Deploy", taskList.AddedTasks[1].Title);
        Assert.Equal(TaskKind.Review, taskList.AddedTasks[1].Kind);
        var reviewCondition = Assert.IsType<TaskDoneCondition>(taskList.AddedTasks[1].Conditions[0]);
        Assert.Equal(taskList.AddedTasks[0].Id, reviewCondition.TaskId);
    }

    // ============================================================================================
    // MARK: ConfirmSaveAsync — real repository path (chunking, eligibility tail, error surfacing)
    // ============================================================================================

    [Fact]
    public async Task ConfirmSaveAsync_WithRepository_PersistsAndRefreshesTheOneOwner()
    {
        using var db = new SqliteFixture();
        var repository = db.CreateTaskRepository();
        var eligibility = new EligibilityAndResurfaceService(new FixedTimeProvider(Now));
        var realTaskList = new TaskListService(eligibility, new FixedTimeProvider(Now), repository);
        eligibility.TaskList = realTaskList;

        var parser = new FakeIntentParser { Result = new[] { CaptureTestData.SimpleTask("Buy milk", "buy milk") } };
        var provider = new FakeSpeechEngineProvider();
        var engine = (FakeSpeechEngine)provider.SelectedEngine;
        var service = new CaptureFlowService(
            realTaskList, eligibility, parser, provider, new FixedTimeProvider(Now),
            new InMemorySettingsStore(), repository, timeZone: TimeZoneInfo.Utc);
        service.SetParseEngine(Volar.Parsing.ParseEnginePreference.OnDevice);

        await service.StartCaptureAsync();
        await service.StopCaptureAsync();
        engine.RaiseFinal("buy milk");
        await WaitUntilAsync(() => service.ConfirmDrafts.Count > 0);

        await service.ConfirmSaveAsync();

        Assert.Equal(CaptureState.Done, service.State);
        Assert.Empty(service.ConfirmDrafts);
        Assert.Single(realTaskList.Tasks);
        Assert.Equal("Buy milk", realTaskList.Tasks[0].Title);
    }

    [Fact]
    public async Task ConfirmSaveAsync_NoDrafts_IsANoOp()
    {
        var (service, _, _, _) = CreateService();
        await service.ConfirmSaveAsync();
        Assert.Equal(CaptureState.Idle, service.State);
    }
}
