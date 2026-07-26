// ViewModels/TodayViewModelTests.cs — Wave 4 Stage B1. TodayViewModel (port of TodayView.swift's
// CURRENT NOW/NEXT/LATER spotlight grammar, views-inventory.md §1.16) headlessly against real
// FocusSessionService/CaptureFlowService/DelegationOrchestratorService/AppearanceAndPersistenceService/
// ThemeState instances wired to Volar.App.Tests.Capture's FakeTaskListService (reused per this
// project's "same test assembly, no cross-folder duplication" convention — deliberately importing
// ONLY the Capture namespace's FakeTaskListService here, not Workflow's, to avoid an
// ambiguous-reference collision between the two same-named internal fakes in this one file, mirroring
// CapturePopoverViewModelTests.cs's own precedent).
using Volar.App.Services.State;
using Volar.App.Tests.Capture;
using Volar.App.Tests.State;
using Volar.App.Theme;
using Volar.App.ViewModels;
using Volar.Domain;
using Volar.Speech.Playback;
using Xunit;
using TaskState = Volar.Core.TaskState;

namespace Volar.App.Tests.ViewModels;

public sealed class TodayViewModelTests
{
    private static readonly DateTimeOffset Now = CaptureTestData.Now;

    private sealed record Fixture(
        TodayViewModel ViewModel,
        FakeTaskListService TaskList,
        FocusSessionService Focus,
        CaptureFlowService Capture,
        DelegationOrchestratorService Delegation,
        ThemeState Theme);

    private static Fixture CreateFixture(FakeTaskListService? taskList = null)
    {
        var resolvedTaskList = taskList ?? new FakeTaskListService();
        var clock = new FixedTimeProvider(Now);
        var eligibility = new RecordingEligibilityService();
        var focus = new FocusSessionService(resolvedTaskList, new VoicePlayback());
        var capture = new CaptureFlowService(
            resolvedTaskList,
            eligibility,
            new FakeIntentParser(),
            new FakeSpeechEngineProvider { SelectedEngine = new FakeSpeechEngine() },
            clock,
            new InMemorySettingsStore(),
            repository: null,
            scheduler: null,
            voice: null,
            delegationHandoff: null,
            timeZone: TimeZoneInfo.Utc);
        var delegation = new DelegationOrchestratorService(resolvedTaskList, eligibility, clock);
        var appearance = new AppearanceAndPersistenceService(new InMemorySettingsStore());
        var theme = new ThemeState(appearance);

        var vm = new TodayViewModel(resolvedTaskList, focus, capture, delegation, theme, clock, dispatcherQueue: null);
        return new Fixture(vm, resolvedTaskList, focus, capture, delegation, theme);
    }

    private static async Task WaitUntilAsync(Func<bool> predicate, int timeoutMs = 2000)
    {
        var deadline = DateTime.UtcNow.AddMilliseconds(timeoutMs);
        while (!predicate())
        {
            if (DateTime.UtcNow > deadline)
            {
                throw new TimeoutException("Condition was not met within the timeout.");
            }
            await Task.Delay(5);
        }
    }

    // MARK: - NOW / NEXT / LATER derivation (TodayView.swift:168-187)

    [Fact]
    public void Refresh_WithNoTasks_HasNoSpotlightOrPeek_AndReportsEmpty()
    {
        var f = CreateFixture();

        Assert.False(f.ViewModel.HasOpenTasks);
        Assert.Null(f.ViewModel.NowSpotlight);
        Assert.Null(f.ViewModel.NextPeek);
        Assert.Empty(f.ViewModel.LaterTasks);
        Assert.Equal(0, f.ViewModel.OpenTaskCount);
    }

    [Fact]
    public void Refresh_WithOpenTasks_SplitsIntoNowSpotlight_NextPeek_AndLaterDrawer()
    {
        var taskList = new FakeTaskListService();
        var active = TestTasks.New(title: "now task", createdAt: Now);
        var peek = TestTasks.New(title: "next task", createdAt: Now);
        var later1 = TestTasks.New(title: "later 1", createdAt: Now);
        var later2 = TestTasks.New(title: "later 2", createdAt: Now);
        taskList.BackingTasks.AddRange(new[] { active, peek, later1, later2 });
        taskList.ActiveOverride = active;
        var f = CreateFixture(taskList);

        Assert.True(f.ViewModel.HasOpenTasks);
        Assert.Equal(4, f.ViewModel.OpenTaskCount);
        Assert.NotNull(f.ViewModel.NowSpotlight);
        Assert.Equal("now task", f.ViewModel.NowSpotlight!.Title);
        Assert.NotNull(f.ViewModel.NextPeek);
        Assert.Equal("next task", f.ViewModel.NextPeek!.Title);
        Assert.Equal(2, f.ViewModel.LaterTasks.Count);
        Assert.Equal(new[] { "later 1", "later 2" }, f.ViewModel.LaterTasks.Select(r => r.Title));
    }

