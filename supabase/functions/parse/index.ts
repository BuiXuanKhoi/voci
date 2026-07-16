// supabase/functions/parse/index.ts — Edge Function for POST /functions/v1/parse
//
// Implements contracts/parse-proxy.md (spec 002-workflow-command-center). Read that file before
// changing status codes or field names — this is the ONLY internet-facing surface of the product.
//
// Request shapes (validated in ../_shared/schema.ts):
//   parse mode (default):    { transcript, locale_hint?, now, open_task_titles? }
//   breakdown mode:          { mode: "breakdown", task_title, notes? }
// Auth (../_shared/auth.ts), exactly one required:
//   Authorization: Bearer <StoreKit JWS>   -> paid, unmetered, soft rate-limited
//   X-Device-Token: <App Attest token>     -> free, metered (daily counter)
//
// Privacy: this file must never log transcript/title/notes body text — only sizes/counts/status/
// latency, via ../_shared/log.ts (see that module's doc comment for why it's the only logger).

import { createClient } from "npm:@supabase/supabase-js@2.110.6";
import { requireEnv, readEnvInt } from "../_shared/env.ts";
import { logEvent, logError } from "../_shared/log.ts";
import { BodyTooLargeError, errorResponse, jsonResponse, readBodyCapped } from "../_shared/http.ts";
import { verifyPaidAuth, verifyFreeAuth } from "../_shared/auth.ts";
import { checkFreeQuota, checkPaidRateLimit } from "../_shared/quota.ts";
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
    // exception message to the client (opaque 5xx hardening requirement) and never let an
    // unhandled rejection crash the isolate without a response.
    logError("parse_unhandled_error", {
      message: err instanceof Error ? err.name : "unknown",
      latencyMs: Math.round(performance.now() - startedAt),
    });
    return errorResponse(500, "internal_error");
  }
});

async function handle(req: Request, startedAt: number): Promise<Response> {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: { allow: "POST, OPTIONS" } });
  }
  if (req.method !== "POST") {
    return errorResponse(405, "method_not_allowed");
  }

  const contentType = (req.headers.get("content-type") ?? "").toLowerCase();
  if (!contentType.startsWith("application/json")) {
    return errorResponse(415, "unsupported_media_type");
  }

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
    return errorResponse(400, "invalid_json");
  }

  const validated = validateRequestBody(parsedJson);
  if (!validated.ok) {
    return errorResponse(400, "invalid_request", { detail: validated.error });
  }
  const body = validated.value;

  // --- Auth: exactly one of the two headers, verified per ../_shared/auth.ts ---
  const authorizationHeader = req.headers.get("authorization");
  const deviceTokenHeader = req.headers.get("x-device-token");

  if (!authorizationHeader && !deviceTokenHeader) {
    return errorResponse(401, "auth_missing");
  }

  const authResult = authorizationHeader
    ? await verifyPaidAuth(authorizationHeader)
    : await verifyFreeAuth(deviceTokenHeader);

  if (!authResult.ok) {
    logEvent("parse_auth_rejected", {
      authMode: authorizationHeader ? "paid" : "free",
      status: authResult.response.status,
      latencyMs: Math.round(performance.now() - startedAt),
    });
    return authResult.response;
  }

  // --- Supabase service-role client (server-only; never the anon key) for the atomic RPC quota
  // counters. Required regardless of auth mode's metering, since paid mode is soft-rate-limited
  // through the same mechanism. ---
  const supabaseCfg = requireEnv(["SUPABASE_URL", "SUPABASE_SERVICE_ROLE_KEY"] as const);
  if (!supabaseCfg.ok) {
    return errorResponse(503, "config_missing", { missingEnv: supabaseCfg.missing });
  }
  const supabase = createClient(supabaseCfg.values.SUPABASE_URL, supabaseCfg.values.SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });

  const now = new Date();
  let quotaCount: number;
  try {
    if (authResult.mode === "free") {
      const check = await checkFreeQuota(supabase, authResult.quotaKeyHash, now);
      quotaCount = check.count;
      if (!check.allowed) {
        logEvent("parse_request", {
          authMode: "free",
          status: 429,
          quotaCount: check.count,
          latencyMs: Math.round(performance.now() - startedAt),
        });
        return jsonResponse(429, { reason: "quota", resetAt: check.resetAt });
      }
    } else {
      const check = await checkPaidRateLimit(supabase, authResult.rateLimitKeyHash, now);
      quotaCount = check.count;
      if (!check.allowed) {
        logEvent("parse_request", {
          authMode: "paid",
          status: 429,
          rpmCount: check.count,
          latencyMs: Math.round(performance.now() - startedAt),
        });
        // Contract only documents a "quota" reason for 429; paid soft-rate-limit reuses the same
        // shape so the client's existing 429 -> heuristic-fallback branch handles it unchanged.
        return jsonResponse(429, { reason: "quota", resetAt: check.resetAt });
      }
    }
  } catch (err) {
    logError("parse_quota_failure", {
      authMode: authResult.mode,
      message: err instanceof Error ? err.message : "unknown",
      latencyMs: Math.round(performance.now() - startedAt),
    });
    return errorResponse(500, "internal_error");
  }

  const geminiCfg = requireEnv(["GEMINI_API_KEY"] as const);
  if (!geminiCfg.ok) {
    return errorResponse(503, "config_missing", { missingEnv: geminiCfg.missing });
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
        logError("parse_output_invalid", { authMode: authResult.mode });
        return errorResponse(502, "upstream_error");
      }
      logEvent("parse_request", {
        authMode: authResult.mode,
        status: 200,
        mode: "parse",
        transcriptChars: body.transcript.length,
        openTaskTitleCount: body.openTaskTitles.length,
        taskCount: result.tasks.length,
        droppedCount: result.droppedCount,
        quotaCount,
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
      logError("parse_output_invalid", { authMode: authResult.mode, mode: "breakdown" });
      return errorResponse(502, "upstream_error");
    }
    logEvent("parse_request", {
      authMode: authResult.mode,
      status: 200,
      mode: "breakdown",
      taskTitleChars: body.taskTitle.length,
      stepCount: steps.length,
      quotaCount,
      latencyMs: Math.round(performance.now() - startedAt),
    });
    return jsonResponse(200, { steps });
  } catch (err) {
    // Covers GeminiUpstreamError (non-2xx, timeout, transport, malformed JSON text) and anything
    // else from this block. NEVER forward `err.message` — it may contain upstream response
    // fragments (see gemini.ts) — log only the error's class name.
    logError("parse_upstream_failure", {
      authMode: authResult.mode,
      errorType: err instanceof GeminiUpstreamError ? "gemini_upstream" : "unexpected",
      latencyMs: Math.round(performance.now() - startedAt),
    });
    return errorResponse(502, "upstream_error");
  }
}
