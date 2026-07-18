// TaskRepository.cs — port of Sources/Model/TaskStore.swift's validated CRUD surface.
//
// LIFECYCLE: every public method opens a fresh, short-lived VolarDbContext via
// IDbContextFactory<VolarDbContext> (see VolarDbContextFactory.cs), does its work, and disposes it
// before returning — this type itself holds NO DbContext field, so it is safe to keep a single
// TaskRepository instance around (e.g. registered as a singleton in DI) even though DbContext
// itself is not thread-safe: no two overlapping calls ever touch the same context instance.
//
// TRUST BOUNDARY (mirrors TaskStore.swift's header comment): validation here runs on the WRITE path
// only (Add*/AddCondition/SetRecurrence/SetParent). A row edited directly on disk bypasses all of
// it. GetAllAsync does not re-validate `.taskDone` acyclicity or re-check the batch cap on read, for
// the same reasons the Swift original gives — cost, and Volar.Core's NextTask is documented to
// tolerate a corrupted snapshot without crashing.
using Microsoft.EntityFrameworkCore;
using Volar.Core;
using Volar.Data.Entities;
using Volar.Data.Exceptions;

namespace Volar.Data;

public sealed class TaskRepository(
    IDbContextFactory<VolarDbContext> contextFactory,
    IRecurrenceResetter? recurrenceResetter = null)
{
    /// Validation rule 6.
    public const int MaxBatchSize = 10;

    private readonly IDbContextFactory<VolarDbContext> _contextFactory = contextFactory;
    private readonly IRecurrenceResetter _recurrenceResetter = recurrenceResetter ?? new UnsupportedRecurrenceResetter();

    // MARK: - Fetch --------------------------------------------------------------------------------

    /// Loads every persisted task, ordered by <see cref="TaskEntity.CreatedAt"/> (matches
    /// TaskStore.fetchAllModels' `SortDescriptor(\.createdAt)`). Unlike the Swift original's
    /// `fetchAll()`, this does NOT run a legacy-migration fold — see the "bẫy #1" note in this
    /// task's final report: a from-SwiftData migration is out of scope for a fresh Windows install,
    /// so there is no `dependsOn` column or fold step to port.
    public async Task<IReadOnlyList<TaskEntity>> GetAllAsync(CancellationToken ct = default)
    {
        await using var context = await _contextFactory.CreateDbContextAsync(ct);
        return await context.Tasks
            .Include(t => t.Conditions)
            .OrderBy(t => t.CreatedAt)
            .ToListAsync(ct);
    }

    /// Port of `TaskStore.active(now:)`.
    public async Task<TaskEntity?> GetActiveAsync(DateTimeOffset now, TimeZoneInfo timeZone, CancellationToken ct = default)
    {
        await using var context = await _contextFactory.CreateDbContextAsync(ct);
        var tasks = await context.Tasks.Include(t => t.Conditions).ToListAsync(ct);
        var snapshot = tasks.Select(t => t.ToSnapshot()).ToList();
        var winner = NextTaskSelector.NextTask(snapshot, now, timeZone);
        return winner is null ? null : tasks.FirstOrDefault(t => t.Id == winner.Value.Id);
    }

    /// Port of `TaskStore.isSensitive(_:)` — defaults to <see langword="false"/> for an
    /// unknown/deleted id, matching every other "task not found" fallback in this file.
    public async Task<bool> IsSensitiveAsync(Guid id, CancellationToken ct = default)
    {
        await using var context = await _contextFactory.CreateDbContextAsync(ct);
        return await context.Tasks
            .Where(t => t.Id == id)
            .Select(t => (bool?)t.IsSensitive)
            .FirstOrDefaultAsync(ct) ?? false;
    }

    // MARK: - Insert ---------------------------------------------------------------------------------

    /// Port of `TaskStore.add(_:)`. <paramref name="task"/>'s <see cref="TaskEntity.Conditions"/>
    /// are sanitized against the current store before insert (invalid `.taskDone` edges — a
    /// self-reference or a cycle — are silently dropped, matching
    /// `TaskStore.sanitizedConditions`'s behavior; `.afterDate`/`.external` never fail this check).
    public async Task AddAsync(TaskEntity task, CancellationToken ct = default)
    {
        await using var context = await _contextFactory.CreateDbContextAsync(ct);
        var snapshot = await BuildSnapshotAsync(context, ct);
        InsertSanitized(context, task, snapshot);
        await context.SaveChangesAsync(ct);
    }

    /// Port of `TaskStore.addBatch(_:)`. Validation rule 6: throws <see cref="BatchTooLargeException"/>
    /// above <see cref="MaxBatchSize"/>. Each item is sanitized against a snapshot that grows as
    /// earlier items in the SAME batch are accepted, so intra-batch `.taskDone` references validate
    /// correctly without a second pass — matches the Swift original exactly.
    public async Task AddBatchAsync(IReadOnlyList<TaskEntity> items, CancellationToken ct = default)
    {
        if (items.Count > MaxBatchSize)
        {
            throw new BatchTooLargeException(MaxBatchSize);
        }

        await using var context = await _contextFactory.CreateDbContextAsync(ct);
        var snapshot = await BuildSnapshotAsync(context, ct);
        foreach (var item in items)
        {
            InsertSanitized(context, item, snapshot);
        }
        await context.SaveChangesAsync(ct);
    }

    /// Shared by AddAsync/AddBatchAsync: sanitizes <paramref name="task"/>'s conditions, adds it to
    /// <paramref name="context"/>, and appends its engine-facing snapshot to <paramref
    /// name="snapshot"/> (in/out) so subsequent items in the same batch see it.
    private static void InsertSanitized(VolarDbContext context, TaskEntity task, List<TaskSnapshot> snapshot)
    {
        if (task.Id == Guid.Empty)
        {
            task.Id = Guid.NewGuid();
        }

        var proposed = task.Conditions.OrderBy(c => c.OrderIndex).Select(c => c.ToCoreCondition()).ToList();
        task.Conditions = SanitizeConditions(task.Id, proposed, snapshot);

        context.Tasks.Add(task);
        snapshot.Add(task.ToSnapshot());
    }

    /// Filters out any `.taskDone` condition that would fail `DependencyGraph.ValidateCondition`
    /// (self-reference or cycle) rather than throwing — port of `TaskStore.sanitizedConditions`.
    /// `.afterDate`/`.external` never throw so they always pass through unchanged.
    private static List<ConditionEntity> SanitizeConditions(Guid taskId, IReadOnlyList<Condition> proposed, IReadOnlyList<TaskSnapshot> snapshot)
    {
        var result = new List<ConditionEntity>(proposed.Count);
        foreach (var condition in proposed)
        {
            if (condition is TaskDoneCondition)
            {
                try
                {
                    DependencyGraph.ValidateCondition(condition, taskId, snapshot);
                }
                catch (DependencyException ex)
                {
                    Console.Error.WriteLine($"[Volar.Data.TaskRepository] dropped invalid condition on {taskId}: {ex.Message}");
                    continue;
                }
            }
            result.Add(condition.ToEntity(taskId, result.Count));
        }
        return result;
    }

    // MARK: - Conditions / recurrence / parent -------------------------------------------------------

    /// Validation rule 1: port of `TaskStore.addCondition(_:to:)`. A no-op for an unknown id
    /// (matches Swift's `guard fetchModel(id) != nil else return`).
    public async Task AddConditionAsync(Guid id, Condition condition, CancellationToken ct = default)
    {
        await using var context = await _contextFactory.CreateDbContextAsync(ct);
        var task = await context.Tasks.Include(t => t.Conditions).FirstOrDefaultAsync(t => t.Id == id, ct);
        if (task is null)
        {
            return;
        }

        if (condition is TaskDoneCondition)
        {
            var snapshot = await BuildSnapshotAsync(context, ct);
            try
            {
                DependencyGraph.ValidateCondition(condition, id, snapshot);
            }
            catch (DependencyException ex)
            {
                throw new InvalidConditionException(Describe(ex.Error));
            }
        }

        var nextIndex = task.Conditions.Count == 0 ? 0 : task.Conditions.Max(c => c.OrderIndex) + 1;
        // Must go through context.Add (NOT task.Conditions.Add) — see the "Modified vs Added" note
        // on CompleteOne below for why appending a client-keyed entity to an already-tracked
        // parent's collection navigation via plain List.Add() is a real EF Core footgun.
        context.Add(condition.ToEntity(id, nextIndex));
        await context.SaveChangesAsync(ct);
    }

    /// Validation rule 2: port of `TaskStore.setRecurrence(_:on:)`. Recurrence is only ever allowed
    /// on a task with no children. <paramref name="recurrenceJson"/> is opaque pre-serialized JSON
    /// (see TaskEntity.RecurrenceJson's doc comment — Volar.Data has no visibility into the actual
    /// `Recurrence` type) — pass <see langword="null"/> to clear.
    public async Task SetRecurrenceAsync(Guid id, string? recurrenceJson, CancellationToken ct = default)
    {
        await using var context = await _contextFactory.CreateDbContextAsync(ct);
        var task = await context.Tasks.FirstOrDefaultAsync(t => t.Id == id, ct);
        if (task is null)
        {
            return;
        }

        if (recurrenceJson is not null && await HasChildrenAsync(context, id, ct))
        {
            throw new RecurrenceRequiresLeafException(task.Title);
        }

        task.RecurrenceJson = recurrenceJson;
        await context.SaveChangesAsync(ct);
    }

    /// Validation rule 3: port of `TaskStore.setParent(_:to:)`. `parentId` must reference an
    /// existing task, the parent-link graph must stay acyclic, and a recurring task can't gain
    /// children (the flip side of rule 2, only checkable from this direction).
    public async Task SetParentAsync(Guid childId, Guid? parentId, CancellationToken ct = default)
    {
        await using var context = await _contextFactory.CreateDbContextAsync(ct);
        var child = await context.Tasks.FirstOrDefaultAsync(t => t.Id == childId, ct);
        if (child is null)
        {
            return;
        }

        if (parentId is null)
        {
            child.ParentId = null;
            await context.SaveChangesAsync(ct);
            return;
        }

        if (childId == parentId.Value)
        {
            throw new ParentCycleException(child.Title, child.Title);
        }

        var parent = await context.Tasks.FirstOrDefaultAsync(t => t.Id == parentId.Value, ct);
        if (parent is null)
        {
            throw new ParentNotFoundException();
        }
        if (parent.RecurrenceJson is not null)
        {
            throw new ParentHasRecurrenceException(parent.Title);
        }

        // Walk up from the PROPOSED parent following existing ParentId links; if childId is
        // reached, attaching would close a cycle. The visited-set bounds the walk even against a
        // store that already contains a corrupted parent cycle above `parent`.
        var visited = new HashSet<Guid>();
        Guid? cursor = parentId;
        while (cursor is Guid current)
        {
            if (!visited.Add(current))
            {
                break;
            }
            if (current == childId)
            {
                throw new ParentCycleException(child.Title, parent.Title);
            }
            cursor = await context.Tasks
                .Where(t => t.Id == current)
                .Select(t => (Guid?)t.ParentId)
                .FirstOrDefaultAsync(ct);
        }

        child.ParentId = parentId;
        await context.SaveChangesAsync(ct);
    }

    // MARK: - Completion -------------------------------------------------------------------------------

    /// <summary>
    /// Port of `TaskStore.toggle(_:now:calendar:anchorRecurrenceToCompletion:)`. Open -> done
    /// (moment) -> (recurring) open at next occurrence; completing the last open child of a parent
    /// auto-completes the parent too, cascading upward (validation rule 5). A no-op for an unknown
    /// id.
    /// </summary>
    /// <param name="timeZone">Explicit injected time zone for recurrence-reset calendar math and
    /// for consistency with Volar.Core's purity convention — never defaults to
    /// <see cref="TimeZoneInfo.Local"/> implicitly; pass <see langword="null"/> only from a test or
    /// a caller that deliberately wants UTC-calendar semantics.</param>
    public async Task ToggleAsync(
        Guid id,
        DateTimeOffset? now = null,
        TimeZoneInfo? timeZone = null,
        bool anchorRecurrenceToCompletion = false,
        CancellationToken ct = default)
    {
        var effectiveNow = now ?? DateTimeOffset.UtcNow;
        var effectiveZone = timeZone ?? TimeZoneInfo.Utc;

        await using var context = await _contextFactory.CreateDbContextAsync(ct);
        var task = await context.Tasks.Include(t => t.Conditions).FirstOrDefaultAsync(t => t.Id == id, ct);
        if (task is null)
        {
            return;
        }

        if (task.Status == TaskState.Done)
        {
            task.Status = TaskState.Todo;
            task.CompletedAt = null;
            await context.SaveChangesAsync(ct);
            return;
        }

        await CompleteCascadingAsync(context, task, effectiveNow, effectiveZone, anchorRecurrenceToCompletion, ct);
        await context.SaveChangesAsync(ct);
    }

    /// Walks from <paramref name="task"/> up through ParentId links, completing (with recurrence
    /// reset where applicable) each task whose completion just emptied its parent's open-child set.
    /// A visited-set bounds the walk so a corrupted store containing a ParentId cycle can't loop
    /// forever.
    private async Task CompleteCascadingAsync(
        VolarDbContext context, TaskEntity task, DateTimeOffset now, TimeZoneInfo timeZone,
        bool anchorRecurrenceToCompletion, CancellationToken ct)
    {
        var current = task;
        var visited = new HashSet<Guid>();
        // Only the task the user actually completed gets the capture-time override; cascaded parent
        // auto-completions always reset on their own schedule.
        var anchorOverride = anchorRecurrenceToCompletion;

        while (visited.Add(current.Id))
        {
            CompleteOne(context, current, now, timeZone, anchorOverride);
            anchorOverride = false;

            if (current.ParentId is not Guid parentId)
            {
                break;
            }
            var parent = await context.Tasks.Include(t => t.Conditions).FirstOrDefaultAsync(t => t.Id == parentId, ct);
            if (parent is null || parent.Status == TaskState.Done)
            {
                break;
            }
            var hasOpenSiblings = await context.Tasks.AnyAsync(
                t => t.ParentId == parentId && t.Id != current.Id && t.StatusRaw != "done", ct);
            if (hasOpenSiblings)
            {
                break;
            }
            current = parent;
        }
    }

    /// Completion for exactly one task: log + either recurrence reset-in-place or a plain Done.
    private void CompleteOne(VolarDbContext context, TaskEntity task, DateTimeOffset now, TimeZoneInfo timeZone, bool anchorToCompletion)
    {
        task.CompletedAt = now;
        if (task.RecurrenceJson is { } recurrenceJson)
        {
            var input = new RecurrenceResetInput(
                recurrenceJson,
                task.Deadline,
                task.Conditions.OrderBy(c => c.OrderIndex).Select(c => c.ToCoreCondition()).ToList(),
                now,
                anchorToCompletion,
                timeZone);
            var reset = _recurrenceResetter.Reset(input);

            task.Deadline = reset.Deadline;
            task.Conditions.Clear();
            var index = 0;
            foreach (var condition in reset.Conditions)
            {
                // BUG FIX (see AddConditionAsync's note above): `task` is already tracked (loaded via
                // Include earlier in ToggleAsync), and ConditionMapping.ToEntity assigns a real,
                // non-default Guid.NewGuid() primary key before this entity is ever seen by the
                // ChangeTracker. If it were appended via plain `task.Conditions.Add(...)` (a List
                // mutation the tracker only notices via DetectChanges, not an explicit `context.Add`
                // call), EF Core's automatic change detection cannot tell "brand-new object" apart
                // from "pre-existing row being re-attached" for an entity with a store-generated key
                // that already has a non-default value — it resolves that ambiguity by assuming the
                // entity already exists in the database and marks it Modified instead of Added. That
                // produces an UPDATE ... WHERE Id = @p against a row that was never inserted, which
                // SaveChanges reports as a DbUpdateConcurrencyException ("expected to affect 1 row(s),
                // but actually affected 0 row(s)") — confirmed via EF's SQL log and a ChangeTracker
                // dump while diagnosing the same failure in AddConditionAsync. context.Add explicitly
                // marks the entity Added; EF's FK-based fixup then links it into task.Conditions
                // automatically since TaskId is already set to task.Id.
                context.Add(condition.ToEntity(task.Id, index));
                index++;
            }
            task.Status = TaskState.Todo;
        }
        else
        {
            task.Status = TaskState.Done;
        }

        context.CompletionEvents.Add(new CompletionEventEntity
        {
            Id = Guid.NewGuid(),
            TaskId = task.Id,
            TitleSnapshot = task.Title,
            ParentIdSnapshot = task.ParentId,
            EstimateSnapshot = task.DurationMinutes,
            CompletedAt = task.CompletedAt ?? now,
        });
    }

    // MARK: - Delete -----------------------------------------------------------------------------------

    /// Validation rule 4: port of `TaskStore.delete(_:now:)`. Strips the deleted id from every
    /// other task's `.taskDone` conditions and nulls children's ParentId, then returns ids of OTHER
    /// tasks that flip newly-eligible as a result. `CompletionEvent`s referencing this id are left
    /// untouched by design.
    public async Task<IReadOnlyList<Guid>> DeleteAsync(Guid id, DateTimeOffset? now = null, CancellationToken ct = default)
    {
        var effectiveNow = now ?? DateTimeOffset.UtcNow;
        await using var context = await _contextFactory.CreateDbContextAsync(ct);

        var all = await context.Tasks.Include(t => t.Conditions).ToListAsync(ct);
        var target = all.FirstOrDefault(t => t.Id == id);
        if (target is null)
        {
            return [];
        }

        var beforeSnapshot = all.Select(t => t.ToSnapshot()).ToList();

        foreach (var other in all)
        {
            if (other.Id == id)
            {
                continue;
            }
            if (other.ParentId == id)
            {
                other.ParentId = null;
            }
            var stripped = other.Conditions
                .Where(c => !(c.Kind == "taskDone" && c.TaskDoneTargetId == id))
                .ToList();
            if (stripped.Count != other.Conditions.Count)
            {
                var toRemove = other.Conditions.Except(stripped).ToList();
                foreach (var removed in toRemove)
                {
                    other.Conditions.Remove(removed);
                }
            }
        }

        context.Tasks.Remove(target);
        await context.SaveChangesAsync(ct);

        var afterSnapshot = all.Where(t => t.Id != id).Select(t => t.ToSnapshot()).ToList();
        return Snapshots.EligibilityDiff(beforeSnapshot, afterSnapshot, effectiveNow);
    }

    // MARK: - External conditions -----------------------------------------------------------------------

    /// T036 (phase5-contract.md §C): port of `TaskStore.clearFirstExternalCondition(on:now:)`.
    public Task<IReadOnlyList<Guid>> ClearFirstExternalConditionAsync(Guid id, DateTimeOffset? now = null, CancellationToken ct = default) =>
        ClearFirstExternalAsync(id, now, static _ => true, ct);

    /// FIX 1 (security): port of `TaskStore.clearExternalCondition(withPrefix:on:now:)` — only
    /// matches the first unsatisfied `.external` condition whose description starts with
    /// <paramref name="prefix"/>, so an inbound signal can't satisfy a condition it doesn't own.
    public Task<IReadOnlyList<Guid>> ClearExternalConditionAsync(string prefix, Guid id, DateTimeOffset? now = null, CancellationToken ct = default) =>
        ClearFirstExternalAsync(id, now, description => description.StartsWith(prefix, StringComparison.Ordinal), ct);

    /// Shared implementation: finds the first unsatisfied `.external` condition (in list order —
    /// see ConditionEntity.OrderIndex) on <paramref name="id"/> whose description satisfies
    /// <paramref name="match"/>, flips it to satisfied, saves, and returns newly-eligible task ids.
    /// A no-op for an unknown id or a task with nothing matching.
    private async Task<IReadOnlyList<Guid>> ClearFirstExternalAsync(
        Guid id, DateTimeOffset? now, Func<string, bool> match, CancellationToken ct)
    {
        var effectiveNow = now ?? DateTimeOffset.UtcNow;
        await using var context = await _contextFactory.CreateDbContextAsync(ct);

        var task = await context.Tasks.Include(t => t.Conditions).FirstOrDefaultAsync(t => t.Id == id, ct);
        if (task is null)
        {
            return [];
        }

        var target = task.Conditions
            .OrderBy(c => c.OrderIndex)
            .FirstOrDefault(c => c.Kind == "external" && c.ExternalSatisfied == false && match(c.ExternalDescription!));
        if (target is null)
        {
            return [];
        }

        var all = await context.Tasks.Include(t => t.Conditions).ToListAsync(ct);
        var beforeSnapshot = all.Select(t => t.ToSnapshot()).ToList();

        target.ExternalSatisfied = true;
        await context.SaveChangesAsync(ct);

        var afterSnapshot = all.Select(t => t.ToSnapshot()).ToList();
        return Snapshots.EligibilityDiff(beforeSnapshot, afterSnapshot, effectiveNow);
    }

    // MARK: - Frog / corrections -----------------------------------------------------------------------

    /// Port of `TaskStore.setFrog(_:)`: sets <paramref name="id"/> as the single "frog of the day",
    /// clearing the flag on every other task. <see langword="null"/> clears it everywhere.
    public async Task SetFrogAsync(Guid? id, CancellationToken ct = default)
    {
        await using var context = await _contextFactory.CreateDbContextAsync(ct);
        var tasks = await context.Tasks.ToListAsync(ct);
        var changed = false;
        foreach (var task in tasks)
        {
            var shouldBeFrog = task.Id == id;
            if (task.Frog != shouldBeFrog)
            {
                task.Frog = shouldBeFrog;
                changed = true;
            }
        }
        if (changed)
        {
            await context.SaveChangesAsync(ct);
        }
    }

    /// Port of `TaskStore.recordCorrection(...)` (constitution V / FR-044).
    public async Task RecordCorrectionAsync(string attribute, string parsed, string corrected, string transcript, CancellationToken ct = default)
    {
        await using var context = await _contextFactory.CreateDbContextAsync(ct);
        context.ParseCorrections.Add(new ParseCorrectionEntity
        {
            Id = Guid.NewGuid(),
            Attribute = attribute,
            ParsedValue = parsed,
            CorrectedValue = corrected,
            Transcript = transcript,
            CreatedAt = DateTimeOffset.UtcNow,
        });
        await context.SaveChangesAsync(ct);
    }

    // MARK: - Helpers ------------------------------------------------------------------------------------

    private static async Task<List<TaskSnapshot>> BuildSnapshotAsync(VolarDbContext context, CancellationToken ct)
    {
        var tasks = await context.Tasks.Include(t => t.Conditions).ToListAsync(ct);
        return tasks.Select(t => t.ToSnapshot()).ToList();
    }

    /// Unlike `TaskStore.hasChildren`'s Swift original (which falls back to 0/false on any
    /// `fetchCount` failure — a defensive shim against a documented `// UNVERIFIED` SwiftData
    /// concern), this deliberately lets an EF Core/SQLite query failure propagate. EF Core against
    /// SQLite does not have the specific "occasionally throws on a routine count" concern the Swift
    /// comment was guarding against, so failing loud here surfaces a real bug earlier instead of
    /// silently treating "query failed" the same as "no children" (which would incorrectly allow a
    /// recurrence to be set on a task that might actually have children). Flagged for Opus review.
    private static Task<bool> HasChildrenAsync(VolarDbContext context, Guid id, CancellationToken ct) =>
        context.Tasks.AnyAsync(t => t.ParentId == id, ct);

    private static string Describe(DependencyError error) => error switch
    {
        DependencyError.Cycle c =>
            $"“{c.From}” is already waiting on “{c.To}” — making “{c.To}” wait on “{c.From}” would create a loop.",
        DependencyError.SelfDependency s => $"“{s.Title}” can't wait on itself.",
        _ => throw new NotSupportedException($"Unhandled {nameof(DependencyError)} subtype: {error.GetType()}"),
    };
}