    [Fact]
    public void Refresh_WithNoActiveTask_TreatsFirstOpenTaskAsNextPeek_NotNow()
    {
        // TodayView.swift:174-177: `guard let active = appState.activeTask else { return
        // appState.openTasks }` — nothing is excluded when the engine found nothing eligible.
        var taskList = new FakeTaskListService();
        taskList.BackingTasks.Add(TestTasks.New(title: "only open", createdAt: Now));
        taskList.ActiveOverride = null;
        var f = CreateFixture(taskList);

        Assert.Null(f.ViewModel.NowSpotlight);
        Assert.NotNull(f.ViewModel.NextPeek);
        Assert.Equal("only open", f.ViewModel.NextPeek!.Title);
    }

    [Fact]
    public void Refresh_PopulatesCompletedTasks_FromDoneTasks()
    {
        var taskList = new FakeTaskListService();
        taskList.BackingTasks.Add(TestTasks.New(title: "done one", status: TaskState.Done, createdAt: Now));
        var f = CreateFixture(taskList);

        Assert.True(f.ViewModel.HasCompletedTasks);
        Assert.Equal("done one", f.ViewModel.CompletedTasks.Single().Title);
        Assert.Equal(1, f.ViewModel.DoneTaskCount);
    }

    // MARK: - NOW spotlight actions (TodayView.swift's nowSpotlight buttons + context menu)

    [Fact]
    public async Task ToggleActiveDoneAsync_TogglesTheActiveTask()
    {
        var taskList = new FakeTaskListService();
        var active = TestTasks.New(title: "active", createdAt: Now);
        taskList.BackingTasks.Add(active);
        taskList.ActiveOverride = active;
        var f = CreateFixture(taskList);

        await f.ViewModel.ToggleActiveDoneAsync();

        Assert.Equal(new[] { active.Id }, taskList.ToggledIds);
    }

    [Fact]
    public void OpenActiveDetail_RaisesOpenDetailRequested_WithTheActiveTasksId()
    {
        var taskList = new FakeTaskListService();
        var active = TestTasks.New(createdAt: Now);
        taskList.BackingTasks.Add(active);
        taskList.ActiveOverride = active;
        var f = CreateFixture(taskList);
        Guid? raised = null;
        f.ViewModel.OpenDetailRequested += id => raised = id;

        f.ViewModel.OpenActiveDetail();

        Assert.Equal(active.Id, raised);
    }

    [Fact]
    public void RequestActiveBreakdown_RaisesBreakdownRequested_WithTheActiveTasksId()
    {
        var taskList = new FakeTaskListService();
        var active = TestTasks.New(createdAt: Now);
        taskList.BackingTasks.Add(active);
        taskList.ActiveOverride = active;
        var f = CreateFixture(taskList);
        Guid? raised = null;
        f.ViewModel.BreakdownRequested += id => raised = id;

        f.ViewModel.RequestActiveBreakdown();

        Assert.Equal(active.Id, raised);
    }

    [Fact]
    public void OpenActiveDetail_WithNoActiveTask_DoesNotRaise()
    {
        var f = CreateFixture();
        var raised = false;
        f.ViewModel.OpenDetailRequested += _ => raised = true;

        f.ViewModel.OpenActiveDetail();

        Assert.False(raised);
    }

    // MARK: - Row-level events bubble through TodayViewModel (Later/Completed/NextPeek rows)

    [Fact]
    public void LaterRow_OpenDetailRequested_BubblesThroughTodayViewModel()
    {
        var taskList = new FakeTaskListService();
        var active = TestTasks.New(title: "active", createdAt: Now);
        var laterTask = TestTasks.New(title: "later", createdAt: Now);
        taskList.BackingTasks.AddRange(new[] { active, laterTask });
        taskList.ActiveOverride = active;
        var f = CreateFixture(taskList);
        Guid? raised = null;
        f.ViewModel.OpenDetailRequested += id => raised = id;

        // active + peek consumed the first two; nothing left for Later in this 2-task setup, so add
        // one more open task to actually populate the Later drawer.
        taskList.BackingTasks.Add(TestTasks.New(title: "later2", createdAt: Now));
        f.ViewModel.Refresh();
        var laterRow = f.ViewModel.LaterTasks.Single();

        laterRow.OpenDetail();

        Assert.Equal(laterRow.Id, raised);
    }

    // MARK: - Focus pill controls (TodayView.swift:398-454)

