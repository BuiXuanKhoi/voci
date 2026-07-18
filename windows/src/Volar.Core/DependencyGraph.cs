namespace Volar.Core;

/// <summary>
/// The two ways adding a <see cref="TaskDoneCondition"/> can be rejected by
/// <see cref="DependencyGraph.ValidateCondition"/> — carried on a thrown
/// <see cref="DependencyException"/> so the app can render a message such as
/// <i>"'A' đang chờ 'B' — không thể để 'B' chờ ngược lại 'A'."</i> directly from the error
/// (Constitution Principle II: never silently guess or drop — always explain).
/// </summary>
/// <remarks>
/// Both payloads carry human-readable titles (rather than raw ids), matching Swift's
/// <c>enum DependencyError: Error, Equatable</c>. Modeled as an <see langword="abstract record"/>
/// with two nested <see langword="sealed"/> subtypes so structural (value) equality on the payload
/// is available directly on <see cref="DependencyError"/>, matching the Swift enum's synthesized
/// <c>Equatable</c> conformance — this is why the error payload is a plain record rather than the
/// thrown <see cref="Exception"/> itself (a C# <see cref="Exception"/> does not have — and should
/// not be given — value equality).
/// </remarks>
public abstract record DependencyError
{
    private protected DependencyError() { }

    /// <summary>
    /// Adding "<c>From</c> depends on (via TaskDone) <c>To</c>" would close a cycle in the
    /// existing graph.
    /// </summary>
    public sealed record Cycle(string From, string To) : DependencyError;

    /// <summary>A task cannot depend on itself.</summary>
    public sealed record SelfDependency(string Title) : DependencyError;
}

/// <summary>
/// Thrown by <see cref="DependencyGraph.ValidateCondition"/> when a proposed
/// <see cref="TaskDoneCondition"/> would violate the <see cref="TaskDoneCondition"/> dependency
/// graph's DAG invariant. Carries the structured <see cref="DependencyError"/> payload so callers
/// can pattern-match on <see cref="Error"/> instead of parsing <see cref="Exception.Message"/>.
/// </summary>
public sealed class DependencyException(DependencyError error) : Exception(DependencyException.Describe(error))
{
    public DependencyError Error { get; } = error;

    private static string Describe(DependencyError error) => error switch
    {
        DependencyError.Cycle c => $"'{c.From}' depends on '{c.To}', which would create a cycle.",
        DependencyError.SelfDependency s => $"'{s.Title}' cannot depend on itself.",
        _ => throw new NotSupportedException($"Unhandled {nameof(DependencyError)} subtype: {error.GetType()}")
    };
}

/// <summary>
/// Validates the <see cref="TaskDoneCondition"/> dependency graph (Constitution Principle III;
/// spec FR-011/FR-012): port of Swift's free functions <c>validateCondition(adding:to:in:)</c> and
/// <c>wouldCreateCycle(from:dependsOn:in:)</c>.
/// </summary>
public static class DependencyGraph
{
    /// <summary>
    /// Validates adding <paramref name="condition"/> to task <paramref name="id"/> within
    /// <paramref name="snapshot"/>, throwing <see cref="DependencyException"/> when it would
    /// violate the <see cref="TaskDoneCondition"/> graph's DAG invariant.
    /// </summary>
    /// <remarks>
    /// Only <see cref="TaskDoneCondition"/> payloads participate in the dependency graph:
    /// <list type="bullet">
    /// <item>
    /// A <see cref="TaskDoneCondition"/> self-reference (<c>id == target</c>) always throws
    /// <see cref="DependencyError.SelfDependency"/>.
    /// </item>
    /// <item>
    /// A <see cref="TaskDoneCondition"/> edge that would close a cycle (the target can already
    /// reach <paramref name="id"/> by following existing <see cref="TaskDoneCondition"/> edges)
    /// throws <see cref="DependencyError.Cycle"/>.
    /// </item>
    /// <item>
    /// <see cref="AfterDateCondition"/> and <see cref="ExternalCondition"/> never throw — they
    /// carry no graph edge.
    /// </item>
    /// </list>
    /// <para>
    /// This method is pure: it neither mutates <paramref name="snapshot"/> nor reads the clock or
    /// any external state, and never persists anything itself. Cycle detection is intentionally
    /// performed at condition-creation time so <see cref="NextTaskSelector.NextTask"/>'s hot path
    /// may assume the <see cref="TaskDoneCondition"/> graph is already acyclic.
    /// </para>
    /// </remarks>
    public static void ValidateCondition(Condition condition, Guid id, IReadOnlyList<TaskSnapshot> snapshot)
    {
        if (condition is not TaskDoneCondition taskDone)
        {
            return;
        }

        if (id == taskDone.TaskId)
        {
            throw new DependencyException(new DependencyError.SelfDependency(TitleFor(id, snapshot)));
        }
        if (WouldCreateCycle(id, taskDone.TaskId, snapshot))
        {
            throw new DependencyException(
                new DependencyError.Cycle(TitleFor(id, snapshot), TitleFor(taskDone.TaskId, snapshot)));
        }
    }

