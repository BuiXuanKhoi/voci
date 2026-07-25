// ConfigParseCredentialProviderTests.cs — Wave 3-B (A3: Local<->Cloud switch, macOS commit
// f88d5e5). Also covers the end-to-end "silent fallback" acceptance criterion: cloud selected +
// unconfigured must degrade IntentRouter to the heuristic tier with no exception and no network
// attempt.
using Volar.Domain;
using Xunit;

namespace Volar.Parsing.Tests;

public class ConfigParseCredentialProviderTests
{
    [Fact]
    public void IsConfigured_False_WhenNeitherKeyIsSet()
    {
        var provider = new ConfigParseCredentialProvider(new InMemorySettingsStore());

        Assert.False(provider.IsConfigured);
    }

    [Fact]
    public void IsConfigured_False_WhenOnlyBaseUrlIsSet()
    {
        var settings = new InMemorySettingsStore();
        settings.SetString(ConfigParseCredentialProvider.BaseUrlSettingsKey, "https://example.supabase.co");

        Assert.False(new ConfigParseCredentialProvider(settings).IsConfigured);
    }

    [Fact]
    public void IsConfigured_False_WhenOnlyTokenIsSet()
    {
        var settings = new InMemorySettingsStore();
        settings.SetString(ConfigParseCredentialProvider.TokenSettingsKey, "a-token");

        Assert.False(new ConfigParseCredentialProvider(settings).IsConfigured);
    }

    [Fact]
    public void IsConfigured_False_WhenBaseUrlIsNotAValidAbsoluteUri()
    {
        var settings = new InMemorySettingsStore();
        settings.SetString(ConfigParseCredentialProvider.BaseUrlSettingsKey, "not a url");
        settings.SetString(ConfigParseCredentialProvider.TokenSettingsKey, "a-token");

        Assert.False(new ConfigParseCredentialProvider(settings).IsConfigured);
    }

    [Fact]
    public void IsConfigured_True_WhenBothAreSetValidly()
    {
        var settings = new InMemorySettingsStore();
        settings.SetString(ConfigParseCredentialProvider.BaseUrlSettingsKey, "https://example.supabase.co");
        settings.SetString(ConfigParseCredentialProvider.TokenSettingsKey, "a-token");

        Assert.True(new ConfigParseCredentialProvider(settings).IsConfigured);
    }

    [Fact]
    public async Task GetBaseUrlAsync_Throws_WhenUnconfigured()
    {
        var provider = new ConfigParseCredentialProvider(new InMemorySettingsStore());

        await Assert.ThrowsAsync<ParseCredentialNotConfiguredException>(() => provider.GetBaseUrlAsync());
    }

    [Fact]
    public async Task GetBaseUrlAsync_ReturnsTheConfiguredUri()
    {
        var settings = new InMemorySettingsStore();
        settings.SetString(ConfigParseCredentialProvider.BaseUrlSettingsKey, "https://example.supabase.co");
        var provider = new ConfigParseCredentialProvider(settings);

        var uri = await provider.GetBaseUrlAsync();

        Assert.Equal("https://example.supabase.co", uri.ToString().TrimEnd('/'));
    }

    [Fact]
    public async Task GetAuthHeaderAsync_ReturnsNull_WhenTokenAbsent()
    {
        var provider = new ConfigParseCredentialProvider(new InMemorySettingsStore());

        var header = await provider.GetAuthHeaderAsync();

        Assert.Null(header);
    }

    [Fact]
    public async Task GetAuthHeaderAsync_ReturnsPaidJws_WhenTokenPresent()
    {
        var settings = new InMemorySettingsStore();
        settings.SetString(ConfigParseCredentialProvider.TokenSettingsKey, "a-token");
        var provider = new ConfigParseCredentialProvider(settings);

        var header = await provider.GetAuthHeaderAsync();

        var paidJws = Assert.IsType<ParseAuthHeader.PaidJws>(header);
        Assert.Equal("a-token", paidJws.Jws);
    }

    // MARK: - Silent fallback acceptance criterion (end-to-end through IntentRouter)

