// Entities/ConditionMapping.cs — ConditionEntity <-> Volar.Core.Condition, the C# analogue of
// VolarTask.swift's private ConditionDTO + its `asCondition` getter / `conditions` setter.
using Volar.Core;

namespace Volar.Data.Entities;

public static class ConditionMapping
{
    /// <summary>
    /// Converts a persisted row back to the engine type. Throws only on a truly unrecognized
    /// <see cref="ConditionEntity.Kind"/> or a missing required payload field for the given kind —
    /// that should never happen for a row this project itself wrote (see
    /// <see cref="ToEntity"/>/<see cref="TaskRepository"/>'s insert path), but unlike Swift's
    /// per-element "decode failure -&gt; drop the element" tolerance (VolarTask.conditions getter),
    /// a malformed row surfacing here indicates the *database itself* is corrupt (a hostile direct
    /// edit, or a bug), which is a louder failure than a malformed JSON blob would be — callers that
    /// need Swift's forgiving behavior should catch and skip, matching
    /// <c>TaskEntity.ToSnapshot()</c>'s callers if that tolerance is ever needed at the query layer.
    /// </summary>
    public static Condition ToCoreCondition(this ConditionEntity entity) => entity.Kind switch
    {
        "taskDone" => new TaskDoneCondition(
            entity.TaskDoneTargetId
                ?? throw new InvalidOperationException($"Condition row {entity.Id} has Kind=taskDone but no TaskDoneTargetId.")),
        "afterDate" => new AfterDateCondition(
            entity.AfterDate
                ?? throw new InvalidOperationException($"Condition row {entity.Id} has Kind=afterDate but no AfterDate.")),
        "external" => new ExternalCondition(
            entity.ExternalDescription
                ?? throw new InvalidOperationException($"Condition row {entity.Id} has Kind=external but no ExternalDescription."),
            entity.ExternalSatisfied
                ?? throw new InvalidOperationException($"Condition row {entity.Id} has Kind=external but no ExternalSatisfied.")),
        _ => throw new InvalidOperationException($"Condition row {entity.Id} has unrecognized Kind '{entity.Kind}'."),
    };

    /// <summary>
    /// Converts an engine-facing <see cref="Condition"/> into a persistable row for <paramref
    /// name="taskId"/> at position <paramref name="orderIndex"/>. Always assigns a fresh
    /// <see cref="Guid"/> for the row's own identity (distinct from any id the condition payload
    /// itself carries, e.g. <see cref="TaskDoneCondition.TaskId"/>).
    /// </summary>
    public static ConditionEntity ToEntity(this Condition condition, Guid taskId, int orderIndex) => condition switch
    {
        TaskDoneCondition c => new ConditionEntity
        {
            Id = Guid.NewGuid(),
            TaskId = taskId,
            OrderIndex = orderIndex,
            Kind = "taskDone",
            TaskDoneTargetId = c.TaskId,
        },
        AfterDateCondition c => new ConditionEntity
        {
            Id = Guid.NewGuid(),
            TaskId = taskId,
            OrderIndex = orderIndex,
            Kind = "afterDate",
            AfterDate = c.Date,
        },
        ExternalCondition c => new ConditionEntity
        {
            Id = Guid.NewGuid(),
            TaskId = taskId,
            OrderIndex = orderIndex,
            Kind = "external",
            ExternalDescription = c.Description,
            ExternalSatisfied = c.Satisfied,
        },
        _ => throw new NotSupportedException($"Unhandled {nameof(Condition)} subtype: {condition.GetType()}"),
    };
}
