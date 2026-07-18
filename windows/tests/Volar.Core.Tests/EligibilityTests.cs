using Volar.Core;
using Xunit;
using static Volar.Core.Tests.Fixtures;

namespace Volar.Core.Tests;

/// <summary>
/// User Story 3 (condition-aware eligibility). Covers the 001 §6.2 #3/#6/#8/#9 scenarios
/// re-expressed with TaskDone conditions (dependsOn -&gt; conditions: [TaskDoneCondition(id)],
/// migrated 1:1 with the same intent and assertions), plus the v2 eligibility surface: AfterDate,
/// External, mixed-condition AND semantics, parent-of-open-child exclusion, and determinism under
/// shuffle at n=500.
/// </summary>
public class EligibilityTests
{
    // MARK: - §6.2 cases migrated from dependsOn to conditions: [TaskDoneCondition(id)]

    // §6.2 #3: a priority-1 task blocked by an unfinished prerequisite is skipped in favor of an
    // eligible task, and becomes selectable once the prerequisite is marked Done.
    [Fact]
    public void BlockedPriorityOneTaskIsSkippedThenUnblocks()
    {
        var prerequisite = MakeTask(id: FixedGuid(1), status: TaskState.Todo, priority: 3);
        var blockedTask = MakeTask(
            id: FixedGuid(2), status: TaskState.Todo, priority: 1,
            conditions: [new TaskDoneCondition(prerequisite.Id)]);
        var fallbackTask = MakeTask(id: FixedGuid(3), status: TaskState.Todo, priority: 4);

        var beforeCompletion = NextTaskSelector.NextTask(
            [prerequisite, blockedTask, fallbackTask], ReferenceNow, TestTimeZone);
        // blockedTask (priority 1) is not eligible yet, so the fallback (priority 4) wins over the
        // unrelated prerequisite (priority 3) — the blocked task must never be chosen.
        Assert.NotEqual(blockedTask.Id, beforeCompletion?.Id);

        var completedPrerequisite = prerequisite;
        completedPrerequisite.Status = TaskState.Done;

        var afterCompletion = NextTaskSelector.NextTask(
            [completedPrerequisite, blockedTask, fallbackTask], ReferenceNow, TestTimeZone);

        Assert.Equal(blockedTask.Id, afterCompletion?.Id);
    }

    // §6.2 #3 (multi-prerequisite variant): a task remains blocked until ALL its TaskDone
    // conditions are resolved, not just some of them.
    [Fact]
    public void TaskWithMultiplePrerequisitesStaysBlockedUntilAllResolved()
    {
        var firstPrerequisite = MakeTask(id: FixedGuid(1), status: TaskState.Done);
        var secondPrerequisite = MakeTask(id: FixedGuid(2), status: TaskState.Todo);
        var dependent = MakeTask(
            id: FixedGuid(3), status: TaskState.Todo, priority: 1,
            conditions: [new TaskDoneCondition(firstPrerequisite.Id), new TaskDoneCondition(secondPrerequisite.Id)]);

        var stillBlocked = NextTaskSelector.NextTask(
            [firstPrerequisite, secondPrerequisite, dependent], ReferenceNow, TestTimeZone);
        Assert.NotEqual(dependent.Id, stillBlocked?.Id);

        var completedSecondPrerequisite = secondPrerequisite;
        completedSecondPrerequisite.Status = TaskState.Done;

        var nowUnblocked = NextTaskSelector.NextTask(
            [firstPrerequisite, completedSecondPrerequisite, dependent], ReferenceNow, TestTimeZone);
        Assert.Equal(dependent.Id, nowUnblocked?.Id);
    }

    // §6.2 #6: completing a task cascades — its dependent, previously blocked, becomes the new
    // NextTask result.
    [Fact]
    public void CompletingTaskCascadesToDependent()
    {
        var prerequisite = MakeTask(id: FixedGuid(1), status: TaskState.Todo, priority: 1);
        var dependent = MakeTask(
            id: FixedGuid(2), status: TaskState.Todo, priority: 1,
            conditions: [new TaskDoneCondition(prerequisite.Id)]);

        var before = NextTaskSelector.NextTask([prerequisite, dependent], ReferenceNow, TestTimeZone);
        Assert.Equal(prerequisite.Id, before?.Id);

        var completedPrerequisite = prerequisite;
        completedPrerequisite.Status = TaskState.Done;

        var after = NextTaskSelector.NextTask([completedPrerequisite, dependent], ReferenceNow, TestTimeZone);

        Assert.Equal(dependent.Id, after?.Id);
    }

