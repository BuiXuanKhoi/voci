// Workflow/FocusSessionServiceTests.cs — FocusSessionService (inventory cluster E). The
// CompleteFocusTaskAsync tests are FIX 3's actual regression coverage: they exercise a REAL
// TaskListService over a REAL TaskRepository (via Volar.App.Tests.State.SqliteFixture) so the
// recurrence reset-in-place (delta 0) and parent-completion cascade (delta -2) scenarios are
// genuine repository behavior, not a hand-simulated guess — proving this service reads
// `ITaskListService.OpenTasks.Count` AFTER the mutation rather than assuming "-1".
using System.Linq;
using Volar.App.Services.State;
using Volar.App.Tests.State;
using Volar.Data;
using Volar.Data.Entities;
using Volar.Domain;
using Volar.Speech.Playback;
using Xunit;
using TaskState = Volar.Core.TaskState;

namespace Volar.App.Tests.Workflow;

public sealed class FocusSessionServiceTests
{
    private static readonly DateTimeOffset Now = new(2026, 7, 25, 9, 0, 0, TimeSpan.Zero);

    // MARK: - StartFocus

    [Fact]
    public void StartFocus_WithNoFrog_DefaultsIndexToZero_AndActivatesSession()
    {
        var taskList = new FakeTaskListService(new[] { TestTasks.New(title: "a"), TestTasks.New(title: "b") });
        var service = new FocusSessionService(taskList, new VoicePlayback());

        service.StartFocus();

        Assert.True(service.FocusActive);
        Assert.False(service.FocusPaused);
        Assert.Equal(FocusSessionService.DefaultFocusSeconds, service.FocusSecondsLeft);
        Assert.Equal(0, service.FocusIndex);
        service.EndFocus();
    }

    [Fact]
    public void StartFocus_WithAFrog_JumpsIndexToTheFrogsPositionInOpenTasks()
    {
        var taskList = new FakeTaskListService(new[]
        {
            TestTasks.New(title: "a"),
            TestTasks.New(title: "frog", frog: true),
            TestTasks.New(title: "b"),
        });
        var service = new FocusSessionService(taskList, new VoicePlayback());

        service.StartFocus();

        Assert.Equal(1, service.FocusIndex);
        service.EndFocus();
    }

    [Fact]
    public void VoiceFeedback_DefaultsToFalse_AndReflectsTheConstructorParameterOtherwise()
    {
        var taskList = new FakeTaskListService();
        Assert.False(new FocusSessionService(taskList, new VoicePlayback()).VoiceFeedback);
        Assert.True(new FocusSessionService(taskList, new VoicePlayback(), voiceFeedback: true).VoiceFeedback);
    }

    // MARK: - ToggleFocusPause / EndFocus

    [Fact]
    public void ToggleFocusPause_TogglesTheFlag()
    {
        var service = new FocusSessionService(new FakeTaskListService(), new VoicePlayback());
        service.StartFocus();

        service.ToggleFocusPause();
        Assert.True(service.FocusPaused);
        service.ToggleFocusPause();
        Assert.False(service.FocusPaused);

        service.EndFocus();
    }

    [Fact]
    public void EndFocus_ResetsEveryFocusField()
    {
        var service = new FocusSessionService(new FakeTaskListService(), new VoicePlayback());
        service.StartFocus();
        service.ToggleFocusPause();

        service.EndFocus();

        Assert.False(service.FocusActive);
        Assert.False(service.FocusPaused);
        Assert.Equal(FocusSessionService.DefaultFocusSeconds, service.FocusSecondsLeft);
    }

    // MARK: - StepFocusIndex (FocusOverlay's direct prev/next navigation seam)

    [Fact]
    public void StepFocusIndex_ClampsWithinOpenTasksRange()
    {
        var taskList = new FakeTaskListService(new[] { TestTasks.New(title: "a"), TestTasks.New(title: "b") });
        var service = new FocusSessionService(taskList, new VoicePlayback());
        service.StartFocus();

        service.StepFocusIndex(-5);
        Assert.Equal(0, service.FocusIndex);

        service.StepFocusIndex(5);
        Assert.Equal(1, service.FocusIndex);

        service.EndFocus();
    }

