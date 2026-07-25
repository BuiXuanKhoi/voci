// Services/Contracts.cs — the interfaces Opus froze for Wave 3-C
// (specs/003-windows-port/wave3c-services.md, "Interfaces frozen by Opus"). Copied verbatim: C2
// owns this file and nobody else edits it — every other Wave 3-C agent (C1/C3/C4/C5) codes against
// these exact signatures. If a signature turns out to be wrong, the fix is a report, not a silent
// edit here (see this task's hard constraints).
//
// ITaskListService is the single owner of task state (Opus decision 5, binding): every other
// service holds a reference to this interface and reads through it — nobody caches a second
// `TaskItem` collection. IEligibilityAndResurfaceService is the shared mutation tail every writer
// calls (inventory cluster D), kept separate specifically so FIX 2's resurface chaining stays
// unit-testable on its own (see EligibilityAndResurfaceService.cs).
using Volar.Domain;

namespace Volar.App.Services;

/// <summary>Single clock seam for every service. Mirrors the Swift <c>clock: () -&gt; Date</c>
/// closure — no service may read <see cref="DateTimeOffset.Now"/>/<see cref="DateTimeOffset.UtcNow"/>
/// directly (wave-wide rule); every "now" comes from this interface instead, so tests can inject a
/// fixed instant.</summary>
public interface ITimeProvider
{
    DateTimeOffset Now { get; }
}

/// <summary>The one owner of task state (Opus decision 5). Every other service holds a reference
/// and reads through it — nobody caches a second copy.</summary>
public interface ITaskListService
{
    IReadOnlyList<TaskItem> Tasks { get; }

    IReadOnlyList<TaskItem> NowTasks { get; }

    IReadOnlyList<TaskItem> LaterTasks { get; }

    IReadOnlyList<TaskItem> DoneTasks { get; }

    IReadOnlyList<TaskItem> OpenTasks { get; }

    TaskItem? FrogTask { get; }

    /// <summary>Recompute per read, never cache (inventory §4) — the same guarantee Swift's
    /// <c>AppState.activeTask</c> computed property gives.</summary>
    TaskItem? ActiveTask { get; }

    /// <summary>Replaces macOS's <c>.volarTasksDidChange</c> NotificationCenter pair. Raised after
    /// any mutation or refresh completes, on the UI thread.</summary>
    event Action? TasksChanged;

    Task RefreshAsync();

    Task AddAsync(TaskItem task);

    Task ToggleDoneAsync(Guid id);

    Task DeleteAsync(Guid id);

    Task SetFrogAsync(Guid id);
}

/// <summary>The shared mutation tail every writer calls (inventory cluster D). Kept separate from
/// the task list precisely because FIX 2's resurface chaining must be unit-testable alone.</summary>
public interface IEligibilityAndResurfaceService
{
    /// <summary>Diff eligibility across a mutation, notify newly-unblocked tasks, and (re)arm
    /// resurface for EVERY task with a future <c>.afterDate</c> — see FIX 2.</summary>
    Task NotifyEligibilityAndScheduleResurfaceAsync(
        IReadOnlyList<TaskItem> before, IReadOnlyList<TaskItem> after);

    /// <summary>Re-arm at launch/wake. Must be idempotent.</summary>
    Task RearmAsync();
}
