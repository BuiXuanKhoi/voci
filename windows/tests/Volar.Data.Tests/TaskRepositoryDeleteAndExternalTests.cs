// TaskRepositoryDeleteAndExternalTests.cs — Rule 4 (delete strips references + reports newly-
// eligible tasks) and the external-condition-clearing surface (T036 / FIX 1).
using Volar.Core;
using Volar.Data.Entities;
using Xunit;

namespace Volar.Data.Tests;

public sealed class TaskRepositoryDeleteAndExternalTests
{
    [Fact]
    public async Task Rule4_DeleteUnknownId_ReturnsEmptyAndIsANoOp()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();
        var a = Fixtures.NewTask(title: "A");
        await repo.AddAsync(a);

        var newlyEligible = await repo.DeleteAsync(Guid.NewGuid());

        Assert.Empty(newlyEligible);
        Assert.Single(await repo.GetAllAsync());
    }

    [Fact]
    public async Task Rule4_Delete_RemovesTheTaskRow()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();
        var a = Fixtures.NewTask(title: "A");
        await repo.AddAsync(a);

        await repo.DeleteAsync(a.Id);

        Assert.Empty(await repo.GetAllAsync());
    }

    [Fact]
    public async Task Rule4_Delete_StripsTaskDoneConditionsReferencingDeletedId_AndReportsNewlyEligible()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();
        var blocker = Fixtures.NewTask(title: "Blocker");
        await repo.AddAsync(blocker);
        var dependent = Fixtures.NewTask(title: "Dependent", conditions: [new TaskDoneCondition(blocker.Id)]);
        await repo.AddAsync(dependent);

        var newlyEligible = await repo.DeleteAsync(blocker.Id);

        Assert.Contains(dependent.Id, newlyEligible);
        var storedDependent = (await repo.GetAllAsync()).Single(t => t.Id == dependent.Id);
        Assert.Empty(storedDependent.Conditions);
    }

    [Fact]
    public async Task Rule4_Delete_NullsChildrensParentId()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();
        var parent = Fixtures.NewTask(title: "Parent");
        await repo.AddAsync(parent);
        var child = Fixtures.NewTask(title: "Child", parentId: parent.Id);
        await repo.AddAsync(child);

        await repo.DeleteAsync(parent.Id);

        Assert.Null((await repo.GetAllAsync()).Single(t => t.Id == child.Id).ParentId);
    }

    [Fact]
    public async Task Rule4_Delete_LeavesUnrelatedConditionsAlone()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();
        var unrelatedTarget = Fixtures.NewTask(title: "Unrelated target");
        await repo.AddAsync(unrelatedTarget);
        var toDelete = Fixtures.NewTask(title: "To delete");
        await repo.AddAsync(toDelete);
        var dependent = Fixtures.NewTask(
            title: "Dependent",
            conditions: [new TaskDoneCondition(unrelatedTarget.Id), new ExternalCondition("waiting", Satisfied: false)]);
        await repo.AddAsync(dependent);

        await repo.DeleteAsync(toDelete.Id);

        var storedDependent = (await repo.GetAllAsync()).Single(t => t.Id == dependent.Id);
        Assert.Equal(2, storedDependent.Conditions.Count);
    }

    [Fact]
    public async Task ClearFirstExternalConditionAsync_ClearsFirstUnsatisfiedExternal_InListOrder()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();
        var task = Fixtures.NewTask(
            title: "Waiting on two things",
            conditions:
            [
                new ExternalCondition("waiting on legal", Satisfied: false),
                new ExternalCondition("waiting on design", Satisfied: false),
            ]);
        await repo.AddAsync(task);

        await repo.ClearFirstExternalConditionAsync(task.Id);

        var stored = (await repo.GetAllAsync()).Single().Conditions.OrderBy(c => c.OrderIndex).ToList();
        Assert.True(stored[0].ExternalSatisfied);
        Assert.False(stored[1].ExternalSatisfied);
    }

    [Fact]
    public async Task ClearFirstExternalConditionAsync_WhenNothingUnsatisfied_ReturnsEmpty()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();
        var task = Fixtures.NewTask(title: "Nothing waiting");
        await repo.AddAsync(task);

        var result = await repo.ClearFirstExternalConditionAsync(task.Id);

        Assert.Empty(result);
    }

    [Fact]
    public async Task ClearFirstExternalConditionAsync_UnblocksAndReportsNewlyEligible()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();
        var task = Fixtures.NewTask(
            title: "Blocked",
            conditions: [new ExternalCondition("waiting on AI: summary", Satisfied: false)]);
        await repo.AddAsync(task);

        var newlyEligible = await repo.ClearFirstExternalConditionAsync(task.Id);

        Assert.Contains(task.Id, newlyEligible);
    }

    [Fact]
    public async Task ClearExternalConditionAsync_OnlyMatchesMatchingPrefix()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();
        var task = Fixtures.NewTask(
            title: "Two waits",
            conditions:
            [
                new ExternalCondition("waiting on legal: contract", Satisfied: false),
                new ExternalCondition("waiting on AI: summary", Satisfied: false),
            ]);
        await repo.AddAsync(task);

        // FIX 1: an inbound AI-delegation signal must only ever clear the condition IT owns
        // ("waiting on AI: "), never a human-tracked gate that happens to be first in the list.
        await repo.ClearExternalConditionAsync("waiting on AI: ", task.Id);

        var stored = (await repo.GetAllAsync()).Single().Conditions;
        var legal = stored.Single(c => c.ExternalDescription == "waiting on legal: contract");
        var ai = stored.Single(c => c.ExternalDescription == "waiting on AI: summary");
        Assert.False(legal.ExternalSatisfied);
        Assert.True(ai.ExternalSatisfied);
    }

    [Fact]
    public async Task ClearExternalConditionAsync_NoMatch_ReturnsEmptyAndLeavesConditionsUnchanged()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();
        var task = Fixtures.NewTask(
            title: "One wait",
            conditions: [new ExternalCondition("waiting on legal: contract", Satisfied: false)]);
        await repo.AddAsync(task);

        var result = await repo.ClearExternalConditionAsync("waiting on AI: ", task.Id);

        Assert.Empty(result);
        Assert.False((await repo.GetAllAsync()).Single().Conditions.Single().ExternalSatisfied);
    }
}
