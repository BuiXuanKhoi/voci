// supabase/functions/groq/index.ts — Edge Function for POST /functions/v1/groq/audio/transcriptions
//
// Pro-only Groq Speech-to-Text proxy. See README.md in this directory and
// specs/002-workflow-command-center/contracts/account-auth.md §1/§3 for the product/architecture
// rationale this implements: cloud speech (Groq Whisper) is Pro-only in the freemium matrix — free
// accounts get a `403 upgrade_required` and fall back to on-device WhisperKit, unlike ../parse
// (both tiers, different daily caps). Structure, error shapes, and logging discipline deliberately
// mirror ../parse/index.ts; read that file first if this one is unclear.
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
// Privacy: this file must never log audio bytes, filename, transcript text, or a raw user id —
// only sizes/counts/status/latency and a HASH of user_id, via ../_shared/log.ts + ../_shared/
// auth.ts's `hashUserId`. Upstream error bodies are never read into a log line or forwarded to the
// client either — they could carry account/billing detail belonging to the Groq key's owner (us),
// not the caller.

import { requireEnv, readEnvInt } from "../_shared/env.ts";
import { logEvent, logError } from "../_shared/log.ts";
import { BodyTooLargeError, errorResponse, jsonResponse, readBodyCappedBytes } from "../_shared/http.ts";
import { createServiceRoleClient, hashUserId, verifyAccount } from "../_shared/auth.ts";
import { consumeQuota, speechLimitForPro } from "../_shared/quota.ts";

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

  try {
    return await handle(req, startedAt);
  } catch (err) {
    // Last-resort net: nothing above should throw uncaught, but if it does, never leak the
    // exception message to the client (opaque hardening requirement) and never let an unhandled
    // rejection crash the isolate without a response.
    logError("groq_unhandled_error", {
      message: err instanceof Error ? err.name : "unknown",
      latencyMs: Math.round(performance.now() - startedAt),
    });
    return errorResponse(503, "service_unavailable");
  }
});

