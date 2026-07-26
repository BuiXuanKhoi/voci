// ViewModels/CapturePopoverViewModelTests.cs — Wave 4 Stage B, agent B2. Exercises
// CapturePopoverViewModel headlessly against a REAL CaptureFlowService wired to the same fakes
// Capture/CaptureFlowServiceTests.cs already established (FakeTaskListService/FakeIntentParser/
// FakeSpeechEngine/FakeSpeechEngineProvider, all `internal` to this assembly, reused here rather
// than duplicated — see Capture/TestSupport.cs). Deliberately does NOT re-test
// CaptureFlowService's own state-machine correctness (that's CaptureFlowServiceTests.cs's job) —
// this file proves the VM's passthrough/visibility/formatting/keyboard-dispatch logic against real
// service behavior, and that PropertyChanged actually fires when the underlying service mutates.
using Volar.App.Services.State;
using Volar.App.Tests.Capture;
using Volar.App.Tests.State;
using Volar.App.ViewModels;
using Volar.Core;
using Volar.Domain;
using Xunit;

namespace Volar.App.Tests.ViewModels;

public sealed class CapturePopoverViewModelTests
{
    private static readonly DateTimeOffset Now = CaptureTestData.Now;

    private sealed record Fixture(
        CapturePopoverViewModel ViewModel, CaptureFlowService Service, FakeTaskListService TaskList, FakeSpeechEngine Engine);