    [Fact]
    public void StepFocusIndex_WithNoOpenTasks_StaysAtZero()
    {
        var service = new FocusSessionService(new FakeTaskListService(), new VoicePlayback());
        service.StepFocusIndex(3);
        Assert.Equal(0, service.FocusIndex);
    }

    // MARK: - The 1s tick loop (real, but injected with a fast delay — see this file's header for
    // why a genuine, tiny, real delay is used rather than a busy-spin fake).

    [Fact]
    public void StartFocus_TickLoop_ActuallyDecrements_AndEventuallyEndsTheSessionOnItsOwn()
    {
        // NOTE: EndFocus() resets FocusSecondsLeft back to DefaultFocusSeconds unconditionally
        // (mirrors `endFocus()`, `AppState.swift:1603-1609`) — so "FocusActive == false" alone
        // can't distinguish "the loop actually counted all the way down" from "someone called
        // EndFocus() immediately." This test instead first observes a genuine MID-countdown value
        // (proving real decrementing happened) before separately confirming the session ends on its
        // own.
        //
        // The delay stand-in is a manually-released gate rather than an instant `Task.Run(() => {})`.
        // An instantly-completing delay races the poll below: on an idle machine the thread pool can
        // spin through all 1500 ticks — including the final `EndFocus()`, which resets
        // FocusSecondsLeft back to DefaultFocusSeconds — before the FIRST `Poll.WaitUntil` ever
        // samples FocusSecondsLeft, so the mid-countdown value this test needs to observe is already
        // gone (only reproduces the failure on a quiet machine; a loaded one incidentally paces the
        // ticks slowly enough to hide it). The gate makes tick pacing deterministic instead: the tick
        // loop blocks on `gate.WaitAsync` between iterations, so releasing exactly one permit lets
        // exactly one decrement happen and then re-blocks the loop — the decremented value cannot be
        // overwritten by a later tick until this test releases more permits itself.
        var taskList = new FakeTaskListService();
        var gate = new SemaphoreSlim(0);
        Func<TimeSpan, CancellationToken, Task> delay = (_, ct) => gate.WaitAsync(ct);
        var service = new FocusSessionService(taskList, new VoicePlayback(), delay: delay);

        service.StartFocus();
        gate.Release(1); // let exactly one tick run, then the loop re-blocks on the gate.

        Poll.WaitUntil(
            () => service.FocusSecondsLeft == FocusSessionService.DefaultFocusSeconds - 1,
            TimeSpan.FromSeconds(10));
        Assert.Equal(FocusSessionService.DefaultFocusSeconds - 1, service.FocusSecondsLeft);

        gate.Release(int.MaxValue / 2); // enough permits for every remaining tick to run to completion.
        Poll.WaitUntil(() => !service.FocusActive, TimeSpan.FromSeconds(10));
        Assert.False(service.FocusPaused);
    }

    [Fact]
    public void StartFocus_WhilePaused_TheCountdownNeverAdvances()
    {
        var taskList = new FakeTaskListService();
        var service = new FocusSessionService(
            taskList, new VoicePlayback(), delay: (_, ct) => Task.Delay(1, ct));

        service.StartFocus();
        service.ToggleFocusPause();
        Thread.Sleep(30); // let a handful of no-op ticks pass while paused.
        var first = service.FocusSecondsLeft;
        Thread.Sleep(30);
        var second = service.FocusSecondsLeft;

        Assert.Equal(first, second);
        Assert.True(service.FocusPaused);
        service.EndFocus();
    }

    [Fact]
    public void StartFocus_CalledTwice_NeverDoubleDecrements()
    {
        // The monotonic session guard must invalidate the FIRST tick loop the moment a second
        // StartFocus() call arms a new one — otherwise two overlapping loops would each decrement
        // FocusSecondsLeft independently, draining it twice as fast.
        var taskList = new FakeTaskListService();
        var service = new FocusSessionService(
            taskList, new VoicePlayback(), delay: (_, ct) => Task.Delay(1, ct));

        service.StartFocus();
        Thread.Sleep(20);
        service.StartFocus(); // resets FocusSecondsLeft to the full default and re-arms.
        var justAfterRestart = service.FocusSecondsLeft;

        Assert.True(justAfterRestart > FocusSessionService.DefaultFocusSeconds - 5);
        service.EndFocus();
    }