    /// <summary>
    /// Non-throwing predicate: would adding a <see cref="TaskDoneCondition"/>(<paramref
    /// name="target"/>) condition to task <paramref name="source"/> close a cycle in the existing
    /// <see cref="TaskDoneCondition"/> graph described by <paramref name="snapshot"/>?
    /// </summary>
    /// <remarks>
    /// A self-edge (<c>source == target</c>) is treated as a trivial cycle and returns
    /// <see langword="true"/>. Otherwise this performs a depth-first search starting from
    /// <paramref name="target"/>, following existing <see cref="TaskDoneCondition"/> edges
    /// outward; if <paramref name="source"/> is reachable from <paramref name="target"/>, the new
    /// edge would close a loop.
    /// <para>
    /// Pure: neither mutates <paramref name="snapshot"/> nor reads the clock or any external
    /// state. O(V+E) over the existing <see cref="TaskDoneCondition"/> graph. The visited set
    /// bounds the traversal even over adversarial (already-cyclic) input data, so this never
    /// hangs.
    /// </para>
    /// </remarks>
    public static bool WouldCreateCycle(Guid source, Guid target, IReadOnlyList<TaskSnapshot> snapshot)
    {
        if (source == target)
        {
            return true;
        }

        var taskDoneEdgesById = new Dictionary<Guid, List<Guid>>(snapshot.Count);
        foreach (var task in snapshot)
        {
            var edges = new List<Guid>();
            foreach (var condition in task.Conditions)
            {
                if (condition is TaskDoneCondition taskDone)
                {
                    edges.Add(taskDone.TaskId);
                }
            }
            taskDoneEdgesById[task.Id] = edges;
        }

        var visited = new HashSet<Guid>();
        var stack = new Stack<Guid>();
        stack.Push(target);
        while (stack.Count > 0)
        {
            var current = stack.Pop();
            if (current == source)
            {
                return true;
            }
            if (!visited.Add(current))
            {
                continue;
            }
            if (taskDoneEdgesById.TryGetValue(current, out var neighbors))
            {
                foreach (var neighbor in neighbors)
                {
                    stack.Push(neighbor);
                }
            }
        }
        return false;
    }

    /// <summary>
    /// Looks up a task's title by id for use in error messages; falls back to the id's string form
    /// if the task is not found in the snapshot (should not normally happen for a valid edge, but
    /// keeps this helper total).
    /// </summary>
    private static string TitleFor(Guid id, IReadOnlyList<TaskSnapshot> snapshot)
    {
        foreach (var task in snapshot)
        {
            if (task.Id == id)
            {
                return task.Title;
            }
        }
        return id.ToString();
    }
}
