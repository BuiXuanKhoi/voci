// Volar.Domain/TaskItem.cs — port of Sources/Model/TaskItem.swift: UI/domain task model + mapping
// into Volar.Core.TaskSnapshot (v2 shape, contracts/volarcore-api.md).
using System.Globalization;
using Volar.Core;

namespace Volar.Domain;

/// <summary>
/// UI-facing priority, 1 (highest) ... 3 (lowest). Maps 1:1 onto <see cref="TaskSnapshot.Priority"/>'s
/// <c>int?</c> scale via the numeric enum value (the engine additionally allows 4 / <see
/// langword="null"/>; this app never produces those, so this enum only needs high/medium/low).
/// </summary>
public enum Priority
{
    High = 1,
    Medium = 2,
    Low = 3
}

/// <summary>
/// UI-only "Now" vs "Later today" bucket. Volar.Core has no notion of this; it is purely how the
/// app groups its task list, mirroring the prototype's <c>task.when</c>.
/// </summary>
public enum When
{
    Now,
    Later
}

/// <summary>
/// UI/domain task model — the mutable value the app edits and lists, distinct from
/// <see cref="TaskSnapshot"/> (the small immutable-by-convention value <see cref="Snapshot"/> maps
/// into for the selection engine).
/// </summary>
/// <remarks>
/// Declared as a (non-<see langword="readonly"/>) <see langword="record struct"/> — like
/// <see cref="TaskSnapshot"/> — to mirror the Swift <c>struct TaskItem: Identifiable, Sendable,
/// Equatable</c>'s <c>var</c>-field (mutable-in-place, copy-on-assignment) value semantics.
/// <para>
/// Unlike the Swift source, <see cref="Id"/> and <see cref="CreatedAt"/> have no default values in
/// the constructor below: Swift defaulted them to <c>UUID()</c> / <c>Date()</c>, but the latter
/// reads the system clock, which this project's domain-purity rule forbids ("mọi thời điểm 'bây
/// giờ' phải là tham số truyền vào") — every instant must be supplied explicitly by the caller.
/// </para>
/// </remarks>
public record struct TaskItem
{
    public Guid Id { get; set; }
    public string Title { get; set; }
    public string Details { get; set; }
    public Priority Priority { get; set; }
    public TaskState Status { get; set; }
    public DateTimeOffset? Deadline { get; set; }

    /// <summary>
    /// Gates eligibility (replaces v1's <c>dependsOn: [Guid]</c> — data-model.md "Persisted
    /// layer"). AND semantics, mirrors <see cref="TaskSnapshot.Conditions"/> 1:1 (see
    /// <see cref="Snapshot"/>). A <see cref="TaskDoneCondition"/> must be validated via
    /// <see cref="DependencyGraph.ValidateCondition"/> by the persistence layer before being
    /// attached — this struct itself carries no validation, matching <see cref="Condition"/>'s own
    /// pure-value nature.
    /// </summary>
    public IReadOnlyList<Condition> Conditions { get; set; }

    public DateTimeOffset CreatedAt { get; set; }
    public When When { get; set; }
    public int? DurationMinutes { get; set; }
    public bool Frog { get; set; }

    // MARK: - v2 fields (specs/002-workflow-command-center/data-model.md "Persisted layer")

    /// <summary>Free-text notes, distinct from <see cref="Details"/> (the voice-capture read-back copy).</summary>
    public string? Notes { get; set; }

    /// <summary>Verbatim utterance for voice-created tasks — always kept (FR-001).</summary>
    public string? SourceTranscript { get; set; }

    public TaskKind Kind { get; set; }

    /// <summary>
    /// Leaf tasks only — the persistence layer rejects setting this on a task that has children
    /// (data-model.md validation rule 2).
    /// </summary>
    public Recurrence? Recurrence { get; set; }

    /// <summary><see langword="null"/> -&gt; global default <see cref="ReminderPolicy.DefaultPolicy"/>.</summary>
    public ReminderPolicy? ReminderOverride { get; set; }

    /// <summary>"Save game" note surfaced on re-entry (FR-042).</summary>
    public string? ResumeNote { get; set; }

    /// <summary>Switch-away counter; &gt;= 3 triggers a one-time breakdown suggestion (FR-030).</summary>
    public int SwitchAwayCount { get; set; }

