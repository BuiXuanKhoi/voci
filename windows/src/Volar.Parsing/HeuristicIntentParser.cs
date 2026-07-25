// Volar.Parsing/HeuristicIntentParser.cs — adapts Volar.Domain.HeuristicNLParser (sync, no notion of
// IIntentParser) to IIntentParser so it can serve as IntentRouter's floor tier.
//
// Port of Swift's `extension HeuristicNLParser: IntentParser` (Sources/Model/NLParser.swift,
// ~L575-599). That conformance lives here rather than in Volar.Domain because: (a) IIntentParser
// itself is declared in this project (the Parsing porting wave's contract, per
// Volar.Domain/NLParser.cs's own remarks), and (b) the dependency direction is Volar.Parsing ->
// Volar.Domain, never the reverse — Volar.Domain must stay parser-tier-agnostic.
using Volar.Domain;

namespace Volar.Parsing;

/// <summary>Adapts <see cref="HeuristicNLParser"/> to <see cref="IIntentParser"/>.</summary>
public sealed class HeuristicIntentParser : IIntentParser
{
    private readonly HeuristicNLParser _parser;
    private readonly TimeZoneInfo _timeZone;

    /// <param name="timeZone">
    /// Explicit, never read from <see cref="TimeZoneInfo.Local"/> internally — matches
    /// <see cref="HeuristicNLParser"/>'s own domain-purity rule (Volar.Domain never reads the system
    /// clock/timezone), extended here to Volar.Parsing for the same testability reason.
    /// </param>
    /// <param name="parser">Injectable for tests; defaults to a fresh <see cref="HeuristicNLParser"/>.</param>
    public HeuristicIntentParser(TimeZoneInfo timeZone, HeuristicNLParser? parser = null)
    {
        _timeZone = timeZone ?? throw new ArgumentNullException(nameof(timeZone));
        _parser = parser ?? new HeuristicNLParser();
    }

    /// <summary>
    /// Matches <see cref="IIntentParser.ParseAsync"/> exactly (parsing-contract.md). Synchronous work
    /// wrapped in an already-completed <see cref="Task"/> — <see cref="HeuristicNLParser"/> is pure
    /// text-in/<see cref="ParsedTask"/>-out with no I/O, so no real asynchrony is needed; this only
    /// exists to satisfy the interface's async shape, matching why the Swift protocol method itself
    /// is <c>async</c> for a synchronous implementation.
    /// </summary>
    public Task<IReadOnlyList<ParsedTask>> ParseAsync(
        string transcript,
        DateTimeOffset now,
        IReadOnlyList<string> openTaskTitles,
        CancellationToken cancellationToken = default)
        => Task.FromResult(_parser.ParseMany(transcript, now, _timeZone, openTaskTitles));

    /// <summary>
    /// Template floor for breakdown mode — port of Swift's
    /// <c>HeuristicNLParser: IntentParser.breakdown(title:notes:)</c>: a generic 5-step scaffold, not
    /// real reasoning (this parser is pure keyword/regex text-in/<see cref="ParsedTask"/>-out — it has
    /// no model to ask "what are the steps?"), just enough to satisfy the contract's "3...9 step
    /// titles" bound so the confirm card always has something even when Slm/Cloud both fell through.
    /// Never fabricates for an empty/whitespace-only title — returns <c>[]</c> instead (constitution
    /// II — never silently guess).
    /// </summary>
    public Task<IReadOnlyList<string>> BreakdownAsync(
        string title, string? notes, CancellationToken cancellationToken = default)
    {
        var trimmedTitle = title.Trim();
        if (trimmedTitle.Length == 0)
        {
            return Task.FromResult<IReadOnlyList<string>>(Array.Empty<string>());
        }
        IReadOnlyList<string> steps = new[]
        {
            $"Gather what's needed for {trimmedTitle}",
            "Start the first small piece",
            "Work through the middle of it",
            "Check the result",
            $"Wrap up {trimmedTitle}"
        };
        return Task.FromResult(steps);
    }
}
