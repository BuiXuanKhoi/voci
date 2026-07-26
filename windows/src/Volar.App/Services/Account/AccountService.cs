// Services/Account/AccountService.cs — implements IAccountService against Supabase Auth (GoTrue)
// directly + the `subscription/*` edge functions, per
// specs/002-workflow-command-center/contracts/account-auth.md (frozen 2026-07-26). Windows has no
// native Sign in with Apple — Email OTP (contract §2's `otp`/`verify` pair) is the ONLY sign-in path
// this port implements; see this feature's final report for the Apple-hidden-email limitation this
// implies.
using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace Volar.App.Services.Account;

public sealed class AccountService : IAccountService
{
    /// <summary>Contract §2: "Base https://nuzrpipwacravfgsiacv.supabase.co".</summary>
    public static readonly Uri DefaultBaseUrl = new("https://nuzrpipwacravfgsiacv.supabase.co");

    /// <summary>Contract §2: publishable "anon" key sent as the `apikey` header on every GoTrue
    /// call. Public by design (it is embedded in every Supabase client, including this repo's own
    /// already-checked-in supabase/ config) — never treated as a secret.</summary>
    public const string DefaultApiKey = "sb_publishable_pz2_mJTispHtuvcYWTpE6g_SDHmpRUI";

    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    private readonly HttpClient _http;
    private readonly Services.ITimeProvider _clock;
    private readonly ITokenStore _tokenStore;
    private readonly Uri _baseUrl;
    private readonly string _apiKey;

    private readonly object _gate = new();
    private StoredSession? _session;
    private SubscriptionStatusSnapshot? _status;
    private Task<string?>? _refreshTask;

    public event Action? Changed;

    public AccountService(
        HttpClient httpClient,
        Services.ITimeProvider clock,
        ITokenStore? tokenStore = null,
        Uri? baseUrl = null,
        string? apiKey = null)
    {
        _http = httpClient ?? throw new ArgumentNullException(nameof(httpClient));
        _clock = clock ?? throw new ArgumentNullException(nameof(clock));
        _tokenStore = tokenStore ?? new DpapiTokenStore();
        _baseUrl = baseUrl ?? DefaultBaseUrl;
        _apiKey = apiKey ?? DefaultApiKey;

        // Loaded once at construction, exactly like JsonFileSettingsStore's own "load once into
        // memory" convention. A corrupt/undecryptable store degrades to null (signed out) — never
        // throws out of this constructor.
        _session = SafeLoad(_tokenStore);
    }

    private static StoredSession? SafeLoad(ITokenStore store)
    {
        try
        {
            return store.Load();
        }
        catch
        {
            return null;
        }
    }

    // ============================================================================================
    // MARK: - Read surface
    // ============================================================================================

    public AccountSessionState State
    {
        get
        {
            lock (_gate)
            {
                return _session is null ? AccountSessionState.SignedOut : AccountSessionState.SignedIn;
            }
        }
    }

    public AccountUser? CurrentUser
    {
        get
        {
            lock (_gate)
            {
                return _session is null ? null : new AccountUser(_session.UserId, _session.Email);
            }
        }
    }

    public SubscriptionStatusSnapshot? CachedStatus
    {
        get
        {
            lock (_gate)
            {
                return _status;
            }
        }
    }

    // ============================================================================================
    // MARK: - Sign-in (Email OTP, contract §2)
    // ============================================================================================