    /// <summary>
    /// Latest completion instant; full history lives elsewhere (a <c>CompletionEvent</c> log,
    /// outside this project's scope) — recurrence resets in place, so this field alone can't
    /// reconstruct history.
    /// </summary>
    public DateTimeOffset? CompletedAt { get; set; }

    /// <summary>
    /// Breakdown child -&gt; parent link. Engine rule: a task that is a parent of any open child is
    /// excluded from <see cref="NextTaskSelector.NextTask"/>, even though it stays selectable in its
    /// own right once every child is done/archived.
    /// </summary>
    public Guid? ParentId { get; set; }

    /// <summary>
    /// Present while delegated-to-AI (US4); cleared once the matching <see cref="ExternalCondition"/>
    /// is satisfied (signal or manual).
    /// </summary>
    public DelegationMeta? Delegation { get; set; }

    public TaskItem(
        Guid id,
        string title,
        Priority priority,
        When when,
        DateTimeOffset createdAt,
        string details = "",
        TaskState status = TaskState.Todo,
        DateTimeOffset? deadline = null,
        IReadOnlyList<Condition>? conditions = null,
        int? durationMinutes = null,
        bool frog = false,
        string? notes = null,
        string? sourceTranscript = null,
        TaskKind kind = TaskKind.Task,
        Recurrence? recurrence = null,
        ReminderPolicy? reminderOverride = null,
        string? resumeNote = null,
        int switchAwayCount = 0,
        DateTimeOffset? completedAt = null,
        Guid? parentId = null,
        DelegationMeta? delegation = null)
    {
        Id = id;
        Title = title;
        Details = details;
        Priority = priority;
        Status = status;
        Deadline = deadline;
        Conditions = conditions ?? Array.Empty<Condition>();
        CreatedAt = createdAt;
        When = when;
        DurationMinutes = durationMinutes;
        Frog = frog;
        Notes = notes;
        SourceTranscript = sourceTranscript;
        Kind = kind;
        Recurrence = recurrence;
        ReminderOverride = reminderOverride;
        ResumeNote = resumeNote;
        SwitchAwayCount = switchAwayCount;
        CompletedAt = completedAt;
        ParentId = parentId;
        Delegation = delegation;
    }

    /// <summary>Derived: "done" is purely the engine status, never a separately stored bool.</summary>
    public readonly bool Done => Status == TaskState.Done;

    /// <summary>
    /// Derived: formatted deadline time ("11:30 AM"); <see langword="null"/> once done or when
    /// there's no deadline at all — matches the prototype's <c>timeBadge</c> (only ever shown for
    /// open tasks). Formats whatever offset <see cref="Deadline"/> itself carries (this type has no
    /// injected <see cref="TimeZoneInfo"/> of its own); always <see cref="CultureInfo.InvariantCulture"/>
    /// so the rendered string never varies by machine locale.
    /// </summary>
    public readonly string? TimeBadge
    {
        get
        {
            if (Done || Deadline is not DateTimeOffset deadline)
            {
                return null;
            }
            return deadline.ToString("h:mm tt", CultureInfo.InvariantCulture);
        }
    }

    /// <summary>Derived: "45 min" / "1 hr" / "1h 30m" — matches the prototype's <c>dur</c> label.</summary>
    public readonly string? DurationLabel
    {
        get
        {
            if (DurationMinutes is not int minutes || minutes <= 0)
            {
                return null;
            }
            if (minutes < 60)
            {
                return $"{minutes.ToString(CultureInfo.InvariantCulture)} min";
            }
            var hours = minutes / 60;
            var remainder = minutes % 60;
            if (remainder == 0)
            {
                return hours == 1 ? "1 hr" : $"{hours.ToString(CultureInfo.InvariantCulture)} hrs";
            }
            return $"{hours.ToString(CultureInfo.InvariantCulture)}h {remainder.ToString(CultureInfo.InvariantCulture)}m";
        }
    }

    /// <summary>
    /// The only bridge into the pure selection engine (contracts/volarcore-api.md): maps this
    /// domain struct into the small value type <see cref="NextTaskSelector.NextTask"/> actually
    /// consumes. No selection logic is duplicated here. <see cref="DurationMinutes"/> feeds the
    /// engine's <see cref="TaskSnapshot.EstimateMinutes"/> — same concept, kept under its existing
    /// domain-facing name here.
    /// </summary>
    public readonly TaskSnapshot Snapshot() => new(
        Id,
        Title,
        Status,
        (int)Priority,
        Deadline,
        Conditions,
        DurationMinutes,
        ParentId,
        CreatedAt);
}
