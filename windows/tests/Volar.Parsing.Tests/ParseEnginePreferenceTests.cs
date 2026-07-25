// ParseEnginePreferenceTests.cs — Wave 3-B (A3: Local<->Cloud switch, macOS commit f88d5e5).
using Volar.Domain;
using Xunit;

namespace Volar.Parsing.Tests;

public class ParseEnginePreferenceTests
{
    [Theory]
    [InlineData(ParseEnginePreference.OnDevice, "onDevice")]
    [InlineData(ParseEnginePreference.Cloud, "cloud")]
    public void ToRawValue_MatchesSwiftRawValue(ParseEnginePreference preference, string expected)
    {
        Assert.Equal(expected, preference.ToRawValue());
    }

    [Theory]
    [InlineData("onDevice", ParseEnginePreference.OnDevice)]
    [InlineData("cloud", ParseEnginePreference.Cloud)]
    public void TryParse_RoundTripsKnownRawValues(string raw, ParseEnginePreference expected)
    {
        var ok = ParseEnginePreferenceExtensions.TryParse(raw, out var parsed);

        Assert.True(ok);
        Assert.Equal(expected, parsed);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("Cloud")] // case-sensitive, like Swift's RawRepresentable init
    [InlineData("garbage")]
    public void TryParse_ReturnsFalse_AndDefaultsToOnDevice_ForUnknownInput(string? raw)
    {
        var ok = ParseEnginePreferenceExtensions.TryParse(raw, out var parsed);

        Assert.False(ok);
        Assert.Equal(ParseEnginePreference.OnDevice, parsed);
    }

    [Fact]
    public void FromCloudConsent_True_MapsToCloud()
    {
        Assert.Equal(ParseEnginePreference.Cloud, ParseEnginePreferenceExtensions.FromCloudConsent(true));
    }

    [Fact]
    public void FromCloudConsent_False_MapsToOnDevice()
    {
        Assert.Equal(ParseEnginePreference.OnDevice, ParseEnginePreferenceExtensions.FromCloudConsent(false));
    }

    [Fact]
    public void ToCloudConsent_IsTheExactInverseOfFromCloudConsent()
    {
        foreach (var preference in new[] { ParseEnginePreference.OnDevice, ParseEnginePreference.Cloud })
        {
            var consent = preference.ToCloudConsent();
            Assert.Equal(preference, ParseEnginePreferenceExtensions.FromCloudConsent(consent));
        }
    }

    [Fact]
    public void PreferenceStore_Get_DefaultsToOnDevice_WhenConsentNeverSet()
    {
        var settings = new InMemorySettingsStore();

        Assert.Equal(ParseEnginePreference.OnDevice, ParseEnginePreferenceStore.Get(settings));
    }

    [Fact]
    public void PreferenceStore_Set_ThenGet_RoundTrips_ForBothCases()
    {
        var settings = new InMemorySettingsStore();

        ParseEnginePreferenceStore.Set(settings, ParseEnginePreference.Cloud);
        Assert.Equal(ParseEnginePreference.Cloud, ParseEnginePreferenceStore.Get(settings));

        ParseEnginePreferenceStore.Set(settings, ParseEnginePreference.OnDevice);
        Assert.Equal(ParseEnginePreference.OnDevice, ParseEnginePreferenceStore.Get(settings));
    }

    [Fact]
    public async Task PreferenceStore_Set_WritesTheSameKey_DefaultCloudParseGateReads()
    {
        // Single-source-of-truth guard: the Settings picker and the router's consent gate must
        // never be able to disagree (this is the whole point of bridging over cloudParseConsent
        // instead of introducing a second key).
        var settings = new InMemorySettingsStore();
        var gate = new DefaultCloudParseGate(settings, isNetworkAvailable: () => true);

        ParseEnginePreferenceStore.Set(settings, ParseEnginePreference.Cloud);

        Assert.True(await gate.IsOptedInAsync());
    }

    [Fact]
    public void CloudParseConsentKey_MatchesMacOSUserDefaultsKey()
    {
        Assert.Equal("volar.cloudParseConsent", ParseEnginePreferenceStore.CloudParseConsentKey);
    }
}
