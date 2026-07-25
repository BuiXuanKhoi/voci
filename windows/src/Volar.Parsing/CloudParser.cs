// Volar.Parsing/CloudParser.cs — text-only cloud intent parsing client for
// POST /functions/v1/parse (contracts/parse-proxy.md). Port of Sources/Parsing/CloudParser.swift.
//
// The server side of this route is ALREADY IMPLEMENTED (supabase/functions/parse/index.ts +
// _shared/{auth,schema,quota}.ts) — this client is written to match that real, already-reviewed wire
// contract exactly (field names, status codes, auth header shapes), not just prose. In particular
// note the request body's field-naming quirk mirrored byte-for-byte from the Swift client and the
// real `_shared/schema.ts` validator: `transcript`/`now`/`mode`/`notes` are single-word (no case
// ambiguity) but `open_task_titles` and `task_title` are snake_case on the wire even though the
// server's *internal* TypeScript interface names them camelCase — `_shared/schema.ts`'s own
// `validateParseRequest`/`validateBreakdownRequest` read `body.open_task_titles`/`body.task_title`
// literally, so that is what must be sent. The RESPONSE body, by contrast, is genuinely camelCase
// throughout (`estimateMinutes`, `reminderOverride`, `followUpReview`, ...) — see
// `_shared/schema.ts`'s `ParsedTaskOut`.
//
// CONSTITUTION I (text-only, no audio egress): this file contains no audio type, no multipart/binary
// upload — the only payload ever sent is JSON built from string/DateTimeOffset values.
using System.Globalization;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Volar.Domain;

namespace Volar.Parsing;

// MARK: - Credential provider (injected — mirrors GroqCredentialProvider in Volar.Speech)

/// <summary>
/// Exactly one of these becomes exactly one HTTP header on the <c>/parse</c> request, per
/// <c>parse-proxy.md</c> + the real server (<c>_shared/auth.ts</c>: "exactly one of Authorization /
/// X-Device-Token required").
/// </summary>
public abstract record ParseAuthHeader
{
    private protected ParseAuthHeader() { }

    /// <summary>
    /// <c>Authorization: Bearer &lt;jws&gt;</c> — paid tier, unmetered (soft rate-limited
    /// server-side). ASSUMPTION flagged for the StoreKit/purchase owner (matches the Swift source's
    /// own flagged assumption): <paramref name="Jws"/> must be proof of an ACTIVE purchase (carries a
    /// transaction id the server hashes into its rate-limit key), not merely proof of install.
    /// </summary>
    public sealed record PaidJws(string Jws) : ParseAuthHeader;

    /// <summary>
    /// <c>X-Device-Token: &lt;token&gt;</c> — free tier, metered server-side (daily counter).
    /// <paramref name="Token"/> MUST already be the fully-encoded header value — this file treats it
    /// as an opaque string, never constructing it itself.
    /// </summary>
    public sealed record FreeDeviceToken(string Token) : ParseAuthHeader;
}

/// <summary>
/// Supplies the parse-proxy base URL + per-request auth, injected so this file never hardcodes a
/// project URL or holds a secret directly. Concrete implementation is the owning composite's
/// responsibility (NOT built in this file): decide paid-vs-free by checking entitlement state, then
/// either return a cached/fetched JWS (<see cref="ParseAuthHeader.PaidJws"/>) or a device-attestation
/// token (<see cref="ParseAuthHeader.FreeDeviceToken"/>).
/// </summary>
/// <remarks>
/// ASSUMPTION for the reviewer: <see cref="GetAuthHeaderAsync"/> returning <see langword="null"/> is
/// the ONLY signal <see cref="CloudParser"/> uses for "no credential available right now" — it must
/// never throw to report that state (this file only handles <see cref="GetBaseUrlAsync"/> throwing,
/// for endpoint-resolution failures, e.g. missing config).
/// </remarks>
public interface IParseCredentialProvider
{
    /// <summary>Base URL of the Supabase project. <see cref="CloudParser"/> appends <c>functions/v1/parse</c>.</summary>
    Task<Uri> GetBaseUrlAsync(CancellationToken cancellationToken = default);

    /// <summary>
    /// <see langword="null"/> = no credential available right now (not opted in / no active
    /// entitlement / device attestation unavailable) — <see cref="CloudParser"/> treats this as
    /// "Cloud unavailable" and NEVER sends an unauthenticated request.
    /// </summary>
    Task<ParseAuthHeader?> GetAuthHeaderAsync(CancellationToken cancellationToken = default);
}

