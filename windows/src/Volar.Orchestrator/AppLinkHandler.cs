// AppLinkHandler.cs — port of Sources/Orchestrator/AppLinkHandler.swift: inbound `volar://`
// app-link routing (feature 002, US4, contracts/phase6-contract.md §A +
// contracts/app-links.md, the authoritative behavioral spec).
//
// URL SCHEME: `volar`. OS-level protocol registration (Windows registry `HKCU\Software\Classes\
// volar`) is DEFERRED to Wave 3 (App shell) per this task's brief — this file is PURE
// parsing/routing logic only: given an already-received URL (however the OS handed it to the
// app), decide what it means and call into `IOrchestratorTaskStore` / `DelegationTracker`. It
// performs no protocol registration, no window activation, no process I/O of any kind.
//
// CAPTURE SEAM: capture parsing itself is NOT implemented here (`volar://capture?text=...&
// source=...` must "hand text to the existing capture pipeline" without bypassing the confirm
// card — app-links.md). This file exposes `OnCapture`, a delegate the app-wiring agent (Wave 3)
// sets to the existing capture entry point. Leaving this file free of any UI dependency keeps it
// testable in isolation.
using Volar.Core;
using Volar.Domain;

namespace Volar.Orchestrator;

/// <summary>
/// Routes inbound <c>volar://</c> URLs. Inbound-only, one-way, idempotent, non-destructive
/// (Constitution I/II, app-links.md's own framing): a signal may surface work for review but can
/// never complete, delete, or create a task on its own.
/// </summary>
/// <remarks>
/// Swift's original is <c>@MainActor</c>-isolated. This port carries no isolation of its own;
/// callers are expected to confine access to a single thread, same as <see cref="DelegationTracker"/>.
/// </remarks>
public sealed class AppLinkHandler
{
    private readonly IOrchestratorTaskStore _store;
    private readonly DelegationTracker _delegation;

    /// <summary>
    /// For the ambiguous <c>ai-done</c> case, the candidate waiting tasks so the UI can show a
    /// one-tap card (contract A). Cleared once resolved (see <see cref="ResolveDisambiguation"/>/
    /// <see cref="DismissDisambiguation"/> below) or superseded by a later <see cref="Handle(Uri)"/>
    /// call.
    /// </summary>
    public IReadOnlyList<Guid> PendingDisambiguation { get; private set; } = Array.Empty<Guid>();

    /// <summary>
    /// Capture seam (see file header): the app-wiring agent (Wave 3) assigns this to the existing
    /// capture pipeline entry point. <c>text</c> is already percent-decoded; <c>source</c> is the
    /// optional origin reference app-links.md documents for <c>volar://capture</c>. Left
    /// <see langword="null"/> (default) is a safe no-op — a capture link received before wiring is
    /// complete is logged and dropped, never silently guessed at.
    /// </summary>
    public Action<string, string?>? OnCapture { get; set; }

    /// <summary>Injectable log sink — defaults to <see cref="Console.WriteLine(string)"/>, mirroring the Swift original's <c>print(...)</c> convention (also used by tests to assert on log output without capturing stdout).</summary>
    public Action<string>? Logger { get; set; }

    public AppLinkHandler(IOrchestratorTaskStore store, DelegationTracker delegation)
    {
        _store = store;
        _delegation = delegation;
    }

    /// <summary>
    /// Entry point for a raw URL string (e.g. as handed off by the OS before this app parses it).
    /// A string that fails to parse as an absolute URI at all is logged and ignored — this method
    /// never throws on malformed input.
    /// </summary>
    public void Handle(string rawUrl)
    {
        if (!Uri.TryCreate(rawUrl, UriKind.Absolute, out var uri))
        {
            Log($"malformed or unparsable URL, ignored: {rawUrl}");
            return;
        }
        Handle(uri);
    }

    /// <summary>
    /// Routes <c>&lt;scheme&gt;://ai-done?cwd=...&amp;tty=...</c> per app-links.md's matching
    /// ladder (exactly-one-waiting -&gt; cwd prefix-match -&gt; ambient disambiguation card;
    /// unknown/none -&gt; log+ignore). Idempotent; NEVER completes a task. Also
    /// <c>&lt;scheme&gt;://capture?text=</c> -&gt; feeds the existing capture/parse pipeline
    /// (never bypasses the confirm card). Malformed input (missing host, unknown host) is logged
    /// and ignored — this method never throws or crashes on bad input.
    /// </summary>
    public void Handle(Uri url)
    {
        if (!string.Equals(url.Scheme, "volar", StringComparison.OrdinalIgnoreCase))
        {
            Log($"ignored URL with unexpected scheme: {url}");
            return;
        }
        var host = url.Host;
        if (string.IsNullOrEmpty(host))
        {
            Log($"malformed or hostless URL, ignored: {url}");
            return;
        }
        var parameters = ParseQuery(url.Query);
        switch (host)
        {
            case "ai-done":
                HandleAiDone(parameters);
                break;
            case "capture":
                HandleCapture(parameters);
                break;
            default:
                Log($"unknown app-link host {host}, ignored");
                break;
        }
    }

