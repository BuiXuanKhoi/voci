// Volar.Domain/NLParser.cs — port of Sources/Model/NLParser.swift: on-device NL parsing.
// ParsedTask/ParsedValue/ParsedCondition/HeuristicNLParser (specs/002-workflow-command-center/
// contracts/parsing-contract.md).
using System.Globalization;
using System.Text.RegularExpressions;
using Volar.Core;

namespace Volar.Domain;

// MARK: - ParsedValue<T>

/// <summary>
/// Wraps a parsed attribute with its model confidence so the UI can gate it.
/// </summary>
/// <param name="Value">The parsed value.</param>
/// <param name="Confidence">Model confidence, in [0, 1].</param>
public readonly record struct ParsedValue<T>(T Value, double Confidence)
{
    /// <summary>&lt; 0.7 -&gt; dashed "uncertain" chip; never auto-committed.</summary>
    public bool IsUncertain => Confidence < 0.7;
}

// MARK: - ParsedCondition

/// <summary>
/// A parsed blocking condition BEFORE resolution to a Volar.Core <see cref="Condition"/>.
/// <see cref="TaskDone"/> references a task by fuzzy title (resolved to a <see cref="Guid"/> via a
/// picker at confirm time, never auto-attached below 0.7 confidence).
/// </summary>
/// <remarks>
/// Modeled as a closed discriminated union (an <see langword="abstract record"/> with three
/// <see langword="sealed"/> subtypes), mirroring both Swift's <c>enum ParsedCondition</c> and
/// Volar.Core's own <see cref="Condition"/> — matched exhaustively via <see langword="switch"/>
/// expressions.
/// </remarks>
public abstract record ParsedCondition
{
    private protected ParsedCondition() { }

    public sealed record TaskDone(string TitleQuery, double Confidence) : ParsedCondition;

    public sealed record AfterDate(DateTimeOffset Date, double Confidence) : ParsedCondition;

    public sealed record External(string Description, double Confidence) : ParsedCondition;
}

// MARK: - ParsedTask (v2)

/// <summary>
/// The validated value the confirm card renders and the app materializes into a
/// <see cref="TaskItem"/>. Assistive, never authoritative.
/// </summary>
/// <param name="Title">Required; the only guaranteed field.</param>
/// <param name="SourceTranscript">Verbatim utterance, ALWAYS retained.</param>
/// <param name="Deadline">Resolved absolute instant.</param>
/// <param name="Priority">1...4.</param>
/// <param name="Kind">Defaults to <see cref="TaskKind.Task"/>; <see cref="TaskKind.Review"/> when
/// "review after…".</param>
/// <param name="Conditions">taskDone (by fuzzy title ref) / afterDate / external.</param>
/// <param name="Subtasks">Breakdown step titles (may be empty).</param>
/// <param name="FollowUpReview">"when done, review it" -&gt; a second review task.</param>
public sealed record ParsedTask(
    string Title,
    string SourceTranscript,
    string? Notes = null,
    ParsedValue<DateTimeOffset>? Deadline = null,
    ParsedValue<int>? EstimateMinutes = null,
    ParsedValue<int>? Priority = null,
    ParsedValue<ReminderPolicy>? ReminderOverride = null,
    ParsedValue<Recurrence>? Recurrence = null,
    TaskKind Kind = TaskKind.Task,
    IReadOnlyList<ParsedCondition>? Conditions = null,
    IReadOnlyList<string>? Subtasks = null,
    bool FollowUpReview = false)
{
    public IReadOnlyList<ParsedCondition> Conditions { get; init; } = Conditions ?? Array.Empty<ParsedCondition>();

    public IReadOnlyList<string> Subtasks { get; init; } = Subtasks ?? Array.Empty<string>();
}

// MARK: - INLParser

/// <summary>
/// Abstraction over "turn a transcript into a <see cref="ParsedTask"/>".
/// </summary>
/// <remarks>
/// Unlike the Swift <c>protocol NLParser</c> (whose single required method read <c>Date()</c> — the
/// system clock — internally as an implicit default), <paramref name="now"/> and <paramref
/// name="timeZone"/> below are always required, explicit parameters: this project's domain-purity
/// rule forbids Volar.Domain from ever reading the system clock or <see cref="TimeZoneInfo.Local"/>.
/// The caller (app layer) supplies both.
/// </remarks>
public interface INLParser
{
    ParsedTask Parse(string transcript, DateTimeOffset now, TimeZoneInfo timeZone);
}

