// ValidationRuleTests.cs — the 6 persistence validation rules TaskStore.swift enforces (see that
// file's header comment), each exercised as both a PASS case (the mutation succeeds) and a BLOCKED
// case (the mutation throws the matching TaskRepositoryException subtype) wherever the rule can be
// violated. Rules 4 and 5 are behavioral (delete reference-stripping; completion cascade) rather
// than throwing, so they're covered by "does the expected side effect happen" assertions instead —
// see TaskRepositoryDeleteTests.cs / TaskRepositoryCompletionTests.cs for those.
using Volar.Core;
using Volar.Data.Entities;
using Volar.Data.Exceptions;
using Xunit;

namespace Volar.Data.Tests;

public sealed class ValidationRuleTests
{
    // Rule 1 — AddConditionAsync: a `.taskDone` condition must not self-reference or close a cycle.
    // `.afterDate` / `.external` never throw.

    [Fact]
    public async Task Rule1_Pass_TaskDoneConditionOnUnrelatedTask_Attaches()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();
        var a = Fixtures.NewTask(title: "A");
        var b = Fixtures.NewTask(title: "B");
        await repo.AddBatchAsync([a, b]);

        await repo.AddConditionAsync(a.Id, new TaskDoneCondition(b.Id));

        var stored = (await repo.GetAllAsync()).Single(t => t.Id == a.Id);
        var condition = Assert.Single(stored.Conditions);
        Assert.Equal(b.Id, condition.TaskDoneTargetId);
    }

    [Fact]
    public async Task Rule1_Pass_AfterDateAndExternalConditions_NeverThrow()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();
        var a = Fixtures.NewTask(title: "A");
        await repo.AddAsync(a);

        await repo.AddConditionAsync(a.Id, new AfterDateCondition(DateTimeOffset.UtcNow.AddDays(3)));
        await repo.AddConditionAsync(a.Id, new ExternalCondition("waiting on legal", Satisfied: false));

        var stored = (await repo.GetAllAsync()).Single(t => t.Id == a.Id);
        Assert.Equal(2, stored.Conditions.Count);
    }

    [Fact]
    public async Task Rule1_Blocked_SelfReference_ThrowsInvalidCondition()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();
        var a = Fixtures.NewTask(title: "A");
        await repo.AddAsync(a);

        await Assert.ThrowsAsync<InvalidConditionException>(
            () => repo.AddConditionAsync(a.Id, new TaskDoneCondition(a.Id)));
    }

    [Fact]
    public async Task Rule1_Blocked_Cycle_ThrowsInvalidCondition()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();
        var a = Fixtures.NewTask(title: "A");
        var b = Fixtures.NewTask(title: "B");
        await repo.AddBatchAsync([a, b]);
        // A depends on B...
        await repo.AddConditionAsync(a.Id, new TaskDoneCondition(b.Id));

        // ...so making B depend on A would close a cycle.
        await Assert.ThrowsAsync<InvalidConditionException>(
            () => repo.AddConditionAsync(b.Id, new TaskDoneCondition(a.Id)));
    }

    [Fact]
    public async Task Rule1_Blocked_UnknownTaskId_IsANoOp()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();

        // No exception, no row created — matches `guard fetchModel(id) != nil else return`.
        await repo.AddConditionAsync(Guid.NewGuid(), new ExternalCondition("x", Satisfied: false));
        Assert.Empty(await repo.GetAllAsync());
    }

    // Rule 2 — SetRecurrenceAsync: recurrence is only ever allowed on a task with no children.

    [Fact]
    public async Task Rule2_Pass_LeafTask_AcceptsRecurrence()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();
        var leaf = Fixtures.NewTask(title: "Leaf");
        await repo.AddAsync(leaf);

        await repo.SetRecurrenceAsync(leaf.Id, """{"kind":"daily"}""");

        var stored = (await repo.GetAllAsync()).Single();
        Assert.Equal("""{"kind":"daily"}""", stored.RecurrenceJson);
    }

    [Fact]
    public async Task Rule2_Blocked_TaskWithChildren_ThrowsRecurrenceRequiresLeaf()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();
        var parent = Fixtures.NewTask(title: "Parent");
        await repo.AddAsync(parent);
        var child = Fixtures.NewTask(title: "Child", parentId: parent.Id);
        await repo.AddAsync(child);

        await Assert.ThrowsAsync<RecurrenceRequiresLeafException>(
            () => repo.SetRecurrenceAsync(parent.Id, """{"kind":"daily"}"""));
    }

    [Fact]
    public async Task Rule2_Pass_ClearingRecurrence_NeverBlockedByChildren()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();
        var parent = Fixtures.NewTask(title: "Parent");
        await repo.AddAsync(parent);
        var child = Fixtures.NewTask(title: "Child", parentId: parent.Id);
        await repo.AddAsync(child);

        // Passing null (clearing) is never gated by the leaf check — only a non-null value is.
        await repo.SetRecurrenceAsync(parent.Id, null);

        Assert.Null((await repo.GetAllAsync()).Single(t => t.Id == parent.Id).RecurrenceJson);
    }

    // Rule 3 — SetParentAsync: parent must exist, the link graph must stay acyclic, and a recurring
    // task can't gain children.

    [Fact]
    public async Task Rule3_Pass_ValidParentLink_Attaches()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();
        var parent = Fixtures.NewTask(title: "Parent");
        var child = Fixtures.NewTask(title: "Child");
        await repo.AddBatchAsync([parent, child]);

        await repo.SetParentAsync(child.Id, parent.Id);

        Assert.Equal(parent.Id, (await repo.GetAllAsync()).Single(t => t.Id == child.Id).ParentId);
    }

    [Fact]
    public async Task Rule3_Pass_NullParent_DetachesWithoutError()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();
        var parent = Fixtures.NewTask(title: "Parent");
        var child = Fixtures.NewTask(title: "Child", parentId: parent.Id);
        await repo.AddBatchAsync([parent, child]);

        await repo.SetParentAsync(child.Id, null);

        Assert.Null((await repo.GetAllAsync()).Single(t => t.Id == child.Id).ParentId);
    }

    [Fact]
    public async Task Rule3_Blocked_UnknownParent_ThrowsParentNotFound()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();
        var child = Fixtures.NewTask(title: "Child");
        await repo.AddAsync(child);

        await Assert.ThrowsAsync<ParentNotFoundException>(
            () => repo.SetParentAsync(child.Id, Guid.NewGuid()));
    }

    [Fact]
    public async Task Rule3_Blocked_SelfParent_ThrowsParentCycle()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();
        var a = Fixtures.NewTask(title: "A");
        await repo.AddAsync(a);

        await Assert.ThrowsAsync<ParentCycleException>(() => repo.SetParentAsync(a.Id, a.Id));
    }

    [Fact]
    public async Task Rule3_Blocked_TransitiveCycle_ThrowsParentCycle()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();
        var a = Fixtures.NewTask(title: "A");
        var b = Fixtures.NewTask(title: "B");
        var c = Fixtures.NewTask(title: "C");
        await repo.AddBatchAsync([a, b, c]);
        // A -> B -> C (B's parent is A, C's parent is B)
        await repo.SetParentAsync(b.Id, a.Id);
        await repo.SetParentAsync(c.Id, b.Id);

        // Attaching A under C would close the loop A -> B -> C -> A.
        await Assert.ThrowsAsync<ParentCycleException>(() => repo.SetParentAsync(a.Id, c.Id));
    }

    [Fact]
    public async Task Rule3_Blocked_RecurringParent_ThrowsParentHasRecurrence()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();
        var recurring = Fixtures.NewTask(title: "Recurring", recurrenceJson: """{"kind":"daily"}""");
        var child = Fixtures.NewTask(title: "Child");
        await repo.AddBatchAsync([recurring, child]);

        await Assert.ThrowsAsync<ParentHasRecurrenceException>(
            () => repo.SetParentAsync(child.Id, recurring.Id));
    }

    // Rule 6 — AddBatchAsync: batch size is capped.

    [Fact]
    public async Task Rule6_Blocked_BatchOverLimit_ThrowsBatchTooLarge()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();
        var items = Enumerable.Range(0, TaskRepository.MaxBatchSize + 1)
            .Select(i => Fixtures.NewTask(title: $"Task {i}"))
            .ToList();

        var ex = await Assert.ThrowsAsync<BatchTooLargeException>(() => repo.AddBatchAsync(items));
        Assert.Contains(TaskRepository.MaxBatchSize.ToString(), ex.Message);
        // Nothing should have been persisted from a rejected batch.
        Assert.Empty(await repo.GetAllAsync());
    }

    [Fact]
    public async Task Rule6_Pass_BatchAtExactLimit_Succeeds()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();
        var items = Enumerable.Range(0, TaskRepository.MaxBatchSize)
            .Select(i => Fixtures.NewTask(title: $"Task {i}"))
            .ToList();

        await repo.AddBatchAsync(items);

        Assert.Equal(TaskRepository.MaxBatchSize, (await repo.GetAllAsync()).Count);
    }
}