    [Fact]
    public async Task Router_FallsBackSilentlyToHeuristic_WhenCloudSelectedButUnconfigured_NoNetworkAttempt()
    {
        var settings = new InMemorySettingsStore();
        ParseEnginePreferenceStore.Set(settings, ParseEnginePreference.Cloud); // user picked Cloud...
        // ...but never configured a proxy URL/token -> ConfigParseCredentialProvider.IsConfigured
        // is false. CloudParser must never even attempt a request (GetBaseUrlAsync throws before
        // any HttpClient.SendAsync call happens), so the RecordingHttpMessageHandler below must see
        // zero requests.
        var handler = new RecordingHttpMessageHandler();
        var cloud = new CloudParser(new ConfigParseCredentialProvider(settings), new HttpClient(handler));
        var gate = new DefaultCloudParseGate(settings, isNetworkAvailable: () => true);
        var heuristic = new FakeIntentParser
        {
            ParseResult = new[] { new Volar.Domain.ParsedTask("fallback title", "utterance") },
        };
        var router = new IntentRouter(heuristic, cloud: cloud, cloudGate: gate);

        var tasks = await router.ParseAsync("nói gì đó", DateTimeOffset.UtcNow, Array.Empty<string>());

        Assert.Equal(0, handler.CallCount);
        Assert.Equal(IntentRouter.Route.Heuristic, router.LastRoute);
        Assert.Single(tasks);
        Assert.Equal("fallback title", tasks[0].Title);
    }

    [Fact]
    public async Task Router_AttemptsCloud_WhenConfigured_AndOptedIn()
    {
        var settings = new InMemorySettingsStore();
        settings.SetString(ConfigParseCredentialProvider.BaseUrlSettingsKey, "https://example.supabase.co");
        settings.SetString(ConfigParseCredentialProvider.TokenSettingsKey, "a-token");
        ParseEnginePreferenceStore.Set(settings, ParseEnginePreference.Cloud);

        var handler = new RecordingHttpMessageHandler
        {
            ResponseFactory = _ => new HttpResponseMessage(System.Net.HttpStatusCode.OK)
            {
                Content = new StringContent("[]"),
            },
        };
        var cloud = new CloudParser(new ConfigParseCredentialProvider(settings), new HttpClient(handler));
        var gate = new DefaultCloudParseGate(settings, isNetworkAvailable: () => true);
        var heuristic = new FakeIntentParser
        {
            ParseResult = new[] { new Volar.Domain.ParsedTask("heuristic fallback", "utterance") },
        };
        var router = new IntentRouter(heuristic, cloud: cloud, cloudGate: gate);

        await router.ParseAsync("nói gì đó", DateTimeOffset.UtcNow, Array.Empty<string>());

        Assert.Equal(1, handler.CallCount); // configured + opted-in -> Cloud IS attempted this time
    }

    [Fact]
    public async Task Router_DoesNotAttemptCloud_WhenNotOptedIn_EvenIfConfigured()
    {
        var settings = new InMemorySettingsStore();
        settings.SetString(ConfigParseCredentialProvider.BaseUrlSettingsKey, "https://example.supabase.co");
        settings.SetString(ConfigParseCredentialProvider.TokenSettingsKey, "a-token");
        // Deliberately NOT calling ParseEnginePreferenceStore.Set(...) -> consent absent -> gate closed.

        var handler = new RecordingHttpMessageHandler();
        var cloud = new CloudParser(new ConfigParseCredentialProvider(settings), new HttpClient(handler));
        var gate = new DefaultCloudParseGate(settings, isNetworkAvailable: () => true);
        var heuristic = new FakeIntentParser
        {
            ParseResult = new[] { new Volar.Domain.ParsedTask("fallback title", "utterance") },
        };
        var router = new IntentRouter(heuristic, cloud: cloud, cloudGate: gate);

        await router.ParseAsync("nói gì đó", DateTimeOffset.UtcNow, Array.Empty<string>());

        Assert.Equal(0, handler.CallCount);
    }
}
