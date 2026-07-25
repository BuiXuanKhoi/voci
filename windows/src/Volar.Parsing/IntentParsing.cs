// Volar.Parsing/IntentParsing.cs — port of Sources/Parsing/IntentParsing.swift: the IIntentParser
// contract, IntentRouter (tiered cascade), and the shared raw-output decode/validation helper both
// OnnxSlmParser (T020 equivalent) and CloudParser (T021 equivalent) funnel through before ever
// producing a Volar.Domain.ParsedTask.
//
// Frozen seam: specs/002-workflow-command-center/contracts/parsing-contract.md. ParsedTask,
// ParsedValue<T>, ParsedCondition, Recurrence, ReminderPolicy, TaskKind are owned by Volar.Domain
// (NLParser.cs / Recurrence.cs) and referenced HERE BY NAME ONLY — nothing in this file redefines
// them.
using System.Globalization;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using Volar.Domain;

namespace Volar.Parsing;

// MARK: - IIntentParser (frozen contract)

/// <summary>
/// One utterance -&gt; 1...10 tasks, or one parent title -&gt; 3...9 breakdown step titles.
/// Implemented by <see cref="OnnxSlmParser"/>, <see cref="CloudParser"/>, and
/// <see cref="HeuristicIntentParser"/> (the Volar.Domain <see cref="HeuristicNLParser"/> adapter).
/// </summary>
/// <remarks>
/// Port of Swift's <c>protocol IntentParser</c>. Never throws for content reasons — a parser that
/// can't produce anything usable returns an empty list and lets <see cref="IntentRouter"/> fall
/// through to the next tier (constitution II: a parsing failure degrades, never crashes, never
/// silently drops the whole utterance).
/// </remarks>
public interface IIntentParser
{
    Task<IReadOnlyList<ParsedTask>> ParseAsync(
        string transcript,
        DateTimeOffset now,
        IReadOnlyList<string> openTaskTitles,
        CancellationToken cancellationToken = default);

    Task<IReadOnlyList<string>> BreakdownAsync(
        string title,
        string? notes,
        CancellationToken cancellationToken = default);
}

// MARK: - Cloud opt-in / reachability gate (injected — owned by Settings/AppState/StoreKit owner)

/// <summary>
/// Whether Cloud is even allowed to be <i>attempted</i> this call. Quota (429) is a per-call SERVER
/// verdict handled inside <see cref="CloudParser"/>/<see cref="IntentRouter"/>, not this gate — this
/// only covers the two preconditions research.md R5 requires before any network request is made:
/// explicit one-time privacy consent (constitution I — text egress requires consent regardless of
/// tier) and basic reachability (avoid a doomed round-trip while offline).
/// </summary>
/// <remarks>
/// Port of Swift's <c>protocol CloudParseGate</c>. Deliberately minimal (two booleans, no
/// tier/entitlement info) — tier selection (paid JWS vs free device token) lives entirely inside
/// whatever concrete <see cref="IParseCredentialProvider"/> is injected into <see cref="CloudParser"/>,
/// not here. <see cref="IntentRouter"/> only asks "may I try Cloud at all right now."
/// </remarks>
public interface ICloudParseGate
{
    /// <summary>
    /// One-time explicit privacy consent has been granted (never assume true; absent consent, Cloud
    /// must never be attempted even if a valid credential exists).
    /// </summary>
    Task<bool> IsOptedInAsync(CancellationToken cancellationToken = default);

    /// <summary>
    /// Best-effort network reachability. <see langword="true"/> when unknown/unable to determine (a
    /// real request will fail cleanly and fall through anyway — this is purely an optimization to
    /// skip an obviously-doomed request, not a security gate).
    /// </summary>
    Task<bool> IsOnlineAsync(CancellationToken cancellationToken = default);
}

// MARK: - IntentRouter (T019 equivalent)

