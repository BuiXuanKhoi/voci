using Volar.Domain;
using Xunit;

namespace Volar.Parsing.Tests;

public class ParsedTaskValidationTests
{
    private const string SourceTranscript = "remind me to call mom";

    [Fact]
    public void Validate_EmptyTitle_FallsBackToSourceTranscript()
    {
        var raw = new RawParsedTask(new RawConfidence<string>("   ", 0.9));

        var task = ParsedTaskValidation.Validate(raw, SourceTranscript);

        Assert.Equal(SourceTranscript, task.Title);
    }

    [Fact]
    public void Validate_ValidTitle_IsTrimmed()
    {
        var raw = new RawParsedTask(new RawConfidence<string>("  Call mom  ", 0.9));

        var task = ParsedTaskValidation.Validate(raw, SourceTranscript);

        Assert.Equal("Call mom", task.Title);
    }

    [Theory]
    [InlineData(-0.1)]
    [InlineData(1.1)]
    [InlineData(double.NaN)]
    public void Validate_DeadlineWithInvalidConfidence_IsDropped(double confidence)
    {
        var raw = new RawParsedTask(
            new RawConfidence<string>("Call mom", 0.9),
            Deadline: new RawConfidence<string>("2026-07-21T10:00:00Z", confidence));

        var task = ParsedTaskValidation.Validate(raw, SourceTranscript);

        Assert.Null(task.Deadline);
        // Per-attribute failure must not discard the rest of the task.
        Assert.Equal("Call mom", task.Title);
    }

    [Fact]
    public void Validate_DeadlineWithUnparsableDate_IsDropped()
    {
        var raw = new RawParsedTask(
            new RawConfidence<string>("Call mom", 0.9),
            Deadline: new RawConfidence<string>("not-a-date", 0.9));

        var task = ParsedTaskValidation.Validate(raw, SourceTranscript);

        Assert.Null(task.Deadline);
    }

    [Fact]
    public void Validate_DeadlineValid_IsKeptAsUtc()
    {
        var raw = new RawParsedTask(
            new RawConfidence<string>("Call mom", 0.9),
            Deadline: new RawConfidence<string>("2026-07-21T10:00:00Z", 0.85));

        var task = ParsedTaskValidation.Validate(raw, SourceTranscript);

        Assert.NotNull(task.Deadline);
        Assert.Equal(new DateTimeOffset(2026, 7, 21, 10, 0, 0, TimeSpan.Zero), task.Deadline!.Value.Value);
        Assert.Equal(0.85, task.Deadline.Value.Confidence);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(5)]
    [InlineData(1)]
    [InlineData(4)]
    public void Validate_PriorityOutOfRange_IsDropped_InRange_IsKept(int priority)
    {
        var raw = new RawParsedTask(
            new RawConfidence<string>("Call mom", 0.9),
            Priority: new RawConfidence<int>(priority, 0.8));

        var task = ParsedTaskValidation.Validate(raw, SourceTranscript);

        if (priority is >= 1 and <= 4)
        {
            Assert.Equal(priority, task.Priority!.Value.Value);
        }
        else
        {
            Assert.Null(task.Priority);
        }
    }

    [Fact]
    public void Validate_EstimateMinutes_NonPositive_IsDropped()
    {
        var raw = new RawParsedTask(
            new RawConfidence<string>("Call mom", 0.9),
            EstimateMinutes: new RawConfidence<double>(0, 0.8));

        var task = ParsedTaskValidation.Validate(raw, SourceTranscript);

        Assert.Null(task.EstimateMinutes);
    }

    [Fact]
    public void Validate_EstimateMinutes_Positive_IsRoundedToInt()
    {
        var raw = new RawParsedTask(
            new RawConfidence<string>("Call mom", 0.9),
            EstimateMinutes: new RawConfidence<double>(14.6, 0.8));

        var task = ParsedTaskValidation.Validate(raw, SourceTranscript);

        Assert.Equal(15, task.EstimateMinutes!.Value.Value);
    }

