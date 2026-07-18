using Volar.Core;
using Xunit;
using static Volar.Core.Tests.Fixtures;

namespace Volar.Core.Tests;

/// <summary>
/// User Story 4 (reject <see cref="TaskDoneCondition"/> cycles): §6.2 #5, a longer chain variant,
/// self-reference, a valid non-closing edge, and proof that <see cref="AfterDateCondition"/>/
/// <see cref="ExternalCondition"/> never participate in cycle validation.
/// </summary>
public class DependencyGraphTests
{
    /// <summary>
    /// Runs <paramref name="body"/>, returning the thrown <see cref="DependencyError"/> if any, or
    /// <see langword="null"/> if it completed without throwing. Kept as an explicit try/catch
    /// (rather than relying on <c>Assert.Throws</c>) so both "throws this exact error" and "does
    /// not throw" are asserted the same straightforward way — port of Swift's
    /// <c>capturedDependencyError</c>.
    /// </summary>
    private static DependencyError? CapturedDependencyError(Action body)
    {
        try
        {
            body();
            return null;
        }
        catch (DependencyException ex)
        {
            return ex.Error;
        }
    }

    // §6.2 #5: A already has a TaskDone(B) condition; attempting to add TaskDone(A) to B is
    // rejected as a direct cycle (A -> B -> A).
    [Fact]
    public void DirectCycleIsRejected()
    {
        var taskB = MakeTask(id: FixedGuid(2), title: "B");
        var taskA = MakeTask(id: FixedGuid(1), title: "A", conditions: [new TaskDoneCondition(taskB.Id)]);
        TaskSnapshot[] tasks = [taskA, taskB];

        Assert.True(DependencyGraph.WouldCreateCycle(taskB.Id, taskA.Id, tasks));

        var error = CapturedDependencyError(() =>
            DependencyGraph.ValidateCondition(new TaskDoneCondition(taskA.Id), taskB.Id, tasks));

        Assert.Equal(new DependencyError.Cycle("B", "A"), error!);
    }

    // Transitive chain: A -> B -> C (via TaskDone); attempting to add TaskDone(A) to C is rejected
    // as a cycle (A -> B -> C -> A).
    [Fact]
    public void TransitiveChainCycleIsRejected()
    {
        var taskC = MakeTask(id: FixedGuid(3), title: "C");
        var taskB = MakeTask(id: FixedGuid(2), title: "B", conditions: [new TaskDoneCondition(taskC.Id)]);
        var taskA = MakeTask(id: FixedGuid(1), title: "A", conditions: [new TaskDoneCondition(taskB.Id)]);
        TaskSnapshot[] tasks = [taskA, taskB, taskC];

        Assert.True(DependencyGraph.WouldCreateCycle(taskC.Id, taskA.Id, tasks));

        var error = CapturedDependencyError(() =>
            DependencyGraph.ValidateCondition(new TaskDoneCondition(taskA.Id), taskC.Id, tasks));

        Assert.Equal(new DependencyError.Cycle("C", "A"), error!);
    }

    // Self-reference: a task cannot have a TaskDone condition pointing at itself.
    [Fact]
    public void SelfReferenceIsRejected()
    {
        var taskA = MakeTask(id: FixedGuid(1), title: "A");
        TaskSnapshot[] tasks = [taskA];

        Assert.True(DependencyGraph.WouldCreateCycle(taskA.Id, taskA.Id, tasks));

        var error = CapturedDependencyError(() =>
            DependencyGraph.ValidateCondition(new TaskDoneCondition(taskA.Id), taskA.Id, tasks));

        Assert.Equal(new DependencyError.SelfDependency("A"), error!);
    }

    // A valid new TaskDone condition that does not close a loop is accepted (no throw).
    [Fact]
    public void ValidNonClosingEdgeIsAccepted()
    {
        var taskA = MakeTask(id: FixedGuid(1), title: "A");
        var taskB = MakeTask(id: FixedGuid(2), title: "B");
        TaskSnapshot[] tasks = [taskA, taskB];

        Assert.False(DependencyGraph.WouldCreateCycle(taskA.Id, taskB.Id, tasks));

        var error = CapturedDependencyError(() =>
            DependencyGraph.ValidateCondition(new TaskDoneCondition(taskB.Id), taskA.Id, tasks));

        Assert.Null(error);
    }

    // AfterDate and External never carry a graph edge, so they can never throw — even when the
    // snapshot already contains an unrelated TaskDone cycle, and even for a "self"-shaped payload
    // that would be rejected if it were TaskDone.
    [Fact]
    public void AfterDateNeverThrows()
    {
        var taskA = MakeTask(id: FixedGuid(1), title: "A", conditions: [new TaskDoneCondition(FixedGuid(2))]);
        var taskB = MakeTask(id: FixedGuid(2), title: "B", conditions: [new TaskDoneCondition(FixedGuid(1))]);
        TaskSnapshot[] tasks = [taskA, taskB];

        var error = CapturedDependencyError(() =>
            DependencyGraph.ValidateCondition(new AfterDateCondition(ReferenceNow), taskA.Id, tasks));

        Assert.Null(error);
    }

    [Fact]
    public void ExternalNeverThrows()
    {
        var taskA = MakeTask(id: FixedGuid(1), title: "A", conditions: [new TaskDoneCondition(FixedGuid(2))]);
        var taskB = MakeTask(id: FixedGuid(2), title: "B", conditions: [new TaskDoneCondition(FixedGuid(1))]);
        TaskSnapshot[] tasks = [taskA, taskB];

        var error = CapturedDependencyError(() =>
            DependencyGraph.ValidateCondition(
                new ExternalCondition("waiting", false), taskA.Id, tasks));

        Assert.Null(error);
    }
}
