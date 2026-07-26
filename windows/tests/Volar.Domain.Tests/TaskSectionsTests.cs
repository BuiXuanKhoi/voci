using Volar.Core;
using Volar.Domain;
using Xunit;

namespace Volar.Domain.Tests;

public class TaskSectionsTests
{
    // Fixed, non-DST zone (UTC+7); no test reads the system clock.
    private static readonly TimeZoneInfo Ict = TimeZoneInfo.CreateCustomTimeZone("ICT-sections-test", TimeSpan.FromHours(7), "ICT", "ICT");

    // Monday, 2026-03-16, 09:00 +07:00.
    private static readonly DateTimeOffset Now = new(2026, 3, 16, 9, 0, 0, TimeSpan.FromHours(7));

    private static DateTimeOffset Cut => TaskSections.StartOfTomorrow(Now, Ict);

    private static DateTimeOffset Local(int day, int hour) => new(2026, 3, day, hour, 0, 0, TimeSpan.FromHours(7));

    private static TaskItem Task(
        DateTimeOffset? deadline = null,
        IReadOnlyList<Condition>? conditions = null,
        TaskState status = TaskState.Todo) =>
        new()
        {
            Id = Guid.NewGuid(),
            Title = "t",
            Details = string.Empty,
            Status = status,
            Deadline = deadline,
            Conditions = conditions ?? Array.Empty<Condition>(),
            CreatedAt = Now,
        };

    // MARK: - The day boundary itself

    [Fact]
    public void StartOfTomorrow_IsLocalMidnight_NotNowPlus24h()
    {
        var local = TimeZoneInfo.ConvertTime(Cut, Ict);
        Assert.Equal(new DateTime(2026, 3, 17, 0, 0, 0), local.DateTime);
    }

    // MARK: - Inbox

    [Fact]
    public void Inbox_NoDeadlineNoConditions_IsInbox()
    {
        Assert.True(TaskSections.IsInbox(Task()));
    }

    [Fact]
    public void Inbox_WithDeadline_IsNotInbox()
    {
        Assert.False(TaskSections.IsInbox(Task(deadline: Local(20, 9))));
    }

    [Fact]
    public void Inbox_WithAnyCondition_IsNotInbox()
    {
        // Blocked-on-another-task is a chain, not an unsorted capture — even though it has no date.
        var blocked = Task(conditions: new Condition[] { new TaskDoneCondition(Guid.NewGuid()) });
        Assert.False(TaskSections.IsInbox(blocked));
    }

    [Theory]
    [InlineData(TaskState.Done)]
    [InlineData(TaskState.Archived)]
    public void Inbox_ResolvedTask_IsNotInbox(TaskState status)
    {
        Assert.False(TaskSections.IsInbox(Task(status: status)));
    }

    // MARK: - Upcoming: deadlines

    [Fact]
    public void Upcoming_DeadlineTomorrow_IsUpcoming()
    {
        Assert.Equal(Local(17, 9), TaskSections.UpcomingDate(Task(deadline: Local(17, 9)), Cut));
    }

    [Fact]
    public void Upcoming_DeadlineLaterToday_IsNotUpcoming()
    {
        // Still due today -> Today owns it, even though the instant is in the future.
        Assert.Null(TaskSections.UpcomingDate(Task(deadline: Local(16, 23)), Cut));
    }

    [Fact]
    public void Upcoming_OverdueDeadline_IsNotUpcoming()
    {
        Assert.Null(TaskSections.UpcomingDate(Task(deadline: Local(14, 9)), Cut));
    }

    [Fact]
    public void Upcoming_DeadlineExactlyAtMidnight_IsUpcoming()
    {
        // The boundary is inclusive on the Upcoming side: 00:00 tomorrow is a later calendar day.
        Assert.Equal(Cut, TaskSections.UpcomingDate(Task(deadline: Cut), Cut));
    }

    // MARK: - Upcoming: deferred tasks (the reason this section exists at all)

    [Fact]
    public void Upcoming_DeferredToFutureDate_IsUpcoming_EvenWithNoDeadline()
    {
        var deferred = Task(conditions: new Condition[] { new AfterDateCondition(Local(19, 8)) });
        Assert.Equal(Local(19, 8), TaskSections.UpcomingDate(deferred, Cut));
    }

    [Fact]
    public void Upcoming_DeferPassed_IsNotUpcoming()
    {
        var deferred = Task(conditions: new Condition[] { new AfterDateCondition(Local(15, 8)) });
        Assert.Null(TaskSections.UpcomingDate(deferred, Cut));
    }

    [Fact]
    public void Upcoming_NonDateCondition_DoesNotQualify()
    {
        var blocked = Task(conditions: new Condition[] { new ExternalCondition("waiting on Bob", false) });
        Assert.Null(TaskSections.UpcomingDate(blocked, Cut));
    }

    [Fact]
    public void Upcoming_DeadlineAndDefer_GroupsUnderTheEarlier()
    {
        // Deferred to Wednesday, due Friday: Wednesday is the next date the user must care about.
        var both = Task(
            deadline: Local(20, 17),
            conditions: new Condition[] { new AfterDateCondition(Local(18, 8)) });
        Assert.Equal(Local(18, 8), TaskSections.UpcomingDate(both, Cut));
    }

    [Fact]
    public void Upcoming_FutureDeadlineWithPastDefer_UsesTheDeadline()
    {
        var both = Task(
            deadline: Local(20, 17),
            conditions: new Condition[] { new AfterDateCondition(Local(15, 8)) });
        Assert.Equal(Local(20, 17), TaskSections.UpcomingDate(both, Cut));
    }

    [Fact]
    public void Upcoming_MultipleFutureDefers_UsesTheEarliest()
    {
        var many = Task(conditions: new Condition[]
        {
            new AfterDateCondition(Local(22, 8)),
            new AfterDateCondition(Local(18, 8)),
            new AfterDateCondition(Local(25, 8)),
        });
        Assert.Equal(Local(18, 8), TaskSections.UpcomingDate(many, Cut));
    }

    [Theory]
    [InlineData(TaskState.Done)]
    [InlineData(TaskState.Archived)]
    public void Upcoming_ResolvedTask_IsNotUpcoming(TaskState status)
    {
        Assert.Null(TaskSections.UpcomingDate(Task(deadline: Local(20, 9), status: status), Cut));
    }

    // MARK: - The sections must not overlap

    [Fact]
    public void InboxAndUpcoming_AreDisjoint()
    {
        var candidates = new[]
        {
            Task(),
            Task(deadline: Local(20, 9)),
            Task(deadline: Local(16, 23)),
            Task(conditions: new Condition[] { new AfterDateCondition(Local(19, 8)) }),
            Task(conditions: new Condition[] { new TaskDoneCondition(Guid.NewGuid()) }),
        };

        foreach (var task in candidates)
        {
            Assert.False(TaskSections.IsInbox(task) && TaskSections.IsUpcoming(task, Cut));
        }
    }
}