    // §6.2 #8: when every task in the set is blocked by an unresolved TaskDone condition, nothing
    // is selected. (Fixture uses a mutual cycle purely to construct "every candidate blocked" —
    // NextTask itself does not assume or enforce acyclicity; that invariant is enforced separately
    // by DependencyGraph.ValidateCondition/WouldCreateCycle at edge-creation time.)
    [Fact]
    public void AllTasksBlockedReturnsNull()
    {
        var taskA = MakeTask(id: FixedGuid(1), status: TaskState.Todo, conditions: [new TaskDoneCondition(FixedGuid(2))]);
        var taskB = MakeTask(id: FixedGuid(2), status: TaskState.Todo, conditions: [new TaskDoneCondition(FixedGuid(3))]);
        var taskC = MakeTask(id: FixedGuid(3), status: TaskState.Todo, conditions: [new TaskDoneCondition(FixedGuid(1))]);

        var result = NextTaskSelector.NextTask([taskA, taskB, taskC], ReferenceNow, TestTimeZone);

        Assert.Null(result);
    }

    // Clarify #9: an archived (not completed) prerequisite still counts as resolved and no longer
    // blocks its dependent.
    [Fact]
    public void ArchivedPrerequisiteUnblocksDependent()
    {
        var archivedPrerequisite = MakeTask(id: FixedGuid(1), status: TaskState.Archived);
        var dependent = MakeTask(
            id: FixedGuid(2), status: TaskState.Todo, priority: 1,
            conditions: [new TaskDoneCondition(archivedPrerequisite.Id)]);

        var result = NextTaskSelector.NextTask([archivedPrerequisite, dependent], ReferenceNow, TestTimeZone);

        Assert.Equal(dependent.Id, result?.Id);
    }

    // A deleted prerequisite (its id is simply absent from the snapshot) also counts as resolved
    // and no longer blocks its dependent.
    [Fact]
    public void DeletedPrerequisiteUnblocksDependent()
    {
        var deletedPrerequisiteId = FixedGuid(99); // never appears in `tasks`
        var dependent = MakeTask(
            id: FixedGuid(2), status: TaskState.Todo, priority: 1,
            conditions: [new TaskDoneCondition(deletedPrerequisiteId)]);

        var result = NextTaskSelector.NextTask([dependent], ReferenceNow, TestTimeZone);

        Assert.Equal(dependent.Id, result?.Id);
    }

    // MARK: - v2: AfterDate

    // now == date counts as satisfied (now >= date), not merely now > date.
    [Fact]
    public void AfterDateSatisfiedAtExactBoundary()
    {
        var task = MakeTask(id: FixedGuid(1), status: TaskState.Todo, conditions: [new AfterDateCondition(ReferenceNow)]);

        var result = NextTaskSelector.NextTask([task], ReferenceNow, TestTimeZone);

        Assert.Equal(task.Id, result?.Id);
    }

    [Fact]
    public void AfterDateInFutureBlocks()
    {
        var task = MakeTask(id: FixedGuid(1), status: TaskState.Todo, conditions: [new AfterDateCondition(Tomorrow())]);

        var result = NextTaskSelector.NextTask([task], ReferenceNow, TestTimeZone);

        Assert.NotEqual(task.Id, result?.Id);
    }

    [Fact]
    public void AfterDateInPastSatisfied()
    {
        var task = MakeTask(id: FixedGuid(1), status: TaskState.Todo, conditions: [new AfterDateCondition(Yesterday())]);

        var result = NextTaskSelector.NextTask([task], ReferenceNow, TestTimeZone);

        Assert.Equal(task.Id, result?.Id);
    }

    // MARK: - v2: External

    [Fact]
    public void ExternalSatisfiedTrueIsEligible()
    {
        var task = MakeTask(
            id: FixedGuid(1), status: TaskState.Todo,
            conditions: [new ExternalCondition("waiting on reply", true)]);

        var result = NextTaskSelector.NextTask([task], ReferenceNow, TestTimeZone);

        Assert.Equal(task.Id, result?.Id);
    }

    [Fact]
    public void ExternalSatisfiedFalseBlocks()
    {
        var task = MakeTask(
            id: FixedGuid(1), status: TaskState.Todo,
            conditions: [new ExternalCondition("waiting on reply", false)]);

        var result = NextTaskSelector.NextTask([task], ReferenceNow, TestTimeZone);

        Assert.NotEqual(task.Id, result?.Id);
    }

