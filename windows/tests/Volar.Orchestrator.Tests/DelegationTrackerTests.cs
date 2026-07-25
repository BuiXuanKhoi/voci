using Volar.Core;
using Volar.Domain;
using Xunit;

namespace Volar.Orchestrator.Tests;

public class DelegationTrackerTests
{
    // MARK: - Delegate

    [Fact]
    public void Delegate_AddsWaitingCondition_AndSchedulesCheckBack()
    {
        var store = new FakeOrchestratorTaskStore();
        var task = Fixtures.MakeTask();
        store.AddTask(task);
        var tracker = new DelegationTracker(store);

        tracker.Delegate(task.Id, "build", Fixtures.ReferenceNow, "/proj");

        var updated = store.Get(task.Id)!.Value;
        Assert.Single(updated.Conditions);
        Assert.True(DelegationTracker.IsWaitingOnAI(updated.Conditions[0]));
        Assert.Equal("waiting on AI: build", ((ExternalCondition)updated.Conditions[0]).Description);
        Assert.Equal(1, tracker.WipCount());
    }

    [Fact]
    public void Delegate_DefaultCheckBackIsTenMinutes()
    {
        var store = new FakeOrchestratorTaskStore();
        var task = Fixtures.MakeTask();
        store.AddTask(task);
        var tracker = new DelegationTracker(store);

        tracker.Delegate(task.Id, "build", Fixtures.ReferenceNow, cwdHint: null);

        var due = tracker.DueForRecheck(Fixtures.ReferenceNow.AddMinutes(10));
        Assert.Contains(task.Id, due);
        var notYetDue = tracker.DueForRecheck(Fixtures.ReferenceNow.AddMinutes(5));
        Assert.DoesNotContain(task.Id, notYetDue);
    }

    [Fact]
    public void Delegate_CheckBackMinutesFloorsAtOne()
    {
        var store = new FakeOrchestratorTaskStore();
        var task = Fixtures.MakeTask();
        store.AddTask(task);
        var tracker = new DelegationTracker(store);

        tracker.Delegate(task.Id, "build", Fixtures.ReferenceNow, cwdHint: null, checkBackMinutes: -5);

        var due = tracker.DueForRecheck(Fixtures.ReferenceNow.AddMinutes(1));
        Assert.Contains(task.Id, due);
    }

    [Fact]
    public void Delegate_AlreadyWaiting_DoesNotAddSecondCondition()
    {
        var store = new FakeOrchestratorTaskStore();
        var task = Fixtures.MakeTask(conditions: new Condition[] { Fixtures.WaitingOnAi("first") });
        store.AddTask(task);
        var tracker = new DelegationTracker(store);

        tracker.Delegate(task.Id, "second", Fixtures.ReferenceNow, cwdHint: null);

        var updated = store.Get(task.Id)!.Value;
        Assert.Single(updated.Conditions);
        // The original condition's description is unchanged — re-delegating updates schedule, not the store condition.
        Assert.Equal("waiting on AI: first", ((ExternalCondition)updated.Conditions[0]).Description);
    }

    [Fact]
    public void Delegate_StoreThrows_IsSwallowed_MetaStillScheduled()
    {
        var store = new FakeOrchestratorTaskStore { ThrowOnAddCondition = new InvalidOperationException("boom") };
        var task = Fixtures.MakeTask();
        store.AddTask(task);
        var tracker = new DelegationTracker(store);

        var ex = Record.Exception(() => tracker.Delegate(task.Id, "build", Fixtures.ReferenceNow, cwdHint: "/proj"));

        Assert.Null(ex);
        Assert.Equal("/proj", tracker.CwdHint(task.Id));
    }

    // MARK: - WipCount