    public async Task<OtpSendResult> SendOtpAsync(string email, CancellationToken cancellationToken = default)
    {
        var trimmed = (email ?? string.Empty).Trim();
        if (trimmed.Length == 0 || !trimmed.Contains('@'))
        {
            return new OtpSendResult(OtpSendOutcome.InvalidEmail, "Enter a valid email address.");
        }

        var body = JsonSerializer.Serialize(new { email = trimmed, create_user = true });
        using var request = BuildGoTrueRequest(HttpMethod.Post, "auth/v1/otp", body);

        HttpResponseMessage response;
        try
        {
            response = await SendWithTimeoutAsync(request, TimeSpan.FromSeconds(20), cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch
        {
            return new OtpSendResult(OtpSendOutcome.NetworkError, "Couldn't reach the server. Check your connection.");
        }

        using (response)
        {
            if (response.IsSuccessStatusCode)
            {
                return OtpSendResult.Ok();
            }
            if (response.StatusCode is HttpStatusCode.BadRequest or HttpStatusCode.UnprocessableEntity)
            {
                return new OtpSendResult(OtpSendOutcome.InvalidEmail, "That email address was rejected by the server.");
            }
            return new OtpSendResult(OtpSendOutcome.ServerError, "Something went wrong sending the code. Try again.");
        }
    }

    public async Task<VerifyOtpResult> VerifyOtpAsync(string email, string code, CancellationToken cancellationToken = default)
    {
        var trimmedEmail = (email ?? string.Empty).Trim();
        var trimmedCode = (code ?? string.Empty).Trim();
        if (trimmedEmail.Length == 0 || trimmedCode.Length == 0)
        {
            return new VerifyOtpResult(VerifyOtpOutcome.InvalidCode, "Enter the code we emailed you.");
        }

        var body = JsonSerializer.Serialize(new { email = trimmedEmail, token = trimmedCode, type = "email" });
        using var request = BuildGoTrueRequest(HttpMethod.Post, "auth/v1/verify", body);

        HttpResponseMessage response;
        try
        {
            response = await SendWithTimeoutAsync(request, TimeSpan.FromSeconds(20), cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch
        {
            return new VerifyOtpResult(VerifyOtpOutcome.NetworkError, "Couldn't reach the server. Check your connection.");
        }

        using (response)
        {
            if (!response.IsSuccessStatusCode)
            {
                var invalid = response.StatusCode is HttpStatusCode.BadRequest or HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden;
                return invalid
                    ? new VerifyOtpResult(VerifyOtpOutcome.InvalidCode, "That code is invalid or expired.")
                    : new VerifyOtpResult(VerifyOtpOutcome.ServerError, "Something went wrong verifying the code. Try again.");
            }

            GoTrueSessionWire? wire;
            try
            {
                var bytes = await response.Content.ReadAsByteArrayAsync(cancellationToken).ConfigureAwait(false);
                wire = JsonSerializer.Deserialize<GoTrueSessionWire>(bytes, JsonOptions);
            }
            catch (JsonException)
            {
                return new VerifyOtpResult(VerifyOtpOutcome.ServerError, "Unexpected response from the server.");
            }

            if (wire?.AccessToken is not { Length: > 0 } accessToken
                || wire.RefreshToken is not { Length: > 0 } refreshToken
                || wire.ExpiresAt is not { } expiresAtSeconds
                || wire.User?.Id is not { Length: > 0 } userId)
            {
                return new VerifyOtpResult(VerifyOtpOutcome.ServerError, "Unexpected response from the server.");
            }

            var session = new StoredSession(accessToken, refreshToken, DateTimeOffset.FromUnixTimeSeconds(expiresAtSeconds), userId, wire.User.Email);
            PersistSession(session);

            // Fire-and-forget: contract's tier/quota gate needs a fresh status moments after
            // sign-in (Task 2 — "Refresh on sign-in"). Never awaited: sign-in itself must complete
            // as soon as the session is persisted, regardless of how long subscription/status takes.
            _ = SafeRefreshStatusAsync();

            return new VerifyOtpResult(VerifyOtpOutcome.SignedIn);
        }
    }

    public async Task SignOutAsync(CancellationToken cancellationToken = default)
    {
        StoredSession? current;
        lock (_gate)
        {
            current = _session;
        }

        if (current is not null)
        {
            try
            {
                using var request = BuildGoTrueRequest(HttpMethod.Post, "auth/v1/logout", jsonBody: null, bearerToken: current.AccessToken);
                using var response = await SendWithTimeoutAsync(request, TimeSpan.FromSeconds(10), cancellationToken).ConfigureAwait(false);
                // Best-effort — whether or not GoTrue acknowledges the logout, the client still
                // forgets the session below. A revoked-but-not-yet-expired token left server-side
                // after a network failure here is an accepted, harmless residual (it just expires
                // naturally at ExpiresAt).
            }
            catch
            {
                // Sign-out must always succeed LOCALLY regardless of network state.
            }
        }

        ClearSession();
    }

    public async Task<DeleteAccountResult> DeleteAccountAsync(CancellationToken cancellationToken = default)
    {
        var token = await GetValidAccessTokenAsync(cancellationToken).ConfigureAwait(false);
        if (token is null)
        {
            return new DeleteAccountResult(DeleteAccountOutcome.NotSignedIn);
        }

        using var request = BuildEdgeFunctionRequest(HttpMethod.Post, "functions/v1/subscription/delete-account", token);

        HttpResponseMessage response;
        try
        {
            response = await SendWithTimeoutAsync(request, TimeSpan.FromSeconds(20), cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch
        {
            return new DeleteAccountResult(DeleteAccountOutcome.NetworkError, "Couldn't reach the server. Check your connection.");
        }

        using (response)
        {
            if (!response.IsSuccessStatusCode)
            {
                return new DeleteAccountResult(DeleteAccountOutcome.ServerError, "Something went wrong deleting your account. Try again.");
            }
        }

        ClearSession();
        return new DeleteAccountResult(DeleteAccountOutcome.Deleted);
    }

    // ============================================================================================
    // MARK: - Access token (refresh, serialised)
    // ============================================================================================

    public async Task<string?> GetValidAccessTokenAsync(CancellationToken cancellationToken = default)
    {
        StoredSession? current;
        lock (_gate)
        {
            current = _session;
        }
        if (current is null)
        {
            return null; // signed out — not an error, see this method's own interface doc comment.
        }

        if (current.ExpiresAt - _clock.Now > TimeSpan.FromSeconds(60))
        {
            return current.AccessToken;
        }

        var refreshTask = GetOrStartRefresh();
        return await refreshTask.WaitAsync(cancellationToken).ConfigureAwait(false);
    }

    /// <summary>
    /// Concurrency: guarantees exactly ONE in-flight <see cref="RefreshInternalAsync"/> task exists
    /// at a time — every concurrent caller within the same expiry window observes and awaits the
    /// SAME <see cref="Task{TResult}"/> instance (double-checked under <see cref="_gate"/>), so N
    /// simultaneous <see cref="GetValidAccessTokenAsync"/> callers cause exactly one HTTP refresh
    /// call. The shared task deliberately does NOT take any single caller's
    /// <see cref="CancellationToken"/> for the underlying network operation (it has its own fixed
    /// internal timeout) — one caller cancelling must never abort a refresh every OTHER concurrent
    /// caller is also waiting on; each caller instead races its own token against the shared task via
    /// <see cref="Task{TResult}.WaitAsync(CancellationToken)"/> in <see cref="GetValidAccessTokenAsync"/>.
    /// </summary>
    private Task<string?> GetOrStartRefresh()
    {
        lock (_gate)
        {
            _refreshTask ??= RefreshInternalAsync();
            return _refreshTask;
        }
    }

    private async Task<string?> RefreshInternalAsync()
    {
        try
        {
            StoredSession? current;
            lock (_gate)
            {
                current = _session;
            }
            if (current is null)
            {
                return null;
            }

            var body = JsonSerializer.Serialize(new { refresh_token = current.RefreshToken });
            using var request = BuildGoTrueRequest(HttpMethod.Post, "auth/v1/token?grant_type=refresh_token", body);

            HttpResponseMessage response;
            try
            {
                response = await SendWithTimeoutAsync(request, TimeSpan.FromSeconds(20), CancellationToken.None).ConfigureAwait(false);
            }
            catch
            {
                // Transient/offline failure — NEVER clear the stored session for this (the brief:
                // "never retry in a loop" applies to REJECTIONS, not transient network hiccups; a
                // laptop that's briefly offline must not be signed out). Just unavailable this call.
                return null;
            }

            using (response)
            {
                if (response.StatusCode is HttpStatusCode.BadRequest or HttpStatusCode.Unauthorized)
                {
                    // Refresh token itself is invalid/expired/revoked — this IS a rejection. Clear
                    // the session and go signed-out; the NEXT call to GetValidAccessTokenAsync will
                    // see State == SignedOut and return null immediately, no further network attempt
                    // (never retried in a loop).
                    ClearSession();
                    return null;
                }
                if (!response.IsSuccessStatusCode)
                {
                    return null; // other failure (5xx/etc.) — degrade silently, keep old session.
                }

                GoTrueSessionWire? wire;
                try
                {
                    var bytes = await response.Content.ReadAsByteArrayAsync().ConfigureAwait(false);
                    wire = JsonSerializer.Deserialize<GoTrueSessionWire>(bytes, JsonOptions);
                }
                catch (JsonException)
                {
                    return null;
                }

                if (wire?.AccessToken is not { Length: > 0 } accessToken
                    || wire.RefreshToken is not { Length: > 0 } refreshToken
                    || wire.ExpiresAt is not { } expiresAtSeconds)
                {
                    return null;
                }

                var newSession = new StoredSession(
                    accessToken,
                    refreshToken,
                    DateTimeOffset.FromUnixTimeSeconds(expiresAtSeconds),
                    wire.User?.Id ?? current.UserId,
                    wire.User?.Email ?? current.Email);
                PersistSession(newSession);
                return accessToken;
            }
        }
        finally
        {
            // Cleared regardless of outcome so the NEXT expiry check starts a fresh refresh rather
            // than replaying this (by-now-completed) task's result forever.
            lock (_gate)
            {
                _refreshTask = null;
            }
        }
    }

    // ============================================================================================
    // MARK: - Subscription status (tier + quota)
    // ============================================================================================

    public async Task<SubscriptionStatusSnapshot?> RefreshStatusAsync(CancellationToken cancellationToken = default)
    {
        var token = await GetValidAccessTokenAsync(cancellationToken).ConfigureAwait(false);
        if (token is null)
        {
            lock (_gate)
            {
                _status = null;
            }
            return null;
        }

        using var request = BuildEdgeFunctionRequest(HttpMethod.Get, "functions/v1/subscription/status", token);

        HttpResponseMessage response;
        try
        {
            response = await SendWithTimeoutAsync(request, TimeSpan.FromSeconds(15), cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch
        {
            return null; // keep whatever was cached before — a transient hiccup must not wipe it.
        }

        using (response)
        {
            if (!response.IsSuccessStatusCode)
            {
                return null;
            }

            SubscriptionStatusWire? wire;
            try
            {
                var bytes = await response.Content.ReadAsByteArrayAsync(cancellationToken).ConfigureAwait(false);
                wire = JsonSerializer.Deserialize<SubscriptionStatusWire>(bytes, JsonOptions);
            }
            catch (JsonException)
            {
                return null;
            }

            if (wire?.Tier is not { Length: > 0 } tier)
            {
                return null;
            }

            DateTimeOffset? expiresAt = null;
            if (!string.IsNullOrEmpty(wire.ExpiresAt)
                && DateTimeOffset.TryParse(
                    wire.ExpiresAt,
                    System.Globalization.CultureInfo.InvariantCulture,
                    System.Globalization.DateTimeStyles.AssumeUniversal | System.Globalization.DateTimeStyles.AdjustToUniversal,
                    out var parsedExpiresAt))
            {
                expiresAt = parsedExpiresAt;
            }

            var snapshot = new SubscriptionStatusSnapshot(
                tier, expiresAt, wire.ParseUsedToday, wire.ParseLimit, wire.SpeechUsedToday, wire.SpeechLimit, _clock.Now);
            lock (_gate)
            {
                _status = snapshot;
            }
            RaiseChanged();
            return snapshot;
        }
    }

    public void RefreshStatusIfStale(TimeSpan? maxAge = null)
    {
        if (State != AccountSessionState.SignedIn)
        {
            return;
        }
        var age = maxAge ?? TimeSpan.FromSeconds(30);
        var status = CachedStatus;
        if (status is not null && _clock.Now - status.FetchedAt < age)
        {
            return;
        }
        _ = SafeRefreshStatusAsync();
    }

    private async Task SafeRefreshStatusAsync()
    {
        try
        {
            await RefreshStatusAsync().ConfigureAwait(false);
        }
        catch
        {
            // Background/fire-and-forget refresh — never let a failure here surface anywhere.
        }
    }

    // ============================================================================================
    // MARK: - Session mutation helpers
    // ============================================================================================

    private void PersistSession(StoredSession session)
    {
        lock (_gate)
        {
            _session = session;
        }
        try
        {
            _tokenStore.Save(session);
        }
        catch
        {
            // Best-effort — the in-memory session above already stands for this process's lifetime.
        }
        RaiseChanged();
    }

    private void ClearSession()
    {
        bool wasSignedIn;
        lock (_gate)
        {
            wasSignedIn = _session is not null;
            _session = null;
            _status = null;
        }
        try
        {
            _tokenStore.Clear();
        }
        catch
        {
            // Best-effort — in-memory state is already cleared regardless.
        }
        if (wasSignedIn)
        {
            RaiseChanged();
        }
    }

    private void RaiseChanged() => Changed?.Invoke();

    // ============================================================================================
    // MARK: - HTTP plumbing
    // ============================================================================================

    private HttpRequestMessage BuildGoTrueRequest(HttpMethod method, string relativePath, string? jsonBody, string? bearerToken = null)
    {
        var request = new HttpRequestMessage(method, new Uri(_baseUrl, relativePath));
        request.Headers.TryAddWithoutValidation("apikey", _apiKey);
        if (bearerToken is not null)
        {
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", bearerToken);
        }
        if (jsonBody is not null)
        {
            request.Content = new StringContent(jsonBody, Encoding.UTF8, "application/json");
        }
        return request;
    }

    /// <summary>Contract §3: edge-function calls carry ONLY the account bearer token — no `apikey`
    /// header (`config.toml`'s `verify_jwt = false` means the gateway does not require one; see
    /// contract §7's own note on why that is intentional, not an oversight).</summary>
    private HttpRequestMessage BuildEdgeFunctionRequest(HttpMethod method, string relativePath, string bearerToken)
    {
        var request = new HttpRequestMessage(method, new Uri(_baseUrl, relativePath));
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", bearerToken);
        return request;
    }

    private async Task<HttpResponseMessage> SendWithTimeoutAsync(HttpRequestMessage request, TimeSpan timeout, CancellationToken cancellationToken)
    {
        using var timeoutCts = new CancellationTokenSource(timeout);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeoutCts.Token);
        return await _http.SendAsync(request, linked.Token).ConfigureAwait(false);
    }
}