// MARK: - Outcome (not part of IIntentParser — lets IntentRouter distinguish quota from any other failure)

/// <summary>
/// <see cref="CloudParser"/>'s own richer result, consumed by <see cref="IntentRouter"/> directly
/// (NOT part of the frozen <see cref="IIntentParser"/> surface, whose parse method returns plain
/// tasks). This is how the 429 "gentle note" (FR-012) signal reaches the router without changing the
/// frozen return type.
/// </summary>
public abstract record CloudParseOutcome
{
    private protected CloudParseOutcome() { }

    public sealed record Tasks(IReadOnlyList<ParsedTask> Value) : CloudParseOutcome;

    /// <summary>429 <c>{ reason: "quota", resetAt }</c>. <paramref name="ResetAt"/> is best-effort (null if absent/malformed).</summary>
    public sealed record QuotaExceeded(DateTimeOffset? ResetAt) : CloudParseOutcome;

    /// <summary>
    /// Any other non-200 (401 invalid/expired auth, 403, 4xx, 5xx, config_missing 503,
    /// upstream_error 502), transport failure (offline/DNS/TLS/timeout), or a response that failed
    /// decode/size validation. The router falls through silently — never a user-visible error beyond
    /// the quota note.
    /// </summary>
    public sealed record Unavailable : CloudParseOutcome
    {
        public static readonly Unavailable Instance = new();
    }
}

// MARK: - CloudParser (T021 equivalent)

/// <summary>
/// Pure network + decode layer for the <c>/functions/v1/parse</c> route. No app state, no UI —
/// unit-testable by injecting an <see cref="HttpMessageHandler"/>. Never retries (contract: one round
/// trip per parse; a 5xx here just means "fall through to the next tier now," not "retry the network").
/// </summary>
public sealed class CloudParser : IIntentParser
{
    private readonly IParseCredentialProvider _credentials;
    private readonly HttpClient _httpClient;

    /// <summary>Contract: "text, &lt;=2000 chars". Truncated client-side — never rejected outright.</summary>
    public int MaxTranscriptChars { get; init; } = 2000;

    /// <summary>
    /// Sanity cap on the RESPONSE body before attempting to decode it — bounds memory/CPU spent
    /// decoding a hostile or corrupted response BEFORE the JSON parser ever runs, independent of the
    /// 10-task cap applied after decode.
    /// </summary>
    public int MaxResponseBytes { get; init; } = 256 * 1024;

    public TimeSpan Timeout { get; init; } = TimeSpan.FromSeconds(20);

    private static readonly JsonSerializerOptions ResponseJsonOptions = new(JsonSerializerDefaults.Web);

    public CloudParser(IParseCredentialProvider credentials, HttpClient? httpClient = null)
    {
        _credentials = credentials ?? throw new ArgumentNullException(nameof(credentials));
        _httpClient = httpClient ?? new HttpClient();
    }

    // MARK: Parse mode

    public async Task<CloudParseOutcome> ParseDetailedAsync(
        string transcript,
        DateTimeOffset now,
        IReadOnlyList<string> openTaskTitles,
        CancellationToken cancellationToken = default)
    {
        var trimmed = (transcript.Length > MaxTranscriptChars ? transcript[..MaxTranscriptChars] : transcript).Trim();
        if (trimmed.Length == 0)
        {
            return CloudParseOutcome.Unavailable.Instance;
        }

        Uri baseUrl;
        ParseAuthHeader? header;
        try
        {
            baseUrl = await _credentials.GetBaseUrlAsync(cancellationToken).ConfigureAwait(false);
            header = await _credentials.GetAuthHeaderAsync(cancellationToken).ConfigureAwait(false);
        }
        catch
        {
            return CloudParseOutcome.Unavailable.Instance;
        }
        if (header is null)
        {
            // No consent / no entitlement / no device token available — never send an unauthenticated
            // request (the server would 401 it anyway, but we shouldn't even try: that would count as
            // a network attempt while "offline"/"not opted in" from the user's perspective, and could
            // leak the transcript to the wire before auth fails).
            return CloudParseOutcome.Unavailable.Instance;
        }

        var payload = new JsonObject
        {
            ["transcript"] = trimmed,
            ["now"] = FormatIso8601(now)
        };
        if (openTaskTitles.Count > 0)
        {
            var titlesArray = new JsonArray();
            foreach (var title in openTaskTitles.Take(100))
            {
                titlesArray.Add(title.Length > 200 ? title[..200] : title);
            }
            payload["open_task_titles"] = titlesArray;
        }

        using var request = BuildRequest(baseUrl, header, payload);
        if (request is null)
        {
            return CloudParseOutcome.Unavailable.Instance;
        }

        HttpResponseMessage response;
        try
        {
            using var timeoutCts = new CancellationTokenSource(Timeout);
            using var linkedCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeoutCts.Token);
            response = await _httpClient.SendAsync(request, linkedCts.Token).ConfigureAwait(false);
        }
        catch
        {
            // Transport failure (offline/DNS/TLS/timeout) — silent fall-through, no user-visible
            // error. Deliberately not logging the exception message: this route's privacy contract is
            // "no transcript logging," and an exception message could echo request details.
            return CloudParseOutcome.Unavailable.Instance;
        }

