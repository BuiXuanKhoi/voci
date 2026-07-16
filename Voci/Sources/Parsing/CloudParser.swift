// Sources/Parsing/CloudParser.swift — text-only cloud intent parsing client for
// `POST /functions/v1/parse` (contracts/parse-proxy.md). Mirrors the networking/credential-
// provider pattern of `Sources/Speech/GroqTranscriptionClient.swift` (struct, injected provider,
// `URLSession`, no hardcoded secrets) so this stays idiomatic to the codebase.
//
// The server side of this route is ALREADY IMPLEMENTED (`supabase/functions/parse/index.ts` +
// `_shared/{auth,schema,quota}.ts`, T004/T022) — this client is written to match that real,
// already-reviewed wire contract exactly (field names, status codes, auth header shapes), not
// just the prose in parse-proxy.md. See `supabase/README.md` for the curl-level ground truth.
//
// CONSTITUTION I (text-only, no audio egress): this file contains no audio type, no AVFoundation
// import, no multipart/binary upload — the only payload ever sent is a JSON object built from
// `String`/`Date`/`[String]`. Grep-verifiable: no `Data` audio buffer, no `AVAudio*` symbol
// anywhere below.
import Foundation

// MARK: - Credential provider (injected — mirrors GroqCredentialProvider)

/// Exactly one of these becomes exactly one HTTP header on the `/parse` request, per
/// `parse-proxy.md` + the real server (`_shared/auth.ts`: "exactly one of Authorization /
/// X-Device-Token required").
enum ParseAuthHeader: Sendable, Equatable {
    /// `Authorization: Bearer <jws>` — paid tier, unmetered (soft rate-limited server-side).
    /// ASSUMPTION flagged for the StoreKit owner (matches `supabase/README.md`'s own flagged
    /// assumption): `jws` must be a `Transaction.jwsRepresentation` from
    /// `Transaction.currentEntitlements` (proof of an ACTIVE purchase — carries
    /// `originalTransactionId`, which the server hashes into its rate-limit key), NOT an
    /// `AppTransaction.jwsRepresentation` (proof of install only, no transaction id). If the
    /// concrete `ParseCredentialProvider` sends the wrong JWS type, the server will 401 every
    /// paid request — reconcile against the StoreKit provider before shipping.
    case paidJWS(String)
    /// `X-Device-Token: <token>` — free tier, metered server-side (daily counter). `token` MUST
    /// already be the fully-encoded header value: base64url(JSON{keyId, assertion,
    /// clientDataHashB64}) — see `DeviceCheckProvider.swift`, which is the only file that should
    /// ever construct this string. `CloudParser` treats it as an opaque string.
    case freeDeviceToken(String)
}

/// Supplies the parse-proxy base URL + per-request auth, injected so this file never hardcodes a
/// project URL or holds a secret directly — mirrors `GroqCredentialProvider`'s split of
/// `baseURL()`/`authorization()`. Concrete implementation is the StoreKit/DeviceCheck owner's
/// composite (NOT built in this file): it decides paid-vs-free by checking entitlement state,
/// then either returns a cached/fetched StoreKit JWS (`.paidJWS`) or calls into a
/// `DeviceAttestationProvider` (`DeviceCheckProvider.swift`, T023) for `.freeDeviceToken`.
///
/// ASSUMPTION for the reviewer to check against that work: `authHeader()` returning `nil` is the
/// ONLY signal `CloudParser` uses for "no credential available right now" — it must never throw
/// to report that state (this file only handles `baseURL()` throwing, for endpoint-resolution
/// failures, e.g. missing config).
protocol ParseCredentialProvider: Sendable {
    /// Base URL of the Supabase project (e.g. `https://<project-ref>.supabase.co`).
    /// `CloudParser` appends `functions/v1/parse`.
    func baseURL() async throws -> URL
    /// `nil` = no credential available right now (not opted in / no active entitlement / device
    /// attestation unavailable) — `CloudParser` treats this as "Cloud unavailable" and NEVER
    /// sends an unauthenticated request.
    func authHeader() async -> ParseAuthHeader?
}

// MARK: - Outcome (non-protocol — lets IntentRouter distinguish quota from any other failure)

