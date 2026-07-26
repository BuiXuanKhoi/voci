// Services/Account/IAccountService.cs — the app-facing account/auth/entitlement seam
// (specs/002-workflow-command-center/contracts/account-auth.md). Implemented by
// <see cref="AccountService"/>; exists as an interface so AccountViewModel/tests can substitute a
// fake without spinning up a real HttpClient/DPAPI file.
namespace Volar.App.Services.Account;

public interface IAccountService
{
    /// <summary>Fires whenever sign-in state, the current user, or the cached subscription status
    /// changes — the ONLY change-notification surface this service exposes (deliberately not
    /// per-property, mirroring <c>ThemeState.Changed</c>'s own single-event shape elsewhere in this
    /// port). Consumers (AccountViewModel) marshal to the UI thread themselves via
    /// <c>UiDispatch.Post</c>, same as every other Wave-4 VM's "subscribe to service events" rule —
    /// this event itself may fire from a background thread (an HTTP continuation).</summary>
    event Action? Changed;

    AccountSessionState State { get; }

    /// <summary><see langword="null"/> when signed out.</summary>
    AccountUser? CurrentUser { get; }

    /// <summary>Last-fetched tier/quota snapshot, or <see langword="null"/> if never fetched (or
    /// cleared on sign-out). Read synchronously — callers needing a GUARANTEED fresh value should
    /// call <see cref="RefreshStatusAsync"/> instead and await its result.</summary>
    SubscriptionStatusSnapshot? CachedStatus { get; }

    /// <summary>Step 1 of email sign-in: <c>POST /auth/v1/otp</c>. Idempotent to call repeatedly
    /// (e.g. "Resend code").</summary>
    Task<OtpSendResult> SendOtpAsync(string email, CancellationToken cancellationToken = default);

    /// <summary>Step 2: <c>POST /auth/v1/verify</c>. On success, persists the session (DPAPI,
    /// <see cref="ITokenStore"/>), flips <see cref="State"/> to
    /// <see cref="AccountSessionState.SignedIn"/>, and kicks a background
    /// <see cref="RefreshStatusAsync"/> so tier/quota are populated moments after sign-in.</summary>
    Task<VerifyOtpResult> VerifyOtpAsync(string email, string code, CancellationToken cancellationToken = default);

    /// <summary>Best-effort server-side <c>POST /auth/v1/logout</c>, then ALWAYS clears the local
    /// session regardless of whether the network call succeeded — sign-out must never fail from
    /// the user's perspective just because the network is down.</summary>
    Task SignOutAsync(CancellationToken cancellationToken = default);

    /// <summary><c>POST /functions/v1/subscription/delete-account</c> (Apple Guideline 5.1.1(v) —
    /// required regardless of platform). On success clears the local session too.</summary>
    Task<DeleteAccountResult> DeleteAccountAsync(CancellationToken cancellationToken = default);

    /// <summary>
    /// The single seam every cloud-call credential provider (parse, Groq speech) goes through.
    /// Returns <see langword="null"/> whenever no usable token is available RIGHT NOW — signed out,
    /// or a refresh attempt failed/was rejected — which callers treat identically to "not
    /// configured" (never an exception, never a user-visible error; see
    /// <see cref="Volar.Parsing.ConfigParseCredentialProvider"/>/
    /// <see cref="Volar.Speech.Groq.AccountGroqCredentialProvider"/>'s own doc comments).
    /// </summary>
    /// <remarks>
    /// Concurrency: N simultaneous callers whose token happens to be within ~60s of expiry (or
    /// already expired) collapse onto exactly ONE in-flight refresh HTTP call — see
    /// <see cref="AccountService"/>'s own doc comment for the exact mechanism. A 400/401 refresh
    /// rejection clears the stored session and returns <see langword="null"/>; it is never retried
    /// in a loop — the NEXT call to this method (if still signed out) just returns
    /// <see langword="null"/> immediately without attempting the network again.
    /// </remarks>
    Task<string?> GetValidAccessTokenAsync(CancellationToken cancellationToken = default);

    /// <summary><c>GET /functions/v1/subscription/status</c>. Updates <see cref="CachedStatus"/>
    /// and fires <see cref="Changed"/> on success. Returns <see langword="null"/> (and leaves
    /// <see cref="CachedStatus"/> at whatever it was) on any failure — a transient network hiccup
    /// must never wipe out the last-known-good quota display.</summary>
    Task<SubscriptionStatusSnapshot?> RefreshStatusAsync(CancellationToken cancellationToken = default);

    /// <summary>
    /// Fire-and-forget convenience: kicks a background <see cref="RefreshStatusAsync"/> if signed in
    /// AND (<see cref="CachedStatus"/> is missing OR older than <paramref name="maxAge"/>) — never
    /// awaited, never throws, safe to call from a hot path (e.g. every time a credential provider's
    /// <c>IsConfigured</c>/<c>GetAuthHeaderAsync</c> is consulted) without adding latency. This is
    /// this port's approximation of the brief's "refresh on ... after a cloud call": the lower-layer
    /// credential providers (<c>Volar.Parsing</c>/<c>Volar.Speech</c>) cannot hold a direct reference
    /// to this service to fire a precise post-call event (see those files' own layering notes), so
    /// staleness-driven refresh here plus explicit <c>GroqEngine.OnFinal</c>/<c>OnError</c> hooks in
    /// <c>CompositionRoot</c> (which CAN see both sides) stand in for it — see this feature's final
    /// report, "assumptions."
    /// </summary>
    void RefreshStatusIfStale(TimeSpan? maxAge = null);
}