    // MARK: - v2: mixed-condition AND semantics

    // One unsatisfied condition blocks even when every other condition on the same task is
    // satisfied.
    [Fact]
    public void MixedConditionsUseAndSemantics()
    {
        var doneePrerequisite = MakeTask(id: FixedGuid(1), status: TaskState.Done);
        var blocked = MakeTask(
            id: FixedGuid(2), status: TaskState.Todo,
            conditions:
            [
                new TaskDoneCondition(doneePrerequisite.Id), // satisfied
                new AfterDateCondition(ReferenceNow), // satisfied (boundary)
                new ExternalCondition("sign-off", false), // unsatisfied
            ]);
        var fallback = MakeTask(id: FixedGuid(3), status: TaskState.Todo);

        var result = NextTaskSelector.NextTask([doneePrerequisite, blocked, fallback], ReferenceNow, TestTimeZone);

        Assert.Equal(fallback.Id, result?.Id);

        // Flipping the last unsatisfied condition makes the task eligible.
        var unblocked = blocked;
        unblocked.Conditions =
        [
            new TaskDoneCondition(doneePrerequisite.Id),
            new AfterDateCondition(ReferenceNow),
            new ExternalCondition("sign-off", true),
        ];
        unblocked.Priority = 1;
        var lowerPriorityFallback = fallback;
        lowerPriorityFallback.Priority = 4;

        var afterFlip = NextTaskSelector.NextTask(
            [doneePrerequisite, unblocked, lowerPriorityFallback], ReferenceNow, TestTimeZone);
        Assert.Equal(unblocked.Id, afterFlip?.Id);
    }

    // MARK: - v2: parent-of-open-child exclusion

    // A parent with >=1 open (todo/inProgress) child is never returned by NextTask, even when that
    // child is itself ineligible (its own conditions block it) — the parent must still be
    // excluded, and neither parent nor blocked child may win over an unrelated eligible task.
    [Fact]
    public void ParentOfOpenChildExcludedEvenWhenChildIneligible()
    {
        var parent = MakeTask(id: FixedGuid(1), title: "Parent", status: TaskState.Todo, priority: 1);
        var ineligibleChild = MakeTask(
            id: FixedGuid(2), title: "Child", status: TaskState.Todo, priority: 1,
            conditions: [new ExternalCondition("blocked", false)],
            parentId: parent.Id);
        var unrelated = MakeTask(id: FixedGuid(3), title: "Unrelated", status: TaskState.Todo, priority: 4);

        var result = NextTaskSelector.NextTask([parent, ineligibleChild, unrelated], ReferenceNow, TestTimeZone);

        Assert.NotEqual(parent.Id, result?.Id);
        Assert.NotEqual(ineligibleChild.Id, result?.Id);
        Assert.Equal(unrelated.Id, result?.Id);
    }

    // A parent becomes selectable once its last open child is no longer open (done/archived), and
    // an eligible child (no open siblings) can itself be selected while the parent is excluded.
    [Fact]
    public void ParentEligibleOnceChildDoneEligibleChildCanWinWhileParentExcluded()
    {
        var parent = MakeTask(id: FixedGuid(1), status: TaskState.Todo, priority: 1);
        var openChild = MakeTask(id: FixedGuid(2), status: TaskState.Todo, priority: 1, parentId: parent.Id);

        var whileChildOpen = NextTaskSelector.NextTask([parent, openChild], ReferenceNow, TestTimeZone);
        // The parent is excluded; the open, unconditioned child is eligible and wins.
        Assert.Equal(openChild.Id, whileChildOpen?.Id);

        var doneChild = openChild;
        doneChild.Status = TaskState.Done;

        var afterChildDone = NextTaskSelector.NextTask([parent, doneChild], ReferenceNow, TestTimeZone);
        Assert.Equal(parent.Id, afterChildDone?.Id);
    }

    // MARK: - v2: determinism under shuffle at n=500

    // A synthetic snapshot of 500 tasks with a mix of statuses, conditions, deadlines, priorities,
    // and parent/child relationships must resolve to the exact same NextTask result regardless of
    // the snapshot's list order.
    [Fact]
    public void NextTaskDeterministicUnderShuffleAtN500()
    {
        var generator = new SeededGenerator(42);
        var snapshot = SyntheticSnapshot.Synthesize(500, ref generator);

        var resultInOrder = NextTaskSelector.NextTask(snapshot, ReferenceNow, TestTimeZone);

        // Run several independent shuffles; every one must agree with the original order.
        for (var trial = 0; trial < 5; trial++)
        {
            var shuffleGenerator = new SeededGenerator((ulong)(1000 + trial));
            var shuffled = SyntheticSnapshot.Shuffled(snapshot, ref shuffleGenerator);
            var resultShuffled = NextTaskSelector.NextTask(shuffled, ReferenceNow, TestTimeZone);
            Assert.Equal(resultInOrder?.Id, resultShuffled?.Id);
        }
    }
}