/// `CloudParser`'s own richer result, consumed by `IntentRouter.parse` directly (NOT part of the
/// frozen `IntentParser` protocol, whose `parse` returns plain `[ParsedTask]`). This is how the
/// 429 "gentle note" (FR-012) signal reaches the router without changing the frozen return type.
enum CloudParseOutcome: Sendable, Equatable {
    case tasks([ParsedTask])
    /// 429 `{ reason: "quota", resetAt }`. `resetAt` is best-effort (nil if absent/malformed).
    case quotaExceeded(resetAt: Date?)
    /// Any other non-200 (401 invalid/expired auth, 403, 4xx, 5xx, `config_missing` 503,
    /// `upstream_error` 502), transport failure (offline/DNS/TLS/timeout), or a response that
    /// failed decode/size validation. The router falls through silently — never a user-visible
    /// error beyond the quota note.
    case unavailable
}

// MARK: - CloudParser (T021)

/// Pure network + decode layer for the `/functions/v1/parse` route. No app state, no UI —
/// unit-testable by injecting a `URLSession` (mirrors `GroqTranscriptionClient`). Never retries
/// (contract: one round trip per parse; a 5xx here just means "fall through to Heuristic now",
/// not "retry the network").
struct CloudParser: Sendable {
    let credentials: ParseCredentialProvider
    var session: URLSession = .shared
    /// Contract: "text, ≤2000 chars". Truncated client-side before sending — never rejected
    /// outright, since a truncated transcript is still better than discarding the utterance.
    var maxTranscriptChars = 2000
    /// Sanity cap on the RESPONSE body before attempting to decode it — bounds memory/CPU spent
    /// decoding a hostile or corrupted (e.g. MITM-tampered, or a buggy future server change)
    /// response BEFORE `JSONDecoder` ever runs, independent of the 10-task cap applied after
    /// decode. 10 tasks at the contract's own per-field caps (300-char titles, 1000-char notes,
    /// etc.) comfortably fit well under this.
    var maxResponseBytes = 256 * 1024
    var timeout: TimeInterval = 20

    /// Fresh instance per call, deliberately not a shared `static let`: `ISO8601DateFormatter` is
    /// a mutable reference type Foundation has not audited/marked `Sendable`, and this struct's
    /// methods run off the main actor — sharing one instance across concurrent calls would be a
    /// Swift 6 strict-concurrency risk (and a real, if unlikely, data race) for a cost that's
    /// negligible next to the network round trip itself. Default `formatOptions` include
    /// `.withInternetDateTime`, which always emits a trailing `Z` — satisfies the server's
    /// `isIso8601WithZone` check (`_shared/schema.ts`) that requires a zone designator on `now`.
    private static func makeRequestFormatter() -> ISO8601DateFormatter { ISO8601DateFormatter() }

    // MARK: Parse mode

    func parseDetailed(_ transcript: String, now: Date, openTaskTitles: [String]) async -> CloudParseOutcome {
        let trimmed = String(transcript.prefix(maxTranscriptChars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unavailable }

        guard let base = try? await credentials.baseURL(),
              let header = await credentials.authHeader() else {
            // No consent / no entitlement / no device token available — never send an
            // unauthenticated request (the server would 401 it anyway, but we shouldn't even try:
            // that would count as a network attempt while "offline"/"not opted in" from the
            // user's perspective, and could leak the transcript to the wire before auth fails).
            return .unavailable
        }

        var payload: [String: Any] = [
            "transcript": trimmed,
            "now": Self.makeRequestFormatter().string(from: now),
        ]
        if !openTaskTitles.isEmpty {
            payload["open_task_titles"] = Array(openTaskTitles.prefix(100)).map { String($0.prefix(200)) }
        }

        guard let request = Self.makeRequest(base: base, header: header, timeout: timeout, jsonPayload: payload) else {
            return .unavailable
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // Transport failure (offline/DNS/TLS/timeout) — silent fall-through, no user-visible
            // error. Deliberately not logging `error.localizedDescription`: it can echo request
            // details on some platforms, and this route's privacy contract is "no transcript
            // logging" — err on the side of logging nothing here rather than auditing every OS's
            // error string for leakage.
            return .unavailable
        }
        guard let http = response as? HTTPURLResponse else { return .unavailable }

        switch http.statusCode {
        case 200:
            guard data.count <= maxResponseBytes else { return .unavailable }
            guard let raws = try? JSONDecoder().decode([RawParsedTask].self, from: data), !raws.isEmpty else {
                return .unavailable
            }
            let capped = Array(raws.prefix(IntentRouter.maxTaskCap))
            let validated = ParsedTaskValidation.validateAll(capped, sourceTranscript: transcript)
            return .tasks(validated)
        case 429:
            let quota = try? JSONDecoder().decode(QuotaResponse.self, from: data)
            let resetAt = quota?.resetAt.flatMap { ParsedTaskValidation.parseISO8601($0) }
            return .quotaExceeded(resetAt: resetAt)
        default:
            // 401 (invalid/expired auth -> fallback, prompt re-validation in Settings elsewhere),
            // 403, 5xx (`upstream_error`/`config_missing`/`internal_error`), or any other 4xx —
            // all fall through the same way per contract ("401 -> fallback"; "5xx -> fallback").
            return .unavailable
        }
    }

    // MARK: Breakdown mode (same route, `mode: "breakdown"`)

    func breakdownDetailed(title: String, notes: String?) async -> [String]? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return nil }