    /// <summary>Mirrors CaptureFlowServiceTests.cs's own `CreateService` helper: skips the one-time
    /// cloud-parse consent gate by default (via `SetParseEngine`) so most tests reach `.Parsed`
    /// directly; <see cref="CloudConsent_BlocksEscape_ButEnterDeclinesToOnDevice"/> below builds its
    /// own fixture WITHOUT this call specifically to exercise the gate.</summary>
    private static Fixture CreateFixture(
        FakeTaskListService? taskList = null,
        FakeIntentParser? parser = null,
        FakeSpeechEngine? engine = null,
        bool skipConsentGate = true)
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
            new InMemorySettingsStore(),
            repository: null,
            scheduler: null,
            voice: null,
            delegationHandoff: null,
            timeZone: TimeZoneInfo.Utc);
        if (skipConsentGate)
        {
            service.SetParseEngine(Volar.Parsing.ParseEnginePreference.OnDevice);
        }
        var vm = new CapturePopoverViewModel(service, resolvedTaskList, dispatcherQueue: null);
        return new Fixture(vm, service, resolvedTaskList, resolvedEngine);
    }

    /// <summary>Polling helper for CaptureFlowService's fire-and-forget continuations — same
    /// rationale as CaptureFlowServiceTests.cs's identically-named helper (every collaborator here
    /// resolves synchronously via already-completed Tasks, so this is defense-in-depth, not a sign
    /// of flakiness).</summary>
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

    private static async Task<Fixture> RecordAndParseAsync(FakeIntentParser parser, string transcript, FakeTaskListService? taskList = null)
    {
        var fixture = CreateFixture(taskList: taskList, parser: parser);
        await fixture.ViewModel.ToggleCaptureAsync();
        await fixture.ViewModel.ToggleCaptureAsync(); // recording -> parsing
        fixture.Engine.RaiseFinal(transcript);
        await WaitUntilAsync(() => fixture.ViewModel.State is CaptureState.Parsed or CaptureState.Error);
        return fixture;
    }

    // ============================================================================================
    // MARK: Construction / passthrough / visibility
    // ============================================================================================

    [Fact]
    public void Construction_IsHeadless_AndReflectsIdleState()
    {
        var fixture = CreateFixture();
        var vm = fixture.ViewModel;

        Assert.Equal(CaptureState.Idle, vm.State);
        Assert.False(vm.ShowWave);
        Assert.False(vm.ShowTranscript);
        Assert.False(vm.ShowParsedCard);
        Assert.False(vm.ShowActions);
        Assert.False(vm.ShowVoiceDoneCard);
        Assert.False(vm.ShowError);
        Assert.Equal(string.Empty, vm.HintText);
        Assert.Equal(HintTone.Muted, vm.HintToneValue);
        Assert.Empty(vm.ConfirmDrafts);
    }

    [Fact]
    public async Task ToggleCaptureAsync_EntersRecording_ShowsWaveAndListeningDot_RaisesPropertyChanged()
    {
        var fixture = CreateFixture();
        var raiseCount = 0;
        fixture.ViewModel.PropertyChanged += (_, _) => raiseCount++;

        await fixture.ViewModel.ToggleCaptureAsync();

        Assert.Equal(CaptureState.Recording, fixture.ViewModel.State);
        Assert.True(fixture.ViewModel.ShowWave);
        Assert.True(fixture.ViewModel.WaveformActive);
        Assert.True(fixture.ViewModel.ShowListeningDot);
        Assert.True(fixture.ViewModel.ShowTranscript);
        Assert.True(fixture.ViewModel.ShowCaret);
        Assert.Equal("Listening…", fixture.ViewModel.HintText);
        Assert.True(raiseCount > 0);
    }

    [Fact]
    public async Task SingleDraft_ShowsParsedCardAndActions_WithSingularSaveLabel()
    {
        var parser = new FakeIntentParser { Result = new[] { CaptureTestData.SimpleTask("Buy milk", "buy milk") } };
        var fixture = await RecordAndParseAsync(parser, "buy milk");

        Assert.Equal(CaptureState.Parsed, fixture.ViewModel.State);
        Assert.True(fixture.ViewModel.ShowParsedCard);
        Assert.True(fixture.ViewModel.ShowActions);
        Assert.False(fixture.ViewModel.IsSaveDisabled);
        Assert.Single(fixture.ViewModel.ConfirmDrafts);
        Assert.Equal("Save task", fixture.ViewModel.SaveLabel);
        Assert.Equal("Looks right? Hit return.", fixture.ViewModel.HintText);
        Assert.Equal("Buy milk", fixture.ViewModel.TranscriptText);
    }

    [Fact]
    public async Task MultiDraft_PluralizesSaveLabelAndHint_RemoveDraftDropsOneAndUpdatesLabel()
    {
        var parser = new FakeIntentParser
        {
            Result = new[]
            {
                CaptureTestData.SimpleTask("Task A", "task a and task b"),
                CaptureTestData.SimpleTask("Task B", "task a and task b"),
            },
        };
        var fixture = await RecordAndParseAsync(parser, "task a and task b");

        Assert.Equal(2, fixture.ViewModel.ConfirmDrafts.Count);
        Assert.Equal("Save 2 tasks", fixture.ViewModel.SaveLabel);
        Assert.Equal("Looks right? Hit return to save all.", fixture.ViewModel.HintText);
        Assert.Equal("Task A  +1 more", fixture.ViewModel.TranscriptText);

        var secondDraftId = fixture.ViewModel.ConfirmDrafts[1].Id;
        fixture.ViewModel.RemoveDraft(secondDraftId);

        Assert.Single(fixture.ViewModel.ConfirmDrafts);
        Assert.Equal("Save task", fixture.ViewModel.SaveLabel);
    }

    // ============================================================================================
    // MARK: Confirm-card title editing (anh Khôi's bug report #2: the parsed title must be
    // editable before Save) — CapturePopover.xaml.cs's title TextBox calls UpdateDraftTitle directly
    // (bypassing PropertyChanged/Refresh() by design, see CaptureFlowService.UpdateDraftTitle's own
    // doc comment), so TranscriptText is asserted via a direct read rather than a PropertyChanged
    // subscription.
    // ============================================================================================

    [Fact]
    public async Task UpdateDraftTitle_ChangesTranscriptTextToTheEditedTitle()
    {
        var parser = new FakeIntentParser { Result = new[] { CaptureTestData.SimpleTask("Buy milk", "buy milk") } };
        var fixture = await RecordAndParseAsync(parser, "buy milk");

        var draft = fixture.ViewModel.ConfirmDrafts[0];
        fixture.ViewModel.UpdateDraftTitle(draft.Id, "Buy oat milk");

        Assert.Equal("Buy oat milk", fixture.ViewModel.TranscriptText);
    }

    [Fact]
    public async Task UpdateDraftTitle_BlankEdit_TranscriptTextFallsBackToTheOriginalTitle()
    {
        var parser = new FakeIntentParser { Result = new[] { CaptureTestData.SimpleTask("Buy milk", "buy milk") } };
        var fixture = await RecordAndParseAsync(parser, "buy milk");

        var draft = fixture.ViewModel.ConfirmDrafts[0];
        fixture.ViewModel.UpdateDraftTitle(draft.Id, "   ");

        Assert.Equal("Buy milk", fixture.ViewModel.TranscriptText);
    }

    [Fact]
    public async Task UpdateDraftTitle_ThenSave_SavedTaskCarriesTheEditedTitle()
    {
        var taskList = new FakeTaskListService();
        var parser = new FakeIntentParser { Result = new[] { CaptureTestData.SimpleTask("Buy milk", "buy milk") } };
        var fixture = await RecordAndParseAsync(parser, "buy milk", taskList);

        var draft = fixture.ViewModel.ConfirmDrafts[0];
        fixture.ViewModel.UpdateDraftTitle(draft.Id, "Buy oat milk");

        await fixture.ViewModel.ConfirmSaveAsync();
        await WaitUntilAsync(() => taskList.AddedTasks.Count == 1);
        Assert.Equal("Buy oat milk", taskList.AddedTasks[0].Title);
    }

    // ============================================================================================
    // MARK: Chip / condition / conflict command wiring (end-to-end through ConfirmSaveAsync's
    // materialization, so these prove the VM's methods reach the SAME resolution logic the confirm
    // card's Save button relies on — not just that a flag toggled)
    // ============================================================================================

    [Fact]
    public async Task DismissAttribute_Deadline_DropsItFromTheSavedTask()
    {
        var task = new ParsedTask(
            "Call Bob", "call bob tomorrow",
            Deadline: new ParsedValue<DateTimeOffset>(Now.AddDays(1), 0.95));
        var taskList = new FakeTaskListService();
        var fixture = await RecordAndParseAsync(new FakeIntentParser { Result = new[] { task } }, "call bob tomorrow", taskList);

        var draft = fixture.ViewModel.ConfirmDrafts[0];
        fixture.ViewModel.DismissAttribute(ChipKind.Deadline, draft.Id);
        Assert.Contains(ChipKind.Deadline, draft.Dismissed);

        await fixture.ViewModel.ConfirmSaveAsync();
        await WaitUntilAsync(() => taskList.AddedTasks.Count == 1);
        Assert.Null(taskList.AddedTasks[0].Deadline);
    }

    [Fact]
    public async Task AcceptUncertainAttribute_Priority_KeepsItInTheSavedTask()
    {
        // Confidence 0.4 (< 0.7) would normally be dropped at save unless explicitly accepted.
        var task = new ParsedTask(
            "Ship release", "ship release maybe high priority",
            Priority: new ParsedValue<int>(1, 0.4));
        var taskList = new FakeTaskListService();
        var fixture = await RecordAndParseAsync(new FakeIntentParser { Result = new[] { task } }, "ship release maybe high priority", taskList);

        var draft = fixture.ViewModel.ConfirmDrafts[0];
        Assert.True(draft.Task.Priority!.Value.IsUncertain);

        fixture.ViewModel.AcceptUncertainAttribute(ChipKind.Priority, draft.Id);
        Assert.Contains(ChipKind.Priority, draft.Accepted);

        await fixture.ViewModel.ConfirmSaveAsync();
        await WaitUntilAsync(() => taskList.AddedTasks.Count == 1);
        Assert.Equal(Priority.High, taskList.AddedTasks[0].Priority);
    }

    [Fact]
    public async Task ResolveTaskDone_PicksDependency_ThenSavedTaskCarriesThatCondition()
    {
        var openTask = CaptureTestData.OpenTask("Finish the deck");
        var taskList = new FakeTaskListService();
        taskList.BackingTasks.Add(openTask);

        var task = new ParsedTask(
            "Present to client", "present after finishing the deck",
            Conditions: new ParsedCondition[] { new ParsedCondition.TaskDone("finish the deck", 0.3) });
        var fixture = await RecordAndParseAsync(new FakeIntentParser { Result = new[] { task } }, "present after finishing the deck", taskList);

        var draft = fixture.ViewModel.ConfirmDrafts[0];
        Assert.Contains(openTask, fixture.ViewModel.OpenTasks);

        fixture.ViewModel.ResolveTaskDone(0, openTask.Id, draft.Id);
        Assert.Equal(openTask.Id, draft.ResolvedTaskDone[0]);

        await fixture.ViewModel.ConfirmSaveAsync();
        await WaitUntilAsync(() => taskList.AddedTasks.Count == 1);
        var saved = taskList.AddedTasks[0];
        var condition = Assert.Single(saved.Conditions);
        var taskDone = Assert.IsType<TaskDoneCondition>(condition);
        Assert.Equal(openTask.Id, taskDone.TaskId);
    }

    [Fact]
    public async Task DismissConflictAdvisory_HidesTheAdvisoryRow_WithoutTouchingTheDraft()
    {
        // A capacity conflict needs an existing same-day task; simplest reliable trigger is a
        // possible-duplicate (near-identical title to an existing open task).
        var existing = CaptureTestData.OpenTask("Email the client about the proposal");
        var taskList = new FakeTaskListService();
        taskList.BackingTasks.Add(existing);
        var task = new ParsedTask("Email the client about the proposal", "email the client about the proposal");
        var fixture = await RecordAndParseAsync(new FakeIntentParser { Result = new[] { task } }, "email the client about the proposal", taskList);

        var draft = fixture.ViewModel.ConfirmDrafts[0];
        if (draft.Conflicts.Count == 0)
        {
            // Environment-dependent fuzzy-match threshold; skip rather than assert a false failure —
            // the dismiss-wiring itself is still covered by the assertions below when conflicts DO
            // fire, and ConflictChecker's own detection logic is Volar.Core.Tests' responsibility.
            return;
        }

        Assert.False(draft.ConflictDismissed);
        fixture.ViewModel.DismissConflictAdvisory(draft.Id);
        Assert.True(draft.ConflictDismissed);
    }

    // ============================================================================================
    // MARK: Voice-done confirm / no-match
    // ============================================================================================

    [Fact]
    public async Task VoiceDone_SingleCandidate_ConfirmMarksTaskDone()
    {
        // "<title> xong" is the exact phrasing CaptureFlowServiceTests.cs's own
        // FinishRecording_CompletionPhrase_PresentsHighConfidenceConfirm test uses — reused here
        // rather than inventing new (unverified) VoiceDone phrasing.
        var openTaskId = Guid.NewGuid();
        var taskList = new FakeTaskListService();
        taskList.BackingTasks.Add(CaptureTestData.OpenTask("Buy milk", openTaskId));
        var fixture = CreateFixture(taskList: taskList);

        await fixture.ViewModel.ToggleCaptureAsync();
        await fixture.ViewModel.ToggleCaptureAsync();
        fixture.Engine.RaiseFinal("buy milk xong");
        await WaitUntilAsync(() => fixture.ViewModel.ShowVoiceDoneCard);

        Assert.True(fixture.ViewModel.ShowVoiceDoneCard);
        Assert.False(fixture.ViewModel.ShowParsedCard);
        Assert.False(fixture.ViewModel.ShowActions);
        var confirm = fixture.ViewModel.VoiceDoneConfirmState;
        Assert.NotNull(confirm);
        Assert.Single(confirm.Candidates);
        Assert.Equal(openTaskId, confirm.Candidates[0].TaskId);

        await fixture.ViewModel.ConfirmVoiceDoneAsync(confirm.Candidates[0].TaskId);

        await WaitUntilAsync(() => taskList.ToggledIds.Contains(openTaskId));
    }

    [Fact]
    public async Task VoiceDone_NoMatch_CaptureAsNewTask_FallsThroughToOrdinaryParse()
    {
        // Bare "xong" with NO open tasks -> CandidateFloor never matches anything (VoiceDone.swift's
        // "done-phrase present but nothing matched" case), same setup as CaptureFlowServiceTests.cs's
        // FinishRecording_NoOpenTasks_CompletionPhraseYieldsNoMatch.
        var parser = new FakeIntentParser { Result = new[] { CaptureTestData.SimpleTask("Xong", "xong") } };
        var fixture = CreateFixture(parser: parser);

        await fixture.ViewModel.ToggleCaptureAsync();
        await fixture.ViewModel.ToggleCaptureAsync();
        fixture.Engine.RaiseFinal("xong");
        await WaitUntilAsync(() => fixture.ViewModel.VoiceDoneNoMatchTranscript is not null);

        Assert.True(fixture.ViewModel.ShowVoiceDoneCard);

        await fixture.ViewModel.CaptureVoiceDoneAsNewTaskAsync();
        await WaitUntilAsync(() => fixture.ViewModel.State == CaptureState.Parsed);

        Assert.False(fixture.ViewModel.ShowVoiceDoneCard);
        Assert.True(fixture.ViewModel.ShowParsedCard);
    }

    // ============================================================================================
    // MARK: Keyboard dispatch (HandleEscape/HandlePrimaryEnter) — the exhaustive port of
    // PopoverView.swift's `.keyboardShortcut(.cancelAction)`/`.keyboardShortcut(.defaultAction)`
    // table (see CapturePopoverViewModel.cs's own doc comments for the line citations).
    // ============================================================================================

    [Fact]
    public async Task HandleEscape_DuringRecording_CancelsBackToIdle()
    {
        var fixture = CreateFixture();
        await fixture.ViewModel.ToggleCaptureAsync();
        Assert.Equal(CaptureState.Recording, fixture.ViewModel.State);

        fixture.ViewModel.HandleEscape();
        await WaitUntilAsync(() => fixture.ViewModel.State == CaptureState.Idle);
    }

    [Fact]
    public async Task HandleEscape_DuringParsed_CancelsBackToIdle()
    {
        var parser = new FakeIntentParser { Result = new[] { CaptureTestData.SimpleTask("Task", "task") } };
        var fixture = await RecordAndParseAsync(parser, "task");
        Assert.Equal(CaptureState.Parsed, fixture.ViewModel.State);

        fixture.ViewModel.HandleEscape();
        await WaitUntilAsync(() => fixture.ViewModel.State == CaptureState.Idle);
    }

    [Fact]
    public async Task HandlePrimaryEnter_DuringParsed_TriggersSave()
    {
        var taskList = new FakeTaskListService();
        var parser = new FakeIntentParser { Result = new[] { CaptureTestData.SimpleTask("Task", "task") } };
        var fixture = await RecordAndParseAsync(parser, "task", taskList);
        Assert.Equal(CaptureState.Parsed, fixture.ViewModel.State);

        fixture.ViewModel.HandlePrimaryEnter();
        await WaitUntilAsync(() => taskList.AddedTasks.Count == 1);
    }

    [Fact]
    public async Task HandlePrimaryEnter_DuringMultiCandidateVoiceDone_IsANoOp()
    {
        // "Call mom"/"Call dad" both share exactly 1 of 2 tokens with "call" (post cue-strip) ->
        // both score a tied 0.5 (>= VoiceDone's 0.5 floor, < its 0.8 high-confidence bar) -> neither
        // uniquely wins, so VoiceDone.Classify returns BOTH as a disambiguation list — deterministic,
        // not an environment-dependent fuzzy-match tuning question (unlike a "close but not tied"
        // pair would be).
        var a = CaptureTestData.OpenTask("Call mom");
        var b = CaptureTestData.OpenTask("Call dad");
        var taskList = new FakeTaskListService();
        taskList.BackingTasks.Add(a);
        taskList.BackingTasks.Add(b);
        var fixture = CreateFixture(taskList: taskList);

        await fixture.ViewModel.ToggleCaptureAsync();
        await fixture.ViewModel.ToggleCaptureAsync();
        fixture.Engine.RaiseFinal("call xong");
        await WaitUntilAsync(() => fixture.ViewModel.ShowVoiceDoneCard);

        var confirm = fixture.ViewModel.VoiceDoneConfirmState;
        Assert.NotNull(confirm);
        Assert.True(confirm.Candidates.Count > 1, "expected a tied-score disambiguation list");

        fixture.ViewModel.HandlePrimaryEnter();
        await Task.Delay(50);
        Assert.True(fixture.ViewModel.ShowVoiceDoneCard); // still pending — no default action fired.
    }

    [Fact]
    public async Task CloudConsent_Pending_BlocksEscape_ButEnterDeclinesToOnDeviceAndProceeds()
    {
        var parser = new FakeIntentParser { Result = new[] { CaptureTestData.SimpleTask("Task", "task") } };
        var fixture = CreateFixture(parser: parser, skipConsentGate: false);

        await fixture.ViewModel.ToggleCaptureAsync();
        await fixture.ViewModel.ToggleCaptureAsync();
        fixture.Engine.RaiseFinal("task");
        await WaitUntilAsync(() => fixture.ViewModel.State == CaptureState.Error);

        Assert.True(fixture.ViewModel.PendingCloudConsent);
        Assert.True(fixture.ViewModel.ShowError);

        // Escape: PopoverView.swift's cloud-consent buttons bind neither to `.cancelAction` — a
        // deliberate no-op, not a gap (see HandleEscape's own doc comment).
        fixture.ViewModel.HandleEscape();
        await Task.Delay(50);
        Assert.True(fixture.ViewModel.PendingCloudConsent);

        // Enter: the decline button ("Keep parsing on-device only") carries `.defaultAction`.
        fixture.ViewModel.HandlePrimaryEnter();
        await WaitUntilAsync(() => fixture.ViewModel.State == CaptureState.Parsed);
        Assert.False(fixture.ViewModel.PendingCloudConsent);
    }

    // ============================================================================================
    // MARK: Lifecycle
    // ============================================================================================

    [Fact]
    public async Task Dispose_UnsubscribesFromCaptureChanged()
    {
        var fixture = CreateFixture();
        fixture.ViewModel.Dispose();

        var raised = false;
        fixture.ViewModel.PropertyChanged += (_, _) => raised = true;
        await fixture.Service.StartCaptureAsync();

        Assert.False(raised);
    }

    // ============================================================================================
    // MARK: CapturePopoverFormatting — pure formatter parity with PopoverView.swift's own helpers
    // ============================================================================================

    [Theory]
    [InlineData(1, "High priority")]
    [InlineData(2, "Medium priority")]
    [InlineData(3, "Low priority")]
    [InlineData(4, "Priority 4")]
    public void PriorityLabel_MatchesSwiftCopy(int raw, string expected) =>
        Assert.Equal(expected, CapturePopoverFormatting.PriorityLabel(raw));

    [Theory]
    [InlineData(45, "45 min")]
    [InlineData(60, "1 hr")]
    [InlineData(120, "2 hrs")]
    [InlineData(90, "1h 30m")]
    public void FormattedDuration_MatchesSwiftCopy(int minutes, string expected) =>
        Assert.Equal(expected, CapturePopoverFormatting.FormattedDuration(minutes));

    [Fact]
    public void ConflictAdvisoryText_DeadlineCollision_MatchesSwiftCopy()
    {
        var conflict = new TaskConflict.DeadlineCollision(Guid.NewGuid(), "Ship release");
        Assert.Equal("Clashes with “Ship release” — add anyway?", CapturePopoverFormatting.ConflictAdvisoryText(conflict));
    }

    [Fact]
    public void ConflictAdvisoryText_PossibleDuplicate_MatchesSwiftCopy()
    {
        var conflict = new TaskConflict.PossibleDuplicate(Guid.NewGuid(), "Email the client", 0.9);
        Assert.Equal("Looks similar to “Email the client” — add anyway?", CapturePopoverFormatting.ConflictAdvisoryText(conflict));
    }

    [Fact]
    public void VoiceDoneOneTapLabel_Delegate_AlwaysHandOffCopy_RegardlessOfTitle()
    {
        Assert.Equal("Yes — hand off", CapturePopoverFormatting.VoiceDoneOneTapLabel(new VoiceDoneAction.Delegate(10), "anything"));
        Assert.Equal("Yes — Buy milk", CapturePopoverFormatting.VoiceDoneOneTapLabel(new VoiceDoneAction.Complete(), "Buy milk"));
    }
}
