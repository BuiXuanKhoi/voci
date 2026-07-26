// ConfigParseCredentialProviderTests.cs — REWRITTEN 2026-07-26 for the account-auth contract
// (specs/002-workflow-command-center/contracts/account-auth.md): ConfigParseCredentialProvider no
// longer reads an ISettingsStore-backed proxy URL/token; it wraps two plain delegates
// (getValidAccessToken/isSignedIn) a caller supplies — in production, method-group conversions off
// the real Volar.App.Services.Account.AccountService (see CompositionRoot.cs), here plain lambdas
// over a tiny in-test fake session. Also covers the end-to-end "silent fallback" acceptance
// criterion: cloud selected + signed out must degrade IntentRouter to the heuristic tier with no
// exception and no network attempt.
using Xunit;

namespace Volar.Parsing.Tests;

public class ConfigParseCredentialProviderTests
{
    // MARK: - IsConfigured / GetAuthHeaderAsync

    [Fact]
    public void IsConfigured_False_WhenSignedOut()
    {
        var provider = new ConfigParseCredentialProvider(_ => Task.FromResult<string?>(null), () => false);

        Assert.False(provider.IsConfigured);
    }

    [Fact]
    public void IsConfigured_True_WhenSignedIn()
    {
        var provider = new ConfigParseCredentialProvider(_ => Task.FromResult<string?>("access-token"), () => true);

        Assert.True(provider.IsConfigured);
    }

    [Fact]
    public async Task GetBaseUrlAsync_ReturnsTheFixedSupabaseProjectUrl_ByDefault()
    {
        var provider = new ConfigParseCredentialProvider(_ => Task.FromResult<string?>(null), () => false);

        var uri = await provider.GetBaseUrlAsync();

        Assert.Equal(ConfigParseCredentialProvider.DefaultBaseUrl, uri);
    }

    [Fact]
    public async Task GetBaseUrlAsync_UsesInjectedOverride_WhenSupplied()
    {
        var overrideUrl = new Uri("https://example.supabase.co");
        var provider = new ConfigParseCredentialProvider(_ => Task.FromResult<string?>(null), () => false, overrideUrl);

        var uri = await provider.GetBaseUrlAsync();

        Assert.Equal(overrideUrl, uri);
    }

    [Fact]
    public async Task GetAuthHeaderAsync_ReturnsNull_WhenNoAccessTokenAvailable()
    {
        // Signed out, or a refresh attempt just failed/was rejected — either way, the delegate
        // returns null and this must never throw or fabricate a header.
        var provider = new ConfigParseCredentialProvider(_ => Task.FromResult<string?>(null), () => false);

        var header = await provider.GetAuthHeaderAsync();

        Assert.Null(header);
    }

    [Fact]
    public async Task GetAuthHeaderAsync_ReturnsPaidJws_WrappingTheAccessToken_WhenPresent()
    {
        var provider = new ConfigParseCredentialProvider(_ => Task.FromResult<string?>("account-access-token"), () => true);

        var header = await provider.GetAuthHeaderAsync();

        var paidJws = Assert.IsType<ParseAuthHeader.PaidJws>(header);
        Assert.Equal("account-access-token", paidJws.Jws);
    }

    [Fact]
    public async Task GetAuthHeaderAsync_ForwardsTheCancellationToken_ToTheDelegate()
    {
        CancellationToken? observed = null;
        var provider = new ConfigParseCredentialProvider(
            ct => { observed = ct; return Task.FromResult<string?>("token"); },
            () => true);
        using var cts = new CancellationTokenSource();

        await provider.GetAuthHeaderAsync(cts.Token);

        Assert.Equal(cts.Token, observed);
    }

    // MARK: - Silent fallback acceptance criterion (end-to-end through IntentRouter)

    [Fact]
    public async Task Router_FallsBackSilentlyToHeuristic_WhenCloudSelectedButSignedOut_NoNetworkAttempt()
    {
        var settings = new Volar.Domain.InMemorySettingsStore();
        ParseEnginePreferenceStore.Set(settings, ParseEnginePreference.Cloud); // user picked Cloud...
        // ...but is signed out -> ConfigParseCredentialProvider.GetAuthHeaderAsync returns null.
        // CloudParser must never even attempt a request, so the RecordingHttpMessageHandler below
        // must see zero requests.
        var handler = new RecordingHttpMessageHandler();
        var credentialProvider = new ConfigParseCredentialProvider(_ => Task.FromResult<string?>(null), () => false);
        var cloud = new CloudParser(credentialProvider, new HttpClient(handler));
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
    public async Task Router_AttemptsCloud_WhenSignedIn_AndOptedIn()
    {
        var settings = new Volar.Domain.InMemorySettingsStore();
        ParseEnginePreferenceStore.Set(settings, ParseEnginePreference.Cloud);

        var handler = new RecordingHttpMessageHandler
        {
            ResponseFactory = _ => new HttpResponseMessage(System.Net.HttpStatusCode.OK)
            {
                Content = new StringContent("[]"),
            },
        };
        var credentialProvider = new ConfigParseCredentialProvider(_ => Task.FromResult<string?>("token"), () => true);
        var cloud = new CloudParser(credentialProvider, new HttpClient(handler));
        var gate = new DefaultCloudParseGate(settings, isNetworkAvailable: () => true);
        var heuristic = new FakeIntentParser
        {
            ParseResult = new[] { new Volar.Domain.ParsedTask("heuristic fallback", "utterance") },
        };
        var router = new IntentRouter(heuristic, cloud: cloud, cloudGate: gate);

        await router.ParseAsync("nói gì đó", DateTimeOffset.UtcNow, Array.Empty<string>());

        Assert.Equal(1, handler.CallCount); // signed in + opted-in -> Cloud IS attempted this time
    }

    [Fact]
    public async Task Router_DoesNotAttemptCloud_WhenNotOptedIn_EvenIfSignedIn()
    {
        var settings = new Volar.Domain.InMemorySettingsStore();
        // Deliberately NOT calling ParseEnginePreferenceStore.Set(...) -> consent absent -> gate closed.

        var handler = new RecordingHttpMessageHandler();
        var credentialProvider = new ConfigParseCredentialProvider(_ => Task.FromResult<string?>("token"), () => true);
        var cloud = new CloudParser(credentialProvider, new HttpClient(handler));
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
