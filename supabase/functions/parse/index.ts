// supabase/functions/parse/index.ts — Edge Function for POST /functions/v1/parse
//
// Implements specs/002-workflow-command-center/contracts/account-auth.md §3/§4. Read that file
// before changing status codes, field names, or gate order — this is one of two internet-facing
// surfaces of the product.
//
// Request shapes (validated in ../_shared/schema.ts):
//   parse mode (default):    { transcript, locale_hint?, now, open_task_titles? }
//   breakdown mode:          { mode: "breakdown", task_title, notes? }
//   resolve_completion mode: { mode: "resolve_completion", transcript, now, kind, candidates }
//     — server-side semantic match for "which open task is the user saying they finished",
//     since local Jaccard token-set matching on the client can't handle a paraphrase. Consumes
//     the SAME 'parse' quota route as the other two modes (see TASK brief / usage_counters'
//     CHECK constraint — only 'parse' and 'speech' are valid route values, no new one added).
// Auth (../_shared/auth.ts): `Authorization: Bearer <supabase access_token>` — a real user
// account, verified via `verifyAccount`. Both tiers may call this route; only the daily quota
// limit differs (`PARSE_LIMIT_FREE` / `PARSE_LIMIT_PRO`).
//
// Gate order (contract §4 — FIXED defect: this route used to call `validateRequestBody` BEFORE
// authenticating, letting an unauthenticated caller probe the validation schema; the old
// constraint forcing body-reads before auth no longer exists now that App Attest — which needed
// the raw body to bind `clientDataHash` — is gone):
//   route -> method -> content-type -> AUTH -> tier -> quota (atomic) -> read & validate body ->
//   upstream
//
// Privacy: this file must never log transcript/title/notes body text, access tokens, or a raw user
// id — only sizes/counts/status/latency and a HASH of user_id, via ../_shared/log.ts +
// ../_shared/auth.ts's `hashUserId` (see that module's doc comment for why it's the only logger).

import { requireEnv, readEnvInt } from "../_shared/env.ts";
import { logEvent, logError } from "../_shared/log.ts";
import { BodyTooLargeError, errorResponse, jsonResponse, readBodyCapped } from "../_shared/http.ts";
import { createServiceRoleClient, hashUserId, verifyAccount } from "../_shared/auth.ts";
import { consumeQuota, parseLimitFor } from "../_shared/quota.ts";
import {
  MAX_BODY_BYTES,
  validateBreakdownSteps,
  validateParsedTaskArray,
  validateRequestBody,
  validateResolveCompletion,
  type ResolveCompletionOut,
} from "../_shared/schema.ts";
import {
  DEFAULT_PARSE_MODEL,
  RESOLVE_COMPLETION_SYSTEM_PREAMBLE,
  SYSTEM_PREAMBLE,
  buildBreakdownContents,
  buildBreakdownResponseSchema,
  buildParseContents,
  buildParseResponseSchema,
  buildResolveCompletionContents,
  buildResolveCompletionResponseSchema,
  callGemini,
  GeminiUpstreamError,
} from "../_shared/gemini.ts";

Deno.serve(async (req) => {
  const startedAt = performance.now();

  try {
    return await handle(req, startedAt);
  } catch (err) {
    // Last-resort net: nothing above should throw uncaught, but if it does, never leak the
    // exception message to the client (opaque hardening requirement) and never let an unhandled
    // rejection crash the isolate without a response.
    logError("parse_unhandled_error", {
      message: err instanceof Error ? err.name : "unknown",
      latencyMs: Math.round(performance.now() - startedAt),
    });
    return errorResponse(503, "service_unavailable");
  }
});

