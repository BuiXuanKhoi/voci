// supabase/functions/parse/index.ts — Edge Function for POST /functions/v1/parse
//
// Implements specs/002-workflow-command-center/contracts/account-auth.md §3/§4. Read that file
// before changing status codes, field names, or gate order — this is one of two internet-facing
// surfaces of the product.
//
// Request shapes (validated in ../_shared/schema.ts):
//   parse mode (default):    { transcript, locale_hint?, now, open_task_titles? }
//   breakdown mode:          { mode: "breakdown", task_title, notes? }
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
} from "../_shared/schema.ts";
import {
  DEFAULT_PARSE_MODEL,
  SYSTEM_PREAMBLE,
  buildBreakdownContents,
  buildBreakdownResponseSchema,
  buildParseContents,
  buildParseResponseSchema,
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

    // mode === "breakdown"
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
