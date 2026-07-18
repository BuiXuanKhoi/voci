using Volar.Core;
using Xunit;
using static Volar.Core.Tests.Fixtures;

namespace Volar.Core.Tests;

/// <summary>
/// User Story 2 (auto-advance on completion). At the engine level, "auto-advance" is simply
/// re-invoking <see cref="NextTaskSelector.NextTask"/> with an updated snapshot in which the
/// previously active task's status has been flipped to Done — the engine has no notion of history
/// or an "active" task, so this is exercised purely by comparing two calls against two snapshots.
/// </summary>
public class AutoAdvanceTests
{
    // US2 acceptance scenario 1: completing the active task advances selection to the next
    // correct eligible task.
    [Fact]
    public void CompletingActiveTaskAdvancesToNextTask()
    {
        var activeTask = MakeTask(id: FixedGuid(1), status: TaskState.InProgress, priority: 2);
        var nextEligibleTask = MakeTask(id: FixedGuid(2), status: TaskState.Todo, priority: 1);

        var before = NextTaskSelector.NextTask([activeTask, nextEligibleTask], ReferenceNow, TestTimeZone);
        Assert.Equal(activeTask.Id, before?.Id);

        var completedActiveTask = activeTask;
        completedActiveTask.Status = TaskState.Done;

        var after = NextTaskSelector.NextTask([completedActiveTask, nextEligibleTask], ReferenceNow, TestTimeZone);

        Assert.Equal(nextEligibleTask.Id, after?.Id);
    }

    // US2 acceptance scenario 3: completing the only eligible task leaves nothing selected.
    [Fact]
    public void CompletingSoleEligibleTaskReturnsNull()
    {
        var onlyTask = MakeTask(id: FixedGuid(1), status: TaskState.Todo, priority: 1);

        var before = NextTaskSelector.NextTask([onlyTask], ReferenceNow, TestTimeZone);
        Assert.Equal(onlyTask.Id, before?.Id);

        var completedOnlyTask = onlyTask;
        completedOnlyTask.Status = TaskState.Done;

        var after = NextTaskSelector.NextTask([completedOnlyTask], ReferenceNow, TestTimeZone);

        Assert.Null(after);
    }
}
