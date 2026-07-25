// ReminderTaskStoreAdapterTests.cs — exercises the adapter against a REAL, temp-file-backed SQLite
// TaskRepository (Volar.App.Tests.State.SqliteFixture, reused rather than duplicated — it is
// `public` and lives in this same test assembly), not a hand-rolled fake, so the sync-over-async
// bridge and the TaskEntityMapping projection are both actually exercised end-to-end.
using Volar.App.Services.Adapters;
using Volar.App.Tests.State;
using Volar.Core;
using Volar.Data.Entities;
using Xunit;

namespace Volar.App.Tests.Adapters;

public sealed class ReminderTaskStoreAdapterTests : IDisposable
{
    private readonly SqliteFixture _fixture = new();

    private static TaskEntity NewEntity(
        string title = "Pay rent",
        DateTimeOffset? deadline = null,
        bool isSensitive = false) => new()
        {
            Id = Guid.NewGuid(),
            Title = title,
            PriorityRaw = 2,
            CreatedAt = new DateTimeOffset(2026, 7, 25, 8, 0, 0, TimeSpan.Zero),
            Deadline = deadline,
            IsSensitive = isSensitive,
        };

    [Fact]
    public async Task FetchAll_ProjectsPersistedRows_IntoTaskItems()
    {
        var repository = _fixture.CreateTaskRepository();
        var deadline = new DateTimeOffset(2026, 7, 26, 17, 0, 0, TimeSpan.Zero);
        var entity = NewEntity("Pay rent", deadline);
        await repository.AddAsync(entity);
        var adapter = new ReminderTaskStoreAdapter(repository);

        var all = adapter.FetchAll();

        var task = Assert.Single(all, t => t.Id == entity.Id);
        Assert.Equal("Pay rent", task.Title);
        Assert.Equal(deadline, task.Deadline);
        Assert.Equal(TaskState.Todo, task.Status);
    }

    [Fact]
    public async Task Toggle_FlipsStatusThroughTheRepository()
    {
        var repository = _fixture.CreateTaskRepository();
        var entity = NewEntity();
        await repository.AddAsync(entity);
        var adapter = new ReminderTaskStoreAdapter(repository);

        adapter.Toggle(entity.Id, new DateTimeOffset(2026, 7, 25, 9, 0, 0, TimeSpan.Zero));

        var after = adapter.FetchAll().Single(t => t.Id == entity.Id);
        Assert.Equal(TaskState.Done, after.Status);
    }

    [Fact]
    public void Toggle_UnknownTaskId_IsANoOp_NeverThrows()
    {
        var adapter = new ReminderTaskStoreAdapter(_fixture.CreateTaskRepository());

        adapter.Toggle(Guid.NewGuid(), DateTimeOffset.UtcNow); // must not throw
    }

    [Fact]
    public async Task IsSensitive_ReflectsThePersistedFlag()
    {
        var repository = _fixture.CreateTaskRepository();
        var sensitive = NewEntity("Therapy appointment", isSensitive: true);
        var normal = NewEntity("Buy milk", isSensitive: false);
        await repository.AddAsync(sensitive);
        await repository.AddAsync(normal);
        var adapter = new ReminderTaskStoreAdapter(repository);

        Assert.True(adapter.IsSensitive(sensitive.Id));
        Assert.False(adapter.IsSensitive(normal.Id));
    }

    [Fact]
    public void IsSensitive_UnknownTaskId_DefaultsFalse()
    {
        var adapter = new ReminderTaskStoreAdapter(_fixture.CreateTaskRepository());

        Assert.False(adapter.IsSensitive(Guid.NewGuid()));
    }

    public void Dispose() => _fixture.Dispose();
}
