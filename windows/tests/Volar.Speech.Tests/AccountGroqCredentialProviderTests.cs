// AccountGroqCredentialProviderTests.cs — account-auth contract (2026-07-26): Groq cloud speech is
// Pro-only. Volar.Speech carries zero project references (see AccountGroqCredentialProvider's own
// header comment), so it is wired via plain delegates — these tests supply simple lambdas rather
// than a real Volar.App.Services.Account.AccountService.
using Volar.Speech.Groq;
using Xunit;

namespace Volar.Speech.Tests;

public class AccountGroqCredentialProviderTests
{
    [Fact]
    public async Task GetBaseUrlAsync_ReturnsTheFixedGroqProxyUrl_WithTrailingSlash()
    {
        var provider = new AccountGroqCredentialProvider(_ => Task.FromResult<string?>(null), () => false);

        var url = await provider.GetBaseUrlAsync();

        Assert.Equal(AccountGroqCredentialProvider.ProxyBaseUrl, url);
        Assert.EndsWith("/", url.ToString(), StringComparison.Ordinal);
    }

    [Fact]
    public async Task GetBaseUrlAsync_UsesInjectedOverride_WhenSupplied()
    {
        var overrideUrl = new Uri("https://example.test/functions/v1/groq/");
        var provider = new AccountGroqCredentialProvider(_ => Task.FromResult<string?>(null), () => false, overrideUrl);

        var url = await provider.GetBaseUrlAsync();

        Assert.Equal(overrideUrl, url);
    }

    [Fact]
    public void IsConfigured_False_WhenGateReturnsFalse()
    {
        // e.g. free tier, or no cached status yet, or speech quota exhausted — this class never
        // decides that itself; it just forwards whatever the injected gate says.
        var provider = new AccountGroqCredentialProvider(_ => Task.FromResult<string?>("token"), () => false);

        Assert.False(provider.IsConfigured);
    }

    [Fact]
    public void IsConfigured_True_WhenGateReturnsTrue()
    {
        var provider = new AccountGroqCredentialProvider(_ => Task.FromResult<string?>("token"), () => true);

        Assert.True(provider.IsConfigured);
    }

    [Fact]
    public async Task GetAuthorizationAsync_ReturnsBearerToken_WhenTokenAvailable()
    {
        var provider = new AccountGroqCredentialProvider(_ => Task.FromResult<string?>("account-token"), () => true);

        var auth = await provider.GetAuthorizationAsync();

        Assert.Equal("Bearer account-token", auth);
    }

    [Fact]
    public async Task GetAuthorizationAsync_ThrowsMissingCredentials_WhenNoTokenAvailable()
    {
        // Signed out, or a refresh just failed/was rejected between the pre-record IsConfigured
        // check and upload time (a genuine race — see this class's own IsConfigured remarks).
        var provider = new AccountGroqCredentialProvider(_ => Task.FromResult<string?>(null), () => true);

        var ex = await Assert.ThrowsAsync<GroqTranscriptionException>(() => provider.GetAuthorizationAsync());

        Assert.Equal(GroqTranscriptionErrorKind.MissingCredentials, ex.Kind);
    }

    [Fact]
    public async Task GetAuthorizationAsync_ForwardsTheCancellationToken()
    {
        CancellationToken? observed = null;
        var provider = new AccountGroqCredentialProvider(
            ct => { observed = ct; return Task.FromResult<string?>("token"); },
            () => true);
        using var cts = new CancellationTokenSource();

        await provider.GetAuthorizationAsync(cts.Token);

        Assert.Equal(cts.Token, observed);
    }

    // SECURITY regression guard, same spirit as EnvironmentGroqCredentialProvider's own equivalent
    // test: never let a hardcoded fallback token slip in — the returned authorization must depend
    // entirely on the injected delegate.
    [Fact]
    public async Task GetAuthorizationAsync_NeverReturnsACredential_WhenDelegateReturnsNullForEverything()
    {
        var callCount = 0;
        var provider = new AccountGroqCredentialProvider(_ => { callCount++; return Task.FromResult<string?>(null); }, () => true);

        await Assert.ThrowsAsync<GroqTranscriptionException>(() => provider.GetAuthorizationAsync());

        Assert.True(callCount > 0, "the provider must actually consult the injected delegate, not a hardcoded fallback");
    }
}
