// Entities/TaskEntityMapping.cs — TaskEntity <-> Volar.Domain.TaskItem, resolving the Wave-1 note
// left at TaskEntity.cs:6-9 ("once Volar.Domain.TaskItem exists, Opus should add
// TaskEntity.ToTaskItem() / TaskRepository.Add(TaskItem) overloads"). Wave 3-C (C2, contract
// decision 6): services speak Volar.Domain.TaskItem, never TaskEntity — this file is the ONLY
// bridge between the two shapes, mirroring VolarTask.swift's `asTaskItem` getter / `apply(_:)`
// setter pair (Sources/Model/VolarTask.swift:229-280) field-for-field.
//
// SCOPE: this file provides <see cref="ToTaskItem"/> (entity -> domain, full fidelity) and
// <see cref="ToEntity"/> (domain -> entity, for TaskRepository.AddAsync/AddBatchAsync — there is no
// generic "update an existing row from a TaskItem" path here because TaskRepository itself exposes
// none yet: every mutation it supports is a narrow, purpose-built method (ToggleAsync/SetFrogAsync/
// AddConditionAsync/...), never a blanket "save this whole TaskItem back". `apply(_:)`'s C# mirror
// can be added the day a caller actually needs a full-record edit path; inventing one now with no
// caller would be untested, unused surface.
//
// JSON CODEC: RecurrenceJson/ReminderOverrideJson/DelegationJson are opaque TEXT columns on
// TaskEntity (see that file's own doc comments) — Volar.Data has no visibility into Volar.Domain's
// Recurrence/ReminderPolicy/DelegationMeta *shapes* until this file, which is the first thing in
// this project allowed to decode them (Volar.Data already references Volar.Domain — see this
// project's .csproj comment for JsonFileSettingsStore/ISettingsStore, the first sanctioned
// exception to the original "Core only" rule). There is no cross-language wire-compatibility
// requirement (the brief for this port is a fresh Windows install, not a SwiftData migration — see
// TaskEntity.cs's own "Migration note"), so the JSON shape below is this port's own invention, not a
// mirror of Swift's `Codable`-synthesized encoding. Every decode is wrapped to fail closed to
// <see langword="null"/> on malformed JSON — mirrors `VolarTask.recurrence`/`reminderOverride`/
// `delegation`'s own `try?`-based tolerance (a corrupt blob degrades to "unset", never throws).
using System.Text.Json;
using Volar.Core;
using Volar.Domain;

namespace Volar.Data.Entities;

