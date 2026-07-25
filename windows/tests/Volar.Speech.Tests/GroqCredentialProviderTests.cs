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

    // MARK: - IsConfigured (Wave 3-B, A3: Local<->Cloud switch, macOS commit f88d5e5)

    [Fact]
    public void IsConfigured_False_WhenNoSourceHasAToken()
    {
        var provider = new EnvironmentGroqCredentialProvider(_ => null);

        Assert.False(provider.IsConfigured);
    }

    [Fact]
    public void IsConfigured_True_WhenProxyTokenEnvVarIsSet()
    {
        var provider = new EnvironmentGroqCredentialProvider(name => name == "GROQ_PROXY_TOKEN" ? "proxy-token" : null);

        Assert.True(provider.IsConfigured);
    }

    [Fact]
    public void IsConfigured_True_WhenApiKeyEnvVarIsSet()
    {
        var provider = new EnvironmentGroqCredentialProvider(name => name == "GROQ_API_KEY" ? "dev-key" : null);

        Assert.True(provider.IsConfigured);
    }

    [Fact]
    public void IsConfigured_True_WhenOnlyTheSettingsFallbackKeyIsSet()
    {
        // "volar.groqToken" plays the role UserDefaults.standard.string(forKey: "volar.groqToken")
        // plays on macOS — reached here through the SAME injected reader a Wave 3-C composite
        // (settings-store-then-environment) would supply.
        var provider = new EnvironmentGroqCredentialProvider(name => name == "volar.groqToken" ? "from-settings" : null);

        Assert.True(provider.IsConfigured);
    }

    [Fact]
    public async Task IsConfigured_AndGetAuthorizationAsync_NeverDisagree()
    {
        foreach (var reader in new Func<string, string?>[]
                 {
                     _ => null,
                     name => name == "GROQ_PROXY_TOKEN" ? "a" : null,
                     name => name == "GROQ_API_KEY" ? "b" : null,
                     name => name == "volar.groqToken" ? "c" : null,
                 })
        {
            var provider = new EnvironmentGroqCredentialProvider(reader);

            if (provider.IsConfigured)
            {
                await provider.GetAuthorizationAsync(); // must not throw
            }
            else
            {
                await Assert.ThrowsAsync<GroqTranscriptionException>(() => provider.GetAuthorizationAsync());
            }
        }
    }

    [Fact]
    public async Task GetBaseUrlAsync_FallsBackToSettingsKey_WhenEnvVarAbsent()
    {
        var provider = new EnvironmentGroqCredentialProvider(name => name == "volar.groqBaseURL" ? "https://proxy.example.com/v1" : null);

        var url = await provider.GetBaseUrlAsync();

        Assert.Equal("https://proxy.example.com/v1", url.ToString());
    }

    [Fact]
    public async Task GetBaseUrlAsync_PrefersEnvVar_OverSettingsKey()
    {
        var provider = new EnvironmentGroqCredentialProvider(name => name switch
        {
            "GROQ_BASE_URL" => "https://env.example.com/v1",
            "volar.groqBaseURL" => "https://settings.example.com/v1",
            _ => null,
        });

        var url = await provider.GetBaseUrlAsync();

        Assert.Equal("https://env.example.com/v1", url.ToString());
    }
}
