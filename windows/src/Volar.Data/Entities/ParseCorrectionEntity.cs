// Entities/ParseCorrectionEntity.cs — port of Sources/Model/ParseCorrection.swift's @Model.
namespace Volar.Data.Entities;

/// <summary>
/// One user correction of a parsed attribute (constitution V, FR-044). Local-only: nothing in this
/// project has a network code path, and nothing here ever egresses a row anywhere — the only
/// persistence is the same local SQLite store used for <see cref="TaskEntity"/> /
/// <see cref="CompletionEventEntity"/>.
/// </summary>
public sealed class ParseCorrectionEntity
{
    public Guid Id { get; set; }

    /// Free-form (not an enum) so a new chip kind added later by another agent can log a correction
    /// without a matching case added here — same rationale as the Swift original.
    public required string Attribute { get; set; }

    public required string ParsedValue { get; set; }

    public required string CorrectedValue { get; set; }

    public required string Transcript { get; set; }

    public DateTimeOffset CreatedAt { get; set; }
}