async function handle(req: Request, startedAt: number): Promise<Response> {
  // --- Strict routing: only a path ending in "/audio/transcriptions" is legitimate; everything
  // else is rejected before any auth/quota/upstream work happens. ---
  const { pathname } = new URL(req.url);
  if (!pathname.endsWith("/audio/transcriptions")) {
    return errorResponse(404, "invalid_request");
  }

  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: { allow: "POST, OPTIONS" } });
  }
  if (req.method !== "POST") {
    return errorResponse(405, "invalid_request");
  }

  const contentType = (req.headers.get("content-type") ?? "").toLowerCase();
  if (!contentType.startsWith("multipart/form-data")) {
    return errorResponse(415, "invalid_request");
  }

  // --- Auth: any real account may authenticate; tier is checked separately right below (a free
  // user's credential IS valid, it just isn't entitled to this route). Any rejection here is the
  // same opaque shape ../parse uses. ---
  const authResult = await verifyAccount(req);
  if (!authResult.ok) {
    logEvent("groq_auth_rejected", {
      status: authResult.response.status,
      latencyMs: Math.round(performance.now() - startedAt),
    });
    return authResult.response;
  }
  const userIdHash = await hashUserId(authResult.userId);

  // --- Tier gate: Pro-only route (contract §1/§3). Free tier -> 403 upgrade_required, client
  // falls back to on-device WhisperKit; this must happen BEFORE quota/body work. ---
  if (authResult.tier !== "pro") {
    logEvent("groq_upgrade_required", {
      userIdHash,
      latencyMs: Math.round(performance.now() - startedAt),
    });
    return errorResponse(403, "upgrade_required");
  }

  const supabase = createServiceRoleClient();
  if (!supabase) {
    return errorResponse(503, "service_unavailable");
  }

  const now = new Date();
  let quotaUsed: number;
  try {
    const limit = speechLimitForPro();
    const check = await consumeQuota(supabase, authResult.userId, "speech", limit, now);
    quotaUsed = check.used;
    if (!check.allowed) {
      logEvent("groq_request", {
        userIdHash,
        status: 429,
        quotaUsed: check.used,
        latencyMs: Math.round(performance.now() - startedAt),
      });
      return jsonResponse(429, { error: "quota_exceeded", resetAt: check.resetAt });
    }
  } catch (err) {
    logError("groq_quota_failure", {
      userIdHash,
      message: err instanceof Error ? err.message : "unknown",
      latencyMs: Math.round(performance.now() - startedAt),
    });
    return errorResponse(503, "service_unavailable");
  }

  const groqCfg = requireEnv(["GROQ_API_KEY"] as const);
  if (!groqCfg.ok) {
    // Opaque to the caller — never report *which* var is missing in the HTTP response, only in
    // the server-side log where it's useful to whoever owns the deployment.
    logError("groq_config_missing", { missingEnv: groqCfg.missing.join(",") });
    return errorResponse(503, "service_unavailable");
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
    return errorResponse(413, "payload_too_large");
  }

  let rawBytes: Uint8Array;
  try {
    rawBytes = await readBodyCappedBytes(req, maxAudioBytes);
  } catch (err) {
    if (err instanceof BodyTooLargeError) return errorResponse(413, "payload_too_large");
    return errorResponse(400, "invalid_request");
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
  } catch {
    return errorResponse(400, "invalid_request");
  }

  const file = form.get("file");
  if (!(file instanceof File)) {
    return errorResponse(400, "invalid_request");
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
  } catch {
    logError("groq_config_invalid", { reason: "groq_base_url_unparseable" });
    return errorResponse(503, "service_unavailable");
  }

  const timeoutMs = readEnvInt("GROQ_UPSTREAM_TIMEOUT_MS", DEFAULT_UPSTREAM_TIMEOUT_MS);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);

  try {
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

    if (upstreamRes.status === 429) {
      await upstreamRes.arrayBuffer().catch(() => {}); // drain; body never logged/forwarded
      logEvent("groq_request", {
        userIdHash,
        status: 429,
        quotaUsed,
        audioBytes: rawBytes.length,
        latencyMs: Math.round(performance.now() - startedAt),
      });
      return errorResponse(429, "rate_limited");
    }

    if (!upstreamRes.ok) {
      // Never surface an upstream error body to the client or a log line — it could contain
      // account/billing detail belonging to the Groq key's owner. Every other non-2xx (5xx,
      // transport-adjacent 4xx we have no specific mapping for) collapses to one opaque 502; only
      // status code (not body) is logged.
      await upstreamRes.arrayBuffer().catch(() => {});
      logError("groq_upstream_failure", {
        status: upstreamRes.status,
        audioBytes: rawBytes.length,
        latencyMs: Math.round(performance.now() - startedAt),
      });
      return errorResponse(502, "upstream_error");
    }

    let json: unknown;
    try {
      json = await upstreamRes.json();
    } catch {
      logError("groq_upstream_invalid_json", {
        audioBytes: rawBytes.length,
        latencyMs: Math.round(performance.now() - startedAt),
      });
      return errorResponse(502, "upstream_error");
    }

    logEvent("groq_request", {
      userIdHash,
      status: 200,
      quotaUsed,
      audioBytes: rawBytes.length,
      latencyMs: Math.round(performance.now() - startedAt),
    });
    // Passed through verbatim on success — GroqTranscriptionClient.swift decodes
    // `{ text: string }`, the OpenAI-compatible shape Groq returns. Never logged: the transcript
    // text must not reach a log line (see ../_shared/log.ts module doc comment).
    return jsonResponse(200, json);
  } catch (err) {
    const errorType = err instanceof Error && err.name === "AbortError" ? "timeout" : "transport";
    logError("groq_upstream_failure", {
      errorType,
      audioBytes: rawBytes.length,
      latencyMs: Math.round(performance.now() - startedAt),
    });
    return errorResponse(502, "upstream_error");
  } finally {
    clearTimeout(timer);
  }
}