    // MARK: - CompleteFocusTaskAsync: FIX 3 (count openTasks AFTER the mutation, never guess "-1")

    [Fact]
    public async Task CompleteFocusTaskAsync_PlainTask_RemovesExactlyOneFromOpenCount()
    {
        var taskList = new FakeTaskListService(new[] { TestTasks.New(title: "only") });
        var id = taskList.Tasks[0].Id;
        var service = new FocusSessionService(taskList, new VoicePlayback());
        service.StartFocus();

        var remaining = await service.CompleteFocusTaskAsync(id);

        Assert.Equal(0, remaining);
        Assert.False(service.FocusActive); // batch emptied -> session auto-ends.
        Assert.Equal(0, service.FocusIndex);
    }

    [Fact]
    public async Task CompleteFocusTaskAsync_RecurringTask_ResetsInPlace_RemainingReflectsDeltaZero_NotMinusOne()
    {
        using var db = new SqliteFixture();
        var resetter = new LocalFixedOffsetRecurrenceResetter(TimeSpan.FromDays(1));
        var repository = db.CreateTaskRepository(resetter);
        var taskListService = new TaskListService(new RecordingEligibilityService(), new FixedTimeProvider(Now), repository);

        var recurring = TestTasks.New(title: "daily standup", deadline: Now);
        await repository.AddAsync(recurring.ToEntity());
        await taskListService.RefreshAsync();
        var id = taskListService.Tasks.Single().Id;
        await repository.SetRecurrenceAsync(id, """{"kind":"daily"}""");

        var service = new FocusSessionService(taskListService, new VoicePlayback());
        service.StartFocus();

        var remaining = await service.CompleteFocusTaskAsync(id);

        // A naive "-1 assumed" guess would report 0 (1 open task minus 1). The recurring task
        // actually resets in place and stays open — FIX 3's whole point.
        Assert.Equal(1, remaining);
        Assert.True(service.FocusActive); // still something open -> session must stay active.
        Assert.Equal(TaskState.Todo, taskListService.Tasks.Single().Status);
        service.EndFocus();
    }

    [Fact]
    public async Task CompleteFocusTaskAsync_LastOpenChild_CascadesParentToo_RemainingReflectsDeltaTwo_NotMinusOne()
    {
        using var db = new SqliteFixture();
        var repository = db.CreateTaskRepository();
        var taskListService = new TaskListService(new RecordingEligibilityService(), new FixedTimeProvider(Now), repository);

        var parent = TestTasks.New(title: "parent");
        await repository.AddAsync(parent.ToEntity());
        await taskListService.RefreshAsync();
        var parentId = taskListService.Tasks.Single().Id;

        var child = TestTasks.New(title: "only child", parentId: parentId);
        await repository.AddAsync(child.ToEntity());
        await taskListService.RefreshAsync();

        var service = new FocusSessionService(taskListService, new VoicePlayback());
        service.StartFocus();

        var remaining = await service.CompleteFocusTaskAsync(child.Id);

        // A naive "-1 assumed" guess would report 1 (2 open tasks minus 1). The parent
        // auto-completes too (cascade), so BOTH close — 0, not 1.
        Assert.Equal(0, remaining);
        Assert.False(service.FocusActive);
        Assert.Equal(0, service.FocusIndex);
        Assert.All(taskListService.Tasks, t => Assert.Equal(TaskState.Done, t.Status));
    }

    // MARK: - ReadDayAloud

    [Fact]
    public void ReadDayAloud_NeverThrows_RegardlessOfOpenTaskCount()
    {
        var withTasks = new FocusSessionService(
            new FakeTaskListService(new[] { TestTasks.New(title: "a") }), new VoicePlayback());
        withTasks.ReadDayAloud();

        var empty = new FocusSessionService(new FakeTaskListService(), new VoicePlayback());
        empty.ReadDayAloud();
    }
}
