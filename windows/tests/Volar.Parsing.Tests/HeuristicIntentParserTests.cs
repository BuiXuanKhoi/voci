using Xunit;

namespace Volar.Parsing.Tests;

public class HeuristicIntentParserTests
{
    private static readonly DateTimeOffset Now = new(2026, 7, 20, 9, 0, 0, TimeSpan.Zero);
    private static readonly TimeZoneInfo Utc = TimeZoneInfo.Utc;

    [Fact]
    public async Task ParseAsync_DelegatesToHeuristicNLParser_ParseMany()
    {
        IIntentParser adapter = new HeuristicIntentParser(Utc);

        var result = await adapter.ParseAsync("buy milk tomorrow", Now, Array.Empty<string>());

        Assert.Single(result);
        Assert.Equal("buy milk tomorrow", result[0].Title, ignoreCase: true);
    }

    [Fact]
    public async Task BreakdownAsync_EmptyTitle_ReturnsEmpty()
    {
        IIntentParser adapter = new HeuristicIntentParser(Utc);

        var steps = await adapter.BreakdownAsync("   ", null);

        Assert.Empty(steps);
    }

    [Fact]
    public async Task BreakdownAsync_NonEmptyTitle_ReturnsFiveStepTemplate_ValidByRouterBound()
    {
        IIntentParser adapter = new HeuristicIntentParser(Utc);

        var steps = await adapter.BreakdownAsync("Plan a trip", null);

        Assert.Equal(5, steps.Count);
        Assert.True(IntentRouter.IsValidBreakdown(steps));
        Assert.Contains("Plan a trip", steps[0]);
        Assert.Contains("Plan a trip", steps[^1]);
    }
}