public static class TaskEntityMapping
{
    // Case-insensitive so a hand-authored or future-tooling-written blob using camelCase keys
    // (the more common JSON convention) still round-trips against this project's own PascalCase
    // record property names — this codec has no cross-process/cross-language wire-compat
    // requirement (see this file's header), so there is no reason to be stricter than necessary.
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };

    // MARK: - Entity -> Domain

    /// <summary>
    /// Projects a persisted row into the domain shape every Wave 3-C service actually speaks.
    /// Round-trips every field <see cref="TaskEntity"/> carries, including conditions (in
    /// <see cref="ConditionEntity.OrderIndex"/> order — same rule <see cref="TaskEntity.ToSnapshot"/>
    /// already follows), recurrence, reminder override, parent link, frog, and resume note.
    /// Deliberately does NOT surface <see cref="TaskEntity.IsSensitive"/> — <see cref="TaskItem"/>
    /// has no such field by design (mirrors `VolarTask.isSensitive`'s own doc comment: "never
    /// threaded through the Domain-facing shape... read directly by the Reminders module at fire
    /// time").
    /// </summary>
    public static TaskItem ToTaskItem(this TaskEntity entity)
    {
        var conditions = entity.Conditions
            .OrderBy(c => c.OrderIndex)
            .Select(c => c.ToCoreCondition())
            .ToList();

        return new TaskItem(
            id: entity.Id,
            title: entity.Title,
            priority: PriorityFromRaw(entity.PriorityRaw),
            when: WhenFromRaw(entity.WhenRaw),
            createdAt: entity.CreatedAt,
            details: entity.Details,
            status: entity.Status,
            deadline: entity.Deadline,
            conditions: conditions,
            durationMinutes: entity.DurationMinutes,
            frog: entity.Frog,
            notes: entity.Notes,
            sourceTranscript: entity.SourceTranscript,
            kind: TaskKindFromRaw(entity.KindRaw),
            recurrence: DecodeRecurrence(entity.RecurrenceJson),
            reminderOverride: DecodeReminderPolicy(entity.ReminderOverrideJson),
            resumeNote: entity.ResumeNote,
            switchAwayCount: entity.SwitchAwayCount,
            completedAt: entity.CompletedAt,
            parentId: entity.ParentId,
            delegation: DecodeDelegation(entity.DelegationJson));
    }

    // MARK: - Domain -> Entity

    /// <summary>
    /// Builds a fresh, not-yet-persisted <see cref="TaskEntity"/> from a domain <see cref="TaskItem"/>
    /// — the insert-side half of the bridge, consumed by <c>TaskListService.AddAsync</c>. The
    /// returned entity's <see cref="TaskEntity.Conditions"/> are plain positional-order
    /// <see cref="ConditionEntity"/> rows; <see cref="TaskRepository.InsertSanitized"/> re-derives
    /// them from <see cref="ConditionEntity.ToCoreCondition"/> and re-validates
    /// (<c>SanitizeConditions</c>) before the row is actually written, exactly as it already does
    /// for any other caller — this method does not duplicate that validation.
    /// </summary>
    public static TaskEntity ToEntity(this TaskItem item)
    {
        var entity = new TaskEntity
        {
            Id = item.Id,
            Title = item.Title,
            Details = item.Details,
            PriorityRaw = PriorityToRaw(item.Priority),
            Deadline = item.Deadline,
            CreatedAt = item.CreatedAt,
            WhenRaw = WhenToRaw(item.When),
            DurationMinutes = item.DurationMinutes,
            Frog = item.Frog,
            Notes = item.Notes,
            SourceTranscript = item.SourceTranscript,
            KindRaw = TaskKindToRaw(item.Kind),
            ResumeNote = item.ResumeNote,
            SwitchAwayCount = item.SwitchAwayCount,
            CompletedAt = item.CompletedAt,
            ParentId = item.ParentId,
            RecurrenceJson = EncodeRecurrence(item.Recurrence),
            ReminderOverrideJson = EncodeReminderPolicy(item.ReminderOverride),
            DelegationJson = EncodeDelegation(item.Delegation),
        };
        entity.Status = item.Status;

        var index = 0;
        foreach (var condition in item.Conditions)
        {
            entity.Conditions.Add(condition.ToEntity(item.Id, index));
            index++;
        }

        return entity;
    }

    // MARK: - Priority (raw 1...4 persisted scale <-> Volar.Domain.Priority's 1...3 UI scale)
    //
    // Mirrors `VolarTask.asTaskItem`/`apply(_:)`'s own conversion EXACTLY (`Priority(rawValue:
    // priorityRaw) ?? .medium` / `priorityRaw = item.priority.rawValue`) — deliberately NOT the
    // different clamp `AppState.uiPriority(from:)` uses (`3, 4 -> .low`, `default -> .medium`),
    // which exists for a different call site (an uncertain ENGINE parse result, `Int?`, handled by
    // Wave 3-C's C3/C4). A persisted row's PriorityRaw is always an already-committed value, so the
    // simpler fail-closed-to-Medium default is the correct mirror here.
    private static Priority PriorityFromRaw(int raw) => raw switch
    {
        1 => Priority.High,
        2 => Priority.Medium,
        3 => Priority.Low,
        _ => Priority.Medium,
    };

    private static int PriorityToRaw(Priority priority) => (int)priority;

    // MARK: - When ("now" / anything else -> "later", matches `VolarTask.when(from:)` exactly)

    private static When WhenFromRaw(string raw) => raw == "now" ? When.Now : When.Later;

    private static string WhenToRaw(When when) => when == When.Now ? "now" : "later";

    // MARK: - TaskKind ("task" / "review", unrecognized -> "task", matches `TaskKind(rawValue:) ?? .task`)

    private static TaskKind TaskKindFromRaw(string raw) => raw switch
    {
        "review" => TaskKind.Review,
        _ => TaskKind.Task,
    };

    private static string TaskKindToRaw(TaskKind kind) => kind == TaskKind.Review ? "review" : "task";

    // MARK: - Recurrence JSON codec

    private sealed record RecurrenceDto(string Kind, int? Days);

    private static string? EncodeRecurrence(Recurrence? recurrence)
    {
        if (recurrence is null)
        {
            return null;
        }
        var dto = recurrence switch
        {
            Recurrence.Daily => new RecurrenceDto("daily", null),
            Recurrence.Weekly => new RecurrenceDto("weekly", null),
            Recurrence.Monthly => new RecurrenceDto("monthly", null),
            Recurrence.Every e => new RecurrenceDto("every", e.Days),
            _ => throw new NotSupportedException($"Unhandled {nameof(Recurrence)} subtype: {recurrence.GetType()}"),
        };
        return JsonSerializer.Serialize(dto, JsonOptions);
    }

    /// <summary>Fail-closed: malformed/unrecognized JSON decodes to <see langword="null"/> rather
    /// than throwing — mirrors `VolarTask.recurrence`'s `try?`.</summary>
    private static Recurrence? DecodeRecurrence(string? json)
    {
        if (string.IsNullOrEmpty(json))
        {
            return null;
        }
        try
        {
            var dto = JsonSerializer.Deserialize<RecurrenceDto>(json, JsonOptions);
            return dto?.Kind switch
            {
                "daily" => new Recurrence.Daily(),
                "weekly" => new Recurrence.Weekly(),
                "monthly" => new Recurrence.Monthly(),
                "every" when dto.Days is int days => new Recurrence.Every(days),
                _ => null,
            };
        }
        catch (JsonException)
        {
            return null;
        }
    }

    // MARK: - ReminderPolicy JSON codec
    //
    // TimeSpan is carried as raw Ticks (long), never a culture-sensitive string — same
    // culture-invariance discipline as the rest of this codebase (e.g. TaskItem.TimeBadge's
    // explicit CultureInfo.InvariantCulture).

    private sealed record ReminderPolicyDto(long[] OffsetTicks, long? RepeatEveryTicks);

    private static string? EncodeReminderPolicy(ReminderPolicy? policy)
    {
        if (policy is not ReminderPolicy value)
        {
            return null;
        }
        var dto = new ReminderPolicyDto(
            value.Offsets.Select(o => o.Ticks).ToArray(),
            value.RepeatEvery?.Ticks);
        return JsonSerializer.Serialize(dto, JsonOptions);
    }

    private static ReminderPolicy? DecodeReminderPolicy(string? json)
    {
        if (string.IsNullOrEmpty(json))
        {
            return null;
        }
        try
        {
            var dto = JsonSerializer.Deserialize<ReminderPolicyDto>(json, JsonOptions);
            if (dto?.OffsetTicks is null)
            {
                return null;
            }
            var offsets = dto.OffsetTicks.Select(TimeSpan.FromTicks).ToList();
            TimeSpan? repeat = dto.RepeatEveryTicks is long ticks ? TimeSpan.FromTicks(ticks) : null;
            return new ReminderPolicy(offsets, repeat);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    // MARK: - DelegationMeta JSON codec

    private sealed record DelegationMetaDto(
        string Label, DateTimeOffset CheckBackAt, int BackoffStage, string? CwdHint, DateTimeOffset DelegatedAt);

    private static string? EncodeDelegation(DelegationMeta? meta)
    {
        if (meta is not DelegationMeta value)
        {
            return null;
        }
        var dto = new DelegationMetaDto(value.Label, value.CheckBackAt, value.BackoffStage, value.CwdHint, value.DelegatedAt);
        return JsonSerializer.Serialize(dto, JsonOptions);
    }

    private static DelegationMeta? DecodeDelegation(string? json)
    {
        if (string.IsNullOrEmpty(json))
        {
            return null;
        }
        try
        {
            var dto = JsonSerializer.Deserialize<DelegationMetaDto>(json, JsonOptions);
            if (dto is null)
            {
                return null;
            }
            return new DelegationMeta(dto.Label, dto.CheckBackAt, dto.BackoffStage, dto.CwdHint, dto.DelegatedAt);
        }
        catch (JsonException)
        {
            return null;
        }
    }
}