    [Fact]
    public void StartFocus_ActivatesFocusSession_AndRefreshesFocusActive()
    {
        var taskList = new FakeTaskListService();
        taskList.BackingTasks.Add(TestTasks.New(title: "a", createdAt: Now));
        var f = CreateFixture(taskList);

        f.ViewModel.StartFocus();

        Assert.True(f.ViewModel.FocusActive);
        f.ViewModel.EndFocus();
    }

    [Fact]
    public void ToggleFocusPause_TogglesFocusPaused()
    {
        var taskList = new FakeTaskListService();
        taskList.BackingTasks.Add(TestTasks.New(title: "a", createdAt: Now));
        var f = CreateFixture(taskList);
        f.ViewModel.StartFocus();

        f.ViewModel.ToggleFocusPause();

        Assert.True(f.ViewModel.FocusPaused);
        f.ViewModel.EndFocus();
    }

    [Fact]
    public void EndFocus_DeactivatesFocusSession()
    {
        var taskList = new FakeTaskListService();
        taskList.BackingTasks.Add(TestTasks.New(title: "a", createdAt: Now));
        var f = CreateFixture(taskList);
        f.ViewModel.StartFocus();

        f.ViewModel.EndFocus();

        Assert.False(f.ViewModel.FocusActive);
    }

    // MARK: - Toolbar (TodayView.swift:71-87)

    [Fact]
    public void ToggleAmbientSound_TogglesTheThemesAmbientSoundState()
    {
        var f = CreateFixture();
        var before = f.ViewModel.IsAmbientSoundPlaying;

        f.ViewModel.ToggleAmbientSound();

        Assert.NotEqual(before, f.ViewModel.IsAmbientSoundPlaying);
    }

    [Fact]
    public async Task ToggleCaptureAsync_StartsCapture_AndUpdatesIsCapturing()
    {
        var f = CreateFixture();
        Assert.False(f.ViewModel.IsCapturing);

        await f.ViewModel.ToggleCaptureAsync();

        Assert.True(f.ViewModel.IsCapturing);
        Assert.Equal("Tap to stop", f.ViewModel.CaptureButtonLabel);
    }

    // MARK: - CaptureFlowService.CaptureChanged wiring (fires off-thread per that class's own header
    // comment — dispatcherQueue: null exercises UiDispatch.Post's inline-execution fallback).

    [Fact]
    public async Task ExternalCaptureChanged_RefreshesIsCapturing_WithoutAnyCommandCalledHere()
    {
        var f = CreateFixture();

        await f.Capture.StartCaptureAsync();

        await WaitUntilAsync(() => f.ViewModel.IsCapturing);
    }

    // MARK: - TasksChanged wiring (a mutation from elsewhere must still refresh this VM)

    [Fact]
    public async Task ExternalTasksChanged_RefreshesOpenTaskCount()
    {
        var taskList = new FakeTaskListService();
        var f = CreateFixture(taskList);
        Assert.Equal(0, f.ViewModel.OpenTaskCount);

        taskList.BackingTasks.Add(TestTasks.New(title: "added elsewhere", createdAt: Now));
        await taskList.RefreshAsync();

        Assert.Equal(1, f.ViewModel.OpenTaskCount);
    }

    // MARK: - Drawer toggles (TodayView.swift:774-782)

    [Fact]
    public void ToggleLaterExpanded_FlipsTheFlag()
    {
        var f = CreateFixture();
        Assert.False(f.ViewModel.LaterExpanded);

        f.ViewModel.ToggleLaterExpanded();
        Assert.True(f.ViewModel.LaterExpanded);

        f.ViewModel.ToggleLaterExpanded();
        Assert.False(f.ViewModel.LaterExpanded);
    }

    [Fact]
    public void ToggleCompletedExpanded_FlipsTheFlag()
    {
        var f = CreateFixture();
        Assert.False(f.ViewModel.CompletedExpanded);

        f.ViewModel.ToggleCompletedExpanded();

        Assert.True(f.ViewModel.CompletedExpanded);
    }

    // MARK: - DelegationAmbientSection (T043, TodayView.swift:796-953)

    [Fact]
    public void ShowWipHint_IsFalseWhenNoDelegationTrackerIsWired()
    {
        // DelegationOrchestratorService.WipCount() degrades to 0 with delegation: null (no
        // DelegationTracker wired in this headless fixture) — mirrors that service's own documented
        // no-op-without-a-tracker convention.
        var f = CreateFixture();

        Assert.Equal(0, f.ViewModel.WipCount);
        Assert.False(f.ViewModel.ShowWipHint);
    }

    [Fact]
    public void DismissWipHint_NeverThrows_EvenWithNothingToDismiss()
    {
        var f = CreateFixture();

        f.ViewModel.DismissWipHint();

        Assert.False(f.ViewModel.ShowWipHint);
    }
}
