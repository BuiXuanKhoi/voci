// DbContextLifecycleTests.cs — proves the "fresh DbContext per operation, never a shared/singleton
// instance" lifecycle documented on VolarDbContextFactory/TaskRepository actually holds: many
// repository calls issued concurrently against the SAME TaskRepository instance (which itself holds
// no DbContext field — see TaskRepository.cs's header comment) all succeed without the
// cross-thread/"second operation on this context" InvalidOperationException that sharing a single
// DbContext across threads would produce.
using Volar.Core;
using Xunit;

namespace Volar.Data.Tests;

public sealed class DbContextLifecycleTests
{
    [Fact]
    public async Task ConcurrentAddAsyncCalls_OnSameRepositoryInstance_AllSucceed()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository(); // one instance, shared across all concurrent calls below

        var tasks = Enumerable.Range(0, 20)
            .Select(i => repo.AddAsync(Fixtures.NewTask(title: $"Concurrent {i}")))
            .ToArray();
        await Task.WhenAll(tasks);

        var all = await repo.GetAllAsync();
        Assert.Equal(20, all.Count);
    }

    [Fact]
    public async Task ConcurrentReadsAndWrites_OnSameRepositoryInstance_DoNotThrow()
    {
        using var db = new SqliteTestDatabase();
        var repo = db.CreateTaskRepository();
        var seed = Fixtures.NewTask(title: "Seed", status: TaskState.Todo);
        await repo.AddAsync(seed);

        var operations = new List<Task>
        {
            repo.GetAllAsync(),
            repo.AddConditionAsync(seed.Id, new ExternalCondition("x", Satisfied: false)),
            repo.GetActiveAsync(DateTimeOffset.UtcNow, TimeZoneInfo.Utc),
            repo.IsSensitiveAsync(seed.Id),
            repo.RecordCorrectionAsync("title", "a", "b", "c"),
        };

        // Every call opened (and disposed) its own DbContext instance — none of this throws the
        // "A second operation was started on this context instance" error a shared context would.
        var exception = await Record.ExceptionAsync(() => Task.WhenAll(operations));
        Assert.Null(exception);
    }
}