    [Theory]
    [InlineData("daily", typeof(Recurrence.Daily))]
    [InlineData("weekly", typeof(Recurrence.Weekly))]
    [InlineData("monthly", typeof(Recurrence.Monthly))]
    public void Validate_RecurrenceSimpleTypes_MapCorrectly(string type, Type expected)
    {
        var raw = new RawParsedTask(
            new RawConfidence<string>("Call mom", 0.9),
            Recurrence: new RawConfidence<RawParsedRecurrence>(new RawParsedRecurrence(type), 0.8));

        var task = ParsedTaskValidation.Validate(raw, SourceTranscript);

        Assert.IsType(expected, task.Recurrence!.Value.Value);
    }

    [Fact]
    public void Validate_RecurrenceEvery_WithPositiveDays_MapsToEvery()
    {
        var raw = new RawParsedTask(
            new RawConfidence<string>("Call mom", 0.9),
            Recurrence: new RawConfidence<RawParsedRecurrence>(new RawParsedRecurrence("every", 3), 0.8));

        var task = ParsedTaskValidation.Validate(raw, SourceTranscript);

        var every = Assert.IsType<Recurrence.Every>(task.Recurrence!.Value.Value);
        Assert.Equal(3, every.Days);
    }

    [Theory]
    [InlineData(null)]
    [InlineData(0)]
    [InlineData(-1)]
    public void Validate_RecurrenceEvery_WithoutPositiveDays_IsDropped(int? days)
    {
        var raw = new RawParsedTask(
            new RawConfidence<string>("Call mom", 0.9),
            Recurrence: new RawConfidence<RawParsedRecurrence>(new RawParsedRecurrence("every", days), 0.8));

        var task = ParsedTaskValidation.Validate(raw, SourceTranscript);

        Assert.Null(task.Recurrence);
    }

    [Fact]
    public void Validate_RecurrenceUnknownType_IsDropped()
    {
        var raw = new RawParsedTask(
            new RawConfidence<string>("Call mom", 0.9),
            Recurrence: new RawConfidence<RawParsedRecurrence>(new RawParsedRecurrence("yearly"), 0.8));

        var task = ParsedTaskValidation.Validate(raw, SourceTranscript);

        Assert.Null(task.Recurrence);
    }

    [Fact]
    public void Validate_ReminderOverride_AllOffsetsNonFinite_IsDropped()
    {
        var raw = new RawParsedTask(
            new RawConfidence<string>("Call mom", 0.9),
            ReminderOverride: new RawConfidence<RawParsedReminderOverride>(
                new RawParsedReminderOverride(new[] { double.NaN }), 0.8));

        var task = ParsedTaskValidation.Validate(raw, SourceTranscript);

        Assert.Null(task.ReminderOverride);
    }

    [Fact]
    public void Validate_ReminderOverride_Valid_ConvertsMinutesToTimeSpan()
    {
        var raw = new RawParsedTask(
            new RawConfidence<string>("Call mom", 0.9),
            ReminderOverride: new RawConfidence<RawParsedReminderOverride>(
                new RawParsedReminderOverride(new[] { -60d, 0d }, 15d), 0.8));

        var task = ParsedTaskValidation.Validate(raw, SourceTranscript);

        Assert.Equal(2, task.ReminderOverride!.Value.Value.Offsets.Count);
        Assert.Equal(TimeSpan.FromMinutes(-60), task.ReminderOverride.Value.Value.Offsets[0]);
        Assert.Equal(TimeSpan.FromMinutes(15), task.ReminderOverride.Value.Value.RepeatEvery);
    }

    [Fact]
    public void Validate_TaskDoneCondition_EmptyReferenceTitle_IsDropped()
    {
        var raw = new RawParsedTask(
            new RawConfidence<string>("Call mom", 0.9),
            Conditions: new[]
            {
                new RawConfidence<RawParsedCondition>(new RawParsedCondition("taskDone", ReferenceTitle: "  "), 0.8)
            });

        var task = ParsedTaskValidation.Validate(raw, SourceTranscript);

        Assert.Empty(task.Conditions);
    }

    [Fact]
    public void Validate_TaskDoneCondition_Valid_IsKept()
    {
        var raw = new RawParsedTask(
            new RawConfidence<string>("Call mom", 0.9),
            Conditions: new[]
            {
                new RawConfidence<RawParsedCondition>(new RawParsedCondition("taskDone", ReferenceTitle: "buy milk"), 0.8)
            });

        var task = ParsedTaskValidation.Validate(raw, SourceTranscript);

        var condition = Assert.Single(task.Conditions);
        var taskDone = Assert.IsType<ParsedCondition.TaskDone>(condition);
        Assert.Equal("buy milk", taskDone.TitleQuery);
    }

