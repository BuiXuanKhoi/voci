namespace Volar.Core;

/// <summary>
/// The lifecycle status of a <see cref="TaskSnapshot"/>.
/// </summary>
/// <remarks>
/// Eligibility mapping (see <see cref="NextTaskSelector.NextTask"/>):
/// <list type="bullet">
/// <item>Eligible for selection: <see cref="Todo"/>, <see cref="InProgress"/>.</item>
/// <item>Not eligible: <see cref="Done"/>, <see cref="Archived"/>.</item>
/// </list>
/// <para>
/// <see cref="TaskDoneCondition"/> resolution mapping (see <c>Condition.cs</c> and
/// <c>NextTask.cs</c>): a <see cref="TaskDoneCondition"/> counts as <i>satisfied</i> when the task
/// it refers to is <see cref="Done"/> or <see cref="Archived"/> (or is absent from the snapshot
/// entirely, i.e. deleted). A referenced task that is still <see cref="Todo"/> or
/// <see cref="InProgress"/> continues to block its dependent.
/// </para>
/// </remarks>
public enum TaskState
{
    Todo,
    InProgress,
    Done,
    Archived
}

/// <summary>
/// A pure, immutable-by-convention snapshot of a task, as consumed by the Volar.Core selection
/// engine.
/// </summary>
/// <remarks>
/// This is intentionally a small subset of the fully persisted task model (see
/// <c>specs/002-workflow-command-center/data-model.md</c>): only the fields relevant to
/// eligibility and ordering are represented here. The app layer (Volar.Data / Volar.Domain) is
/// responsible for mapping its persisted model into this value type before calling into
/// Volar.Core.
/// <para>
/// Declared as a <c>record struct</c> (not a <c>record class</c>) to mirror the Swift
/// <c>struct Task: Sendable, Equatable</c>'s value semantics: assigning a <see cref="TaskSnapshot"/>
/// to a new variable and mutating the copy must never affect the original, exactly as Swift's
/// copy-on-assignment struct semantics guarantee. Named <c>TaskSnapshot</c> rather than
/// <c>Task</c> to avoid colliding with <see cref="System.Threading.Tasks.Task"/>.
/// </para>
/// </remarks>
/// <param name="Id">
/// Stable unique identity. Used as the final tiebreak (ordinal order of its string form) in
/// <see cref="NextTaskSelector.OrderedBefore"/> to guarantee a strict total order.
/// </param>
/// <param name="Title">
/// Human-readable title. Not used by ordering or eligibility; carried so dependency-graph errors
/// (<see cref="DependencyError"/>) can produce a readable message.
/// </param>
/// <param name="Status">
/// Drives eligibility (only <see cref="TaskState.Todo"/>/<see cref="TaskState.InProgress"/> are
/// selectable) and tier 1 of the ordering (in-progress ranks before to-do).
/// </param>
/// <param name="Priority">
/// Explicit priority on a 1 (highest) ... 4 scale. <see langword="null"/> means "unset" and is a
/// distinct state from any numeric value: unset priority always sorts after every explicit
/// priority in tier 3 of the ordering.
/// </param>
/// <param name="Deadline">
/// Absolute deadline instant (UTC-backed via <see cref="DateTimeOffset"/>). Drives ORDERING tier 2
/// (near-term urgency) and app-layer reminders only — never gates eligibility.
/// <see langword="null"/> means "no deadline".
/// </param>
/// <param name="Conditions">
/// Eligibility gates. A task is eligible only once every condition here is satisfied (AND
/// semantics) — see <c>Condition.IsSatisfied</c>.
/// </param>
/// <param name="EstimateMinutes">
/// Estimated effort in minutes. Not used by ordering or eligibility; carried for the app layer
/// (quick-win surfacing, focus overlay, future "available minutes" mode).
/// </param>
/// <param name="ParentId">
/// Id of the breakdown parent, if this task is a child. Engine rule: a task that is the parent of
/// any task with status Todo/InProgress is not directly selectable (see <c>NextTask.cs</c>).
/// </param>
/// <param name="CreatedAt">
/// Creation timestamp; earlier tasks are preferred in tier 4 of the ordering when all prior tiers
/// tie.
/// </param>
public record struct TaskSnapshot(
    Guid Id,
    string Title,
    TaskState Status,
    int? Priority,
    DateTimeOffset? Deadline,
    IReadOnlyList<Condition> Conditions,
    int? EstimateMinutes,
    Guid? ParentId,
    DateTimeOffset CreatedAt);