/// <summary>
/// On-device heuristic parser: regex/keyword scans for dates, dependencies, defers, waits,
/// estimates, recurrence, and reminder overrides. Bilingual (Vietnamese + English). No network
/// calls, no I/O, no clock/locale reads anywhere — pure text(+now+timeZone)-in /
/// <see cref="ParsedTask"/>-out.
/// </summary>
/// <remarks>
/// Port of <c>HeuristicNLParser</c> (<c>Sources/Model/NLParser.swift</c>). This port deliberately
/// omits two things from the Swift source, both explicitly out of this project's (W1-B) scope:
/// <list type="bullet">
/// <item>
/// The zero-arg <c>parse(_:)</c> entry point, which read <c>Date()</c> as an implicit default —
/// dropped per the domain-purity rule above; use <see cref="Parse"/> instead, which always takes
/// <c>now</c> explicitly.
/// </item>
/// <item>
/// Conformance to <c>IntentParser</c> (<c>breakdown(title:notes:)</c>) — that protocol is declared
/// in <c>IntentParsing.swift</c>, a separate porting wave's (Volar.Parsing / W2-A) responsibility.
/// </item>
/// </list>
/// <para>
/// <b>Known deviation — flagged for review:</b> the Swift source's "best signal" date/time detector
/// is Apple's <c>NSDataDetector</c>, which has no .NET equivalent, and is itself documented in the
/// Swift source as "English-locale-tuned" and unverified for Vietnamese phrasing. This port replaces
/// it with an explicit regex-based clock-time detector (<see cref="TryDetectExplicitTime"/>) layered
/// on top of the (faithfully ported) weekday-keyword and relative-keyword fallbacks — see that
/// method's doc comment for the exact rules and the judgment calls involved. This is a deliberate,
/// documented redesign of that one sub-rule, not a literal translation.
/// </para>
/// </remarks>
public sealed partial class HeuristicNLParser : INLParser
{
    public ParsedTask Parse(string transcript, DateTimeOffset now, TimeZoneInfo timeZone)
        => ParseOne(transcript, now, timeZone, Array.Empty<string>());

    /// <summary>
    /// Matches the shape <c>IntentParser.parse(_:now:openTaskTitles:)</c> uses
    /// (parsing-contract.md), for a future <c>IntentRouter</c> (Volar.Parsing) to call as its
    /// always-available floor route. Synchronous — the Swift method was <c>async</c> only to satisfy
    /// that protocol's signature; all work here is pure/synchronous, so this port drops the
    /// unnecessary asynchrony rather than fabricate it. Never splits a compound utterance into
    /// multiple tasks (out of scope for this heuristic pass) — the single-task result is always
    /// returned as a one-element list.
    /// </summary>
    public IReadOnlyList<ParsedTask> ParseMany(
        string transcript, DateTimeOffset now, TimeZoneInfo timeZone, IReadOnlyList<string> openTaskTitles)
        => new[] { ParseOne(transcript, now, timeZone, openTaskTitles) };

    // MARK: - Tuning constants

    /// <summary>
    /// Defensive bound on how much of the transcript detection regexes actually scan — protects
    /// against adversarial/pathological input (megabyte-scale paste) doing unbounded work. Does NOT
    /// affect <see cref="ParsedTask.SourceTranscript"/>, which always retains the full, untruncated
    /// input.
    /// </summary>
    private const int MaxWorkingLength = 8_000;

    private const int MaxTitleLength = 300;
    private const string FallbackTitle = "Untitled task";

    // MARK: - Entry point

    private static ParsedTask ParseOne(
        string rawTranscript, DateTimeOffset now, TimeZoneInfo timeZone, IReadOnlyList<string> openTaskTitles)
    {
        var sourceTranscript = rawTranscript;
        var workingText = rawTranscript.Length > MaxWorkingLength ? rawTranscript[..MaxWorkingLength] : rawTranscript;

        if (workingText.Trim().Length == 0)
        {
            // Empty/whitespace-only input — never null, never crash: a title-only placeholder
            // carrying whatever (possibly empty) transcript was actually given.
            return new ParsedTask(FallbackTitle, sourceTranscript);
        }

        var title = CleanTitle(workingText);
        var priority = DetectPriority(workingText);
        var estimateMinutes = DetectEstimate(workingText);
        var recurrence = DetectRecurrence(workingText);
        var reminderOverride = DetectReminderOverride(workingText);
        var kind = DetectKind(workingText);
        var followUpReview = DetectFollowUpReview(workingText);

        // Defer phrasing ("start Monday", "thứ 2 mới làm") takes priority over deadline phrasing
        // for the SAME date token — a defer date means "don't start before", not "due by", so it
        // must never also become the deadline.
        var conditions = new List<ParsedCondition>();
        ParsedValue<DateTimeOffset>? deadline = null;
        var deferCondition = DetectDeferCondition(workingText, now, timeZone);
        if (deferCondition is not null)
        {
            conditions.Add(deferCondition);
        }
        else
        {
            deadline = DetectDeadline(workingText, now, timeZone);
        }
        var dependency = DetectDependencyCondition(workingText, openTaskTitles);
        if (dependency is not null)
        {
            conditions.Add(dependency);
        }
        var external = DetectExternalCondition(workingText);
        if (external is not null)
        {
            conditions.Add(external);
        }

        return new ParsedTask(title, sourceTranscript)
        {
            Deadline = deadline,
            EstimateMinutes = estimateMinutes,
            Priority = priority,
            ReminderOverride = reminderOverride,
            Recurrence = recurrence,
            Kind = kind,
            Conditions = conditions,
            FollowUpReview = followUpReview
        };
    }