        using (response)
        {
            var statusCode = (int)response.StatusCode;
            if (statusCode == 200)
            {
                byte[] bytes;
                try
                {
                    bytes = await response.Content.ReadAsByteArrayAsync(cancellationToken).ConfigureAwait(false);
                }
                catch
                {
                    return CloudParseOutcome.Unavailable.Instance;
                }
                if (bytes.Length > MaxResponseBytes)
                {
                    return CloudParseOutcome.Unavailable.Instance;
                }

                RawParsedTask[]? raws;
                try
                {
                    raws = JsonSerializer.Deserialize<RawParsedTask[]>(bytes, ResponseJsonOptions);
                }
                catch (JsonException)
                {
                    raws = null;
                }
                if (raws is null || raws.Length == 0)
                {
                    return CloudParseOutcome.Unavailable.Instance;
                }

                var capped = raws.Take(IntentRouter.MaxTaskCap).ToArray();
                var validated = ParsedTaskValidation.ValidateAll(capped, transcript);
                return new CloudParseOutcome.Tasks(validated);
            }

            if (statusCode == 429)
            {
                DateTimeOffset? resetAt = null;
                try
                {
                    var bytes = await response.Content.ReadAsByteArrayAsync(cancellationToken).ConfigureAwait(false);
                    var quota = JsonSerializer.Deserialize<QuotaResponse>(bytes, ResponseJsonOptions);
                    if (quota?.ResetAt is { } resetAtString)
                    {
                        resetAt = ParsedTaskValidation.ParseIso8601(resetAtString);
                    }
                }
                catch (JsonException)
                {
                    // Malformed quota body — resetAt stays best-effort null, still a quota outcome.
                }
                return new CloudParseOutcome.QuotaExceeded(resetAt);
            }

            // 401 (invalid/expired auth -> fallback, prompt re-validation elsewhere), 403, 5xx
            // (upstream_error/config_missing/internal_error), or any other 4xx — all fall through the
            // same way per contract ("401 -> fallback"; "5xx -> fallback").
            return CloudParseOutcome.Unavailable.Instance;
        }
    }

    // MARK: Breakdown mode (same route, mode: "breakdown")

    public async Task<IReadOnlyList<string>?> BreakdownDetailedAsync(
        string title, string? notes, CancellationToken cancellationToken = default)
    {
        var trimmedTitle = title.Trim();
        if (trimmedTitle.Length == 0)
        {
            return null;
        }

        Uri baseUrl;
        ParseAuthHeader? header;
        try
        {
            baseUrl = await _credentials.GetBaseUrlAsync(cancellationToken).ConfigureAwait(false);
            header = await _credentials.GetAuthHeaderAsync(cancellationToken).ConfigureAwait(false);
        }
        catch
        {
            return null;
        }
        if (header is null)
        {
            return null;
        }

        var payload = new JsonObject
        {
            ["mode"] = "breakdown",
            ["task_title"] = trimmedTitle.Length > 300 ? trimmedTitle[..300] : trimmedTitle
        };
        if (!string.IsNullOrEmpty(notes))
        {
            payload["notes"] = notes.Length > 1000 ? notes[..1000] : notes;
        }

        using var request = BuildRequest(baseUrl, header, payload);
        if (request is null)
        {
            return null;
        }

        HttpResponseMessage response;
        try
        {
            using var timeoutCts = new CancellationTokenSource(Timeout);
            using var linkedCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeoutCts.Token);
            response = await _httpClient.SendAsync(request, linkedCts.Token).ConfigureAwait(false);
        }
        catch
        {
            return null;
        }

        using (response)
        {
            if (response.StatusCode != System.Net.HttpStatusCode.OK)
            {
                return null;
            }
            byte[] bytes;
            try
            {
                bytes = await response.Content.ReadAsByteArrayAsync(cancellationToken).ConfigureAwait(false);
            }
            catch
            {
                return null;
            }
            if (bytes.Length > MaxResponseBytes)
            {
                return null;
            }

            BreakdownResponse? decoded;
            try
            {
                decoded = JsonSerializer.Deserialize<BreakdownResponse>(bytes, ResponseJsonOptions);
            }
            catch (JsonException)
            {
                return null;
            }
            if (decoded is null)
            {
                return null;
            }

            var steps = decoded.Steps
                .Select(s => s.Title.Trim())
                .Where(s => s.Length > 0)
                .ToArray();
            // Re-check the contract's own bound (3...9) client-side too, even though the server
            // already enforces it — never trust a remote response blindly.
            return steps.Length is >= 3 and <= 9 ? steps : null;
        }
    }

    // MARK: - Shared request builder

    private static HttpRequestMessage? BuildRequest(Uri baseUrl, ParseAuthHeader header, JsonObject jsonPayload)
    {
        string body;
        try
        {
            body = jsonPayload.ToJsonString();
        }
        catch (JsonException)
        {
            return null;
        }

        // TLS is whatever `baseUrl` specifies — this file never downgrades to http:// and never
        // installs a custom certificate-validation bypass (the injected HttpClient's default handler
        // and system trust store are used as-is).
        var url = new Uri(baseUrl, "functions/v1/parse");
        var request = new HttpRequestMessage(HttpMethod.Post, url)
        {
            Content = new StringContent(body, Encoding.UTF8, "application/json")
        };
        switch (header)
        {
            case ParseAuthHeader.PaidJws paidJws:
                request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", paidJws.Jws);
                break;
            case ParseAuthHeader.FreeDeviceToken freeDeviceToken:
                request.Headers.TryAddWithoutValidation("X-Device-Token", freeDeviceToken.Token);
                break;
        }
        // Text-only body: `jsonPayload` is built exclusively from string/DateTimeOffset-derived
        // values above (transcript, ISO8601 timestamp, titles, task_title, notes) — there is no audio
        // parameter anywhere in this file, no multipart body, no binary upload (constitution I).
        return request;
    }

    /// <summary>
    /// ISO8601 with a UTC "Z" zone designator, seconds precision, no fractional seconds — mirrors
    /// Swift's <c>ISO8601DateFormatter</c> default (<c>.withInternetDateTime</c>) exactly, which
    /// satisfies the server's <c>isIso8601WithZone</c> check (<c>_shared/schema.ts</c>) that requires
    /// a zone designator on <c>now</c>.
    /// </summary>
    private static string FormatIso8601(DateTimeOffset value)
        => value.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);

    private sealed record QuotaResponse(string? Reason = null, string? ResetAt = null);

    private sealed record BreakdownResponse(IReadOnlyList<BreakdownStep> Steps);

    private sealed record BreakdownStep(string Title, double EstimateMinutes);

    // MARK: - IIntentParser conformance (frozen protocol surface)
    //
    // Public (not explicit-interface) implementations: IntentRouter holds `CloudParser` by its
    // concrete type (mirroring Swift's `private let cloud: CloudParser?`), so these must be callable
    // directly on that type, not only through an `IIntentParser`-typed reference.

    public async Task<IReadOnlyList<ParsedTask>> ParseAsync(
        string transcript, DateTimeOffset now, IReadOnlyList<string> openTaskTitles, CancellationToken cancellationToken = default)
    {
        var outcome = await ParseDetailedAsync(transcript, now, openTaskTitles, cancellationToken).ConfigureAwait(false);
        return outcome is CloudParseOutcome.Tasks tasks ? tasks.Value : Array.Empty<ParsedTask>();
    }

    public async Task<IReadOnlyList<string>> BreakdownAsync(
        string title, string? notes, CancellationToken cancellationToken = default)
        => await BreakdownDetailedAsync(title, notes, cancellationToken).ConfigureAwait(false)
            ?? Array.Empty<string>();
}
