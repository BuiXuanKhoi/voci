// IReminderTaskStore.cs — seam for the scheduler's read/mutate access to the app's persisted task
// store, mirroring Swift's `TaskStore` dependency (`ReminderScheduler.init(store: TaskStore, ...)`).
//
// Volar.Reminders cannot reference Volar.Data (EF Core) directly per this project's dependency
// rules, so Wave 3 (App shell) is expected to implement this against
// `Volar.Data.TaskRepository` + map `Volar.Data.Entities.TaskEntity` -> `Volar.Domain.TaskItem` —
// the same seam pattern `Volar.Data/IRecurrenceResetter.cs` already uses for the opposite
// direction (Volar.Data depending on not-yet-existing Volar.Domain logic).
using Volar.Domain;

namespace Volar.Reminders;

public interface IReminderTaskStore
{
    /// <summary>
    /// All persisted tasks, freshly read. Constitution IV: every fire-time decision reloads fresh
    /// rather than trusting a stale in-memory snapshot — callers into this method are exactly where
    /// that fresh reload happens.
    /// </summary>
    IReadOnlyList<TaskItem> FetchAll();

    /// <summary>
    /// Toggles the task's done state (mirrors `TaskStore.toggle(_:now:)`) — for a recurring task
    /// this is expected to reset-in-place (reopen with the next occurrence) rather than archive,
    /// same as the Swift original.
    /// </summary>
    void Toggle(Guid taskId, DateTimeOffset now);

    /// <summary>
    /// Whether the task is marked sensitive (mirrors `TaskStore.isSensitive(_:)` /
    /// `VolarTask.isSensitive`) — deliberately never carried on <see cref="TaskItem"/> itself, same
    /// as the Swift original's field-level doc comment explains.
    /// </summary>
    bool IsSensitive(Guid taskId);
}
