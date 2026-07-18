using Volar.Speech.Groq;
using Xunit;

namespace Volar.Speech.Tests;

public class GroqCredentialProviderTests
{
    [Fact]
    public async Task GetBaseUrlAsync_UsesConfiguredUrl_WhenPresent()
    {
        var provider = new EnvironmentGroqCredentialProvider(name => name switch
        {
            "GROQ_BASE_URL" => "https://proxy.example.com/v1",
            _ => null,
        });

        var url = await provider.GetBaseUrlAsync();

        Assert.Equal("https://proxy.example.com/v1", url.ToString());
    }

    [Fact]
    public async Task GetBaseUrlAsync_FallsBackToGroqDirect_WhenAbsent()
    {
        var provider = new EnvironmentGroqCredentialProvider(_ => null);

        var url = await provider.GetBaseUrlAsync();

        Assert.Equal(EnvironmentGroqCredentialProvider.GroqDirectBaseUrl, url);
    }

    [Fact]
    public async Task GetBaseUrlAsync_FallsBackToGroqDirect_WhenConfiguredValueIsNotAValidUrl()
    {
        var provider = new EnvironmentGroqCredentialProvider(name => name == "GROQ_BASE_URL" ? "not a url" : null);

        var url = await provider.GetBaseUrlAsync();

        Assert.Equal(EnvironmentGroqCredentialProvider.GroqDirectBaseUrl, url);
    }

    [Fact]
    public async Task GetAuthorizationAsync_PrefersProxyToken_OverApiKey()
    {
        var provider = new EnvironmentGroqCredentialProvider(name => name switch
        {
            "GROQ_PROXY_TOKEN" => "proxy-token",
            "GROQ_API_KEY" => "dev-key",
            _ => null,
        });

        var auth = await provider.GetAuthorizationAsync();

        Assert.Equal("Bearer proxy-token", auth);
    }

    [Fact]
    public async Task GetAuthorizationAsync_FallsBackToApiKey_WhenProxyTokenAbsent()
    {
        var provider = new EnvironmentGroqCredentialProvider(name => name == "GROQ_API_KEY" ? "dev-key" : null);

        var auth = await provider.GetAuthorizationAsync();

        Assert.Equal("Bearer dev-key", auth);
    }

    [Fact]
    public async Task GetAuthorizationAsync_ThrowsMissingCredentials_WhenBothAbsent()
    {
        var provider = new EnvironmentGroqCredentialProvider(_ => null);

        var ex = await Assert.ThrowsAsync<GroqTranscriptionException>(() => provider.GetAuthorizationAsync());

        Assert.Equal(GroqTranscriptionErrorKind.MissingCredentials, ex.Kind);
    }

    // SECURITY regression guard: this default provider must NEVER contain a literal Groq API key
    // fallback — every credential must come from the injected environment reader. If someone
    // "helpfully" hardcodes a key later, this test fails loudly.
    [Fact]
    public async Task GetAuthorizationAsync_NeverReturnsACredential_WhenEnvironmentReaderReturnsNullForEverything()
    {
        var callCount = 0;
        var provider = new EnvironmentGroqCredentialProvider(_ => { callCount++; return null; });

        await Assert.ThrowsAsync<GroqTranscriptionException>(() => provider.GetAuthorizationAsync());

        Assert.True(callCount > 0, "the provider must actually consult the injected reader, not a hardcoded fallback");
    }
}
