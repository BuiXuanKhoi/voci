using Volar.Core;
using Xunit;
using static Volar.Core.Tests.Fixtures;

namespace Volar.Core.Tests;

/// <summary>
/// <see cref="Snapshots.EligibilityDiff"/> (auto-unblock notifications, FR-015) and
/// <see cref="Snapshots.NextResurfaceDate"/> (resurface scheduler, FR-017) — both pure helpers
/// layered on top of the same eligibility rule <see cref="NextTaskSelector.NextTask"/> uses.
/// </summary>
public class SnapshotTests
{
    // MARK: - EligibilityDiff

    // Completing a prerequisite unblocks its TaskDone dependent: the dependent's id appears in the
    // diff, the (already-eligible, now-done) prerequisite does not.
    [Fact]
    public void TaskCompletionUnblocksDependentAppearingInDiff()
    {
        var prerequisite = MakeTask(id: FixedGuid(1), status: TaskState.Todo);
        var dependent = MakeTask(
            id: FixedGuid(2), status: TaskState.Todo, conditions: [new TaskDoneCondition(prerequisite.Id)]);
        TaskSnapshot[] before = [prerequisite, dependent];

        var completedPrerequisite = prerequisite;
        completedPrerequisite.Status = TaskState.Done;
        TaskSnapshot[] after = [completedPrerequisite, dependent];

        var diff = Snapshots.EligibilityDiff(before, after, ReferenceNow);

        Assert.Equal([dependent.Id], diff);
    }

    // Flipping an External condition from unsatisfied to satisfied unblocks the task; it appears
    // in the diff.
    [Fact]
    public void ExternalFlipUnblocksTaskAppearingInDiff()
    {
        var task = MakeTask(
            id: FixedGuid(1), status: TaskState.Todo,
            conditions: [new ExternalCondition("sign-off", false)]);
        TaskSnapshot[] before = [task];

        var flipped = task;
        flipped.Conditions = [new ExternalCondition("sign-off", true)];
        TaskSnapshot[] after = [flipped];

        var diff = Snapshots.EligibilityDiff(before, after, ReferenceNow);

        Assert.Equal([task.Id], diff);
    }

    // Un-completing a prerequisite re-blocks its dependent (a newly-INeligible task); this is
    // never reported by EligibilityDiff, which only reports newly-eligible ids.
    [Fact]
    public void UnCompletingReblocksDependentNotInDiff()
    {
        var prerequisite = MakeTask(id: FixedGuid(1), status: TaskState.Todo);
        var dependent = MakeTask(
            id: FixedGuid(2), status: TaskState.Todo, conditions: [new TaskDoneCondition(prerequisite.Id)]);

        var completedPrerequisite = prerequisite;
        completedPrerequisite.Status = TaskState.Done;
        // Step 1: prerequisite done, dependent eligible.
        TaskSnapshot[] eligibleSnapshot = [completedPrerequisite, dependent];

        // Step 2: prerequisite reopened (un-completed), dependent blocked again.
        var reopenedPrerequisite = prerequisite;
        reopenedPrerequisite.Status = TaskState.Todo;
        TaskSnapshot[] reblockedSnapshot = [reopenedPrerequisite, dependent];

        var diff = Snapshots.EligibilityDiff(eligibleSnapshot, reblockedSnapshot, ReferenceNow);

        Assert.DoesNotContain(dependent.Id, diff);
        // Reopening the prerequisite makes the prerequisite itself newly eligible
        // (ineligible in `before` while done, eligible in `after` as a todo).
        Assert.Equal([prerequisite.Id], diff);
    }

    // A task absent from `before` entirely but eligible in `after` counts as newly eligible.
    [Fact]
    public void TaskAbsentFromBeforeCountsAsNewlyEligible()
    {
        TaskSnapshot[] before = [];
        var addedTask = MakeTask(id: FixedGuid(1), status: TaskState.Todo);
        TaskSnapshot[] after = [addedTask];

        var diff = Snapshots.EligibilityDiff(before, after, ReferenceNow);

        Assert.Equal([addedTask.Id], diff);
    }

    // MARK: - NextResurfaceDate

    [Fact]
    public void NoAfterDateConditionsAnywhereReturnsNull()
    {
        var task = MakeTask(id: FixedGuid(1), status: TaskState.Todo, conditions: [new TaskDoneCondition(FixedGuid(2))]);

        var result = Snapshots.NextResurfaceDate([task], ReferenceNow);

        Assert.Null(result);
    }

    [Fact]
    public void SeveralFutureAfterDatesReturnsEarliest()
    {
        var earliest = DaysFromReferenceNow(1);
        var middle = DaysFromReferenceNow(3);
        var latest = DaysFromReferenceNow(10);

        var taskA = MakeTask(id: FixedGuid(1), status: TaskState.Todo, conditions: [new AfterDateCondition(latest)]);
        var taskB = MakeTask(id: FixedGuid(2), status: TaskState.Todo, conditions: [new AfterDateCondition(earliest)]);
        var taskC = MakeTask(id: FixedGuid(3), status: TaskState.Done, conditions: [new AfterDateCondition(middle)]);

        var result = Snapshots.NextResurfaceDate([taskA, taskB, taskC], ReferenceNow);

        Assert.Equal(earliest, result);
    }

    // Only past (or exactly-now) AfterDate conditions never resurface: they are already satisfied,
    // so NextResurfaceDate must return null.
    [Fact]
    public void PastOnlyAfterDatesReturnsNull()
    {
        var taskA = MakeTask(id: FixedGuid(1), status: TaskState.Todo, conditions: [new AfterDateCondition(Yesterday())]);
        var taskB = MakeTask(id: FixedGuid(2), status: TaskState.Todo, conditions: [new AfterDateCondition(ReferenceNow)]);

        var result = Snapshots.NextResurfaceDate([taskA, taskB], ReferenceNow);

        Assert.Null(result);
    }
}
