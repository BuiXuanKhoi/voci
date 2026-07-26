// Services/Account/AccountServiceTests.cs — account-auth contract
// (specs/002-workflow-command-center/contracts/account-auth.md, 2026-07-26). Every HTTP call is
// mocked via RoutingHttpMessageHandler below — NEVER hits the real network. Covers: token refresh
// serialisation (concurrent callers -> one refresh), expiry handling, signed-out silently falling
// back to on-device (via GetValidAccessTokenAsync returning null), and 400/401 refresh-rejection
// clearing the session without a retry loop.
using System.Net;
using System.Text;
using System.Threading;
using Volar.App.Services.Account;
using Volar.App.Tests.State;
using Xunit;

namespace Volar.App.Tests.Services.Account;

public class AccountServiceTests
{
    private static readonly DateTimeOffset Now = new(2026, 7, 26, 9, 0, 0, TimeSpan.Zero);

    private sealed class FakeTokenStore : ITokenStore
    {
        public StoredSession? Stored;
        public int SaveCount;
        public int ClearCount;

        public StoredSession? Load() => Stored;

        public void Save(StoredSession session)
        {
            Stored = session;
            SaveCount++;
        }

        public void Clear()
        {
            Stored = null;
            ClearCount++;
        }
    }

    private sealed class RoutingHttpMessageHandler : HttpMessageHandler
    {
        public Func<HttpRequestMessage, Task<HttpResponseMessage>> Responder { get; set; } =
            _ => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK));

        private int _callCount;
        public int CallCount => _callCount;

        public List<HttpRequestMessage> Requests { get; } = new();

        /// <summary>Captured HERE (not read later from <see cref="Requests"/>) because the caller
        /// (<c>AccountService</c>) disposes each request — including its <c>Content</c> — via its own
        /// <c>using</c> as soon as the call returns, so reading the body after the fact would throw
        /// <see cref="ObjectDisposedException"/>.</summary>
        public List<string?> RequestBodies { get; } = new();

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Interlocked.Increment(ref _callCount);
            var body = request.Content is null ? null : await request.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
            lock (Requests)
            {
                Requests.Add(request);
                RequestBodies.Add(body);
            }
            return await Responder(request).ConfigureAwait(false);
        }
    }

    private static HttpResponseMessage Json(HttpStatusCode status, string body) => new(status)
    {
        Content = new StringContent(body, Encoding.UTF8, "application/json"),
    };

    /// <summary>Builds a GoTrue session response body via plain concatenation rather than an
    /// interpolated raw string literal — the wire shape's own consecutive closing braces
    /// (`"user":{...}}`) collide with `$$"""..."""`'s brace-counting rules (CS9007), so this sidesteps
    /// that entirely instead of fighting escaping.</summary>
    private static string SessionJson(string accessToken, string refreshToken, long expiresAtSeconds, string userId, string email) =>
        "{\"access_token\":\"" + accessToken + "\",\"refresh_token\":\"" + refreshToken + "\",\"expires_at\":" + expiresAtSeconds +
        ",\"user\":{\"id\":\"" + userId + "\",\"email\":\"" + email + "\"}}";

    private static AccountService NewService(RoutingHttpMessageHandler handler, FixedTimeProvider clock, FakeTokenStore? store = null) =>
        new(new HttpClient(handler), clock, store ?? new FakeTokenStore());

    // ============================================================================================
    // MARK: - Construction / initial state
    // ============================================================================================

    [Fact]
    public void Constructor_NoStoredSession_StartsSignedOut()
    {
        var service = NewService(new RoutingHttpMessageHandler(), new FixedTimeProvider(Now));

        Assert.Equal(AccountSessionState.SignedOut, service.State);
        Assert.Null(service.CurrentUser);
    }

    [Fact]
    public void Constructor_StoredSession_StartsSignedIn()
    {
        var store = new FakeTokenStore { Stored = new StoredSession("t", "r", Now.AddHours(1), "u1", "e@x.com") };

        var service = NewService(new RoutingHttpMessageHandler(), new FixedTimeProvider(Now), store);

        Assert.Equal(AccountSessionState.SignedIn, service.State);
        Assert.Equal("e@x.com", service.CurrentUser?.Email);
    }

    // ============================================================================================
    // MARK: - Sign-in: SendOtpAsync / VerifyOtpAsync
    // ============================================================================================

    [Fact]
    public async Task SendOtpAsync_InvalidEmail_ReturnsInvalidEmail_NeverCallsNetwork()
    {
        var handler = new RoutingHttpMessageHandler();
        var service = NewService(handler, new FixedTimeProvider(Now));

        var result = await service.SendOtpAsync("not-an-email");

        Assert.Equal(OtpSendOutcome.InvalidEmail, result.Outcome);
        Assert.Equal(0, handler.CallCount);
    }

    [Fact]
    public async Task SendOtpAsync_Success_SendsApiKeyHeader_AndCreateUserTrue_NoAuthorizationHeader()
    {
        var handler = new RoutingHttpMessageHandler { Responder = _ => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)) };
        var service = NewService(handler, new FixedTimeProvider(Now));

        var result = await service.SendOtpAsync("me@example.com");

        Assert.Equal(OtpSendOutcome.Sent, result.Outcome);
        Assert.Equal(1, handler.CallCount);
        var request = Assert.Single(handler.Requests);
        Assert.True(request.Headers.TryGetValues("apikey", out var apiKeyValues));
        Assert.Equal(AccountService.DefaultApiKey, apiKeyValues!.Single());
        Assert.Null(request.Headers.Authorization); // OTP send never carries a bearer — no session yet.
        var body = Assert.Single(handler.RequestBodies);
        Assert.Contains("\"email\":\"me@example.com\"", body);
        Assert.Contains("\"create_user\":true", body);
    }

    [Fact]
    public async Task SendOtpAsync_ServerRejects_ReturnsServerError()
    {
        var handler = new RoutingHttpMessageHandler { Responder = _ => Task.FromResult(new HttpResponseMessage(HttpStatusCode.InternalServerError)) };
        var service = NewService(handler, new FixedTimeProvider(Now));

        var result = await service.SendOtpAsync("me@example.com");

        Assert.Equal(OtpSendOutcome.ServerError, result.Outcome);
    }

    [Fact]
    public async Task VerifyOtpAsync_Success_PersistsSessionAndSignsIn()
    {
        var clock = new FixedTimeProvider(Now);
        var expiresAtSeconds = Now.AddHours(1).ToUnixTimeSeconds();
        var handler = new RoutingHttpMessageHandler
        {
            Responder = _ => Task.FromResult(Json(HttpStatusCode.OK,
                SessionJson("acc", "ref", expiresAtSeconds, "u1", "me@example.com"))),
        };
        var store = new FakeTokenStore();
        var service = NewService(handler, clock, store);
        var changedCount = 0;
        service.Changed += () => changedCount++;

        var result = await service.VerifyOtpAsync("me@example.com", "123456");

        Assert.Equal(VerifyOtpOutcome.SignedIn, result.Outcome);
        Assert.Equal(AccountSessionState.SignedIn, service.State);
        Assert.Equal("me@example.com", service.CurrentUser?.Email);
        Assert.Equal(1, store.SaveCount);
        Assert.True(changedCount >= 1);
    }

    [Fact]
    public async Task VerifyOtpAsync_InvalidCode_ReturnsInvalidCode_StaysSignedOut()
    {
        var handler = new RoutingHttpMessageHandler { Responder = _ => Task.FromResult(new HttpResponseMessage(HttpStatusCode.Unauthorized)) };
        var service = NewService(handler, new FixedTimeProvider(Now));

        var result = await service.VerifyOtpAsync("me@example.com", "000000");

        Assert.Equal(VerifyOtpOutcome.InvalidCode, result.Outcome);
        Assert.Equal(AccountSessionState.SignedOut, service.State);
    }

    // ============================================================================================
    // MARK: - GetValidAccessTokenAsync: signed-out fallback, expiry, refresh
    // ============================================================================================

    [Fact]
    public async Task GetValidAccessTokenAsync_SignedOut_ReturnsNull_NeverCallsNetwork()
    {
        var handler = new RoutingHttpMessageHandler();
        var service = NewService(handler, new FixedTimeProvider(Now));

        var token = await service.GetValidAccessTokenAsync();

        Assert.Null(token);
        Assert.Equal(0, handler.CallCount);
    }

    [Fact]
    public async Task GetValidAccessTokenAsync_TokenStillFresh_ReturnsWithoutRefreshing()
    {
        var clock = new FixedTimeProvider(Now);
        var store = new FakeTokenStore { Stored = new StoredSession("fresh-token", "r1", Now.AddMinutes(10), "u1", "a@b.com") };
        var handler = new RoutingHttpMessageHandler();
        var service = NewService(handler, clock, store);

        var token = await service.GetValidAccessTokenAsync();

        Assert.Equal("fresh-token", token);
        Assert.Equal(0, handler.CallCount);
    }

    [Fact]
    public async Task GetValidAccessTokenAsync_TokenWithinExpiryWindow_RefreshesAndReturnsNewToken()
    {
        var clock = new FixedTimeProvider(Now);
        var store = new FakeTokenStore { Stored = new StoredSession("old", "r1", Now.AddSeconds(30), "u1", "a@b.com") };
        var expiresAtSeconds = Now.AddHours(1).ToUnixTimeSeconds();
        var handler = new RoutingHttpMessageHandler
        {
            Responder = _ => Task.FromResult(Json(HttpStatusCode.OK,
                SessionJson("new", "r2", expiresAtSeconds, "u1", "a@b.com"))),
        };
        var service = NewService(handler, clock, store);

        var token = await service.GetValidAccessTokenAsync();

        Assert.Equal("new", token);
        Assert.Equal(1, handler.CallCount);
        Assert.Equal(1, store.SaveCount);
        Assert.Equal("new", store.Stored?.AccessToken);
    }

    [Fact]
    public async Task GetValidAccessTokenAsync_AlreadyExpired_RefreshesToo()
    {
        var clock = new FixedTimeProvider(Now);
        var store = new FakeTokenStore { Stored = new StoredSession("old", "r1", Now.AddSeconds(-5), "u1", "a@b.com") };
        var expiresAtSeconds = Now.AddHours(1).ToUnixTimeSeconds();
        var handler = new RoutingHttpMessageHandler
        {
            Responder = _ => Task.FromResult(Json(HttpStatusCode.OK,
                SessionJson("new", "r2", expiresAtSeconds, "u1", "a@b.com"))),
        };
        var service = NewService(handler, clock, store);

        var token = await service.GetValidAccessTokenAsync();

        Assert.Equal("new", token);
        Assert.Equal(1, handler.CallCount);
    }

    [Theory]
    [InlineData(HttpStatusCode.BadRequest)]
    [InlineData(HttpStatusCode.Unauthorized)]
    public async Task GetValidAccessTokenAsync_RefreshRejected_ClearsSession_AndNeverRetriesAutomatically(HttpStatusCode rejectionStatus)
    {
        var clock = new FixedTimeProvider(Now);
        var store = new FakeTokenStore { Stored = new StoredSession("old", "r1", Now.AddSeconds(10), "u1", "a@b.com") };
        var handler = new RoutingHttpMessageHandler { Responder = _ => Task.FromResult(new HttpResponseMessage(rejectionStatus)) };
        var service = NewService(handler, clock, store);

        var token = await service.GetValidAccessTokenAsync();

        Assert.Null(token);
        Assert.Equal(AccountSessionState.SignedOut, service.State);
        Assert.Equal(1, store.ClearCount);
        Assert.Equal(1, handler.CallCount);

        // Calling again must NOT attempt the network a second time — already signed out, so
        // GetValidAccessTokenAsync short-circuits before ever reaching the refresh path (never
        // retried in a loop).
        var token2 = await service.GetValidAccessTokenAsync();
        Assert.Null(token2);
        Assert.Equal(1, handler.CallCount);
    }

    [Fact]
    public async Task GetValidAccessTokenAsync_RefreshTransportFailure_KeepsSessionSignedIn_ReturnsNullThisCallOnly()
    {
        var clock = new FixedTimeProvider(Now);
        var store = new FakeTokenStore { Stored = new StoredSession("old", "r1", Now.AddSeconds(10), "u1", "a@b.com") };
        var handler = new RoutingHttpMessageHandler { Responder = _ => throw new HttpRequestException("offline") };
        var service = NewService(handler, clock, store);

        var token = await service.GetValidAccessTokenAsync();

        Assert.Null(token);
        // A transient/offline failure is NOT a rejection — must not sign the user out.
        Assert.Equal(AccountSessionState.SignedIn, service.State);
        Assert.Equal(0, store.ClearCount);
    }

    [Fact]
    public async Task GetValidAccessTokenAsync_ConcurrentCallers_CollapseToExactlyOneRefreshCall()
    {
        var clock = new FixedTimeProvider(Now);
        var store = new FakeTokenStore { Stored = new StoredSession("old-token", "refresh-1", Now.AddSeconds(30), "user-1", "a@b.com") };
        var release = new TaskCompletionSource();
        var expiresAtSeconds = Now.AddHours(1).ToUnixTimeSeconds();
        var handler = new RoutingHttpMessageHandler
        {
            Responder = async _ =>
            {
                // Block until the test has fired every concurrent caller, so they genuinely overlap
                // rather than racing to complete one at a time.
                await release.Task.ConfigureAwait(false);
                return Json(HttpStatusCode.OK,
                    SessionJson("new-token", "refresh-2", expiresAtSeconds, "user-1", "a@b.com"));
            },
        };
        var service = NewService(handler, clock, store);

        var t1 = service.GetValidAccessTokenAsync();
        var t2 = service.GetValidAccessTokenAsync();
        var t3 = service.GetValidAccessTokenAsync();

        // Give all three callers a chance to actually enter GetOrStartRefresh before unblocking the
        // (single) in-flight HTTP call.
        await Task.Delay(50);
        release.SetResult();

        var results = await Task.WhenAll(t1, t2, t3).WaitAsync(TimeSpan.FromSeconds(10));

        Assert.Equal(1, handler.CallCount);
        Assert.All(results, r => Assert.Equal("new-token", r));
    }

    // ============================================================================================
    // MARK: - Sign-out
    // ============================================================================================

    [Fact]
    public async Task SignOutAsync_ClearsSession_EvenWhenTheServerCallFails()
    {
        var clock = new FixedTimeProvider(Now);
        var store = new FakeTokenStore { Stored = new StoredSession("token", "r1", Now.AddHours(1), "u1", "a@b.com") };
        var handler = new RoutingHttpMessageHandler { Responder = _ => throw new HttpRequestException("offline") };
        var service = NewService(handler, clock, store);

        await service.SignOutAsync();

        Assert.Equal(AccountSessionState.SignedOut, service.State);
        Assert.Equal(1, store.ClearCount);
    }

    [Fact]
    public async Task SignOutAsync_NotSignedIn_NeverCallsNetwork()
    {
        var handler = new RoutingHttpMessageHandler();
        var service = NewService(handler, new FixedTimeProvider(Now));

        await service.SignOutAsync();

        Assert.Equal(0, handler.CallCount);
    }

    // ============================================================================================
    // MARK: - Delete account
    // ============================================================================================

    [Fact]
    public async Task DeleteAccountAsync_NotSignedIn_ReturnsNotSignedIn_NeverCallsNetwork()
    {
        var handler = new RoutingHttpMessageHandler();
        var service = NewService(handler, new FixedTimeProvider(Now));

        var result = await service.DeleteAccountAsync();

        Assert.Equal(DeleteAccountOutcome.NotSignedIn, result.Outcome);
        Assert.Equal(0, handler.CallCount);
    }

    [Fact]
    public async Task DeleteAccountAsync_Success_ClearsSession()
    {
        var clock = new FixedTimeProvider(Now);
        var store = new FakeTokenStore { Stored = new StoredSession("token", "r1", Now.AddHours(1), "u1", "a@b.com") };
        var handler = new RoutingHttpMessageHandler { Responder = _ => Task.FromResult(Json(HttpStatusCode.OK, """{"deleted":true}""")) };
        var service = NewService(handler, clock, store);

        var result = await service.DeleteAccountAsync();

        Assert.Equal(DeleteAccountOutcome.Deleted, result.Outcome);
        Assert.Equal(AccountSessionState.SignedOut, service.State);
        Assert.Equal(1, store.ClearCount);

        // Edge-function auth per contract §3: bearer only, no `apikey` header.
        var request = Assert.Single(handler.Requests);
        Assert.Equal("token", request.Headers.Authorization?.Parameter);
        Assert.False(request.Headers.Contains("apikey"));
    }

    // ============================================================================================
    // MARK: - Subscription status
    // ============================================================================================

    [Fact]
    public async Task RefreshStatusAsync_Success_UpdatesCachedStatus_AndFiresChanged()
    {
        var clock = new FixedTimeProvider(Now);
        var store = new FakeTokenStore { Stored = new StoredSession("token", "r1", Now.AddHours(1), "u1", "a@b.com") };
        var handler = new RoutingHttpMessageHandler
        {
            Responder = _ => Task.FromResult(Json(HttpStatusCode.OK,
                """{"tier":"pro","expiresAt":"2027-01-01T00:00:00Z","parseUsedToday":3,"parseLimit":500,"speechUsedToday":1,"speechLimit":500}""")),
        };
        var service = NewService(handler, clock, store);
        var changedCount = 0;
        service.Changed += () => changedCount++;

        var status = await service.RefreshStatusAsync();

        Assert.NotNull(status);
        Assert.Equal("pro", status!.Tier);
        Assert.True(status.IsPro);
        Assert.Equal(3, status.ParseUsedToday);
        Assert.Equal(500, status.ParseLimit);
        Assert.Equal(1, status.SpeechUsedToday);
        Assert.Equal(status, service.CachedStatus);
        Assert.True(changedCount >= 1);
    }

    [Fact]
    public async Task RefreshStatusAsync_SignedOut_ReturnsNull_NeverCallsNetwork()
    {
        var handler = new RoutingHttpMessageHandler();
        var service = NewService(handler, new FixedTimeProvider(Now));

        var status = await service.RefreshStatusAsync();

        Assert.Null(status);
        Assert.Equal(0, handler.CallCount);
    }

    [Fact]
    public async Task RefreshStatusAsync_ServerFailure_KeepsPreviousCachedStatus()
    {
        var clock = new FixedTimeProvider(Now);
        var store = new FakeTokenStore { Stored = new StoredSession("token", "r1", Now.AddHours(1), "u1", "a@b.com") };
        var succeedNext = true;
        var handler = new RoutingHttpMessageHandler
        {
            Responder = _ => Task.FromResult(succeedNext
                ? Json(HttpStatusCode.OK, """{"tier":"free","expiresAt":null,"parseUsedToday":1,"parseLimit":20,"speechUsedToday":0,"speechLimit":0}""")
                : new HttpResponseMessage(HttpStatusCode.InternalServerError)),
        };
        var service = NewService(handler, clock, store);
        var first = await service.RefreshStatusAsync();
        Assert.NotNull(first);

        succeedNext = false;
        var second = await service.RefreshStatusAsync();

        Assert.Null(second);
        Assert.Equal(first, service.CachedStatus); // a transient failure must not wipe the last-known-good snapshot.
    }

    [Fact]
    public void RefreshStatusIfStale_SignedOut_NeverCallsNetwork()
    {
        var handler = new RoutingHttpMessageHandler();
        var service = NewService(handler, new FixedTimeProvider(Now));

        service.RefreshStatusIfStale();

        Assert.Equal(0, handler.CallCount);
    }

    [Fact]
    public async Task RefreshStatusIfStale_NoCachedStatusYet_TriggersBackgroundRefresh()
    {
        var clock = new FixedTimeProvider(Now);
        var store = new FakeTokenStore { Stored = new StoredSession("token", "r1", Now.AddHours(1), "u1", "a@b.com") };
        var called = new TaskCompletionSource();
        var handler = new RoutingHttpMessageHandler
        {
            Responder = _ =>
            {
                called.TrySetResult();
                return Task.FromResult(Json(HttpStatusCode.OK, """{"tier":"free","expiresAt":null,"parseUsedToday":0,"parseLimit":20,"speechUsedToday":0,"speechLimit":0}"""));
            },
        };
        var service = NewService(handler, clock, store);

        service.RefreshStatusIfStale();

        await called.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.True(handler.CallCount >= 1);
    }

    [Fact]
    public async Task RefreshStatusIfStale_RecentlyFetched_SkipsRefreshing()
    {
        var clock = new FixedTimeProvider(Now);
        var store = new FakeTokenStore { Stored = new StoredSession("token", "r1", Now.AddHours(1), "u1", "a@b.com") };
        var handler = new RoutingHttpMessageHandler
        {
            Responder = _ => Task.FromResult(Json(HttpStatusCode.OK, """{"tier":"free","expiresAt":null,"parseUsedToday":0,"parseLimit":20,"speechUsedToday":0,"speechLimit":0}""")),
        };
        var service = NewService(handler, clock, store);
        await service.RefreshStatusAsync();
        Assert.Equal(1, handler.CallCount);

        service.RefreshStatusIfStale(TimeSpan.FromMinutes(5));
        await Task.Delay(50); // give a wrongly-started fire-and-forget task a chance to run

        Assert.Equal(1, handler.CallCount);
    }

    [Fact]
    public async Task RefreshStatusIfStale_ForceViaZeroMaxAge_AlwaysRefreshes()
    {
        var clock = new FixedTimeProvider(Now);
        var store = new FakeTokenStore { Stored = new StoredSession("token", "r1", Now.AddHours(1), "u1", "a@b.com") };
        var handler = new RoutingHttpMessageHandler
        {
            Responder = _ => Task.FromResult(Json(HttpStatusCode.OK, """{"tier":"free","expiresAt":null,"parseUsedToday":0,"parseLimit":20,"speechUsedToday":0,"speechLimit":0}""")),
        };
        var service = NewService(handler, clock, store);
        await service.RefreshStatusAsync();
        Assert.Equal(1, handler.CallCount);

        service.RefreshStatusIfStale(TimeSpan.Zero);
        await Task.Delay(200); // let the fire-and-forget refresh actually run

        Assert.Equal(2, handler.CallCount);
    }
}
