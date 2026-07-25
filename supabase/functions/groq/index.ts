// supabase/functions/groq/index.ts — Edge Function for POST /functions/v1/groq/audio/transcriptions
//
// Paid-only Groq Speech-to-Text proxy. See README.md in this directory for the product/architecture
// rationale and backlog.md's "CHỐT MÔ HÌNH FREEMIUM + BACKEND" section for the decision this
// implements: cloud speech (Groq Whisper) is Pro-only in the freemium matrix — unlike ../parse's
// cloud-parse route, there is NO free/App-Attest branch here. Structure, error shapes, and logging
// discipline deliberately mirror ../parse/index.ts; read that file first if this one is unclear.
//
// Route: the client (Volar/Sources/Speech/GroqTranscriptionClient.swift) always appends
// "audio/transcriptions" to its configured base URL, so the only path this function answers on is
// one ending in that suffix (locally "/groq/audio/transcriptions", behind the gateway
// "/functions/v1/groq/audio/transcriptions"). Everything else is 404; a correct path with a
// non-POST method is 405.
//
// Auth: exactly `Authorization: Bearer <StoreKit JWS>`, verified by ../_shared/auth.ts's
// `verifyPaidAuth` — the SAME function ../parse uses for its paid branch, so an invalid/missing
// credential gets the identical opaque rejection shape (no bespoke error text that could help an
// attacker distinguish "no header" from "bad JWS" from "expired transaction").
//
// Body: multipart/form-data passthrough to Groq's OpenAI-compatible endpoint, under a hard byte
// cap enforced BEFORE any buffering (never an unbounded read — see ../_shared/http.ts's
// `readBodyCappedBytes`). The `language` field, if a client ever sends one, is unconditionally
// stripped before forwarding — auto-detect (vi/en code-switching) is a product decision, not a
// client choice; see GroqTranscriptionClient.swift, which already omits this field by design, and
// treat this strip as defense-in-depth against a modified/malicious client.
//
// Credentials: this function NEVER forwards the caller's Authorization header upstream. It builds
// a brand-new request to Groq with `Authorization: Bearer ${GROQ_API_KEY}` read straight from
// `Deno.env.get` (Supabase Secrets) — the key never touches the client, never touches a log line,
// and the caller's credential is used only to pass verifyPaidAuth, never reused past that point.
//
// Privacy: this file must never log audio bytes, filename, or transcript text — only sizes/counts/
// status/latency, via ../_shared/log.ts (see that module's doc comment for why it's the only
// logger). Upstream error bodies are never read into a log line or forwarded to the client either
// — they could carry account/billing detail belonging to the Groq key's owner (us), not the caller.

import { createClient } from "npm:@supabase/supabase-js@2.110.6";
import { requireEnv, readEnvInt } from "../_shared/env.ts";
import { logEvent, logError } from "../_shared/log.ts";
import { BodyTooLargeError, errorResponse, jsonResponse, readBodyCappedBytes } from "../_shared/http.ts";
import { verifyPaidAuth } from "../_shared/auth.ts";
import { checkPaidRateLimit } from "../_shared/quota.ts";

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
    // exception message to the client (opaque 5xx hardening requirement) and never let an
    // unhandled rejection crash the isolate without a response.
    logError("groq_unhandled_error", {
      message: err instanceof Error ? err.name : "unknown",
      latencyMs: Math.round(performance.now() - startedAt),
    });
    return errorResponse(500, "internal_error");
  }
});