    // MARK: - Title cleanup (EN + VI lead-ins, trailing priority clause strip)

    private static readonly string[] LeadIns =
    {
        "remind me to ", "remember to ", "i need to ", "please remember to ", "please ",
        "nhắc tôi ", "nhắc mình ", "làm ơn nhắc tôi ", "tôi cần ", "mình cần ", "nhớ "
    };

    private static string CleanTitle(string text)
    {
        var title = text.Trim();
        var lower = title.ToLowerInvariant();
        foreach (var leadIn in LeadIns)
        {
            if (lower.StartsWith(leadIn, StringComparison.Ordinal))
            {
                title = title[leadIn.Length..];
                break;
            }
        }

        // Trailing ", high priority" / ", ưu tiên cao" style clauses — drop if present.
        var commaIndex = title.IndexOf(',');
        if (commaIndex >= 0)
        {
            var tail = title[(commaIndex + 1)..].ToLowerInvariant();
            if (tail.Contains("priority", StringComparison.Ordinal)
                || tail.Contains("urgent", StringComparison.Ordinal)
                || tail.Contains("ưu tiên", StringComparison.Ordinal))
            {
                title = title[..commaIndex];
            }
        }

        title = title.Trim();
        if (title.Length == 0)
        {
            return FallbackTitle;
        }
        return title.Length > MaxTitleLength ? title[..MaxTitleLength] : title;
    }

    // MARK: - Priority ("urgent" / "khẩn cấp" / "low priority" / "không gấp" ...)

    private static readonly string[] HighPhrases = { "high priority", "ưu tiên cao", "quan trọng nhất" };
    private static readonly string[] HighWords = { "urgent", "asap", "critical", "khẩn cấp", "gấp" };
    private static readonly string[] LowPhrases = { "low priority", "ưu tiên thấp", "không gấp" };
    private static readonly string[] LowWords = { "whenever", "no rush", "not urgent", "rảnh thì làm", "khi nào rảnh" };
    private static readonly string[] MediumPhrases = { "medium priority", "normal priority", "ưu tiên trung bình" };

    private static ParsedValue<int>? DetectPriority(string text)
    {
        var lower = text.ToLowerInvariant();

        // Only ever set when the transcript SAYS a priority — never fabricate a default when
        // nothing was said.
        if (ContainsAny(lower, HighPhrases)) return new ParsedValue<int>(1, 0.85);
        if (ContainsAny(lower, LowPhrases)) return new ParsedValue<int>(3, 0.85);
        if (ContainsAny(lower, MediumPhrases)) return new ParsedValue<int>(2, 0.8);
        if (ContainsAny(lower, HighWords)) return new ParsedValue<int>(1, 0.72);
        if (ContainsAny(lower, LowWords)) return new ParsedValue<int>(3, 0.7);
        return null;
    }

    private static bool ContainsAny(string haystack, IReadOnlyList<string> needles)
    {
        foreach (var needle in needles)
        {
            if (haystack.Contains(needle, StringComparison.Ordinal))
            {
                return true;
            }
        }
        return false;
    }

    // MARK: - Estimate ("45 min", "1 hr", "nửa tiếng", "~30 phút", "chắc 30 phút")

