// supabase/functions/groq/index.ts — Edge Function for POST /functions/v1/groq/audio/transcriptions
//
// Groq Speech-to-Text proxy, open to both tiers. See README.md in this directory for the product
// rationale: cloud speech (Groq Whisper) used to be Pro-only, but the product is moving cloud-first
// — on-device recognition is now a fallback floor, not the default experience — so free accounts
// are let through too, just with a smaller daily cap (`SPEECH_LIMIT_FREE`, default 20/day) than Pro
// (`SPEECH_LIMIT_PRO`, default 500/day). This makes the route structurally the same shape as
// ../parse (both tiers, different daily caps). Structure, error shapes, and logging discipline
// deliberately mirror ../parse/index.ts; read that file first if this one is unclear.
//
// Route: the client always appends "audio/transcriptions" to its configured base URL, so the only
// path this function answers on is one ending in that suffix (locally
// "/groq/audio/transcriptions", behind the gateway "/functions/v1/groq/audio/transcriptions").
// Everything else is rejected; a correct path with a non-POST method is also rejected.
//
// Auth: `Authorization: Bearer <supabase access_token>`, verified by ../_shared/auth.ts's
// `verifyAccount` — the SAME function ../parse uses, so an invalid/missing credential gets the
// identical opaque rejection shape. StoreKit JWS is NOT sent on this (or any) request anymore —
// see ../_shared/appstore.ts's module doc comment for where that verification moved.
//
// Body: multipart/form-data passthrough to Groq's OpenAI-compatible endpoint, under a hard byte
// cap enforced BEFORE any buffering (never an unbounded read — see ../_shared/http.ts's
// `readBodyCappedBytes`). The `language` field (sent by the client when the user picked a specific
// locale in Settings' Recognition-language picker instead of "Automatic") is forwarded ONLY if
// it's a strict two-letter lowercase ISO-639-1 code (`/^[a-z]{2}$/`); anything else (missing, wrong
// shape, or a client trying to smuggle something else through this field) is dropped before
// forwarding. This is input from the client and therefore untrusted — validate the shape rather
// than passing it through blind.
//
// Credentials: this function NEVER forwards the caller's Authorization header upstream. It builds
// a brand-new request to Groq with `Authorization: Bearer ${GROQ_API_KEY}` read straight from
// `Deno.env.get` (Supabase Secrets) — the key never touches the client, never touches a log line,
// and the caller's credential is used only to pass `verifyAccount`, never reused past that point.
//
// Privacy: this file must never log audio bytes, filename (except behind `LOG_VERBOSE_BODIES`,
// see below), transcript text, or a raw user id — only sizes/counts/status/latency and a HASH of
// user_id, via ../_shared/log.ts + ../_shared/auth.ts's `hashUserId`. Groq's upstream error body
// (only on a non-2xx response, NEVER on 200 — a 200 body is the transcript) is logged truncated,
// unconditionally — that is Groq's own diagnostic message about our request, not user content, and
// is the deliberate, always-on exception documented in ../_shared/log.ts's module doc comment.
//
// Logging: every request gets a `reqId` (../_shared/log.ts's `newRequestId`) generated as the very
// first thing in the top-level `Deno.serve` handler, logged immediately via `logRequestStart`
// (point 1 of 3 — before ANY method/content-type/auth check, so an early-rejected request still
// leaves a trace), threaded through every log call in this file plus every `_shared/` helper that
// logs on this request's behalf (`verifyAccount`, `createServiceRoleClient`), wrapped around the
// Groq call via `logUpstreamRequest`/`logUpstreamResponse` (point 2), and guaranteed on every single
// return path via the local `finish()` closure, which calls `logRequestEnd` (point 3) exactly once
// per request no matter which branch returns.

import { requireEnv, readEnvInt } from "../_shared/env.ts";
import {
  errorDetails,
  logEvent,
  logError,
  logRequestEnd,
  logRequestStart,
  logUpstreamRequest,
  logUpstreamResponse,
  newRequestId,
  truncateForLog,
  verboseBodiesEnabled,
  type LogFields,
} from "../_shared/log.ts";
import { BodyTooLargeError, errorResponse, jsonResponse, readBodyCappedBytes } from "../_shared/http.ts";
import { createServiceRoleClient, hashUserId, verifyAccount } from "../_shared/auth.ts";
import { consumeQuota, speechLimitFor } from "../_shared/quota.ts";