/// <summary>
/// Routes across the Windows parsing tiers, in the SAME order as Swift: tier 1 = local ONNX SLM
/// (optional, default disabled — plays the role of Swift's on-device Foundation Model tier), tier 2 =
/// Cloud (Supabase <c>/parse</c>, opted-in + online + credentialed only), tier 3 = Heuristic
/// (Volar.Domain, rule-based, offline) — the guaranteed non-empty floor.
/// </summary>
/// <remarks>
/// <para>
/// <b>Authority:</b> <c>Volar/Sources/Parsing/IntentParsing.swift</c>'s file header states the order
/// explicitly — "<c>IntentRouter (FM -&gt; Cloud -&gt; Heuristic)</c>" — and its <c>parse(...)</c>
/// body implements exactly that: try FM, return capped if non-empty; else try Cloud, return capped if
/// non-empty; else use Heuristic (always available, never empty) as the floor, capped; else (should
/// never happen) the defensive title-only fallback. This class mirrors that 1:1, with
/// <see cref="ISlmParser"/> standing in for Swift's on-device FM tier (no Windows equivalent to Apple
/// Foundation Models exists, hence "SLM" rather than "FM" in this port's naming).
/// </para>
/// <para>
/// Putting Heuristic LAST is deliberate and load-bearing, not incidental: <see cref="HeuristicNLParser"/>
/// is an unconditional floor (it never returns empty — worst case a bare title-only stub), which is
/// exactly what guarantees the whole router never returns nothing even if Slm/Cloud are both
/// unavailable. Placing it earlier would make the smarter tiers (multi-task splitting, richer
/// structure) structurally unreachable, since the floor would always win first — see git history on
/// this file for that exact bug, previously present here and fixed per lead review.
/// </para>
/// </remarks>
public sealed partial class IntentRouter : IIntentParser
{
    /// <summary>Hard cap, all tiers, all call sites (contract: "Enforces the 10-task cap centrally").</summary>
    public const int MaxTaskCap = 10;

    /// <summary>Which tier actually produced the last successful result — diagnostics only, never PII.</summary>
    public enum Route
    {
        Heuristic,
        Slm,
        Cloud
    }

    /// <summary>Set at the start of every <see cref="ParseAsync"/> call.</summary>
    public Route LastRoute { get; private set; } = Route.Heuristic;

    /// <summary>
    /// <see langword="true"/> for exactly the duration between a <see cref="ParseAsync"/> call that
    /// hit Cloud's 429 and the NEXT call (reset at the top of every call) — the confirm-card/UI owner
    /// reads this once per parse to show the one-line gentle note (FR-012, parse-proxy.md 429). Side
    /// channel: the frozen <see cref="IIntentParser.ParseAsync"/> return type carries tasks only, so
    /// the "quota" signal can't ride in the return value itself.
    /// </summary>
    public bool LastCloudQuotaNote { get; private set; }

    private readonly IIntentParser _heuristic;
    private readonly ISlmParser? _slm;
    private readonly CloudParser? _cloud;
    private readonly ICloudParseGate? _cloudGate;

    /// <param name="heuristic">
    /// The floor. Always available — never <see langword="null"/>. Typically a
    /// <see cref="HeuristicIntentParser"/> wrapping <see cref="HeuristicNLParser"/>.
    /// </param>
    /// <param name="slm">
    /// <see langword="null"/> disables the SLM tier entirely; even when non-null, the tier is skipped
    /// unless <see cref="ISlmParser.IsAvailable"/> is <see langword="true"/> (never crashes on
    /// unavailable/model-missing).
    /// </param>
    /// <param name="cloud">
    /// <see langword="null"/> disables the Cloud tier entirely — router never attempts a network
    /// call.
    /// </param>
    /// <param name="cloudGate">
    /// <see langword="null"/> also disables Cloud (never attempt Cloud without an explicit gate that
    /// can assert consent).
    /// </param>
    public IntentRouter(
        IIntentParser heuristic,
        ISlmParser? slm = null,
        CloudParser? cloud = null,
        ICloudParseGate? cloudGate = null)
    {
        _heuristic = heuristic ?? throw new ArgumentNullException(nameof(heuristic));
        _slm = slm;
        _cloud = cloud;
        _cloudGate = cloudGate;
    }