    [Fact]
    public void WipCount_CountsOnlyLiveWaitingTasks()
    {
        var store = new FakeOrchestratorTaskStore();
        store.AddTask(Fixtures.MakeTask(id: Fixtures.FixedGuid(1), conditions: new Condition[] { Fixtures.WaitingOnAi("a") }));
        store.AddTask(Fixtures.MakeTask(id: Fixtures.FixedGuid(2), status: TaskState.Done, conditions: new Condition[] { Fixtures.WaitingOnAi("b") }));
        store.AddTask(Fixtures.MakeTask(id: Fixtures.FixedGuid(3), status: TaskState.Archived, conditions: new Condition[] { Fixtures.WaitingOnAi("c") }));
        store.AddTask(Fixtures.MakeTask(id: Fixtures.FixedGuid(4)));
        var tracker = new DelegationTracker(store);

        Assert.Equal(1, tracker.WipCount());
    }

    // MARK: - DueForRecheck / BumpBackoff

    [Fact]
    public void BumpBackoff_FirstBump_MovesToThirtyMinutes()
    {
        var store = new FakeOrchestratorTaskStore();
        var task = Fixtures.MakeTask();
        store.AddTask(task);
        var tracker = new DelegationTracker(store);
        tracker.Delegate(task.Id, "build", Fixtures.ReferenceNow, cwdHint: null);

        tracker.BumpBackoff(task.Id, Fixtures.ReferenceNow.AddMinutes(10));

        Assert.DoesNotContain(task.Id, tracker.DueForRecheck(Fixtures.ReferenceNow.AddMinutes(20)));
        Assert.Contains(task.Id, tracker.DueForRecheck(Fixtures.ReferenceNow.AddMinutes(40)));
    }

    [Fact]
    public void BumpBackoff_TwiceReachesBatchOnly_NeverDueAgain()
    {
        var store = new FakeOrchestratorTaskStore();
        var task = Fixtures.MakeTask();
        store.AddTask(task);
        var tracker = new DelegationTracker(store);
        tracker.Delegate(task.Id, "build", Fixtures.ReferenceNow, cwdHint: null);

        tracker.BumpBackoff(task.Id, Fixtures.ReferenceNow.AddMinutes(10));
        tracker.BumpBackoff(task.Id, Fixtures.ReferenceNow.AddMinutes(40));

        Assert.DoesNotContain(task.Id, tracker.DueForRecheck(DateTimeOffset.MaxValue.AddDays(-1)));
        // But it's still surfaced by the batch-reconcile path (independent of backoff stage).
        Assert.Contains(task.Id, tracker.ReconcileBatch());
    }

    [Fact]
    public void BumpBackoff_UnknownTask_IsNoOp()
    {
        var store = new FakeOrchestratorTaskStore();
        var tracker = new DelegationTracker(store);
        var ex = Record.Exception(() => tracker.BumpBackoff(Fixtures.FixedGuid(1), Fixtures.ReferenceNow));
        Assert.Null(ex);
    }

    [Fact]
    public void DueForRecheck_SelfHealsAgainstCompletedTask_NeverResurfaces()
    {
        var store = new FakeOrchestratorTaskStore();
        var task = Fixtures.MakeTask(conditions: new Condition[] { Fixtures.WaitingOnAi("build") });
        store.AddTask(task);
        var tracker = new DelegationTracker(store);
        tracker.Delegate(task.Id, "build", Fixtures.ReferenceNow, cwdHint: null);

        // Completion path clears the condition WITHOUT going through MarkNeedsReview (mirrors a
        // direct `store.toggle`/`store.delete` completion in the real app).
        store.ClearExternalCondition(DelegationTracker.WaitingPrefix, task.Id);

        var due = tracker.DueForRecheck(Fixtures.ReferenceNow.AddMinutes(15));
        Assert.DoesNotContain(task.Id, due);
    }