    /// <summary>
    /// User tapped a candidate on the one-tap disambiguation card: resolve exactly that task
    /// (never auto-picks — the whole reason this card exists is Principle II, "never silently
    /// pick"). A no-op if <paramref name="taskId"/> isn't among the current candidates (stale card
    /// / already resolved by another path).
    /// </summary>
    public void ResolveDisambiguation(Guid taskId)
    {
        if (!PendingDisambiguation.Contains(taskId))
        {
            return;
        }
        _delegation.MarkNeedsReview(taskId);
        PendingDisambiguation = Array.Empty<Guid>();
    }

    /// <summary>User dismissed the disambiguation card without picking. Purely local UI state — no task is touched.</summary>
    public void DismissDisambiguation() => PendingDisambiguation = Array.Empty<Guid>();

    // MARK: - ai-done

    private void HandleAiDone(IReadOnlyDictionary<string, string> parameters)
    {
        // `tty` (app-links.md: "Reserved... Accepted and stored, unused in v2") is deliberately
        // read here only to confirm parsing never throws on it — `DelegationMeta` has no `tty`
        // field to persist it into, so "stored" isn't achievable without a schema change; it is
        // accepted and otherwise ignored until a future schema change adds the field.
        _ = parameters.TryGetValue("tty", out _);

        // A test/probe signal must never resolve a REAL in-flight delegation: receipt-only,
        // matching ladder skipped entirely, never resolves a task.
        if (parameters.TryGetValue("test", out var testValue) && testValue == "1"
            || parameters.TryGetValue("probe", out var probeValue) && probeValue == "1")
        {
            Log("ai-done received with test/probe=1 — receipt-only, matching ladder skipped");
            return;
        }

        var waiting = WaitingTaskIds();
        if (waiting.Count == 0)
        {
            Log("ai-done received with no tasks currently waiting on AI — ignored");
            return;
        }

        // Step 1: exactly one task waiting-on-AI overall -> unambiguous, regardless of cwd/tty.
        if (waiting.Count == 1)
        {
            Resolve(waiting[0]);
            return;
        }

        // Step 2: cwd prefix-match against each waiting task's DelegationMeta.CwdHint. The hint is
        // captured at delegate-time and is typically a project root; the signal's `cwd` is the
        // directory the agent actually ran in, which may be that root or a subdirectory of it — so
        // the match direction is "hint prefixes cwd", not the reverse.
        var cwd = parameters.TryGetValue("cwd", out var rawCwd) ? DecodedCwd(rawCwd) : null;
        if (!string.IsNullOrEmpty(cwd))
        {
            var matches = waiting.Where(taskId =>
            {
                var hint = _delegation.CwdHint(taskId);
                if (string.IsNullOrEmpty(hint))
                {
                    return false;
                }
                // Plain `StartsWith` is not path-boundary aware — "/Users/k/proj" would also match
                // "/Users/k/project2". Require either an exact match or that the hint is followed
                // by a path separator.
                return cwd == hint || cwd!.StartsWith(hint.EndsWith("/", StringComparison.Ordinal) ? hint : hint + "/", StringComparison.Ordinal);
            }).ToList();

            if (matches.Count == 1)
            {
                Resolve(matches[0]);
                return;
            }
            if (matches.Count > 1)
            {
                // Still ambiguous, but narrow the one-tap card to the relevant subset rather than
                // every waiting task in the app.
                PendingDisambiguation = matches;
                Log($"ai-done ambiguous after cwd match ({matches.Count} candidates) — exposed for disambiguation");
                return;
            }
        }

        // Step 3: ambient one-tap disambiguation card listing (all) waiting tasks.
        PendingDisambiguation = waiting;
        Log($"ai-done ambiguous ({waiting.Count} tasks waiting) — exposed for disambiguation");
    }

    private void Resolve(Guid taskId)
    {
        _delegation.MarkNeedsReview(taskId);
        PendingDisambiguation = Array.Empty<Guid>();
    }