async function handle(req: Request, startedAt: number): Promise<Response> {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: { allow: "POST, OPTIONS" } });
  }
  if (req.method !== "POST") {
    return errorResponse(405, "invalid_request");
  }

  const contentType = (req.headers.get("content-type") ?? "").toLowerCase();
  if (!contentType.startsWith("application/json")) {
    return errorResponse(415, "invalid_request");
  }

  // --- AUTH first (contract §4 fix — body is read/validated further down, AFTER auth+quota). ---
  const authResult = await verifyAccount(req);
  if (!authResult.ok) {
    logEvent("parse_auth_rejected", {
      status: authResult.response.status,
      latencyMs: Math.round(performance.now() - startedAt),
    });
    return authResult.response;
  }
  const userIdHash = await hashUserId(authResult.userId);

  // --- Tier: both free and pro may call /parse; only the daily limit differs. ---
  const limit = parseLimitFor(authResult.tier);

  const supabase = createServiceRoleClient();
  if (!supabase) {
    return errorResponse(503, "service_unavailable");
  }

  const now = new Date();
  let quotaUsed: number;
  try {
    const check = await consumeQuota(supabase, authResult.userId, "parse", limit, now);
    quotaUsed = check.used;
    if (!check.allowed) {
      logEvent("parse_request", {
        userIdHash,
        tier: authResult.tier,
        status: 429,
        quotaUsed: check.used,
        latencyMs: Math.round(performance.now() - startedAt),
      });
      return jsonResponse(429, { error: "quota_exceeded", resetAt: check.resetAt });
    }
  } catch (err) {
    logError("parse_quota_failure", {
      userIdHash,
      message: err instanceof Error ? err.message : "unknown",
      latencyMs: Math.round(performance.now() - startedAt),
    });
    return errorResponse(503, "service_unavailable");
  }

  // --- Read & validate body only AFTER auth + quota have both passed. ---
  let rawBody: string;
  try {
    rawBody = await readBodyCapped(req, MAX_BODY_BYTES);
  } catch (err) {
    if (err instanceof BodyTooLargeError) return errorResponse(413, "payload_too_large");
    return errorResponse(400, "invalid_request");
  }

  let parsedJson: unknown;
  try {
    parsedJson = JSON.parse(rawBody);
  } catch {
    return errorResponse(400, "invalid_request");
  }

  const validated = validateRequestBody(parsedJson);
  if (!validated.ok) {
    return errorResponse(400, "invalid_request");
  }
  const body = validated.value;

  const geminiCfg = requireEnv(["GEMINI_API_KEY"] as const);
  if (!geminiCfg.ok) {
    logError("gemini_config_missing", { missingEnv: geminiCfg.missing.join(",") });
    return errorResponse(503, "service_unavailable");
  }
  const model = Deno.env.get("PARSE_MODEL") || DEFAULT_PARSE_MODEL;
  const timeoutMs = readEnvInt("PARSE_UPSTREAM_TIMEOUT_MS", 20000);

  try {
    if (body.mode === "parse") {
      const contents = buildParseContents({
        transcript: body.transcript,
        localeHint: body.localeHint,
        now: body.now,
        openTaskTitles: body.openTaskTitles,
      });
      const raw = await callGemini({
        apiKey: geminiCfg.values.GEMINI_API_KEY,
        model,
        systemInstruction: SYSTEM_PREAMBLE,
        contents,
        responseSchema: buildParseResponseSchema(),
        timeoutMs,
      });
      const result = validateParsedTaskArray(raw);
      if (!result) {
        logError("parse_output_invalid", { tier: authResult.tier });
        return errorResponse(502, "upstream_error");
      }
      logEvent("parse_request", {
        userIdHash,
        tier: authResult.tier,
        status: 200,
        mode: "parse",
        transcriptChars: body.transcript.length,
        openTaskTitleCount: body.openTaskTitles.length,
        taskCount: result.tasks.length,
        droppedCount: result.droppedCount,
        quotaUsed,
        latencyMs: Math.round(performance.now() - startedAt),
      });
      return jsonResponse(200, result.tasks);
    }

    if (body.mode === "breakdown") {
      const contents = buildBreakdownContents({ taskTitle: body.taskTitle, notes: body.notes });
      const raw = await callGemini({
        apiKey: geminiCfg.values.GEMINI_API_KEY,
        model,
        systemInstruction: SYSTEM_PREAMBLE,
        contents,
        responseSchema: buildBreakdownResponseSchema(),
        timeoutMs,
      });
      const steps = validateBreakdownSteps(raw);
      if (!steps) {
        logError("parse_output_invalid", { tier: authResult.tier, mode: "breakdown" });
        return errorResponse(502, "upstream_error");
      }
      logEvent("parse_request", {
        userIdHash,
        tier: authResult.tier,
        status: 200,
        mode: "breakdown",
        taskTitleChars: body.taskTitle.length,
        stepCount: steps.length,
        quotaUsed,
        latencyMs: Math.round(performance.now() - startedAt),
      });
      return jsonResponse(200, { steps });
    }

    // mode === "resolve_completion" — see module doc comment. Unlike `parse`/`breakdown`, an
    // invalid/unparseable model response maps to a well-formed 200 `{ intent: "none", confidence:
    // 0 }` rather than a 502: the client's fallback behavior for "none" and for "server broke" is
    // identical (leave it to the user to complete the task by hand), so collapsing them into one
    // response shape keeps the client's handling simple, and it avoids burning a 5xx-triggered
    // retry loop on what is, from the client's perspective, a completely benign "no match found".
    const contents = buildResolveCompletionContents({
      transcript: body.transcript,
      now: body.now,
      kind: body.kind,
      candidates: body.candidates,
    });
    let resolved: ReturnType<typeof validateResolveCompletion>;
    try {
      const raw = await callGemini({
        apiKey: geminiCfg.values.GEMINI_API_KEY,
        model,
        systemInstruction: RESOLVE_COMPLETION_SYSTEM_PREAMBLE,
        contents,
        responseSchema: buildResolveCompletionResponseSchema(),
        timeoutMs,
      });
      resolved = validateResolveCompletion(raw, body.candidates.length);
      if (!resolved) {
        // Gemini responded, but the JSON didn't pass validateResolveCompletion (bad intent, bad
        // confidence, out-of-range index, etc.) — distinct failure mode from the upstream-call
        // failure below, logged separately so operators can tell "model misbehaved" apart from
        // "upstream unreachable".
        logError("parse_output_invalid", { tier: authResult.tier, mode: "resolve_completion" });
      }
    } catch (err) {
      // Upstream failure (timeout/transport/non-2xx/malformed JSON) also folds into a safe
      // "none" 200 for the same reason as an invalid model response above — see comment there.
      // Still logged as a failure (via the errorType below) so operators can see upstream health.
      logError("parse_upstream_failure", {
        tier: authResult.tier,
        mode: "resolve_completion",
        errorType: err instanceof GeminiUpstreamError ? "gemini_upstream" : "unexpected",
        latencyMs: Math.round(performance.now() - startedAt),
      });
      resolved = undefined;
    }
    // PRIVACY: never log transcript, candidate titles, matchTitle, or any user id here — only
    // counts/status/latency + the hashed user id, matching every other log line in this route.
    const out: ResolveCompletionOut = resolved ?? { intent: "none", confidence: 0 };
    logEvent("parse_request", {
      userIdHash,
      tier: authResult.tier,
      status: 200,
      mode: "resolve_completion",
      kind: body.kind,
      transcriptChars: body.transcript.length,
      candidateCount: body.candidates.length,
      intent: out.intent,
      quotaUsed,
      latencyMs: Math.round(performance.now() - startedAt),
    });
    return jsonResponse(200, out);
  } catch (err) {
    // Covers GeminiUpstreamError (non-2xx, timeout, transport, malformed JSON text) and anything
    // else from this block. NEVER forward `err.message` — it may contain upstream response
    // fragments (see gemini.ts) — log only the error's class name.
    logError("parse_upstream_failure", {
      tier: authResult.tier,
      errorType: err instanceof GeminiUpstreamError ? "gemini_upstream" : "unexpected",
      latencyMs: Math.round(performance.now() - startedAt),
    });
    return errorResponse(502, "upstream_error");
  }
}