/** Under Groq's own documented 25 MB request limit (see GroqTranscriptionClient.swift's
 *  `maxAudioBytes`) so an over-cap request never reaches upstream at all. Override without a
 *  redeploy via `GROQ_MAX_AUDIO_BYTES`. */
const DEFAULT_MAX_AUDIO_BYTES = 20 * 1024 * 1024;

/** Audio upload + transcription legitimately takes longer than a small JSON round trip (contrast
 *  ../_shared/gemini.ts's 20s default) — override via `GROQ_UPSTREAM_TIMEOUT_MS`. */
const DEFAULT_UPSTREAM_TIMEOUT_MS = 30000;

/** `GROQ_BASE_URL` is an operator-set Supabase secret, never caller input — overriding it is not
 *  an SSRF vector from the internet-facing side of this function, only a deployment config knob
 *  (e.g. pointing at a Groq-compatible mirror). A malformed value is still handled as a config
 *  error below, not allowed to throw past this function's error boundary. */
const DEFAULT_GROQ_BASE_URL = "https://api.groq.com/openai/v1";

Deno.serve(async (req) => {
  const startedAt = performance.now();
  const reqId = newRequestId();
  // Logged as the very first thing, before any method/content-type/auth check, so a request that
  // gets rejected in the next few lines still leaves a trace (log.ts's `logRequestStart` doc
  // comment explains why this ordering matters — it is what the lowercased-boundary bug needed and
  // didn't have).
  logRequestStart(req, reqId);

  try {
    return await handle(req, startedAt, reqId);
  } catch (err) {
    // Last-resort net: nothing above should throw uncaught, but if it does, never leak the
    // exception message to the client (opaque hardening requirement) and never let an unhandled
    // rejection crash the isolate without a response.
    logError("groq_unhandled_error", { reqId, ...errorDetails(err) });
    const res = errorResponse(503, "service_unavailable");
    logRequestEnd(res.status, performance.now() - startedAt, { reqId, reason: "unhandled_exception" });
    return res;
  }
});