    /// <summary>
    /// Tasks currently carrying an unsatisfied "waiting on AI" condition — the live candidate set
    /// for the matching ladder. Sharing <see cref="DelegationTracker.IsWaitingOnAI"/> (rather than
    /// redefining the recognition rule here) keeps this type and <see cref="DelegationTracker"/>
    /// from ever disagreeing on what "waiting" means.
    /// </summary>
    private List<Guid> WaitingTaskIds() =>
        _store.FetchAll()
            .Where(t => t.Status != TaskState.Done && t.Status != TaskState.Archived)
            .Where(t => t.Conditions.Any(DelegationTracker.IsWaitingOnAI))
            .Select(t => t.Id)
            .ToList();

    // MARK: - capture

    private void HandleCapture(IReadOnlyDictionary<string, string> parameters)
    {
        if (!parameters.TryGetValue("text", out var rawText))
        {
            Log("capture link missing required text= param — ignored");
            return;
        }
        // No length cap here previously would let an arbitrarily large `text=` go straight into
        // the parse pipeline. Same 2000-char cap the transcript-parsing pipeline enforces on
        // typed/spoken transcripts — an app-link is just another capture entry point and must not
        // be able to smuggle a larger payload past it. `source` is cosmetic (stored in notes) and
        // capped shorter.
        var text = Truncate(rawText.Trim(), 2000);
        if (text.Length == 0)
        {
            Log("capture link text was empty after trimming — ignored");
            return;
        }
        if (OnCapture is null)
        {
            Log("capture link received before the capture pipeline hook was wired — dropped");
            return;
        }
        var source = parameters.TryGetValue("source", out var rawSource) ? Truncate(rawSource, 200) : null;
        OnCapture(text, source);
    }

    /// <summary>
    /// The connector's Stop-hook base64-encodes <c>$PWD</c> before embedding it in the
    /// <c>cwd=</c> query param, since an un-encoded path containing a space/<c>#</c>/<c>&amp;</c>/
    /// non-ASCII byte would otherwise break the URL. Decode it back here. Falls back to the raw
    /// value for backwards compatibility with a hook installed by a previous build that didn't
    /// encode it (base64-decoding a plain path will almost always fail — but if it happens to
    /// succeed and produce garbage, the cwd match step simply won't match anything, which is safe:
    /// at worst it falls through to the disambiguation card, never a wrong resolve). Caps the
    /// result at 1000 chars either way.
    /// </summary>
    private static string? DecodedCwd(string? raw)
    {
        if (string.IsNullOrEmpty(raw))
        {
            return null;
        }
        string decoded;
        if (TryBase64Decode(raw, out var utf8) && utf8 is not null)
        {
            decoded = utf8;
        }
        else
        {
            decoded = raw;
        }
        return Truncate(decoded, 1000);
    }

    private static bool TryBase64Decode(string raw, out string? utf8)
    {
        utf8 = null;
        try
        {
            var bytes = Convert.FromBase64String(raw);
            utf8 = System.Text.Encoding.UTF8.GetString(bytes);
            return true;
        }
        catch (FormatException)
        {
            return false;
        }
    }

    private static string Truncate(string value, int maxLength) =>
        value.Length <= maxLength ? value : value[..maxLength];

    // MARK: - Parsing helpers

    /// <summary>
    /// Parses a URL query string into a first-value-wins name/value map, percent-decoding each
    /// component via <see cref="Uri.UnescapeDataString(string)"/> — mirroring Foundation's
    /// <c>URLComponents.queryItems</c>, which percent-decodes but does NOT translate <c>+</c> to a
    /// space (unlike <c>application/x-www-form-urlencoded</c> form bodies), so this deliberately
    /// does not either. A bare name with no <c>=</c> (no value at all) is skipped, matching Swift's
    /// <c>guard let value = item.value else continue</c>.
    /// </summary>
    internal static IReadOnlyDictionary<string, string> ParseQuery(string query)
    {
        var result = new Dictionary<string, string>();
        var q = query.StartsWith("?", StringComparison.Ordinal) ? query[1..] : query;
        if (q.Length == 0)
        {
            return result;
        }
        foreach (var pair in q.Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var eq = pair.IndexOf('=');
            if (eq < 0)
            {
                // No `=` at all: Swift's `URLQueryItem.value` is nil for a bare name -> skipped.
                continue;
            }
            var name = Uri.UnescapeDataString(pair[..eq]);
            var value = Uri.UnescapeDataString(pair[(eq + 1)..]);
            result[name] = value;
        }
        return result;
    }

    private void Log(string message)
    {
        // Local-only diagnostic (Constitution I: inbound signals are logged locally, never shipped
        // anywhere) — mirrors the Swift original's own `print("[Volar...")` convention.
        if (Logger is not null)
        {
            Logger(message);
        }
        else
        {
            Console.WriteLine($"[Volar.AppLinkHandler] {message}");
        }
    }
}