    public async Task<IReadOnlyList<ParsedTask>> ParseAsync(
        string transcript,
        DateTimeOffset now,
        IReadOnlyList<string> openTaskTitles,
        CancellationToken cancellationToken = default)
    {
        LastCloudQuotaNote = false;
        var trimmed = transcript.Trim();
        if (trimmed.Length == 0)
        {
            // Nothing to parse. Callers shouldn't invoke this on empty input, but never crash or
            // fabricate a task out of nothing — an empty result here is the one legitimate [].
            LastRoute = Route.Heuristic;
            return Array.Empty<ParsedTask>();
        }

        // R5: openTaskTitles forwarded to a remote/on-device model ONLY on dependency phrasing —
        // applied once here so every remote/on-device tier sees the same (possibly-empty) list.
        // Heuristic never receives this (see below) — matches Swift exactly (IntentParsing.swift
        // passes `openTaskTitles: []` to the heuristic tier unconditionally).
        var titles = ContainsDependencyPhrasing(transcript)
            ? openTaskTitles.Take(100).ToArray()
            : Array.Empty<string>();

        // Tier 1: local ONNX SLM — optional, default disabled; never throws on unavailable/disabled/
        // any generation failure (see OnnxSlmParser). Plays the role of Swift's on-device FM tier.
        if (_slm is { IsAvailable: true })
        {
            var slmResult = await _slm.ParseAsync(transcript, now, titles, cancellationToken).ConfigureAwait(false);
            if (slmResult.Count > 0)
            {
                LastRoute = Route.Slm;
                return Cap(slmResult);
            }
        }

        // Tier 2: Cloud (Supabase /parse) — only attempted opted-in + online (never sends an
        // unauthenticated/unconsented request; matches Swift's CloudParseGate check exactly).
        if (_cloud is not null && _cloudGate is not null
            && await _cloudGate.IsOptedInAsync(cancellationToken).ConfigureAwait(false)
            && await _cloudGate.IsOnlineAsync(cancellationToken).ConfigureAwait(false))
        {
            var outcome = await _cloud
                .ParseDetailedAsync(transcript, now, titles, cancellationToken)
                .ConfigureAwait(false);
            switch (outcome)
            {
                case CloudParseOutcome.Tasks { Value.Count: > 0 } tasks:
                    LastRoute = Route.Cloud;
                    return Cap(tasks.Value);
                case CloudParseOutcome.Tasks:
                    break; // decoded but empty — fall through same as any other Cloud non-result
                case CloudParseOutcome.QuotaExceeded:
                    LastCloudQuotaNote = true;
                    break;
                case CloudParseOutcome.Unavailable:
                    break;
            }
        }

        // Tier 3: Heuristic (rule-based, offline, always available) — the guaranteed floor. Note it
        // always receives an EMPTY openTaskTitles list regardless of what the caller passed in,
        // mirroring Swift's IntentParsing.swift, which hardcodes
        // `heuristic.parse(transcript, now: now, openTaskTitles: [])` verbatim.
        var heuristicResult = await _heuristic
            .ParseAsync(transcript, now, Array.Empty<string>(), cancellationToken)
            .ConfigureAwait(false);
        if (heuristicResult.Count > 0)
        {
            LastRoute = Route.Heuristic;
            return Cap(heuristicResult);
        }

        // Defensive floor: even the always-available heuristic returned nothing (shouldn't normally
        // happen). Never discard the utterance — constitution II.
        LastRoute = Route.Heuristic;
        return new[] { TitleOnlyTask(transcript) };
    }

    public async Task<IReadOnlyList<string>> BreakdownAsync(
        string title, string? notes, CancellationToken cancellationToken = default)
    {
        // Same tier order as ParseAsync above (Slm -> Cloud -> Heuristic floor), matching Swift's
        // breakdown(title:notes:): FM breakdown if valid -> Cloud breakdown if valid -> Heuristic's
        // generic-template floor.
        if (_slm is { IsAvailable: true })
        {
            var steps = await _slm.BreakdownAsync(title, notes, cancellationToken).ConfigureAwait(false);
            if (IsValidBreakdown(steps))
            {
                return steps;
            }
        }

        if (_cloud is not null && _cloudGate is not null
            && await _cloudGate.IsOptedInAsync(cancellationToken).ConfigureAwait(false)
            && await _cloudGate.IsOnlineAsync(cancellationToken).ConfigureAwait(false))
        {
            var steps = await _cloud.BreakdownAsync(title, notes, cancellationToken).ConfigureAwait(false);
            if (IsValidBreakdown(steps))
            {
                return steps;
            }
        }

        // Heuristic's breakdown floor (HeuristicIntentParser.BreakdownAsync) is unconditionally
        // non-empty for any non-blank title — the guaranteed final answer, exactly like Swift's
        // `HeuristicNLParser: IntentParser.breakdown(title:notes:)` template floor.
        return await _heuristic.BreakdownAsync(title, notes, cancellationToken).ConfigureAwait(false);
    }

    // MARK: - Cap + floor helpers

    public static IReadOnlyList<ParsedTask> Cap(IReadOnlyList<ParsedTask> tasks)
        => tasks.Count <= MaxTaskCap ? tasks : tasks.Take(MaxTaskCap).ToArray();

