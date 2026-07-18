// Exceptions/TaskRepositoryExceptions.cs — port of TaskStore.swift's `enum TaskStoreError`. Every
// case carries a human-readable message (constitution II: never silently guess or drop — always
// explain), suitable for direct display, exactly like the Swift `errorDescription` computed
// property.
namespace Volar.Data.Exceptions;

/// <summary>Base type for every error <see cref="Volar.Data.TaskRepository"/>'s validated mutation
/// methods can throw.</summary>
public abstract class TaskRepositoryException : Exception
{
    private protected TaskRepositoryException(string message) : base(message)
    {
    }
}

/// <summary>Validation rule 1 (see TaskRepository.AddConditionAsync): a proposed `.taskDone`
/// condition would self-reference or close a cycle.</summary>
public sealed class InvalidConditionException(string message) : TaskRepositoryException(message);

/// <summary>Validation rule 3 (see TaskRepository.SetParentAsync): the proposed parent id does not
/// exist.</summary>
public sealed class ParentNotFoundException()
    : TaskRepositoryException("That parent task no longer exists.");

/// <summary>Validation rule 3: attaching would create a parent-link cycle.</summary>
public sealed class ParentCycleException(string childTitle, string parentTitle)
    : TaskRepositoryException(
        $"“{parentTitle}” can't become a sub-task of “{childTitle}” — that would create a loop.");

/// <summary>Validation rule 3 (flip side of rule 2): the proposed parent already has a recurrence,
/// so it cannot gain children.</summary>
public sealed class ParentHasRecurrenceException(string title)
    : TaskRepositoryException($"“{title}” repeats, so it can't have sub-tasks.");

/// <summary>Validation rule 2: recurrence can only be set on a leaf task (no children).</summary>
public sealed class RecurrenceRequiresLeafException(string title)
    : TaskRepositoryException($"“{title}” has sub-tasks, so it can't repeat on its own.");

/// <summary>Validation rule 6: a batch insert exceeding <see cref="Volar.Data.TaskRepository.MaxBatchSize"/>.</summary>
public sealed class BatchTooLargeException(int limit)
    : TaskRepositoryException($"Only {limit} tasks can be created at once.");
