// Services/Adapters/ReminderTaskStoreAdapter.cs — real IReminderTaskStore over
// Volar.Data.TaskRepository, replacing Stubs.StubReminderTaskStore per that stub's own TODO.
//
// SYNC-OVER-ASYNC, BY DESIGN: IReminderTaskStore (Volar.Reminders/IReminderTaskStore.cs) is a
// synchronous interface — it mirrors Swift's synchronous SwiftData `TaskStore`, and
// ReminderScheduler (its only caller) is itself fully synchronous, called from UI-thread event
// handlers and timer callbacks, never from an async context. TaskRepository is async (this port's
// dependency-injection boundary — see wave3c-services.md decision 7: "async is the boundary, not
// the core"). Bridging the two here with `.GetAwaiter().GetResult()` is the intended shape per
// both interfaces' own header comments ("Wave 3 (App shell) is expected to implement this against
// Volar.Data.TaskRepository") — not a shortcut invented by this file. TaskRepository's own work is
// local SQLite I/O (no network), so the blocking window is small, but a caller on the UI thread
// should still expect ReminderScheduler calls to be synchronous+blocking end-to-end, exactly as
// they are today against the in-memory stub.
//
// Uses Volar.Data.Entities.TaskEntityMapping.ToTaskItem() (C2, wave3c-services.md decision 6) for
// the entity->domain projection — the canonical, full-fidelity mapper landed after this adapter was
// first drafted against a narrower local fallback (Services/Adapters/TaskEntityFallbackMapping.cs,
// since removed once the canonical mapper appeared).
using Volar.Data;
using Volar.Data.Entities;
using Volar.Domain;
using Volar.Reminders;

namespace Volar.App.Services.Adapters;

public sealed class ReminderTaskStoreAdapter : IReminderTaskStore
{
    private readonly TaskRepository _repository;

    public ReminderTaskStoreAdapter(TaskRepository repository)
    {
        _repository = repository ?? throw new ArgumentNullException(nameof(repository));
    }

    public IReadOnlyList<TaskItem> FetchAll() =>
        _repository.GetAllAsync().GetAwaiter().GetResult()
            .Select(TaskEntityMapping.ToTaskItem)
            .ToList();

    public void Toggle(Guid taskId, DateTimeOffset now) =>
        _repository.ToggleAsync(taskId, now).GetAwaiter().GetResult();

    public bool IsSensitive(Guid taskId) =>
        _repository.IsSensitiveAsync(taskId).GetAwaiter().GetResult();
}