    [GeneratedRegex(@"(\d+)\s*(minutes?|mins?|hours?|hrs?|phút|tiếng|giờ)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex EstimateRegex();

    private static readonly string[] HalfHourPhrases = { "nửa tiếng", "nửa giờ", "half an hour", "half hour" };

    private static readonly string[] NinetyPhrases =
    {
        "một tiếng rưỡi", "1 tiếng rưỡi", "hour and a half", "an hour and a half", "1.5 hours", "1.5 hour"
    };

    private static readonly string[] HedgeWords =
        { "chắc", "có lẽ", "khoảng", "tầm", "cỡ", "maybe", "probably", "about", "around", "~" };

    /// <summary>Whether any hedge word appears in the 20 characters immediately before <paramref name="matchStart"/>.</summary>
    private static bool IsHedged(int matchStart, string lower)
    {
        var start = Math.Max(0, matchStart - 20);
        var context = lower[start..matchStart];
        foreach (var word in HedgeWords)
        {
            if (context.Contains(word, StringComparison.Ordinal))
            {
                return true;
            }
        }
        return false;
    }

    private static ParsedValue<int>? DetectEstimate(string text)
    {
        var lower = text.ToLowerInvariant();

        // Fixed-phrase table first — these don't carry an explicit digit for the regex below.
        foreach (var phrase in HalfHourPhrases)
        {
            var index = lower.IndexOf(phrase, StringComparison.Ordinal);
            if (index >= 0)
            {
                return new ParsedValue<int>(30, IsHedged(index, lower) ? 0.6 : 0.75);
            }
        }
        foreach (var phrase in NinetyPhrases)
        {
            var index = lower.IndexOf(phrase, StringComparison.Ordinal);
            if (index >= 0)
            {
                return new ParsedValue<int>(90, IsHedged(index, lower) ? 0.6 : 0.75);
            }
        }

        var match = EstimateRegex().Match(lower);
        if (!match.Success || !match.Groups[1].Success || !match.Groups[2].Success)
        {
            return null;
        }

        // `int.TryParse` returns false (never throws) on overflow — a defensive bound against an
        // adversarial huge digit string ("999999999999 minutes").
        if (!int.TryParse(match.Groups[1].Value, NumberStyles.None, CultureInfo.InvariantCulture, out var value)
            || value <= 0 || value > 1440)
        {
            return null;
        }
        var unit = match.Groups[2].Value;
        var minutes = unit.StartsWith('h') || unit.StartsWith('t') || unit.StartsWith('g') ? value * 60 : value;

        var hedged = IsHedged(match.Index, lower);
        return new ParsedValue<int>(Math.Min(minutes, 24 * 60), hedged ? 0.62 : 0.85);
    }

    // MARK: - Date resolution shared by deadline + defer

    private readonly record struct DateToken(DateTimeOffset Date, bool IsExplicitTime);

    /// <summary>
    /// Vietnamese + English weekday keywords -&gt; <see cref="LocalCalendar.LocalWeekday"/> values
    /// (Sunday = 1 ... Saturday = 7).
    /// </summary>
    private static readonly (string Keyword, int Weekday)[] WeekdayKeywords =
    {
        ("chủ nhật", 1), ("chúa nhật", 1), ("sunday", 1),
        ("thứ hai", 2), ("thứ 2", 2), ("monday", 2),
        ("thứ ba", 3), ("thứ 3", 3), ("tuesday", 3),
        ("thứ tư", 4), ("thứ 4", 4), ("wednesday", 4),
        ("thứ năm", 5), ("thứ 5", 5), ("thursday", 5),
        ("thứ sáu", 6), ("thứ 6", 6), ("friday", 6),
        ("thứ bảy", 7), ("thứ 7", 7), ("saturday", 7)
    };

    private static DateTimeOffset NextOccurrenceOfWeekday(int targetWeekday, DateTimeOffset now, TimeZoneInfo timeZone)
    {
        var currentWeekday = LocalCalendar.LocalWeekday(now, timeZone);
        // When the spoken weekday equals today's weekday, `(target - current + 7) % 7` is 0 — that
        // must mean "next <weekday>" (7 days out), NEVER "today" (a no-op that would make "thứ 2
        // mới làm"/"do it Monday" said ON a Monday silently resolve to right now).
        var delta = ((targetWeekday - currentWeekday) % 7 + 7) % 7;
        var daysToAdd = delta == 0 ? 7 : delta;
        return LocalCalendar.AddDays(now, daysToAdd, timeZone);
    }

    // MARK: - Explicit clock-time detection (NSDataDetector substitute — see class doc comment)

    [GeneratedRegex(@"\b(?:at\s+)?(\d{1,2})(?::([0-5]\d))?\s*(am|pm)\b", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex EnglishClockTimeRegex();

    [GeneratedRegex(@"\bat\s+([01]?\d|2[0-3]):([0-5]\d)\b", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex English24HourClockTimeRegex();

    [GeneratedRegex(@"(\d{1,2})\s*h\s*(\d{2})?\s*(sáng|trưa|chiều|tối|khuya)?", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex VietnameseHourMarkerRegex();

    [GeneratedRegex(@"(\d{1,2})\s*giờ\s*(\d{1,2})?\s*(sáng|trưa|chiều|tối|khuya)?", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex VietnameseGioRegex();

    /// <summary>
    /// Best-effort explicit clock-time detector — this port's deliberate substitute for Apple's
    /// <c>NSDataDetector</c> (see class doc comment; no .NET equivalent exists). Tried in a fixed
    /// order (first match wins): English "(at) HH(:MM)? am/pm", English 24h "at HH:MM", Vietnamese
    /// "&lt;n&gt;h&lt;mm&gt;? &lt;sáng|trưa|chiều|tối|khuya&gt;?", Vietnamese "&lt;n&gt; giờ
    /// &lt;mm&gt;? &lt;sáng|trưa|chiều|tối|khuya&gt;?". Returns <see langword="null"/> when nothing
    /// matches — never fabricates a time. <c>IsLateNight</c> is set only for a "khuya" marker match
    /// (see <see cref="ApplyVietnameseTimeOfDay"/>) — it drives the same-day-rollover rule in
    /// <see cref="ResolveDateToken"/>: a "khuya" hour that has already passed today means "rạng sáng
    /// ngày hôm sau" (tomorrow), never a same-day time already in the past.
    /// </summary>
    private static (int Hour, int Minute, bool IsLateNight)? TryDetectExplicitTime(string text)
    {
        var enMatch = EnglishClockTimeRegex().Match(text);
        if (enMatch.Success)
        {
            var hour = int.Parse(enMatch.Groups[1].Value, CultureInfo.InvariantCulture);
            if (hour is >= 1 and <= 12)
            {
                var minute = enMatch.Groups[2].Success
                    ? int.Parse(enMatch.Groups[2].Value, CultureInfo.InvariantCulture)
                    : 0;
                var isPm = string.Equals(enMatch.Groups[3].Value, "pm", StringComparison.OrdinalIgnoreCase);
                return (ApplyAmPm(hour, isPm), minute, false);
            }
        }

        var en24Match = English24HourClockTimeRegex().Match(text);
        if (en24Match.Success)
        {
            var hour = int.Parse(en24Match.Groups[1].Value, CultureInfo.InvariantCulture);
            var minute = int.Parse(en24Match.Groups[2].Value, CultureInfo.InvariantCulture);
            return (hour, minute, false);
        }

        var vnHourResult = TryMatchVietnameseClock(VietnameseHourMarkerRegex(), text);
        if (vnHourResult is not null)
        {
            return vnHourResult;
        }

        return TryMatchVietnameseClock(VietnameseGioRegex(), text);
    }

    private static (int Hour, int Minute, bool IsLateNight)? TryMatchVietnameseClock(Regex regex, string text)
    {
        var match = regex.Match(text);
        if (!match.Success)
        {
            return null;
        }
        var hour = int.Parse(match.Groups[1].Value, CultureInfo.InvariantCulture);
        if (hour is < 0 or > 23)
        {
            return null;
        }
        var minute = match.Groups[2].Success ? int.Parse(match.Groups[2].Value, CultureInfo.InvariantCulture) : 0;
        if (minute > 59)
        {
            return null;
        }
        var marker = match.Groups[3].Success ? match.Groups[3].Value : null;
        var isLateNight = string.Equals(marker, "khuya", StringComparison.Ordinal);
        return (ApplyVietnameseTimeOfDay(hour, marker), minute, isLateNight);
    }

    private static int ApplyAmPm(int hour12, bool isPm)
    {
        var normalized = hour12 % 12; // 12am -> 0, 12pm -> 0 (then +12 below for pm)
        return isPm ? normalized + 12 : normalized;
    }

    /// <summary>
    /// Applies a Vietnamese time-of-day marker to an hour already parsed as a 0...23 literal (e.g.
    /// "9" in "9 giờ sáng"). Convention (a judgment call — see class doc comment): "sáng" (morning),
    /// "trưa" (noon), and "khuya" (late night) all leave the literal hour as-is (already the
    /// intended 24h hour — "12 giờ trưa" = 12:00, "2h khuya" = 02:00, "1h khuya" = 01:00: "khuya"
    /// hours are always spoken as their literal small-hours value, NEVER offset by 12); "chiều"/"tối"
    /// (afternoon/evening) add 12 when the literal hour is &lt; 12, so "9 giờ tối" = 21:00 while
    /// "9 giờ sáng" stays 09:00. See <see cref="ResolveDateToken"/> for the same-day-rollover rule
    /// that applies specifically to a "khuya" match (<see cref="TryDetectExplicitTime"/>'s
    /// <c>IsLateNight</c> flag).
    /// </summary>
    private static int ApplyVietnameseTimeOfDay(int hour, string? marker) => marker switch
    {
        "chiều" or "tối" => hour < 12 ? hour + 12 : hour,
        _ => hour // "sáng", "trưa", "khuya", or no marker at all: literal hour, unchanged.
    };

    /// <summary>
    /// Resolves a date (and, when detectable, a time-of-day) from free text, tried in order: the
    /// weekday-keyword scan, then coarse relative keywords ("tomorrow"/"mai", "next week"/"tuần
    /// sau", "today"/"hôm nay") for the DAY, combined with <see cref="TryDetectExplicitTime"/> for
    /// the TIME (applied to the resolved day, or to <paramref name="now"/>'s day if no day keyword
    /// matched). See the class doc comment: this combining strategy is this port's substitute for
    /// the Swift source's <c>NSDataDetector</c>-first behavior, not a literal translation of it.
    /// </summary>
    private static DateToken? ResolveDateToken(string text, DateTimeOffset now, TimeZoneInfo timeZone)
    {
        var lower = text.ToLowerInvariant();

        DateTimeOffset? day = null;
        foreach (var (keyword, weekday) in WeekdayKeywords)
        {
            if (lower.Contains(keyword, StringComparison.Ordinal))
            {
                day = NextOccurrenceOfWeekday(weekday, now, timeZone);
                break;
            }
        }
        if (day is null && ContainsTomorrowCue(lower))
        {
            day = LocalCalendar.AddDays(now, 1, timeZone);
        }
        if (day is null
            && (lower.Contains("next week", StringComparison.Ordinal)
                || lower.Contains("tuần sau", StringComparison.Ordinal)
                || lower.Contains("tuần tới", StringComparison.Ordinal)))
        {
            day = LocalCalendar.AddDays(now, 7, timeZone);
        }
        if (day is null && (lower.Contains("today", StringComparison.Ordinal) || lower.Contains("hôm nay", StringComparison.Ordinal)))
        {
            day = now;
        }

        var explicitTime = TryDetectExplicitTime(text);
        if (explicitTime is (int hour, int minute, bool isLateNight))
        {
            var baseDay = day ?? now;
            var resolved = LocalCalendar.WithTimeOfDay(baseDay, hour, minute, timeZone);
            // "Khuya" ("2h khuya" = 02:00, never +12 — see ApplyVietnameseTimeOfDay) is inherently
            // ambiguous about WHICH night it refers to when no other day cue was given: if that
            // small-hours time has already passed today, it must mean "rạng sáng ngày hôm sau" (the
            // early hours of tomorrow), never a same-day instant already in the past. Only applies
            // when no day keyword resolved `day` above — an explicit day cue ("mai 2h khuya") already
            // pins the date and must never be silently bumped again.
            if (isLateNight && day is null && resolved <= now)
            {
                resolved = LocalCalendar.AddDays(resolved, 1, timeZone);
            }
            return new DateToken(resolved, true);
        }

        if (day is DateTimeOffset resolvedDay)
        {
            return new DateToken(resolvedDay, false);
        }
        return null;
    }

    private static bool ContainsTomorrowCue(string lower) =>
        lower.Contains("tomorrow", StringComparison.Ordinal)
        || lower.Contains("ngày mai", StringComparison.Ordinal)
        || lower.Contains(" mai ", StringComparison.Ordinal)
        || lower.EndsWith(" mai", StringComparison.Ordinal)
        || lower.StartsWith("mai ", StringComparison.Ordinal);

    // MARK: - Defer phrasing -> ParsedCondition.AfterDate

    [GeneratedRegex(
        @"\bstart(?:ing)?\s+(?:on\s+)?(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday|next\s+week)\b",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex DeferCueRegex();

    private static ParsedCondition.AfterDate? DetectDeferCondition(string text, DateTimeOffset now, TimeZoneInfo timeZone)
    {
        var lower = text.ToLowerInvariant();
        var hasVietnameseCue = lower.Contains("mới làm", StringComparison.Ordinal)
            || lower.Contains("để tuần sau", StringComparison.Ordinal)
            || lower.Contains("để thứ", StringComparison.Ordinal);
        var hasEnglishCue = lower.Contains("not until", StringComparison.Ordinal)
            || lower.Contains("wait until", StringComparison.Ordinal)
            || DeferCueRegex().IsMatch(text);

        if (!hasVietnameseCue && !hasEnglishCue)
        {
            return null;
        }
        // A defer cue with no resolvable date is left unset rather than fabricating a date.
        var token = ResolveDateToken(text, now, timeZone);
        if (token is null)
        {
            return null;
        }
        return new ParsedCondition.AfterDate(token.Value.Date, token.Value.IsExplicitTime ? 0.8 : 0.72);
    }

    // MARK: - Deadline (only considered when no defer condition won above)

    private static ParsedValue<DateTimeOffset>? DetectDeadline(string text, DateTimeOffset now, TimeZoneInfo timeZone)
    {
        var token = ResolveDateToken(text, now, timeZone);
        if (token is null)
        {
            return null;
        }
        // No explicit clock time -> we're guessing a time-of-day, so this is genuinely ambiguous
        // and must render as an uncertain chip.
        return new ParsedValue<DateTimeOffset>(token.Value.Date, token.Value.IsExplicitTime ? 0.85 : 0.65);
    }

    // MARK: - Dependency phrasing -> ParsedCondition.TaskDone

    [GeneratedRegex(@"(?:after|once)\s+(.+?)\s+is\s+done", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex DependencyPattern1Regex();

    [GeneratedRegex(@"when\s+(.+?)\s+is\s+done", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex DependencyPattern2Regex();

    [GeneratedRegex(@"sau\s+khi\s+(.+?)\s+xong", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex DependencyPattern3Regex();

    [GeneratedRegex(@"(.+?)\s+xong\s+thì", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex DependencyPattern4Regex();

    [GeneratedRegex(@"after\s+(.+?)(?=,|\.|$)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex DependencyPattern5Regex();

    [GeneratedRegex(@"sau\s+khi\s+(.+?)(?=,|thì|\.|$)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex DependencyPattern6Regex();

    /// <summary>
    /// Tried in this exact order — first match with a non-trivial captured group wins. More
    /// specific patterns (requiring "is done" / "xong") come before the generic "after X" / "sau
    /// khi X" fallbacks, which would otherwise match almost any "after ..." clause.
    /// </summary>
    private static IReadOnlyList<Regex> DependencyPatterns { get; } = new[]
    {
        DependencyPattern1Regex(), DependencyPattern2Regex(), DependencyPattern3Regex(),
        DependencyPattern4Regex(), DependencyPattern5Regex(), DependencyPattern6Regex()
    };

    private static string? FirstCapturedGroup(Regex regex, string text)
    {
        var match = regex.Match(text);
        if (!match.Success || match.Groups.Count <= 1 || !match.Groups[1].Success)
        {
            return null;
        }
        return match.Groups[1].Value.Trim();
    }

    /// <summary>
    /// Confidence reflects match certainty: a titleQuery that fuzzy-matches one of the caller's
    /// currently-open task titles is a much stronger signal than a bare heuristic phrase match —
    /// only the former clears the 0.7 auto-attach-adjacent bar (still gated by the confirm-card
    /// picker regardless).
    /// </summary>
    private static double DependencyConfidence(string titleQuery, IReadOnlyList<string> openTaskTitles)
    {
        var normalizedQuery = titleQuery.ToLowerInvariant().Trim();
        if (normalizedQuery.Length == 0)
        {
            return 0.5;
        }
        foreach (var candidate in openTaskTitles)
        {
            var normalizedCandidate = candidate.ToLowerInvariant();
            if (normalizedCandidate.Contains(normalizedQuery, StringComparison.Ordinal)
                || normalizedQuery.Contains(normalizedCandidate, StringComparison.Ordinal))
            {
                return 0.78;
            }
        }
        return 0.55;
    }

    private static ParsedCondition.TaskDone? DetectDependencyCondition(string text, IReadOnlyList<string> openTaskTitles)
    {
        foreach (var regex in DependencyPatterns)
        {
            var titleQuery = FirstCapturedGroup(regex, text);
            if (titleQuery is null || titleQuery.Length <= 1)
            {
                continue;
            }
            var confidence = DependencyConfidence(titleQuery, openTaskTitles);
            return new ParsedCondition.TaskDone(titleQuery, confidence);
        }
        return null;
    }

    // MARK: - Wait phrasing -> ParsedCondition.External

    [GeneratedRegex(@"waiting\s+(?:for|on)\s+(.+?)(?=,|\.|$)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex ExternalPattern1Regex();

    [GeneratedRegex(@"(?:chờ|đợi)\s+(.+?)(?=,|\.|$)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex ExternalPattern2Regex();

    private static IReadOnlyList<Regex> ExternalPatterns { get; } = new[] { ExternalPattern1Regex(), ExternalPattern2Regex() };

    private static ParsedCondition.External? DetectExternalCondition(string text)
    {
        foreach (var regex in ExternalPatterns)
        {
            var description = FirstCapturedGroup(regex, text);
            if (description is null || description.Length <= 1)
            {
                continue;
            }
            var wordCount = description.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length;
            return new ParsedCondition.External(description, wordCount <= 4 ? 0.72 : 0.62);
        }
        return null;
    }

    // MARK: - Recurrence

    [GeneratedRegex(@"(?:every|mỗi|cứ)\s+(\d+)\s+(?:days?|ngày)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex EveryNDaysRegex();

    private static readonly string[] DailyPhrases = { "every day", "daily", "mỗi ngày", "hằng ngày", "hàng ngày" };
    private static readonly string[] WeeklyPhrases = { "every week", "weekly", "mỗi tuần", "hằng tuần", "hàng tuần" };
    private static readonly string[] MonthlyPhrases = { "every month", "monthly", "mỗi tháng", "hằng tháng", "hàng tháng" };

    // Approximate mappings onto the 4-case Recurrence union — flagged uncertain since "every
    // morning" isn't literally "every day" (no time-of-day concept in Recurrence).
    private static readonly string[] LooseDailyPhrases = { "every morning", "mỗi sáng", "every evening", "mỗi tối" };

    private static int? EveryNDays(string lower)
    {
        var match = EveryNDaysRegex().Match(lower);
        if (!match.Success || !match.Groups[1].Success)
        {
            return null;
        }
        if (!int.TryParse(match.Groups[1].Value, NumberStyles.None, CultureInfo.InvariantCulture, out var days)
            || days <= 0 || days > 365)
        {
            return null;
        }
        return days;
    }

    private static ParsedValue<Recurrence>? DetectRecurrence(string text)
    {
        var lower = text.ToLowerInvariant();
        if (ContainsAny(lower, DailyPhrases)) return new ParsedValue<Recurrence>(new Recurrence.Daily(), 0.82);
        if (ContainsAny(lower, WeeklyPhrases)) return new ParsedValue<Recurrence>(new Recurrence.Weekly(), 0.82);
        if (ContainsAny(lower, MonthlyPhrases)) return new ParsedValue<Recurrence>(new Recurrence.Monthly(), 0.8);
        if (ContainsAny(lower, LooseDailyPhrases)) return new ParsedValue<Recurrence>(new Recurrence.Daily(), 0.62);
        var everyDays = EveryNDays(lower);
        if (everyDays is int days) return new ParsedValue<Recurrence>(new Recurrence.Every(days), 0.78);
        return null;
    }

    // MARK: - Reminder override ("remind me every 30 minutes", "nhắc mỗi 30 phút")

    [GeneratedRegex(
        @"(?:remind(?:\s+me)?(?:\s+every)?|nhắc(?:\s+lại)?\s+mỗi)\s+(\d+)\s*(minutes?|mins?|hours?|hrs?|phút|giờ)",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex ReminderIntervalRegex();

    private static ParsedValue<ReminderPolicy>? DetectReminderOverride(string text)
    {
        var lower = text.ToLowerInvariant();
        if (!lower.Contains("remind", StringComparison.Ordinal) && !lower.Contains("nhắc", StringComparison.Ordinal))
        {
            return null;
        }
        var match = ReminderIntervalRegex().Match(text);
        if (!match.Success || !match.Groups[1].Success || !match.Groups[2].Success)
        {
            return null;
        }
        if (!int.TryParse(match.Groups[1].Value, NumberStyles.None, CultureInfo.InvariantCulture, out var value)
            || value <= 0 || value > 1440)
        {
            return null;
        }
        var unit = match.Groups[2].Value.ToLowerInvariant();
        var interval = unit.StartsWith('h') || unit.StartsWith('g') ? TimeSpan.FromHours(value) : TimeSpan.FromMinutes(value);
        var policy = new ReminderPolicy(new[] { TimeSpan.Zero }, interval);
        return new ParsedValue<ReminderPolicy>(policy, 0.8);
    }

    // MARK: - Kind (.review) + followUpReview

    private static TaskKind DetectKind(string text)
    {
        var lower = text.Trim().ToLowerInvariant();
        if (lower.StartsWith("review ", StringComparison.Ordinal)
            || lower.StartsWith("review after", StringComparison.Ordinal)
            || lower.Contains(" review after ", StringComparison.Ordinal))
        {
            return TaskKind.Review;
        }
        if (lower.StartsWith("xem lại ", StringComparison.Ordinal))
        {
            return TaskKind.Review;
        }
        return TaskKind.Task;
    }

    private static readonly string[] FollowUpReviewPhrases =
    {
        "when done, review", "when it's done, review", "once done, review", "then review it",
        "xong thì xem lại", "làm xong thì xem lại", "xong rồi xem lại"
    };

    private static bool DetectFollowUpReview(string text)
    {
        var lower = text.ToLowerInvariant();
        foreach (var phrase in FollowUpReviewPhrases)
        {
            if (lower.Contains(phrase, StringComparison.Ordinal))
            {
                return true;
            }
        }
        return false;
    }
}