// MARK: - Deterministic synthetic snapshot generation (n=500 determinism test)

/// <summary>
/// A trivial deterministic pseudo-random generator (linear congruential) so the n=500 determinism
/// test is fully reproducible without relying on a system random source (which would make the test
/// itself nondeterministic, defeating its purpose). Port of Swift's <c>SeededGenerator</c>.
/// </summary>
internal struct SeededGenerator(ulong seed)
{
    private ulong _state = seed + 0x9E3779B97F4A7C15UL;

    public ulong Next()
    {
        _state = (_state * 6364136223846793005UL) + 1442695040888963407UL;
        return _state;
    }
}

/// <summary>
/// Builds a deterministic 500-task synthetic snapshot mixing every eligibility/ordering dimension:
/// statuses, TaskDone/AfterDate/External conditions, deadlines, priorities, and parent/child
/// relationships. Fully determined by the generator's seed. Also provides a seeded Fisher-Yates
/// shuffle so the n=500 determinism test can produce reproducible re-orderings — this shuffle does
/// not need to match Swift's <c>Array.shuffled(using:)</c> algorithm bit-for-bit, only to be *a*
/// deterministic permutation, since the property under test (order-independence of
/// <see cref="NextTaskSelector.NextTask"/>) is verified entirely within this C# test suite.
/// </summary>
internal static class SyntheticSnapshot
{
    public static TaskSnapshot[] Synthesize(int count, ref SeededGenerator generator)
    {
        var tasks = new TaskSnapshot[count];

        for (var index = 0; index < count; index++)
        {
            var id = FixedGuid(index);
            var statusRoll = generator.Next() % 4;
            var status = statusRoll switch
            {
                0 => TaskState.Todo,
                1 => TaskState.InProgress,
                2 => TaskState.Done,
                _ => TaskState.Archived
            };

            var conditions = new List<Condition>();
            if (generator.Next() % 3 == 0 && index > 0)
            {
                // Reference an earlier task by index so TaskDone conditions never form a cycle.
                var referenced = (int)(generator.Next() % (ulong)index);
                conditions.Add(new TaskDoneCondition(FixedGuid(referenced)));
            }
            if (generator.Next() % 5 == 0)
            {
                var offsetDays = (int)(generator.Next() % 10) - 5;
                conditions.Add(new AfterDateCondition(DaysFromReferenceNow(offsetDays)));
            }
            if (generator.Next() % 7 == 0)
            {
                conditions.Add(new ExternalCondition($"ext-{index}", generator.Next() % 2 == 0));
            }

            int? priority = generator.Next() % 4 == 0 ? null : (int)(generator.Next() % 4) + 1;

            var deadlineRoll = generator.Next() % 3;
            DateTimeOffset? deadline = deadlineRoll switch
            {
                0 => null,
                1 => DaysFromReferenceNow((int)(generator.Next() % 6) - 3),
                _ => Tomorrow()
            };

            // Occasionally attach a parent pointing at an earlier task (never a forward or
            // self-reference, so this never forms a ParentId cycle).
            Guid? parentId = index > 0 && generator.Next() % 6 == 0
                ? FixedGuid((int)(generator.Next() % (ulong)index))
                : null;

            var createdAt = DaysFromReferenceNow(-(int)(generator.Next() % 30));

            tasks[index] = MakeTask(
                id: id,
                title: $"Synthetic {index}",
                status: status,
                priority: priority,
                deadline: deadline,
                conditions: conditions,
                parentId: parentId,
                createdAt: createdAt);
        }

        return tasks;
    }

    public static TaskSnapshot[] Shuffled(IReadOnlyList<TaskSnapshot> source, ref SeededGenerator generator)
    {
        var list = new TaskSnapshot[source.Count];
        for (var i = 0; i < source.Count; i++)
        {
            list[i] = source[i];
        }

        for (var i = list.Length - 1; i > 0; i--)
        {
            var j = (int)(generator.Next() % (ulong)(i + 1));
            (list[i], list[j]) = (list[j], list[i]);
        }
        return list;
    }
}