        guard let base = try? await credentials.baseURL(),
              let header = await credentials.authHeader() else { return nil }

        var payload: [String: Any] = [
            "mode": "breakdown",
            "task_title": String(trimmedTitle.prefix(300)),
        ]
        if let notes, !notes.isEmpty {
            payload["notes"] = String(notes.prefix(1000))
        }

        guard let request = Self.makeRequest(base: base, header: header, timeout: timeout, jsonPayload: payload) else {
            return nil
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return nil
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        guard data.count <= maxResponseBytes else { return nil }
        guard let decoded = try? JSONDecoder().decode(BreakdownResponse.self, from: data) else { return nil }

        let steps = decoded.steps
            .map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // Re-check the contract's own bound (3...9) client-side too, even though the server
        // already enforces it (`_shared/schema.ts`) — never trust a remote response blindly.
        guard (3...9).contains(steps.count) else { return nil }
        return steps
    }

    // MARK: - Shared request builder

    private static func makeRequest(
        base: URL, header: ParseAuthHeader, timeout: TimeInterval, jsonPayload: [String: Any]
    ) -> URLRequest? {
        guard let body = try? JSONSerialization.data(withJSONObject: jsonPayload) else { return nil }
        // TLS is whatever `base` specifies — this file never downgrades to `http://` and never
        // installs a custom `URLSessionDelegate` that would bypass certificate validation
        // (default `URLSession.shared`/system trust store is used as-is).
        let url = base.appendingPathComponent("functions/v1/parse")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        switch header {
        case .paidJWS(let jws):
            request.setValue("Bearer \(jws)", forHTTPHeaderField: "Authorization")
        case .freeDeviceToken(let token):
            request.setValue(token, forHTTPHeaderField: "X-Device-Token")
        }
        // Text-only body: `jsonPayload` is built exclusively from `String`/`Date`-derived values
        // above (transcript, ISO8601 timestamp, titles, task_title, notes) — there is no audio
        // parameter anywhere in this file, no multipart body, no binary upload (constitution I).
        request.httpBody = body
        return request
    }

    private struct QuotaResponse: Decodable {
        var reason: String
        var resetAt: String?
    }

    private struct BreakdownResponse: Decodable {
        struct Step: Decodable {
            var title: String
            var estimateMinutes: Double
        }
        var steps: [Step]
    }
}

// MARK: - IntentParser conformance (frozen protocol surface)

extension CloudParser: IntentParser {
    func parse(_ transcript: String, now: Date, openTaskTitles: [String]) async -> [ParsedTask] {
        if case .tasks(let tasks) = await parseDetailed(transcript, now: now, openTaskTitles: openTaskTitles) {
            return tasks
        }
        return []
    }

    func breakdown(title: String, notes: String?) async -> [String] {
        await breakdownDetailed(title: title, notes: notes) ?? []
    }
}
