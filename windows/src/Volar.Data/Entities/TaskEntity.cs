// Entities/TaskEntity.cs — port of Sources/Model/VolarTask.swift's @Model VolarTask.
//
// SEAM NOTE (read before touching this file): Volar.Domain (which will own TaskItem, the Swift-
// side in-memory counterpart VolarTask.asTaskItem/apply(_:) converts to/from) had zero .cs files
// at the time this project was written — Volar.Domain is being built in parallel by a sibling
// agent (W1-B). Rather than invent a fake TaskItem type here (or block on Volar.Domain), this
// entity plays BOTH roles for now: it is the EF Core-mapped persisted row AND the shape callers of
// Volar.Data get back from TaskRepository. Once Volar.Domain.TaskItem exists, Opus should add
// `TaskEntity.ToTaskItem()` / `TaskRepository.Add(TaskItem)` overloads that translate between the
// two shapes — none of TaskRepository's internals need to change, only its public surface gains an
// additional TaskItem-shaped overload/adapter.
//
// Fields not consumed by Volar.Core.TaskSnapshot (When/Kind/Recurrence/ReminderOverride/
// Delegation/...) are stored as opaque raw strings / JSON text here, exactly as VolarTask.swift
// stores them as raw strings / JSON `Data` blobs — this project has no visibility into the actual
// Volar.Domain enum/struct shapes (When, TaskKind, Recurrence, ReminderPolicy, DelegationMeta), so
// it cannot decode them into typed values. A future Domain/Reminders/Orchestrator-owning agent
// should add typed accessor properties (mirroring VolarTask's `recurrence`/`reminderOverride`/
// `delegation` computed properties: JSON decode with a fail-closed `null` fallback on malformed
// data) once those types exist. See TaskRepository.cs for the corresponding write-side notes.
//
// Migration note: unlike VolarTask.swift, this entity has NO `dependsOn` legacy field and no
// `foldLegacyDependsOn()` — the brief for this port explicitly says a from-SwiftData migration is
// out of scope (Windows is a fresh install), so the dead v1->v2 compatibility shim was dropped
// rather than ported. Flagged in the final report per the task's "bẫy" list, item 1.
using Volar.Core;

namespace Volar.Data.Entities;

/// <summary>
/// Persisted task row. Status/When/Kind are stored as raw strings (not the C# enums an eventual
/// Volar.Domain would define) so this project stays fully decoupled from Volar.Domain's in-progress
/// shape — mirrors VolarTask.swift's own `statusRaw`/`whenRaw`/`kindRaw` string-backed design,
/// which exists for the analogous reason (decoupling the persistence model from
/// `VolarCore.TaskStatus`'s exact Codable/storage shape).
/// </summary>
public sealed class TaskEntity
{
    public Guid Id { get; set; }

    public required string Title { get; set; }

    /// Default "" — mirrors VolarTask.details' migration-safe default.
    public string Details { get; set; } = "";

    /// Raw 1...4 scale (see VolarTask.priorityRaw / VolarCore's Priority notion). Always populated
    /// for a persisted row — VolarTask's initializer requires an explicit `Priority`, so unlike
    /// TaskSnapshot.Priority (which is `int?` at the engine boundary to represent "unset"), there is
    /// no "unset" persisted state here. ToSnapshot() below always projects this as a non-null value.
    public int PriorityRaw { get; set; }

    /// One of "todo" / "inProgress" / "done" / "archived" — same raw values as
    /// `VolarTask.rawValue(for:)`/`status(from:)`. Use <see cref="Status"/> for the typed,
    /// fail-closed (defaults to Todo on any unrecognized value) accessor.
    public string StatusRaw { get; set; } = "todo";

    public DateTimeOffset? Deadline { get; set; }

    public DateTimeOffset CreatedAt { get; set; }

    /// "now" / "later" — VolarCore.TaskSnapshot has no equivalent field; this is carried purely for
    /// the eventual Volar.Domain `When` bucket and is opaque here.
    public string WhenRaw { get; set; } = "now";