    [Fact]
    public void Validate_AfterDateCondition_UnparsableDate_IsDropped()
    {
        var raw = new RawParsedTask(
            new RawConfidence<string>("Call mom", 0.9),
            Conditions: new[]
            {
                new RawConfidence<RawParsedCondition>(new RawParsedCondition("afterDate", Date: "garbage"), 0.8)
            });

        var task = ParsedTaskValidation.Validate(raw, SourceTranscript);

        Assert.Empty(task.Conditions);
    }

    [Fact]
    public void Validate_ExternalCondition_EmptyDescription_IsDropped()
    {
        var raw = new RawParsedTask(
            new RawConfidence<string>("Call mom", 0.9),
            Conditions: new[]
            {
                new RawConfidence<RawParsedCondition>(new RawParsedCondition("external", Description: ""), 0.8)
            });

        var task = ParsedTaskValidation.Validate(raw, SourceTranscript);

        Assert.Empty(task.Conditions);
    }

    [Fact]
    public void Validate_UnknownConditionKind_IsDropped()
    {
        var raw = new RawParsedTask(
            new RawConfidence<string>("Call mom", 0.9),
            Conditions: new[]
            {
                new RawConfidence<RawParsedCondition>(new RawParsedCondition("mystery"), 0.8)
            });

        var task = ParsedTaskValidation.Validate(raw, SourceTranscript);

        Assert.Empty(task.Conditions);
    }

    [Fact]
    public void Validate_Kind_Review_MapsCorrectly_DefaultIsTask()
    {
        var reviewRaw = new RawParsedTask(
            new RawConfidence<string>("Call mom", 0.9),
            Kind: new RawConfidence<string>("review", 0.8));
        var defaultRaw = new RawParsedTask(new RawConfidence<string>("Call mom", 0.9));

        Assert.Equal(TaskKind.Review, ParsedTaskValidation.Validate(reviewRaw, SourceTranscript).Kind);
        Assert.Equal(TaskKind.Task, ParsedTaskValidation.Validate(defaultRaw, SourceTranscript).Kind);
    }

    [Fact]
    public void Validate_Subtasks_EmptyTitlesFiltered_CappedAt20()
    {
        var subtasks = Enumerable.Range(0, 25)
            .Select(i => new RawParsedSubtask(
                new RawConfidence<string>(i % 5 == 0 ? "  " : $"step {i}", 0.5),
                new RawConfidence<double>(10, 0.5)))
            .ToArray();
        var raw = new RawParsedTask(new RawConfidence<string>("Call mom", 0.9), Subtasks: subtasks);

        var task = ParsedTaskValidation.Validate(raw, SourceTranscript);

        Assert.True(task.Subtasks.Count <= 20);
        Assert.DoesNotContain(task.Subtasks, s => s.Trim().Length == 0);
    }

    [Fact]
    public void Validate_FollowUpReview_DefaultsFalse_WhenAbsent()
    {
        var raw = new RawParsedTask(new RawConfidence<string>("Call mom", 0.9));

        var task = ParsedTaskValidation.Validate(raw, SourceTranscript);

        Assert.False(task.FollowUpReview);
    }

    [Fact]
    public void ValidateAll_MapsEachRawTaskIndependently()
    {
        var raws = new[]
        {
            new RawParsedTask(new RawConfidence<string>("First", 0.9)),
            new RawParsedTask(new RawConfidence<string>("Second", 0.9))
        };

        var tasks = ParsedTaskValidation.ValidateAll(raws, SourceTranscript);

        Assert.Equal(2, tasks.Count);
        Assert.Equal("First", tasks[0].Title);
        Assert.Equal("Second", tasks[1].Title);
    }

    [Theory]
    [InlineData("2026-07-21T10:00:00Z")]
    [InlineData("2026-07-21T10:00:00.123Z")]
    [InlineData("2026-07-21T10:00:00+00:00")]
    public void ParseIso8601_AcceptsCommonZonedFormats(string value)
    {
        Assert.NotNull(ParsedTaskValidation.ParseIso8601(value));
    }

    [Fact]
    public void ParseIso8601_RejectsGarbage()
    {
        Assert.Null(ParsedTaskValidation.ParseIso8601("not a date"));
    }
}