    [Fact]
    public void DueForRecheck_OrdersEarliestDueFirst()
    {
        var store = new FakeOrchestratorTaskStore();
        var t1 = Fixtures.MakeTask(id: Fixtures.FixedGuid(1));
        var t2 = Fixtures.MakeTask(id: Fixtures.FixedGuid(2));
        store.AddTask(t1);
        store.AddTask(t2);
        var tracker = new DelegationTracker(store);
        tracker.Delegate(t2.Id, "later", Fixtures.ReferenceNow, cwdHint: null, checkBackMinutes: 20);
        tracker.Delegate(t1.Id, "earlier", Fixtures.ReferenceNow, cwdHint: null, checkBackMinutes: 5);

        var due = tracker.DueForRecheck(Fixtures.ReferenceNow.AddMinutes(30));

        Assert.Equal(new[] { t1.Id, t2.Id }, due);
    }

    // MARK: - MarkNeedsReview

    [Fact]
    public void MarkNeedsReview_ClearsConditionAndMeta_NeverTouchesStatus()
    {
        var store = new FakeOrchestratorTaskStore();
        var task = Fixtures.MakeTask();
        store.AddTask(task);
        var tracker = new DelegationTracker(store);
        tracker.Delegate(task.Id, "build", Fixtures.ReferenceNow, cwdHint: "/proj");

        tracker.MarkNeedsReview(task.Id);

        var updated = store.Get(task.Id)!.Value;
        Assert.False(DelegationTracker.IsWaitingOnAI(updated.Conditions[0]));
        Assert.Equal(TaskState.Todo, updated.Status);
        Assert.Null(tracker.CwdHint(task.Id));
    }

    [Fact]
    public void MarkNeedsReview_NeverDelegated_IsNoOp()
    {
        var store = new FakeOrchestratorTaskStore();
        var task = Fixtures.MakeTask();
        store.AddTask(task);
        var tracker = new DelegationTracker(store);

        var ex = Record.Exception(() => tracker.MarkNeedsReview(task.Id));

        Assert.Null(ex);
        Assert.Equal(TaskState.Todo, store.Get(task.Id)!.Value.Status);
    }

    [Fact]
    public void MarkNeedsReview_Idempotent_SecondCallIsNoOp()
    {
        var store = new FakeOrchestratorTaskStore();
        var task = Fixtures.MakeTask();
        store.AddTask(task);
        var tracker = new DelegationTracker(store);
        tracker.Delegate(task.Id, "build", Fixtures.ReferenceNow, cwdHint: "/proj");

        tracker.MarkNeedsReview(task.Id);
        var ex = Record.Exception(() => tracker.MarkNeedsReview(task.Id));

        Assert.Null(ex);
    }

    // MARK: - ReconcileBatch

    [Fact]
    public void ReconcileBatch_ReturnsAllLiveWaitingTasks_RegardlessOfBackoffStage()
    {
        var store = new FakeOrchestratorTaskStore();
        var task = Fixtures.MakeTask(conditions: new Condition[] { Fixtures.WaitingOnAi("build") });
        store.AddTask(task);
        var tracker = new DelegationTracker(store);

        Assert.Contains(task.Id, tracker.ReconcileBatch());
    }

    // MARK: - IsWaitingOnAI

    [Fact]
    public void IsWaitingOnAI_SatisfiedExternalCondition_ReturnsFalse()
    {
        Assert.False(DelegationTracker.IsWaitingOnAI(new ExternalCondition(DelegationTracker.WaitingPrefix + "x", true)));
    }

    [Fact]
    public void IsWaitingOnAI_WrongPrefix_ReturnsFalse()
    {
        Assert.False(DelegationTracker.IsWaitingOnAI(new ExternalCondition("waiting on legal", false)));
    }

    [Fact]
    public void IsWaitingOnAI_OtherConditionKinds_ReturnFalse()
    {
        Assert.False(DelegationTracker.IsWaitingOnAI(new TaskDoneCondition(Fixtures.FixedGuid(1))));
        Assert.False(DelegationTracker.IsWaitingOnAI(new AfterDateCondition(Fixtures.ReferenceNow)));
    }
}