    /// Maps 1:1 to VolarCore.TaskSnapshot.EstimateMinutes (see ToSnapshot()).
    public int? DurationMinutes { get; set; }

    public bool Frog { get; set; }

    // v2 attributes ------------------------------------------------------------------------------

    public string? Notes { get; set; }

    public string? SourceTranscript { get; set; }

    /// "task" / ... — VolarTask.kindRaw default "task". Opaque here (TaskKind is a Domain type).
    public string KindRaw { get; set; } = "task";

    public string? ResumeNote { get; set; }

    public int SwitchAwayCount { get; set; }

    public DateTimeOffset? CompletedAt { get; set; }

    /// Breakdown-parent link. See VolarDbContext's self-referencing FK config: ON DELETE SET NULL,
    /// matching TaskStore.delete's explicit "null children's parentId" behavior (belt-and-suspenders
    /// — TaskRepository.DeleteAsync also does this explicitly in application code, exactly like
    /// TaskStore.swift, so the DB-level SET NULL is a defensive backstop, not the primary mechanism).
    public Guid? ParentId { get; set; }

    /// Phase 4 contract §E/§B: never threaded through the Domain-facing shape by design (see
    /// VolarTask.isSensitive's doc comment) — read directly by the Reminders module at fire time.
    public bool IsSensitive { get; set; }

    /// Opaque JSON text for VolarCore.Recurrence's eventual Domain wrapper (`Recurrence?`). Stored
    /// as TEXT (not a BLOB, unlike Swift's `Data`) purely so it's human-inspectable in the SQLite
    /// file; still fully opaque to this project.
    public string? RecurrenceJson { get; set; }

    /// Opaque JSON text for the eventual `ReminderPolicy?` per-task override.
    public string? ReminderOverrideJson { get; set; }

    /// Opaque JSON text for the eventual `DelegationMeta?`.
    public string? DelegationJson { get; set; }

    /// Ordered child rows — order preserved via <see cref="ConditionEntity.OrderIndex"/> (Swift's
    /// `conditions` is an ordered `[Condition]` array; `clearFirstExternal` depends on "first
    /// unsatisfied" meaning list order, so order must be preserved exactly).
    public List<ConditionEntity> Conditions { get; set; } = [];

    // Typed, fail-closed accessors (not EF-mapped — see VolarDbContext.OnModelCreating's
    // `b.Ignore(...)` calls) -----------------------------------------------------------------------

    /// Fail-closed accessor over <see cref="StatusRaw"/>: an unrecognized raw value (hostile direct
    /// DB edit, future case this build doesn't know about) reads back as <see cref="TaskState.Todo"/>
    /// rather than throwing — mirrors VolarTask.status(from:)'s `default: return .todo`.
    public TaskState Status
    {
        get => StatusRaw switch
        {
            "inProgress" => TaskState.InProgress,
            "done" => TaskState.Done,
            "archived" => TaskState.Archived,
            _ => TaskState.Todo,
        };
        set => StatusRaw = value switch
        {
            TaskState.InProgress => "inProgress",
            TaskState.Done => "done",
            TaskState.Archived => "archived",
            _ => "todo",
        };
    }

    /// Projects this row into the pure value type Volar.Core's selection engine consumes. Only the
    /// subset of fields TaskSnapshot actually declares participates — everything else on this
    /// entity (Details/Notes/Recurrence/...) is app-layer-only and never crosses into Volar.Core.
    /// <see cref="Conditions"/> is projected in <see cref="ConditionEntity.OrderIndex"/> order so
    /// engine-side behavior that (incidentally) depends on condition order stays deterministic and
    /// matches whatever order the row was originally written in.
    public TaskSnapshot ToSnapshot() => new(
        Id,
        Title,
        Status,
        PriorityRaw,
        Deadline,
        Conditions
            .OrderBy(c => c.OrderIndex)
            .Select(c => c.ToCoreCondition())
            .ToList(),
        DurationMinutes,
        ParentId,
        CreatedAt);
}
