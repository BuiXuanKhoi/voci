// DefaultCloudParseGateTests.cs — Wave 3-B (A3: Local<->Cloud switch, macOS commit f88d5e5).
using Volar.Domain;
using Xunit;

namespace Volar.Parsing.Tests;

public class DefaultCloudParseGateTests
{
    [Fact]
    public async Task IsOptedInAsync_False_WhenConsentKeyIsAbsent()
    {
        var gate = new DefaultCloudParseGate(new InMemorySettingsStore());

        Assert.False(await gate.IsOptedInAsync());
    }

    [Fact]
    public async Task IsOptedInAsync_True_WhenConsentIsSetTrue()
    {
        var settings = new InMemorySettingsStore();
        settings.SetBool("volar.cloudParseConsent", true);
        var gate = new DefaultCloudParseGate(settings);

        Assert.True(await gate.IsOptedInAsync());
    }

    [Fact]
    public async Task IsOptedInAsync_False_WhenConsentWasExplicitlyDeclined()
    {
        var settings = new InMemorySettingsStore();
        settings.SetBool("volar.cloudParseConsent", false);
        var gate = new DefaultCloudParseGate(settings);

        Assert.False(await gate.IsOptedInAsync());
    }

    [Fact]
    public async Task IsOnlineAsync_ReturnsInjectedValue_WhenTrue()
    {
        var gate = new DefaultCloudParseGate(new InMemorySettingsStore(), isNetworkAvailable: () => true);

        Assert.True(await gate.IsOnlineAsync());
    }

    [Fact]
    public async Task IsOnlineAsync_ReturnsInjectedValue_WhenFalse()
    {
        var gate = new DefaultCloudParseGate(new InMemorySettingsStore(), isNetworkAvailable: () => false);

        Assert.False(await gate.IsOnlineAsync());
    }

    [Fact]
    public async Task IsOnlineAsync_ReturnsTrue_WhenTheProbeThrows()
    {
        // "true when unknown/unable to determine" per ICloudParseGate's own contract — not a
        // security gate, purely an optimization to skip an obviously-doomed request.
        var gate = new DefaultCloudParseGate(
            new InMemorySettingsStore(),
            isNetworkAvailable: () => throw new InvalidOperationException("probe unavailable"));

        Assert.True(await gate.IsOnlineAsync());
    }

    [Fact]
    public async Task IsOnlineAsync_DefaultProbe_NeverThrows()
    {
        // Exercises the real NetworkInterface.GetIsNetworkAvailable() default path at least once
        // (no injected delegate) — must never throw regardless of the test machine's actual
        // network state.
        var gate = new DefaultCloudParseGate(new InMemorySettingsStore());

        var result = await Record.ExceptionAsync(async () => await gate.IsOnlineAsync());

        Assert.Null(result);
    }
}
