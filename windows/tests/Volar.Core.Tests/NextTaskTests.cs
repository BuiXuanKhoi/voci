using Volar.Core;
using Xunit;
using static Volar.Core.Tests.Fixtures;

namespace Volar.Core.Tests;

/// <summary>
/// §6.2 ordering &amp; determinism scenarios, plus FR-007 and the clarified multiple-in-progress
/// case. Dependency/eligibility-focused scenarios (#3, #6, #8, #9, deleted-prerequisite) live in
/// <see cref="EligibilityTests"/>; auto-advance scenarios live in <see cref="AutoAdvanceTests"/>;
/// cycle scenarios live in <see cref="DependencyGraphTests"/>.
/// </summary>
public class NextTaskTests
{
    // §6.2 #1: in-progress beats a higher-priority (numerically lower) to-do task.
    [Fact]
    public void InProgressBeatsHigherPriorityTodo()
    {
        var inProgress = MakeTask(id: FixedGuid(1), status: TaskState.InProgress, priority: 3);
        var higherPriorityTodo = MakeTask(id: FixedGuid(2), status: TaskState.Todo, priority: 1);

        var result = NextTaskSelector.NextTask([inProgress, higherPriorityTodo], ReferenceNow, TestTimeZone);

        Assert.Equal(inProgress.Id, result?.Id);
    }

    // §6.2 #2: an overdue deadline beats a priority-1 task with no deadline.
    [Fact]
    public void OverdueBeatsPriorityOneNoDeadline()
    {
        var overdue = MakeTask(id: FixedGuid(1), status: TaskState.Todo, priority: 4, deadline: Yesterday());
        var priorityOneNoDeadline = MakeTask(id: FixedGuid(2), status: TaskState.Todo, priority: 1, deadline: null);

        var result = NextTaskSelector.NextTask([overdue, priorityOneNoDeadline], ReferenceNow, TestTimeZone);

        Assert.Equal(overdue.Id, result?.Id);
    }

    // §6.2 #7: a deadline of tomorrow must NOT outrank an explicit priority-1 task due today (i.e.
    // with no near-term deadline of its own). Only today/overdue deadlines get tier-2 precedence.
    [Fact]
    public void DeadlineTomorrowDoesNotOutrankPriorityToday()
    {
        var deadlineTomorrow = MakeTask(id: FixedGuid(1), status: TaskState.Todo, priority: 4, deadline: Tomorrow());
        var priorityOneNoDeadline = MakeTask(id: FixedGuid(2), status: TaskState.Todo, priority: 1, deadline: null);

        var result = NextTaskSelector.NextTask([deadlineTomorrow, priorityOneNoDeadline], ReferenceNow, TestTimeZone);

        Assert.Equal(priorityOneNoDeadline.Id, result?.Id);
    }

    // §6.2 #4: two tasks equal on every ordering dimension except id resolve via the stable
    // id-ordinal tiebreak, and the result does not depend on input order (SC-001).
    [Fact]
    public void IdenticalTasksResolveViaStableIdTiebreak()
    {
        var taskA = MakeTask(id: FixedGuid(1), status: TaskState.Todo, priority: 2, deadline: null, createdAt: ReferenceNow);
        var taskB = MakeTask(id: FixedGuid(2), status: TaskState.Todo, priority: 2, deadline: null, createdAt: ReferenceNow);

        var resultInOrder = NextTaskSelector.NextTask([taskA, taskB], ReferenceNow, TestTimeZone);
        var resultShuffled = NextTaskSelector.NextTask([taskB, taskA], ReferenceNow, TestTimeZone);

        Assert.Equal(taskA.Id, resultInOrder?.Id);
        Assert.Equal(taskA.Id, resultShuffled?.Id);
        Assert.Equal(resultInOrder?.Id, resultShuffled?.Id);
    }

    // FR-007: a null-priority task must sort after an explicit priority-4 task (unset priority is
    // never treated as a number, and never outranks any explicit priority).
    [Fact]
    public void NullPrioritySortsAfterExplicitPriorityFour()
    {
        var priorityFour = MakeTask(id: FixedGuid(1), status: TaskState.Todo, priority: 4);
        var noPriority = MakeTask(id: FixedGuid(2), status: TaskState.Todo, priority: null);

        var result = NextTaskSelector.NextTask([priorityFour, noPriority], ReferenceNow, TestTimeZone);

        Assert.Equal(priorityFour.Id, result?.Id);
    }

    // Clarify #10: multiple simultaneously in-progress tasks still yield a single, stable result —
    // tier 1 groups them, and tiers 2-5 disambiguate deterministically.
    [Fact]
    public void MultipleInProgressYieldsSingleStableResult()
    {
        var inProgressLowerPriority = MakeTask(id: FixedGuid(1), status: TaskState.InProgress, priority: 2);
        var inProgressHigherPriority = MakeTask(id: FixedGuid(2), status: TaskState.InProgress, priority: 1);

        var resultInOrder = NextTaskSelector.NextTask(
            [inProgressLowerPriority, inProgressHigherPriority], ReferenceNow, TestTimeZone);
        var resultShuffled = NextTaskSelector.NextTask(
            [inProgressHigherPriority, inProgressLowerPriority], ReferenceNow, TestTimeZone);

        Assert.Equal(inProgressHigherPriority.Id, resultInOrder?.Id);
        Assert.Equal(inProgressHigherPriority.Id, resultShuffled?.Id);
    }

    [Fact]
    public void EmptyTaskSetReturnsNull()
    {
        var result = NextTaskSelector.NextTask([], ReferenceNow, TestTimeZone);

        Assert.Null(result);
    }

    [Fact]
    public void AllDoneOrArchivedReturnsNull()
    {
        var doneTask = MakeTask(id: FixedGuid(1), status: TaskState.Done);
        var archivedTask = MakeTask(id: FixedGuid(2), status: TaskState.Archived);

        var result = NextTaskSelector.NextTask([doneTask, archivedTask], ReferenceNow, TestTimeZone);

        Assert.Null(result);
    }
}