    public static bool IsValidBreakdown(IReadOnlyList<string> steps)
        => steps.Count is >= 3 and <= 9 && steps.All(s => s.Trim().Length > 0);

    /// <summary>
    /// The absolute floor: a task with only a title (the source transcript, trimmed) and the
    /// transcript retained verbatim. Never crashes, never discards.
    /// </summary>
    public static ParsedTask TitleOnlyTask(string transcript)
    {
        var trimmed = transcript.Trim();
        return new ParsedTask(trimmed.Length == 0 ? transcript : trimmed, transcript);
    }

    // MARK: - Dependency-phrasing detector (R5)

    [GeneratedRegex(@"\bxong\b[^.!?]{0,40}\bthì\b", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex XongThiRegex();

    [GeneratedRegex(@"\bafter\b", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex AfterRegex();

    [GeneratedRegex(@"\bwhen\b[^.!?]{0,40}\bdone\b", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex WhenDoneRegex();

    /// <summary>
    /// Best-effort keyword/regex detector for "sau khi", "xong … thì", "after", "when … done" —
    /// deliberately simple. False negatives just mean <c>openTaskTitles</c> isn't forwarded (parser
    /// falls back to no cross-task linking, never a crash); false positives just forward a harmless
    /// title list.
    /// </summary>
    public static bool ContainsDependencyPhrasing(string transcript)
    {
        var lower = transcript.ToLowerInvariant();
        if (lower.Contains("sau khi", StringComparison.Ordinal))
        {
            return true;
        }
        if (XongThiRegex().IsMatch(lower))
        {
            return true;
        }
        if (AfterRegex().IsMatch(lower))
        {
            return true;
        }
        if (WhenDoneRegex().IsMatch(lower))
        {
            return true;
        }
        return false;
    }
}

// MARK: - Shared raw wire shape (untrusted) + decode-validation helper

/// <summary>
/// Wraps a raw model-reported value with its raw model-reported confidence — mirrors
/// <c>ConfidenceValue&lt;T&gt;</c> in <c>supabase/functions/_shared/schema.ts</c> (the
/// already-implemented server wire response for <c>/functions/v1/parse</c>). <see cref="CloudParser"/>
/// decodes JSON directly into <c>RawConfidence&lt;T&gt;</c>; <see cref="OnnxSlmParser"/> would
/// construct it manually from on-device generation output. Both funnel into the same
/// <see cref="ParsedTaskValidation.Validate"/> below — one validation code path for both remote/local
/// tiers.
/// </summary>
// NOTE on `[property: JsonRequired]` below: mirrors Swift's `Decodable` synthesis, where a
// non-optional stored property (`var value: T`, `var kind: String`, ...) makes the WHOLE decode
// throw when that key is absent — `try? JSONDecoder().decode([RawParsedTask].self, ...)` then
// yields `nil` for the entire array, not a partially-populated element. Without this attribute,
// System.Text.Json silently defaults a missing required constructor parameter to `null`/`default`
// instead of throwing, which would desync this port from Swift's all-or-nothing-per-element decode
// behavior (and, for reference-typed required fields, risk a null downstream in
// `ParsedTaskValidation`). Optional fields (nullable, with a `= null` default) intentionally have no
// such attribute — a missing key there is a legitimate "the model didn't report this field," exactly
// like Swift's optional stored properties.
public sealed record RawConfidence<T>([property: JsonRequired] T Value, [property: JsonRequired] double Confidence);

/// <summary>"taskDone" | "afterDate" | "external".</summary>
public sealed record RawParsedCondition(
    [property: JsonRequired] string Kind,
    string? ReferenceTitle = null,
    string? Date = null,
    string? Description = null);

/// <summary>"daily" | "weekly" | "monthly" | "every".</summary>
public sealed record RawParsedRecurrence([property: JsonRequired] string Type, int? EveryDays = null);

public sealed record RawParsedReminderOverride(
    [property: JsonRequired] IReadOnlyList<double> OffsetsMinutes,
    double? RepeatEveryMinutes = null);

public sealed record RawParsedSubtask(
    [property: JsonRequired] RawConfidence<string> Title,
    [property: JsonRequired] RawConfidence<double> EstimateMinutes);

/// <summary>
/// The untrusted, wire-shaped task both Cloud and the (future) SLM tier produce before validation.
/// Mirrors <c>ParsedTaskOut</c> in <c>supabase/functions/_shared/schema.ts</c> field-for-field. NEVER
/// used directly by app code beyond this file's validator — it exists only to be converted into a
/// validated <see cref="ParsedTask"/> by <see cref="ParsedTaskValidation.Validate"/>.
/// </summary>
// `Deadline` is an ISO8601 string. `Kind` is "task" | "review".
public sealed record RawParsedTask(
    [property: JsonRequired] RawConfidence<string> Title,
    RawConfidence<string>? Notes = null,
    RawConfidence<string>? Deadline = null,
    RawConfidence<double>? EstimateMinutes = null,
    RawConfidence<int>? Priority = null,
    RawConfidence<RawParsedRecurrence>? Recurrence = null,
    RawConfidence<RawParsedReminderOverride>? ReminderOverride = null,
    IReadOnlyList<RawConfidence<RawParsedCondition>>? Conditions = null,
    RawConfidence<string>? Kind = null,
    IReadOnlyList<RawParsedSubtask>? Subtasks = null,
    RawConfidence<bool>? FollowUpReview = null);

/// <summary>
/// Converts untrusted <see cref="RawParsedTask"/> values into validated <see cref="ParsedTask"/>s
/// (constitution II: "Raw LLM output MUST NEVER be executed or persisted. It MUST be decoded into the
/// validated ParsedTask... Any decode/schema violation MUST fall back to a title-only task... A
/// parsing error on one attribute MUST NOT discard the others").
/// </summary>
/// <remarks>
/// Two-tier fallback, matching the constitution's wording precisely:
/// <list type="number">
/// <item>
/// <b>Per-attribute</b>: a malformed/out-of-range field (bad ISO8601 string, confidence outside
/// 0...1, priority outside 1...4, empty condition description, etc.) drops ONLY that field — every
/// other attribute on the task is preserved.
/// </item>
/// <item>
/// <b>Per-task title</b>: if <c>title</c> itself is unusable (empty after trimming), the task
/// becomes title-only using the ORIGINAL transcript as its title (never a blank/garbage title).
/// </item>
/// </list>
/// A tier-wide failure (the raw array itself couldn't be decoded at all, e.g. malformed JSON) is NOT
/// handled here — that's reported by the producer (<see cref="CloudParser"/>/<see cref="OnnxSlmParser"/>)
/// as "unavailable", so <see cref="IntentRouter"/> falls through to the NEXT tier rather than this
/// helper manufacturing one low-quality task itself.
/// </remarks>
public static class ParsedTaskValidation
{
    /// <summary>
    /// Parses an ISO8601 instant into UTC. Accepts a trailing zone designator (Z or ±HH:MM) or none
    /// (assumed UTC), with or without fractional seconds — mirrors Swift's
    /// <c>ISO8601DateFormatter</c> fallback-to-fractional-seconds behavior. Always returns UTC (never
    /// a naive local time) — matches this port's DateTimeOffset-everywhere rule.
    /// </summary>
    public static DateTimeOffset? ParseIso8601(string value)
    {
        if (DateTimeOffset.TryParse(
                value,
                CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
                out var result))
        {
            return result;
        }
        return null;
    }

    /// <summary>0...1 inclusive; any other value (including NaN) is a schema violation -&gt; field dropped.</summary>
    private static bool IsValidConfidence(double value) => double.IsFinite(value) && value is >= 0 and <= 1;

    public static IReadOnlyList<ParsedTask> ValidateAll(IReadOnlyList<RawParsedTask> raws, string sourceTranscript)
        => raws.Select(r => Validate(r, sourceTranscript)).ToArray();

    public static ParsedTask Validate(RawParsedTask raw, string sourceTranscript)
    {
        var trimmedTitle = raw.Title.Value.Trim();
        var title = trimmedTitle.Length == 0 ? sourceTranscript.Trim() : trimmedTitle;

        string? notes = null;
        if (raw.Notes is { } notesConfidence)
        {
            var trimmedNotes = notesConfidence.Value.Trim();
            notes = trimmedNotes.Length == 0 ? null : trimmedNotes;
        }

        ParsedValue<DateTimeOffset>? deadline = null;
        if (raw.Deadline is { } deadlineConfidence
            && IsValidConfidence(deadlineConfidence.Confidence)
            && ParseIso8601(deadlineConfidence.Value) is { } parsedDeadline)
        {
            deadline = new ParsedValue<DateTimeOffset>(parsedDeadline, deadlineConfidence.Confidence);
        }

        ParsedValue<int>? estimateMinutes = null;
        if (raw.EstimateMinutes is { } estimateConfidence
            && IsValidConfidence(estimateConfidence.Confidence)
            && double.IsFinite(estimateConfidence.Value)
            && estimateConfidence.Value > 0)
        {
            estimateMinutes = new ParsedValue<int>(
                (int)Math.Round(estimateConfidence.Value, MidpointRounding.AwayFromZero),
                estimateConfidence.Confidence);
        }

        ParsedValue<int>? priority = null;
        if (raw.Priority is { } priorityConfidence
            && IsValidConfidence(priorityConfidence.Confidence)
            && priorityConfidence.Value is >= 1 and <= 4)
        {
            priority = new ParsedValue<int>(priorityConfidence.Value, priorityConfidence.Confidence);
        }

        ParsedValue<Recurrence>? recurrence = null;
        if (raw.Recurrence is { } recurrenceConfidence && IsValidConfidence(recurrenceConfidence.Confidence))
        {
            Recurrence? mapped = recurrenceConfidence.Value.Type switch
            {
                "daily" => new Recurrence.Daily(),
                "weekly" => new Recurrence.Weekly(),
                "monthly" => new Recurrence.Monthly(),
                "every" when recurrenceConfidence.Value.EveryDays is > 0
                    => new Recurrence.Every(recurrenceConfidence.Value.EveryDays.Value),
                _ => null
            };
            if (mapped is not null)
            {
                recurrence = new ParsedValue<Recurrence>(mapped, recurrenceConfidence.Confidence);
            }
        }

        ParsedValue<ReminderPolicy>? reminderOverride = null;
        if (raw.ReminderOverride is { } reminderConfidence && IsValidConfidence(reminderConfidence.Confidence))
        {
            var offsets = reminderConfidence.Value.OffsetsMinutes
                .Where(double.IsFinite)
                .Select(TimeSpan.FromMinutes)
                .ToArray();
            if (offsets.Length > 0)
            {
                TimeSpan? repeatEvery = null;
                if (reminderConfidence.Value.RepeatEveryMinutes is { } repeatMinutes
                    && double.IsFinite(repeatMinutes)
                    && repeatMinutes > 0)
                {
                    repeatEvery = TimeSpan.FromMinutes(repeatMinutes);
                }
                var policy = new ReminderPolicy(offsets, repeatEvery);
                reminderOverride = new ParsedValue<ReminderPolicy>(policy, reminderConfidence.Confidence);
            }
        }

        var conditions = new List<ParsedCondition>();
        if (raw.Conditions is not null)
        {
            foreach (var confidenceCondition in raw.Conditions)
            {
                if (!IsValidConfidence(confidenceCondition.Confidence))
                {
                    continue;
                }
                var value = confidenceCondition.Value;
                switch (value.Kind)
                {
                    case "taskDone":
                        var reference = value.ReferenceTitle?.Trim();
                        if (!string.IsNullOrEmpty(reference))
                        {
                            conditions.Add(new ParsedCondition.TaskDone(reference, confidenceCondition.Confidence));
                        }
                        break;
                    case "afterDate":
                        if (value.Date is { } dateString && ParseIso8601(dateString) is { } date)
                        {
                            conditions.Add(new ParsedCondition.AfterDate(date, confidenceCondition.Confidence));
                        }
                        break;
                    case "external":
                        var description = value.Description?.Trim();
                        if (!string.IsNullOrEmpty(description))
                        {
                            conditions.Add(new ParsedCondition.External(description, confidenceCondition.Confidence));
                        }
                        break;
                }
            }
        }

        var kind = raw.Kind?.Value == "review" ? TaskKind.Review : TaskKind.Task;

        // Contract's `subtasks: [String]` carries titles only (no per-step confidence/estimate) —
        // drop empty titles, cap defensively against a hostile/buggy producer flooding this list.
        var subtasks = (raw.Subtasks ?? Array.Empty<RawParsedSubtask>())
            .Select(s => s.Title.Value.Trim())
            .Where(s => s.Length > 0)
            .Take(20)
            .ToArray();

        var followUpReview = raw.FollowUpReview?.Value ?? false;

        return new ParsedTask(
            title,
            sourceTranscript,
            Notes: notes,
            Deadline: deadline,
            EstimateMinutes: estimateMinutes,
            Priority: priority,
            ReminderOverride: reminderOverride,
            Recurrence: recurrence,
            Kind: kind,
            Conditions: conditions,
            Subtasks: subtasks,
            FollowUpReview: followUpReview);
    }
}