async function handle(req: Request, startedAt: number): Promise<Response> {
  // --- Strict routing (design decision 2): only a path ending in "/audio/transcriptions" is
  // legitimate; everything else is 404 before any auth/quota/upstream work happens. ---
  const { pathname } = new URL(req.url);
  if (!pathname.endsWith("/audio/transcriptions")) {
    return errorResponse(404, "not_found");
  }

  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: { allow: "POST, OPTIONS" } });
  }
  if (req.method !== "POST") {
    return errorResponse(405, "method_not_allowed");
  }

  const contentType = (req.headers.get("content-type") ?? "").toLowerCase();
  if (!contentType.startsWith("multipart/form-data")) {
    return errorResponse(415, "unsupported_media_type");
  }

  // --- Auth: paid-only, no free/App-Attest branch for this route (design decision 1). Any
  // rejection from verifyPaidAuth is already the opaque shape ../parse's paid branch uses. ---
  const authorizationHeader = req.headers.get("authorization");
  const authResult = await verifyPaidAuth(authorizationHeader);
  if (!authResult.ok) {
    logEvent("groq_auth_rejected", {
      status: authResult.response.status,
      latencyMs: Math.round(performance.now() - startedAt),
    });
    return authResult.response;
  }
  if (authResult.mode !== "paid") {
    // Unreachable in practice — verifyPaidAuth only ever resolves `mode: "paid"` on success — but
    // `AuthResult` is a shared type covering both auth.ts modes, so this keeps the type checker
    // honest (and the runtime fail-closed) without loosening that shared type just for this file.
    logError("groq_auth_mode_unexpected", { mode: authResult.mode });
    return errorResponse(500, "internal_error");
  }

  // --- Body size gate BEFORE any buffering (design decision 4). `Content-Length` is checked here
  // as the fast-path reject; the real bound is the streaming byte counter inside
  // `readBodyCappedBytes` further down, which also protects against a missing/understated header
  // under chunked transfer-encoding. Missing header is treated the same as oversized — in both
  // cases we cannot safely bound the read, so we fail closed rather than trust an absent hint. ---
  const maxAudioBytes = readEnvInt("GROQ_MAX_AUDIO_BYTES", DEFAULT_MAX_AUDIO_BYTES);
  const contentLengthHeader = req.headers.get("content-length");
  const declaredLength = contentLengthHeader ? Number.parseInt(contentLengthHeader, 10) : NaN;
  if (!contentLengthHeader || !Number.isFinite(declaredLength) || declaredLength > maxAudioBytes) {
    return errorResponse(413, "payload_too_large");
  }

  // --- Supabase service-role client for the atomic paid rate-limit RPC — same mechanism/table
  // ../parse's paid path uses (see ../_shared/quota.ts). ---
  const supabaseCfg = requireEnv(["SUPABASE_URL", "SUPABASE_SERVICE_ROLE_KEY"] as const);
  if (!supabaseCfg.ok) {
    // Opaque to the caller (info-leak hardening) — the specific missing keys are only useful to
    // whoever owns the deployment, never to an unauthenticated internet caller.
    logError("supabase_config_missing", { missingEnv: supabaseCfg.missing.join(",") });
    return errorResponse(503, "config_missing");
  }
  const supabase = createClient(supabaseCfg.values.SUPABASE_URL, supabaseCfg.values.SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });

  const now = new Date();
  let rpmCount: number;
  try {
    const check = await checkPaidRateLimit(supabase, authResult.rateLimitKeyHash, now);
    rpmCount = check.count;
    if (!check.allowed) {
      logEvent("groq_request", {
        status: 429,
        rpmCount: check.count,
        latencyMs: Math.round(performance.now() - startedAt),
      });
      return jsonResponse(429, { reason: "rate_limited", resetAt: check.resetAt });
    }
  } catch (err) {
    logError("groq_quota_failure", {
      message: err instanceof Error ? err.message : "unknown",
      latencyMs: Math.round(performance.now() - startedAt),
    });
    return errorResponse(500, "internal_error");
  }

  const groqCfg = requireEnv(["GROQ_API_KEY"] as const);
  if (!groqCfg.ok) {
    // Opaque to the caller (design decision 7) — never report *which* var is missing in the HTTP
    // response, only in the server-side log where it's useful to whoever owns the deployment.
    logError("groq_config_missing", { missingEnv: groqCfg.missing.join(",") });
    return errorResponse(503, "config_missing");
  }

  // --- Read the raw multipart body under the same hard byte cap already checked above (never an
  // unbounded read regardless of what Content-Length claimed), then reparse it as FormData so the
  // "language" field can be stripped before forwarding (design decision 6). ---
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

  const forwardForm = new FormData();
  for (const [key, value] of form.entries()) {
    if (key === "language") continue; // stripped unconditionally — see module doc comment
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
    return errorResponse(503, "config_missing");
  }

  const timeoutMs = readEnvInt("GROQ_UPSTREAM_TIMEOUT_MS", DEFAULT_UPSTREAM_TIMEOUT_MS);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);

  try {
    const upstreamRes = await fetch(upstreamUrl, {
      method: "POST",
      headers: {
        // Fresh credential built server-side from Deno.env (Supabase Secrets) — the caller's
        // Authorization header is never read again past verifyPaidAuth above and is NEVER
        // forwarded upstream (design decision 5: no client-credential passthrough).
        authorization: `Bearer ${groqCfg.values.GROQ_API_KEY}`,
      },
      body: forwardForm,
      signal: controller.signal,
    });

    if (upstreamRes.status === 429) {
      await upstreamRes.arrayBuffer().catch(() => {}); // drain; body never logged/forwarded
      logEvent("groq_request", {
        status: 429,
        rpmCount,
        audioBytes: rawBytes.length,
        latencyMs: Math.round(performance.now() - startedAt),
      });
      return errorResponse(429, "rate_limited");
    }

    if (!upstreamRes.ok) {
      // Never surface an upstream error body to the client or a log line — it could contain
      // account/billing detail belonging to the Groq key's owner (design decision 8). Every other
      // non-2xx (5xx, transport-adjacent 4xx we have no specific mapping for) collapses to one
      // opaque 502; only status code (not body) is logged.
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
      status: 200,
      rpmCount,
      audioBytes: rawBytes.length,
      latencyMs: Math.round(performance.now() - startedAt),
    });
    // Passed through verbatim on success (design decision 8) — GroqTranscriptionClient.swift
    // decodes `{ text: string }`, the OpenAI-compatible shape Groq returns. Never logged: the
    // transcript text must not reach a log line (see ../_shared/log.ts module doc comment).
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