async function handle(req: Request, startedAt: number, reqId: string): Promise<Response> {
  // Every return path in this function goes through `finish` so `logRequestEnd` (point 3 of the 3
  // required log points) fires exactly once, no matter which branch returns — including the early
  // routing/method/content-type rejections that used to return with no log line at all.
  const finish = (res: Response, fields: LogFields = {}): Response => {
    logRequestEnd(res.status, performance.now() - startedAt, { reqId, ...fields });
    return res;
  };

  // --- Strict routing: only a path ending in "/audio/transcriptions" is legitimate; everything
  // else is rejected before any auth/quota/upstream work happens. ---
  const { pathname } = new URL(req.url);
  if (!pathname.endsWith("/audio/transcriptions")) {
    return finish(errorResponse(404, "invalid_request"), { reason: "unknown_route" });
  }

  if (req.method === "OPTIONS") {
    return finish(new Response(null, { status: 204, headers: { allow: "POST, OPTIONS" } }), {
      reason: "cors_preflight",
    });
  }
  if (req.method !== "POST") {
    return finish(errorResponse(405, "invalid_request"), { reason: "wrong_method" });
  }

  // Keep the header EXACTLY as sent; only the media-type comparison is case-insensitive.
  //
  // This used to be `const contentType = (...).toLowerCase()`, and that lowercased string was then
  // reused verbatim as the content-type of the internal Request the multipart body is reparsed
  // through (see `reparsed` below) — which lowercased the BOUNDARY along with the media type.
  // Boundary matching is byte-exact, and the client's boundary is `volar-<UUID>` where Swift's
  // `UUID.uuidString` is uppercase, so the reparser looked for `--volar-e621e1f8…` in a body
  // delimited by `--volar-E621E1F8…`, found no parts, threw, and every single cloud-speech request
  // died as an unlogged `400 invalid_request`.
  const contentType = req.headers.get("content-type") ?? "";
  if (!contentType.toLowerCase().startsWith("multipart/form-data")) {
    return finish(errorResponse(415, "invalid_request"), { reason: "wrong_content_type" });
  }

  // --- Auth: any real account may authenticate. Any rejection here is the same opaque shape
  // ../parse uses. ---
  const authResult = await verifyAccount(req, reqId);
  if (!authResult.ok) {
    logEvent("groq_auth_rejected", {
      reqId,
      status: authResult.response.status,
      latencyMs: Math.round(performance.now() - startedAt),
    });
    return finish(authResult.response, { reason: "auth_rejected" });
  }
  const userIdHash = await hashUserId(authResult.userId);

  // --- Tier: both free and pro may call /groq now; only the daily limit differs (mirrors
  // ../parse's `parseLimitFor`). This must still run BEFORE any body work. ---
  const limit = speechLimitFor(authResult.tier);

  const supabase = createServiceRoleClient(reqId);
  if (!supabase) {
    return finish(errorResponse(503, "service_unavailable"), { reason: "service_role_client_unavailable" });
  }

  const now = new Date();
  let quotaUsed: number;
  try {
    const check = await consumeQuota(supabase, authResult.userId, "speech", limit, now);
    quotaUsed = check.used;
    if (!check.allowed) {
      logEvent("groq_request", {
        reqId,
        userIdHash,
        tier: authResult.tier,
        status: 429,
        quotaUsed: check.used,
        latencyMs: Math.round(performance.now() - startedAt),
      });
      return finish(jsonResponse(429, { error: "quota_exceeded", resetAt: check.resetAt }), {
        reason: "quota_exceeded",
      });
    }
  } catch (err) {
    logError("groq_quota_failure", {
      reqId,
      userIdHash,
      ...errorDetails(err),
      latencyMs: Math.round(performance.now() - startedAt),
    });
    return finish(errorResponse(503, "service_unavailable"), { reason: "quota_check_exception" });
  }

  const groqCfg = requireEnv(["GROQ_API_KEY"] as const);
  if (!groqCfg.ok) {
    // Opaque to the caller — never report *which* var is missing in the HTTP response, only in
    // the server-side log where it's useful to whoever owns the deployment.
    logError("groq_config_missing", { reqId, missingEnv: groqCfg.missing.join(",") });
    return finish(errorResponse(503, "service_unavailable"), { reason: "config_missing_groq_api_key" });
  }

  // --- Body size gate + read, only AFTER auth/tier/quota have all passed (contract §4 gate
  // order). `Content-Length` is checked as the fast-path reject; the real bound is the streaming
  // byte counter inside `readBodyCappedBytes`, which also protects against a missing/understated
  // header under chunked transfer-encoding. Missing header is treated the same as oversized — in
  // both cases we cannot safely bound the read, so we fail closed rather than trust an absent
  // hint. ---
  const maxAudioBytes = readEnvInt("GROQ_MAX_AUDIO_BYTES", DEFAULT_MAX_AUDIO_BYTES);
  const contentLengthHeader = req.headers.get("content-length");
  const declaredLength = contentLengthHeader ? Number.parseInt(contentLengthHeader, 10) : NaN;
  if (!contentLengthHeader || !Number.isFinite(declaredLength) || declaredLength > maxAudioBytes) {
    logEvent("groq_payload_rejected", {
      reqId,
      reason: "declared_content_length_over_cap_or_missing",
      contentLengthHeader: contentLengthHeader ?? "absent",
      maxAudioBytes,
    });
    return finish(errorResponse(413, "payload_too_large"), {
      reason: "declared_content_length_over_cap_or_missing",
    });
  }

  let rawBytes: Uint8Array;
  try {
    rawBytes = await readBodyCappedBytes(req, maxAudioBytes);
  } catch (err) {
    if (err instanceof BodyTooLargeError) {
      logEvent("groq_payload_rejected", { reqId, reason: "actual_body_over_cap", maxAudioBytes });
      return finish(errorResponse(413, "payload_too_large"), { reason: "actual_body_over_cap" });
    }
    logError("groq_body_read_failed", { reqId, ...errorDetails(err) });
    return finish(errorResponse(400, "invalid_request"), { reason: "body_read_failed" });
  }

  let form: FormData;
  try {
    // Reparsing via a fresh in-memory Request is the simplest correct multipart parser available
    // in this runtime (Fetch API's own boundary handling) without pulling in a dependency; the
    // body is already fully buffered and cap-checked by this point, so this does not reintroduce
    // an unbounded read.
    const reparsed = new Request("http://groq-proxy.internal/", {
      method: "POST",
      headers: { "content-type": contentType },
      // Wrapped in a Blob rather than passed as a raw Uint8Array: Deno's fetch-API BodyInit
      // typings don't accept ArrayBufferView directly even though the runtime does. Re-wrapping
      // in a fresh `Uint8Array` first (same trick as ../_shared/auth.ts's `sha256Hex`) copies the
      // bytes into a plain `ArrayBuffer`-backed view — a generic `Uint8Array<ArrayBufferLike>`
      // (which could be `SharedArrayBuffer`-backed) is not assignable to `BlobPart` under newer TS
      // lib.dom types, but a freshly constructed one is.
      body: new Blob([new Uint8Array(rawBytes)]),
    });
    form = await reparsed.formData();
  } catch (err) {
    // Logged because this branch is otherwise undiagnosable from either side: the client sees a
    // bare 400 and the server said nothing at all — which is exactly how the lowercased-boundary
    // bug above survived. `boundaryEcho` is the declared boundary only, never body content.
    logError("groq_multipart_parse_failed", {
      reqId,
      ...errorDetails(err),
      boundaryEcho: contentType.split("boundary=")[1] ?? "absent",
      bytes: rawBytes.byteLength,
    });
    return finish(errorResponse(400, "invalid_request"), { reason: "multipart_parse_failed" });
  }

  const file = form.get("file");
  if (!(file instanceof File)) {
    logError("groq_missing_file_part", { reqId, fields: [...form.keys()].join(",") });
    return finish(errorResponse(400, "invalid_request"), { reason: "missing_file_part" });
  }

  // Verbose-only: form-SHAPE metadata (field names, filename, content-type, byte count) — NEVER
  // the audio bytes themselves, under any configuration. Gated behind `LOG_VERBOSE_BODIES` so this
  // never fires in production by default (see ../_shared/log.ts module doc comment); `fileName` is
  // held back here specifically (not logged unconditionally like the other groq_request fields)
  // because a user-chosen filename can itself carry incidental personal content.
  if (verboseBodiesEnabled()) {
    logEvent("groq_request_body_verbose", {
      reqId,
      formFields: [...form.keys()].join(","),
      fileName: file.name,
      fileContentType: file.type,
      fileBytes: file.size,
    });
  }

  // Only a strict ISO-639-1 code passes through; anything else for this field is dropped rather
  // than forwarded blind.
  const isValidLanguageCode = (value: FormDataEntryValue): boolean =>
    typeof value === "string" && /^[a-z]{2}$/.test(value);

  const forwardForm = new FormData();
  for (const [key, value] of form.entries()) {
    if (key === "language" && !isValidLanguageCode(value)) continue;
    if (value instanceof File) {
      // Preserve the original filename: Groq's Whisper endpoint uses the extension to help
      // determine the audio container format.
      forwardForm.append(key, value, value.name);
    } else {
      forwardForm.append(key, value);
    }
  }

  const configuredBaseUrl = Deno.env.get("GROQ_BASE_URL") || DEFAULT_GROQ_BASE_URL;
  let upstreamUrl: string;
  try {
    const normalizedBase = configuredBaseUrl.endsWith("/") ? configuredBaseUrl : `${configuredBaseUrl}/`;
    upstreamUrl = new URL("audio/transcriptions", normalizedBase).toString();
  } catch (err) {
    logError("groq_config_invalid", { reqId, reason: "groq_base_url_unparseable", ...errorDetails(err) });
    return finish(errorResponse(503, "service_unavailable"), { reason: "groq_base_url_unparseable" });
  }

  const timeoutMs = readEnvInt("GROQ_UPSTREAM_TIMEOUT_MS", DEFAULT_UPSTREAM_TIMEOUT_MS);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  const upstreamStartedAt = performance.now();

  try {
    logUpstreamRequest("groq", upstreamUrl, "POST", { reqId, audioBytes: rawBytes.length });
    const upstreamRes = await fetch(upstreamUrl, {
      method: "POST",
      headers: {
        // Fresh credential built server-side from Deno.env (Supabase Secrets) — the caller's
        // Authorization header is never read again past verifyAccount above and is NEVER
        // forwarded upstream.
        authorization: `Bearer ${groqCfg.values.GROQ_API_KEY}`,
      },
      body: forwardForm,
      signal: controller.signal,
    });
    logUpstreamResponse("groq", upstreamRes.status, performance.now() - upstreamStartedAt, { reqId });

    if (upstreamRes.status === 429) {
      // Reading + logging the (truncated) error body here is a DELIBERATE, always-on exception to
      // the "never log body content" rule (see ../_shared/log.ts's `logUpstreamResponse` doc
      // comment): this is Groq's OWN diagnostic message about our request, not user content, and
      // without it a 429 is exactly as undiagnosable as the boundary bug this logging pass exists
      // to prevent. Never forwarded to our own HTTP client either way — the client still only ever
      // sees the opaque `429 rate_limited` below.
      const errorBodyText = await upstreamRes.text().catch(() => "");
      logEvent("groq_request", {
        reqId,
        userIdHash,
        tier: authResult.tier,
        status: 429,
        quotaUsed,
        audioBytes: rawBytes.length,
        errorBody: truncateForLog(errorBodyText, 500),
        latencyMs: Math.round(performance.now() - startedAt),
      });
      return finish(errorResponse(429, "rate_limited"), { reason: "upstream_rate_limited" });
    }

    if (!upstreamRes.ok) {
      // Same deliberate exception as the 429 branch above: log Groq's truncated error body, still
      // never forward it to our own client (every other non-2xx collapses to one opaque 502).
      const errorBodyText = await upstreamRes.text().catch(() => "");
      logError("groq_upstream_failure", {
        reqId,
        reason: "upstream_non_ok",
        status: upstreamRes.status,
        audioBytes: rawBytes.length,
        errorBody: truncateForLog(errorBodyText, 500),
        latencyMs: Math.round(performance.now() - startedAt),
      });
      return finish(errorResponse(502, "upstream_error"), { reason: "upstream_non_ok" });
    }

    let json: unknown;
    try {
      json = await upstreamRes.json();
    } catch (err) {
      // Safe to log this parse exception's own message — it describes the JSON SHAPE failure, not
      // the (200, i.e. actual transcript) body text, which is never logged here.
      logError("groq_upstream_invalid_json", {
        reqId,
        ...errorDetails(err),
        audioBytes: rawBytes.length,
        latencyMs: Math.round(performance.now() - startedAt),
      });
      return finish(errorResponse(502, "upstream_error"), { reason: "upstream_invalid_json" });
    }

    logEvent("groq_request", {
      reqId,
      userIdHash,
      tier: authResult.tier,
      status: 200,
      quotaUsed,
      audioBytes: rawBytes.length,
      latencyMs: Math.round(performance.now() - startedAt),
    });
    // Passed through verbatim on success — GroqTranscriptionClient.swift decodes
    // `{ text: string }`, the OpenAI-compatible shape Groq returns. Never logged: the transcript
    // text must not reach a log line (see ../_shared/log.ts module doc comment) — this is exactly
    // the 200 case the "never log an upstream 2xx body" rule protects.
    return finish(jsonResponse(200, json), { reason: "success" });
  } catch (err) {
    const timedOut = err instanceof Error && err.name === "AbortError";
    logError("groq_upstream_failure", {
      reqId,
      reason: timedOut ? "timeout" : "transport_error",
      ...errorDetails(err),
      audioBytes: rawBytes.length,
      latencyMs: Math.round(performance.now() - startedAt),
    });
    return finish(errorResponse(502, "upstream_error"), {
      reason: timedOut ? "timeout" : "transport_error",
    });
  } finally {
    clearTimeout(timer);
  }
}
