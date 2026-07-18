using Volar.Domain;
using Xunit;

namespace Volar.Domain.Tests;

public class NLParserTests
{
    // Fixed, deterministic, non-DST zone (UTC+7) — tests never read the system clock or
    // TimeZoneInfo.Local; `now`/`timeZone` are always passed in explicitly.
    private static readonly TimeZoneInfo Ict = TimeZoneInfo.CreateCustomTimeZone("ICT-nlp-test", TimeSpan.FromHours(7), "ICT", "ICT");

    // Monday, 2026-03-16, 09:00 +07:00.
    private static readonly DateTimeOffset Now = new(2026, 3, 16, 9, 0, 0, TimeSpan.FromHours(7));

    private static readonly HeuristicNLParser Parser = new();

    private static ParsedTask Parse(string text) => Parser.Parse(text, Now, Ict);

    private static ParsedTask ParseWithOpenTitles(string text, params string[] openTaskTitles)
        => Parser.ParseMany(text, Now, Ict, openTaskTitles).Single();

    // MARK: - Entry point / empty input

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("\n\t")]
    public void Parse_EmptyOrWhitespaceInput_ReturnsFallbackTitle(string input)
    {
        var result = Parse(input);
        Assert.Equal("Untitled task", result.Title);
        Assert.Equal(input, result.SourceTranscript);
        Assert.Empty(result.Conditions);
        Assert.Null(result.Deadline);
    }

    [Fact]
    public void ParseMany_ReturnsExactlyOneTask()
    {
        var results = Parser.ParseMany("buy milk", Now, Ict, Array.Empty<string>());
        Assert.Single(results);
    }

    [Fact]
    public void Parse_SourceTranscript_AlwaysRetainedVerbatim_EvenWhenTruncatedForWorkingText()
    {
        var longText = "remind me to " + new string('a', 9_000);
        var result = Parse(longText);
        Assert.Equal(longText, result.SourceTranscript);
        Assert.True(longText.Length > 8_000);
    }

    // MARK: - Title cleanup

    [Theory]
    [InlineData("remind me to call the bank", "call the bank")]
    [InlineData("remember to water the plants", "water the plants")]
    [InlineData("i need to fix the bug", "fix the bug")]
    [InlineData("please remember to submit the form", "submit the form")]
    [InlineData("please pack the bags", "pack the bags")]
    public void CleanTitle_StripsEnglishLeadIns(string input, string expectedTitle)
    {
        Assert.Equal(expectedTitle, Parse(input).Title);
    }

    [Theory]
    [InlineData("nhắc tôi gọi điện cho mẹ", "gọi điện cho mẹ")]
    [InlineData("nhắc mình đi chợ", "đi chợ")]
    [InlineData("làm ơn nhắc tôi tưới cây", "tưới cây")]
    [InlineData("tôi cần nộp báo cáo", "nộp báo cáo")]
    [InlineData("mình cần dọn nhà", "dọn nhà")]
    [InlineData("nhớ mua sữa", "mua sữa")]
    public void CleanTitle_StripsVietnameseLeadIns(string input, string expectedTitle)
    {
        Assert.Equal(expectedTitle, Parse(input).Title);
    }

    [Fact]
    public void CleanTitle_StripsTrailingEnglishPriorityClause()
    {
        Assert.Equal("finish the report", Parse("finish the report, high priority").Title);
    }

    [Fact]
    public void CleanTitle_StripsTrailingVietnamesePriorityClause()
    {
        Assert.Equal("hoàn thành báo cáo", Parse("hoàn thành báo cáo, ưu tiên cao").Title);
    }

    [Fact]
    public void CleanTitle_KeepsCommaClauseThatIsNotAPriorityHint()
    {
        // The comma clause doesn't mention priority/urgent/ưu tiên, so it must be kept.
        Assert.Equal("buy milk, eggs and bread", Parse("buy milk, eggs and bread").Title);
    }

    [Fact]
    public void CleanTitle_TruncatesTitlesLongerThanMaxLength()
    {
        var longTitle = new string('x', 500);
        var result = Parse(longTitle);
        Assert.Equal(300, result.Title.Length);
    }

    // MARK: - Priority

    [Theory]
    [InlineData("high priority call with client", 1, 0.85)]
    [InlineData("this is urgent, fix it now", 1, 0.72)]
    [InlineData("low priority cleanup", 3, 0.85)]
    [InlineData("no rush on this one", 3, 0.7)]
    [InlineData("medium priority review", 2, 0.8)]
    public void DetectPriority_English(string input, int expectedValue, double expectedConfidence)
    {
        var priority = Parse(input).Priority;
        Assert.NotNull(priority);
        Assert.Equal(expectedValue, priority!.Value.Value);
        Assert.Equal(expectedConfidence, priority.Value.Confidence);
    }

    [Theory]
    [InlineData("ưu tiên cao cho việc này", 1, 0.85)]
    [InlineData("việc này khẩn cấp lắm", 1, 0.72)]
    [InlineData("ưu tiên thấp thôi", 3, 0.85)]
    [InlineData("khi nào rảnh thì làm", 3, 0.7)]
    [InlineData("ưu tiên trung bình", 2, 0.8)]
    public void DetectPriority_Vietnamese(string input, int expectedValue, double expectedConfidence)
    {
        var priority = Parse(input).Priority;
        Assert.NotNull(priority);
        Assert.Equal(expectedValue, priority!.Value.Value);
        Assert.Equal(expectedConfidence, priority.Value.Confidence);
    }

    [Fact]
    public void DetectPriority_NoMention_ReturnsNull_NeverFabricated()
    {
        Assert.Null(Parse("buy some milk").Priority);
    }

    // MARK: - Estimate

    [Theory]
    [InlineData("write the report, 45 minutes", 45)]
    [InlineData("call in 2 hours", 120)]
    [InlineData("meeting takes 90 mins", 90)]
    public void DetectEstimate_English_Digits(string input, int expectedMinutes)
    {
        var estimate = Parse(input).EstimateMinutes;
        Assert.NotNull(estimate);
        Assert.Equal(expectedMinutes, estimate!.Value.Value);
    }

    [Theory]
    [InlineData("viết báo cáo 45 phút", 45)]
    [InlineData("họp 2 tiếng", 120)]
    [InlineData("làm việc này 3 giờ", 180)]
    public void DetectEstimate_Vietnamese_Digits(string input, int expectedMinutes)
    {
        var estimate = Parse(input).EstimateMinutes;
        Assert.NotNull(estimate);
        Assert.Equal(expectedMinutes, estimate!.Value.Value);
    }

    [Fact]
    public void DetectEstimate_EnglishHalfHourPhrase()
    {
        var estimate = Parse("clean up, half an hour").EstimateMinutes;
        Assert.Equal(30, estimate!.Value.Value);
        Assert.Equal(0.75, estimate.Value.Confidence);
    }

    [Fact]
    public void DetectEstimate_VietnameseHalfHourPhrase()
    {
        var estimate = Parse("dọn dẹp nửa tiếng").EstimateMinutes;
        Assert.Equal(30, estimate!.Value.Value);
    }

    [Fact]
    public void DetectEstimate_NinetyMinutePhrase_EnglishAndVietnamese()
    {
        Assert.Equal(90, Parse("an hour and a half of work").EstimateMinutes!.Value.Value);
        Assert.Equal(90, Parse("làm một tiếng rưỡi").EstimateMinutes!.Value.Value);
    }

    [Fact]
    public void DetectEstimate_HedgedByEnglishWord_LowersConfidence()
    {
        var hedged = Parse("maybe 30 minutes for this").EstimateMinutes;
        var plain = Parse("30 minutes for this").EstimateMinutes;
        Assert.Equal(0.62, hedged!.Value.Confidence);
        Assert.Equal(0.85, plain!.Value.Confidence);
    }

    [Fact]
    public void DetectEstimate_HedgedByVietnameseWord_LowersConfidence()
    {
        var hedged = Parse("chắc khoảng 30 phút").EstimateMinutes;
        Assert.Equal(0.62, hedged!.Value.Confidence);
    }

    [Fact]
    public void DetectEstimate_OutOfBoundsValue_Ignored()
    {
        Assert.Null(Parse("this takes 0 minutes").EstimateMinutes);
        Assert.Null(Parse("this takes 99999 minutes").EstimateMinutes);
    }

    // MARK: - Deadline: weekday keywords

    [Theory]
    [InlineData("finish report tuesday", 2026, 3, 17)] // tomorrow
    [InlineData("finish report wednesday", 2026, 3, 18)]
    [InlineData("finish report sunday", 2026, 3, 22)]
    public void DetectDeadline_EnglishWeekday_ResolvesToNextOccurrence(string input, int year, int month, int day)
    {
        var deadline = Parse(input).Deadline;
        Assert.NotNull(deadline);
        var local = TimeZoneInfo.ConvertTime(deadline!.Value.Value, Ict);
        Assert.Equal(new DateTime(year, month, day), local.DateTime.Date);
    }

    [Fact]
    public void DetectDeadline_EnglishWeekday_SameAsTodayMeansNextWeek()
    {
        // `now` is a Monday; saying "monday" again must resolve 7 days out, never "today".
        var deadline = Parse("finish report monday").Deadline;
        var local = TimeZoneInfo.ConvertTime(deadline!.Value.Value, Ict);
        Assert.Equal(new DateTime(2026, 3, 23), local.DateTime.Date);
    }

    [Theory]
    [InlineData("hoàn thành báo cáo thứ 3", 2026, 3, 17)]
    [InlineData("hoàn thành báo cáo thứ tư", 2026, 3, 18)]
    [InlineData("hoàn thành báo cáo chủ nhật", 2026, 3, 22)]
    public void DetectDeadline_VietnameseWeekday_ResolvesToNextOccurrence(string input, int year, int month, int day)
    {
        var deadline = Parse(input).Deadline;
        Assert.NotNull(deadline);
        var local = TimeZoneInfo.ConvertTime(deadline!.Value.Value, Ict);
        Assert.Equal(new DateTime(year, month, day), local.DateTime.Date);
    }

    // MARK: - Deadline: relative keywords

    [Fact]
    public void DetectDeadline_Tomorrow_English()
    {
        var deadline = Parse("finish this tomorrow").Deadline;
        var local = TimeZoneInfo.ConvertTime(deadline!.Value.Value, Ict);
        Assert.Equal(new DateTime(2026, 3, 17), local.DateTime.Date);
        Assert.Equal(0.65, deadline.Value.Confidence); // no explicit time -> ambiguous/uncertain
    }

    [Theory]
    [InlineData("làm việc này ngày mai")]
    [InlineData("mai làm việc này")]
    [InlineData("làm việc này mai đi")]
    public void DetectDeadline_Tomorrow_Vietnamese(string input)
    {
        var deadline = Parse(input).Deadline;
        Assert.NotNull(deadline);
        var local = TimeZoneInfo.ConvertTime(deadline!.Value.Value, Ict);
        Assert.Equal(new DateTime(2026, 3, 17), local.DateTime.Date);
    }

    [Fact]
    public void DetectDeadline_NextWeek_English()
    {
        var deadline = Parse("finish this next week").Deadline;
        var local = TimeZoneInfo.ConvertTime(deadline!.Value.Value, Ict);
        Assert.Equal(new DateTime(2026, 3, 23), local.DateTime.Date);
    }

    [Theory]
    [InlineData("làm việc này tuần sau")]
    [InlineData("làm việc này tuần tới")]
    public void DetectDeadline_NextWeek_Vietnamese(string input)
    {
        var deadline = Parse(input).Deadline;
        var local = TimeZoneInfo.ConvertTime(deadline!.Value.Value, Ict);
        Assert.Equal(new DateTime(2026, 3, 23), local.DateTime.Date);
    }

    [Fact]
    public void DetectDeadline_Today_English()
    {
        var deadline = Parse("finish this today").Deadline;
        var local = TimeZoneInfo.ConvertTime(deadline!.Value.Value, Ict);
        Assert.Equal(new DateTime(2026, 3, 16), local.DateTime.Date);
    }

    [Fact]
    public void DetectDeadline_Today_Vietnamese()
    {
        var deadline = Parse("làm việc này hôm nay").Deadline;
        var local = TimeZoneInfo.ConvertTime(deadline!.Value.Value, Ict);
        Assert.Equal(new DateTime(2026, 3, 16), local.DateTime.Date);
    }

    [Fact]
    public void DetectDeadline_NoDateCue_ReturnsNull()
    {
        Assert.Null(Parse("buy milk").Deadline);
    }

    // MARK: - Deadline: explicit clock time (raises confidence to 0.85)

    [Fact]
    public void DetectDeadline_EnglishExplicitTime_PmAfterNoon()
    {
        var deadline = Parse("meet the client tomorrow at 3pm").Deadline;
        Assert.NotNull(deadline);
        Assert.Equal(0.85, deadline!.Value.Confidence);
        var local = TimeZoneInfo.ConvertTime(deadline.Value.Value, Ict);
        Assert.Equal(new DateTime(2026, 3, 17, 15, 0, 0), local.DateTime);
    }

    [Fact]
    public void DetectDeadline_EnglishExplicitTime_AmWithMinutes()
    {
        var deadline = Parse("call at 9:15am tomorrow").Deadline;
        var local = TimeZoneInfo.ConvertTime(deadline!.Value.Value, Ict);
        Assert.Equal(new DateTime(2026, 3, 17, 9, 15, 0), local.DateTime);
    }

    [Fact]
    public void DetectDeadline_VietnameseExplicitTime_ChieuIsAfternoon()
    {
        var deadline = Parse("họp lúc 3h chiều mai").Deadline;
        Assert.NotNull(deadline);
        Assert.Equal(0.85, deadline!.Value.Confidence);
        var local = TimeZoneInfo.ConvertTime(deadline.Value.Value, Ict);
        Assert.Equal(new DateTime(2026, 3, 17, 15, 0, 0), local.DateTime);
    }

    [Fact]
    public void DetectDeadline_VietnameseExplicitTime_SangIsMorning()
    {
        var deadline = Parse("họp lúc 9 giờ sáng mai").Deadline;
        var local = TimeZoneInfo.ConvertTime(deadline!.Value.Value, Ict);
        Assert.Equal(new DateTime(2026, 3, 17, 9, 0, 0), local.DateTime);
    }

    [Fact]
    public void DetectDeadline_NoWeekdayCue_ExplicitTimeAppliesToToday()
    {
        var deadline = Parse("call at 5pm").Deadline;
        var local = TimeZoneInfo.ConvertTime(deadline!.Value.Value, Ict);
        Assert.Equal(new DateTime(2026, 3, 16, 17, 0, 0), local.DateTime);
    }

    // MARK: - Deadline: "khuya" (late night) — keeps the literal hour, never +12; rolls to the next
    // day only when that hour has already passed today and no other day cue was given.

    [Fact]
    public void DetectDeadline_Khuya_KeepsLiteralHour_NeverAddsTwelve()
    {
        // now = 2026-03-16 09:00; "2h khuya" not yet passed today would need now < 02:00, so pin
        // `now` to 00:30 (just after midnight) for the "not yet passed" branch of this rule.
        var earlyNow = new DateTimeOffset(2026, 3, 16, 0, 30, 0, TimeSpan.FromHours(7));
        var deadline = Parser.Parse("nhắc tôi lúc 2h khuya", earlyNow, Ict).Deadline;
        Assert.NotNull(deadline);
        var local = TimeZoneInfo.ConvertTime(deadline!.Value.Value, Ict);
        Assert.Equal(new DateTime(2026, 3, 16, 2, 0, 0), local.DateTime); // same day, literal 02:00 — not 14:00
    }

    [Fact]
    public void DetectDeadline_Khuya_OneAm_KeepsLiteralHour()
    {
        var earlyNow = new DateTimeOffset(2026, 3, 16, 0, 15, 0, TimeSpan.FromHours(7));
        var deadline = Parser.Parse("nhắc tôi lúc 1h khuya", earlyNow, Ict).Deadline;
        var local = TimeZoneInfo.ConvertTime(deadline!.Value.Value, Ict);
        Assert.Equal(new DateTime(2026, 3, 16, 1, 0, 0), local.DateTime); // not 13:00
    }

    [Fact]
    public void DetectDeadline_Khuya_AlreadyPassedToday_RollsToTomorrow()
    {
        // now = 09:00 -> "2h khuya" (02:00) already happened earlier this morning, so it must mean
        // rạng sáng ngày mai (tomorrow 02:00), never a same-day instant already in the past.
        var deadline = Parse("nhắc tôi lúc 2h khuya").Deadline;
        Assert.NotNull(deadline);
        var local = TimeZoneInfo.ConvertTime(deadline!.Value.Value, Ict);
        Assert.Equal(new DateTime(2026, 3, 17, 2, 0, 0), local.DateTime);
    }

    [Fact]
    public void DetectDeadline_Khuya_ExplicitDayCue_NeverRolledAgain()
    {
        // An explicit day cue ("mai" = tomorrow) already pins the date — the rollover rule must not
        // fire a second time on top of it.
        var deadline = Parse("nhắc tôi lúc 2h khuya mai").Deadline;
        var local = TimeZoneInfo.ConvertTime(deadline!.Value.Value, Ict);
        Assert.Equal(new DateTime(2026, 3, 17, 2, 0, 0), local.DateTime);
    }

    [Fact]
    public void DetectDeadline_Khuya_GioVariant_KeepsLiteralHourAndRolls()
    {
        var deadline = Parse("nhắc tôi lúc 2 giờ khuya").Deadline;
        var local = TimeZoneInfo.ConvertTime(deadline!.Value.Value, Ict);
        Assert.Equal(new DateTime(2026, 3, 17, 2, 0, 0), local.DateTime); // 09:00 now -> already passed -> tomorrow
    }

    // MARK: - Defer condition (afterDate) — takes priority over deadline for the same date token

    [Fact]
    public void DetectDeferCondition_EnglishStartingCue_ProducesAfterDate_NotDeadline()
    {
        // The Swift-ported cue regex is narrow: "start(ing) (on) <weekday>" must be adjacent —
        // "start working on this tuesday" does NOT match it (confirmed by this port's own test
        // failure while authoring this suite; the regex is faithfully ported, not the example).
        var result = Parse("starting tuesday, finish this task");
        Assert.Null(result.Deadline);
        var condition = Assert.IsType<ParsedCondition.AfterDate>(Assert.Single(result.Conditions));
        var local = TimeZoneInfo.ConvertTime(condition.Date, Ict);
        Assert.Equal(new DateTime(2026, 3, 17), local.DateTime.Date);
    }

    [Fact]
    public void DetectDeferCondition_EnglishWaitUntilCue()
    {
        var result = Parse("wait until tomorrow to send this");
        Assert.Null(result.Deadline);
        Assert.IsType<ParsedCondition.AfterDate>(Assert.Single(result.Conditions));
    }

    [Fact]
    public void DetectDeferCondition_EnglishNotUntilCue()
    {
        var result = Parse("not until next week please");
        Assert.Null(result.Deadline);
        Assert.IsType<ParsedCondition.AfterDate>(Assert.Single(result.Conditions));
    }

    [Fact]
    public void DetectDeferCondition_VietnameseMoiLamCue()
    {
        var result = Parse("thứ 3 mới làm việc này");
        Assert.Null(result.Deadline);
        var condition = Assert.IsType<ParsedCondition.AfterDate>(Assert.Single(result.Conditions));
        var local = TimeZoneInfo.ConvertTime(condition.Date, Ict);
        Assert.Equal(new DateTime(2026, 3, 17), local.DateTime.Date);
    }

    [Fact]
    public void DetectDeferCondition_VietnameseDeTuanSauCue()
    {
        var result = Parse("để tuần sau làm việc này");
        Assert.Null(result.Deadline);
        Assert.IsType<ParsedCondition.AfterDate>(Assert.Single(result.Conditions));
    }

    [Fact]
    public void DetectDeferCondition_NoResolvableDate_ReturnsNoConditionAtAll()
    {
        // A defer cue with nothing date-like anywhere -> unset entirely, never fabricated.
        var result = Parse("start working on this eventually");
        Assert.Empty(result.Conditions);
        Assert.Null(result.Deadline);
    }

    // MARK: - Dependency condition (taskDone)

    [Fact]
    public void DetectDependency_English_AfterXIsDone()
    {
        var result = Parse("send the invoice after the contract is done");
        var condition = Assert.IsType<ParsedCondition.TaskDone>(Assert.Single(result.Conditions));
        Assert.Equal("the contract", condition.TitleQuery);
    }

    [Fact]
    public void DetectDependency_English_WhenXIsDone()
    {
        var result = Parse("start testing when the build is done");
        var condition = Assert.IsType<ParsedCondition.TaskDone>(Assert.Single(result.Conditions));
        Assert.Equal("the build", condition.TitleQuery);
    }

    [Fact]
    public void DetectDependency_Vietnamese_SauKhiXXong()
    {
        var result = Parse("gửi hóa đơn sau khi hợp đồng xong");
        var condition = Assert.IsType<ParsedCondition.TaskDone>(Assert.Single(result.Conditions));
        Assert.Equal("hợp đồng", condition.TitleQuery);
    }

    [Fact]
    public void DetectDependency_Vietnamese_XXongThi()
    {
        var result = Parse("hợp đồng xong thì gửi hóa đơn");
        var condition = Assert.IsType<ParsedCondition.TaskDone>(Assert.Single(result.Conditions));
        Assert.Equal("hợp đồng", condition.TitleQuery);
    }

    [Fact]
    public void DetectDependency_English_GenericAfterFallback()
    {
        // No "is done" — falls through to pattern 5 (generic "after X").
        var result = Parse("call the client after lunch");
        var condition = Assert.IsType<ParsedCondition.TaskDone>(Assert.Single(result.Conditions));
        Assert.Equal("lunch", condition.TitleQuery);
    }

    [Fact]
    public void DetectDependency_Vietnamese_GenericSauKhiFallback()
    {
        var result = Parse("sau khi ăn trưa thì gọi khách hàng");
        var condition = Assert.IsType<ParsedCondition.TaskDone>(Assert.Single(result.Conditions));
        Assert.Equal("ăn trưa", condition.TitleQuery);
    }

    [Fact]
    public void DetectDependency_SpecificPatternWinsOverGenericFallback_OrderMatters()
    {
        // Both pattern 1 ("after X is done") and pattern 5 ("after X") could match here — pattern 1
        // must win because it is tried first, and it captures the narrower span.
        var result = ParseWithOpenTitles("send the invoice after the contract is done");
        var condition = Assert.IsType<ParsedCondition.TaskDone>(Assert.Single(result.Conditions));
        Assert.Equal("the contract", condition.TitleQuery);
    }

    [Fact]
    public void DetectDependency_ConfidenceHigher_WhenTitleQueryMatchesOpenTask()
    {
        var matched = ParseWithOpenTitles("send the invoice after the contract is done", "Sign the contract");
        var unmatched = ParseWithOpenTitles("send the invoice after the contract is done");

        var matchedCondition = Assert.IsType<ParsedCondition.TaskDone>(Assert.Single(matched.Conditions));
        var unmatchedCondition = Assert.IsType<ParsedCondition.TaskDone>(Assert.Single(unmatched.Conditions));
        Assert.Equal(0.78, matchedCondition.Confidence);
        Assert.Equal(0.55, unmatchedCondition.Confidence);
    }

    // MARK: - External condition (waiting on)

    [Fact]
    public void DetectExternal_English_WaitingFor()
    {
        var result = Parse("waiting for legal approval, then ship it");
        var condition = Assert.IsType<ParsedCondition.External>(Assert.Single(result.Conditions));
        Assert.Equal("legal approval", condition.Description);
        Assert.Equal(0.72, condition.Confidence); // <= 4 words
    }

    [Fact]
    public void DetectExternal_English_WaitingOn()
    {
        var result = Parse("waiting on the vendor to confirm pricing details");
        var condition = Assert.IsType<ParsedCondition.External>(Assert.Single(result.Conditions));
        Assert.Equal(0.62, condition.Confidence); // > 4 words
    }

    [Fact]
    public void DetectExternal_Vietnamese_Cho()
    {
        var result = Parse("chờ khách duyệt giá");
        var condition = Assert.IsType<ParsedCondition.External>(Assert.Single(result.Conditions));
        Assert.Equal("khách duyệt giá", condition.Description);
    }

    [Fact]
    public void DetectExternal_Vietnamese_Doi()
    {
        var result = Parse("đợi sếp phê duyệt");
        var condition = Assert.IsType<ParsedCondition.External>(Assert.Single(result.Conditions));
        Assert.Equal("sếp phê duyệt", condition.Description);
    }

    // MARK: - Recurrence

    [Theory]
    [InlineData("water plants every day", 0.82)]
    [InlineData("water plants daily", 0.82)]
    public void DetectRecurrence_English_Daily(string input, double expectedConfidence)
    {
        var recurrence = Parse(input).Recurrence;
        Assert.NotNull(recurrence);
        Assert.IsType<Recurrence.Daily>(recurrence!.Value.Value);
        Assert.Equal(expectedConfidence, recurrence.Value.Confidence);
    }

    [Theory]
    [InlineData("tưới cây mỗi ngày")]
    [InlineData("tưới cây hằng ngày")]
    [InlineData("tưới cây hàng ngày")]
    public void DetectRecurrence_Vietnamese_Daily(string input)
    {
        var recurrence = Parse(input).Recurrence;
        Assert.IsType<Recurrence.Daily>(recurrence!.Value.Value);
    }

    [Theory]
    [InlineData("team sync every week")]
    [InlineData("team sync weekly")]
    public void DetectRecurrence_English_Weekly(string input)
    {
        Assert.IsType<Recurrence.Weekly>(Parse(input).Recurrence!.Value.Value);
    }

    [Fact]
    public void DetectRecurrence_Vietnamese_Weekly()
    {
        Assert.IsType<Recurrence.Weekly>(Parse("họp nhóm mỗi tuần").Recurrence!.Value.Value);
    }

    [Theory]
    [InlineData("pay rent every month")]
    [InlineData("pay rent monthly")]
    public void DetectRecurrence_English_Monthly(string input)
    {
        Assert.IsType<Recurrence.Monthly>(Parse(input).Recurrence!.Value.Value);
    }

    [Fact]
    public void DetectRecurrence_Vietnamese_Monthly()
    {
        Assert.IsType<Recurrence.Monthly>(Parse("đóng tiền nhà mỗi tháng").Recurrence!.Value.Value);
    }

    [Fact]
    public void DetectRecurrence_LoosePhrase_MapsToDailyWithLowerConfidence()
    {
        var recurrence = Parse("stretch every morning").Recurrence;
        Assert.IsType<Recurrence.Daily>(recurrence!.Value.Value);
        Assert.Equal(0.62, recurrence.Value.Confidence);
    }

    [Fact]
    public void DetectRecurrence_LoosePhrase_Vietnamese()
    {
        var recurrence = Parse("tập thể dục mỗi sáng").Recurrence;
        Assert.IsType<Recurrence.Daily>(recurrence!.Value.Value);
        Assert.Equal(0.62, recurrence.Value.Confidence);
    }

    [Fact]
    public void DetectRecurrence_EveryNDays_English()
    {
        var recurrence = Parse("water the cactus every 3 days").Recurrence;
        var every = Assert.IsType<Recurrence.Every>(recurrence!.Value.Value);
        Assert.Equal(3, every.Days);
        Assert.Equal(0.78, recurrence.Value.Confidence);
    }

    [Fact]
    public void DetectRecurrence_EveryNDays_Vietnamese()
    {
        var recurrence = Parse("tưới xương rồng mỗi 3 ngày").Recurrence;
        var every = Assert.IsType<Recurrence.Every>(recurrence!.Value.Value);
        Assert.Equal(3, every.Days);
    }

    [Fact]
    public void DetectRecurrence_EveryNDays_OutOfBounds_Ignored()
    {
        Assert.Null(Parse("do this every 400 days").Recurrence);
    }

    [Fact]
    public void DetectRecurrence_NoMention_ReturnsNull()
    {
        Assert.Null(Parse("buy milk").Recurrence);
    }

    // MARK: - Reminder override

    [Fact]
    public void DetectReminderOverride_English_Minutes()
    {
        var reminder = Parse("remind me every 30 minutes").ReminderOverride;
        Assert.NotNull(reminder);
        Assert.Equal(TimeSpan.FromMinutes(30), reminder!.Value.Value.RepeatEvery);
        Assert.Equal(0.8, reminder.Value.Confidence);
    }

    [Fact]
    public void DetectReminderOverride_English_Hours()
    {
        var reminder = Parse("remind me every 2 hours").ReminderOverride;
        Assert.Equal(TimeSpan.FromHours(2), reminder!.Value.Value.RepeatEvery);
    }

    [Fact]
    public void DetectReminderOverride_Vietnamese_Minutes()
    {
        var reminder = Parse("nhắc lại mỗi 30 phút").ReminderOverride;
        Assert.Equal(TimeSpan.FromMinutes(30), reminder!.Value.Value.RepeatEvery);
    }

    [Fact]
    public void DetectReminderOverride_Vietnamese_Hours()
    {
        var reminder = Parse("nhắc mỗi 2 giờ").ReminderOverride;
        Assert.Equal(TimeSpan.FromHours(2), reminder!.Value.Value.RepeatEvery);
    }

    [Fact]
    public void DetectReminderOverride_RequiresRemindOrNhacKeyword()
    {
        // Matches the interval regex shape but lacks the required "remind"/"nhắc" gate word.
        Assert.Null(Parse("ping me every 30 minutes").ReminderOverride);
    }

    [Fact]
    public void DetectReminderOverride_NoIntervalMentioned_ReturnsNull()
    {
        Assert.Null(Parse("remind me to call mom").ReminderOverride);
    }

    // MARK: - Kind + follow-up review

    [Theory]
    [InlineData("review the pull request")]
    [InlineData("review after lunch")]
    [InlineData("please review after the meeting")]
    public void DetectKind_English_Review(string input)
    {
        Assert.Equal(TaskKind.Review, Parse(input).Kind);
    }

    [Fact]
    public void DetectKind_Vietnamese_Review()
    {
        Assert.Equal(TaskKind.Review, Parse("xem lại báo cáo tài chính").Kind);
    }

    [Fact]
    public void DetectKind_DefaultsToTask()
    {
        Assert.Equal(TaskKind.Task, Parse("buy milk").Kind);
    }

    [Theory]
    [InlineData("finish the draft, when done, review it")]
    [InlineData("finish the draft, then review it")]
    public void DetectFollowUpReview_English(string input)
    {
        Assert.True(Parse(input).FollowUpReview);
    }

    [Theory]
    [InlineData("làm xong thì xem lại")]
    [InlineData("viết báo cáo xong thì xem lại")]
    public void DetectFollowUpReview_Vietnamese(string input)
    {
        Assert.True(Parse(input).FollowUpReview);
    }

    [Fact]
    public void DetectFollowUpReview_NoMention_False()
    {
        Assert.False(Parse("buy milk").FollowUpReview);
    }

    // MARK: - Multiple rules combined in one utterance

    [Fact]
    public void Parse_CombinesMultipleRules_Independently()
    {
        var result = Parse("remind me to call the bank tomorrow at 3pm, high priority, 30 minutes");

        Assert.Equal("call the bank tomorrow at 3pm", result.Title);
        Assert.NotNull(result.Deadline);
        Assert.Equal(1, result.Priority!.Value.Value);
        Assert.Equal(30, result.EstimateMinutes!.Value.Value);
    }

    // MARK: - ParsedValue<T>

    [Theory]
    [InlineData(0.69, true)]
    [InlineData(0.7, false)]
    [InlineData(0.95, false)]
    public void ParsedValue_IsUncertain_ThresholdIsPointSeven(double confidence, bool expectedUncertain)
    {
        var value = new ParsedValue<int>(1, confidence);
        Assert.Equal(expectedUncertain, value.IsUncertain);
    }

    // MARK: - ParsedTask defaults

    [Fact]
    public void ParsedTask_DefaultConditionsAndSubtasks_AreEmptyNotNull()
    {
        var task = new ParsedTask("Title", "source");
        Assert.NotNull(task.Conditions);
        Assert.Empty(task.Conditions);
        Assert.NotNull(task.Subtasks);
        Assert.Empty(task.Subtasks);
        Assert.Equal(TaskKind.Task, task.Kind);
        Assert.False(task.FollowUpReview);
    }
}
