// supabase/functions/parse/index.ts — Edge Function for POST /functions/v1/parse
//
// Implements specs/002-workflow-command-center/contracts/account-auth.md §3/§4. Read that file
// before changing status codes, field names, or gate order — this is one of two internet-facing
// surfaces of the product.
//
// Request shapes (validated in ../_shared/schema.ts):
//   parse mode (default):    { transcript, locale_hint?, now, open_task_titles?, timezone? }
//     — `now` must already be the user's LOCAL wall-clock time with its real UTC offset (never
//     `Z`/UTC); `timezone` is an optional IANA id (e.g. "Asia/Ho_Chi_Minh") given as extra context
//     for the model on top of that offset. Older clients that don't send `timezone` still work.
//   breakdown mode:          { mode: "breakdown", task_title, notes?, source_transcript?,
//                              deadline?, existing_subtasks? }
//     — the four fields after `notes` are the OPTIONAL 2026-07-29 "richer context" addendum (see
//     `TaskContextFields` in `_shared/schema.ts`): older clients that never send them still work
//     exactly as before (fail-open request validation, see `validateTaskContextFields`).
//   resolve_completion mode: { mode: "resolve_completion", transcript, now, kind, candidates }
//     — server-side semantic match for "which open task is the user saying they finished",
//     since local Jaccard token-set matching on the client can't handle a paraphrase. Consumes
//     the SAME 'parse' quota route as the other two modes (see TASK brief / usage_counters'
//     CHECK constraint — only 'parse' and 'speech' are valid route values, no new one added).
//   stuck mode:              { mode: "stuck", reason: "too_big"|"dread", task_title, notes?,
//                              source_transcript?, deadline?, existing_subtasks? }
//     — "Stuck?" feature (anh Khôi, 2026-07-29): three different reasons a task doesn't get
//     started need three different responses; the third reason ("cant_start" — just can't get
//     moving) never reaches this server at all (client-only 2-minute timer, no model call). Same
//     'parse' quota route, same auth/tier gate as every other mode.
//       `reason: "too_big"` (REDESIGNED same day, after anh Khôi challenged the first version):
//       originally reused the breakdown machinery verbatim to produce a 3-9 step PLAN — rejected
//       because Volar has no real context beyond a short spoken title, so steps 3+ of a full plan
//       were fabrication dressed as advice. Now returns exactly ONE next physical action —
//       `buildNextActionContents`/`NEXT_ACTION_SYSTEM_PREAMBLE`/`buildNextActionResponseSchema`/
//       `validateNextActionMessage` — its OWN prompt/schema/validator/cap, NOT a reuse of
//       breakdown's. The full multi-step plan is still reachable via `mode: "breakdown"` /
//       `TaskBreakdownView` on the client; this reason just no longer produces one itself.
//       `reason: "dread"` is unchanged by that redesign: `buildDreadContents`/
//       `DREAD_SYSTEM_PREAMBLE`/`buildDreadResponseSchema`/`validateDreadMessage` (all in
//       `_shared/gemini.ts`+`_shared/schema.ts`) still produce ONE short message naming the
//       specific dreaded part of the task plus a <=2-minute physical action — see those symbols'
//       own doc comments for the full tone contract (no encouragement, no coaching, no diagnosis,
//       no exclamation marks, hard char cap).
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
// id in the default configuration — only sizes/counts/status/latency and a HASH of user_id, via
// ../_shared/log.ts + ../_shared/auth.ts's `hashUserId` (see that module's doc comment for why it's
// the only logger). The ONE opt-in exception is `LOG_VERBOSE_BODIES=1` (see ../_shared/log.ts's
// module doc comment) — MUST stay off in production.
//
// Logging: every request gets a `reqId` (../_shared/log.ts's `newRequestId`), logged immediately in
// the top-level `Deno.serve` handler via `logRequestStart` (point 1 of 3, before any method/
// content-type/auth check), threaded through every log call in this file plus every `_shared/`
// helper that logs on this request's behalf (`verifyAccount`, `createServiceRoleClient`,
// `callGemini`), wrapped around the Gemini call inside ../_shared/gemini.ts via
// `logUpstreamRequest`/`logUpstreamResponse` (point 2), and guaranteed on every return path via the
// local `finish()` closure, which calls `logRequestEnd` (point 3) exactly once per request.

import { requireEnv, readEnvInt } from "../_shared/env.ts";
import {
  errorDetails,
  logEvent,
  logError,
  logRequestEnd,
  logRequestStart,
  newRequestId,
  truncateForLog,
  verboseBodiesEnabled,
  type LogFields,
} from "../_shared/log.ts";
import { BodyTooLargeError, errorResponse, jsonResponse, readBodyCapped } from "../_shared/http.ts";
import { createServiceRoleClient, hashUserId, verifyAccount } from "../_shared/auth.ts";
import { consumeQuota, parseLimitFor } from "../_shared/quota.ts";
import {
  MAX_BODY_BYTES,
  validateBreakdownSteps,
  validateDreadMessage,
  validateNextActionMessage,
  validateParsedTaskArray,
  validateRequestBody,
  validateResolveCompletion,
  type ResolveCompletionOut,
} from "../_shared/schema.ts";
import {
  DEFAULT_PARSE_MODEL,
  DREAD_SYSTEM_PREAMBLE,
  NEXT_ACTION_SYSTEM_PREAMBLE,
  RESOLVE_COMPLETION_SYSTEM_PREAMBLE,
  SYSTEM_PREAMBLE,
  buildBreakdownContents,
  buildBreakdownResponseSchema,
  buildDreadContents,
  buildDreadResponseSchema,
  buildNextActionContents,
  buildNextActionResponseSchema,
  buildParseContents,
  buildParseResponseSchema,
  buildResolveCompletionContents,
  buildResolveCompletionResponseSchema,
  callGemini,
  GeminiUpstreamError,
} from "../_shared/gemini.ts";

Deno.serve(async (req) => {
  const startedAt = performance.now();
  const reqId = newRequestId();
  // Logged as the very first thing, before any method/content-type/auth check, so an early-rejected
  // request still leaves a trace (see ../_shared/log.ts's `logRequestStart` doc comment).
  logRequestStart(req, reqId);

  try {
    return await handle(req, startedAt, reqId);
  } catch (err) {
    // Last-resort net: nothing above should throw uncaught, but if it does, never leak the
    // exception message to the client (opaque hardening requirement) and never let an unhandled
    // rejection crash the isolate without a response.
    logError("parse_unhandled_error", { reqId, ...errorDetails(err) });
    const res = errorResponse(503, "service_unavailable");
    logRequestEnd(res.status, performance.now() - startedAt, { reqId, reason: "unhandled_exception" });
    return res;
  }
});

async function handle(req: Request, startedAt: number, reqId: string): Promise<Response> {
  // Every return path in this function goes through `finish` so `logRequestEnd` (point 3 of the 3
  // required log points) fires exactly once, no matter which branch returns — including the early
  // method/content-type rejections and validation failures that used to return with no log at all.
  const finish = (res: Response, fields: LogFields = {}): Response => {
    logRequestEnd(res.status, performance.now() - startedAt, { reqId, ...fields });
    return res;
  };

  if (req.method === "OPTIONS") {
    return finish(new Response(null, { status: 204, headers: { allow: "POST, OPTIONS" } }), {
      reason: "cors_preflight",
    });
  }
  if (req.method !== "POST") {
    return finish(errorResponse(405, "invalid_request"), { reason: "wrong_method" });
  }

  const contentType = (req.headers.get("content-type") ?? "").toLowerCase();
  if (!contentType.startsWith("application/json")) {
    return finish(errorResponse(415, "invalid_request"), { reason: "wrong_content_type" });
  }

  // --- AUTH first (contract §4 fix — body is read/validated further down, AFTER auth+quota). ---
  const authResult = await verifyAccount(req, reqId);
  if (!authResult.ok) {
    logEvent("parse_auth_rejected", {
      reqId,
      status: authResult.response.status,
      latencyMs: Math.round(performance.now() - startedAt),
    });
    return finish(authResult.response, { reason: "auth_rejected" });
  }
  const userIdHash = await hashUserId(authResult.userId);

  // --- Tier: both free and pro may call /parse; only the daily limit differs. ---
  const limit = parseLimitFor(authResult.tier);

  const supabase = createServiceRoleClient(reqId);
  if (!supabase) {
    return finish(errorResponse(503, "service_unavailable"), { reason: "service_role_client_unavailable" });
  }

  const now = new Date();
  let quotaUsed: number;
  try {
    const check = await consumeQuota(supabase, authResult.userId, "parse", limit, now);
    quotaUsed = check.used;
    if (!check.allowed) {
      logEvent("parse_request", {
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
    logError("parse_quota_failure", {
      reqId,
      userIdHash,
      ...errorDetails(err),
      latencyMs: Math.round(performance.now() - startedAt),
    });
    return finish(errorResponse(503, "service_unavailable"), { reason: "quota_check_exception" });
  }

  // --- Read & validate body only AFTER auth + quota have both passed. ---
  let rawBody: string;
  try {
    rawBody = await readBodyCapped(req, MAX_BODY_BYTES);
  } catch (err) {
    if (err instanceof BodyTooLargeError) {
      logEvent("parse_payload_rejected", { reqId, reason: "body_too_large" });
      return finish(errorResponse(413, "payload_too_large"), { reason: "body_too_large" });
    }
    logError("parse_body_read_failed", { reqId, ...errorDetails(err) });
    return finish(errorResponse(400, "invalid_request"), { reason: "body_read_failed" });
  }

  let parsedJson: unknown;
  try {
    parsedJson = JSON.parse(rawBody);
  } catch (err) {
    // Safe to log this parse exception's own message (e.g. "Unexpected token ... in JSON at
    // position 5") — that describes the SHAPE of the failure, never `rawBody` itself, which is
    // only ever logged (truncated) behind `LOG_VERBOSE_BODIES` further down.
    logError("parse_json_parse_failed", { reqId, ...errorDetails(err) });
    return finish(errorResponse(400, "invalid_request"), { reason: "json_parse_failed" });
  }

  const validated = validateRequestBody(parsedJson);
  if (!validated.ok) {
    // `validated.error` is a fixed, static description of which validation RULE failed (e.g.
    // "transcript exceeds 2000 chars") — it never echoes the offending value itself, so it is safe
    // to log unconditionally, unlike the body content it describes.
    logEvent("parse_validation_rejected", { reqId, reason: "validation_failed", detail: validated.error });
    return finish(errorResponse(400, "invalid_request"), { reason: "validation_failed" });
  }
  const body = validated.value;

  // Verbose-only: a truncated preview of the validated request body. Gated behind
  // `LOG_VERBOSE_BODIES` (see ../_shared/log.ts module doc comment) — this is the ONE place in this
  // route where transcript/task-title/notes content can reach a log line at all, and only when an
  // operator has deliberately opted in on a non-production deployment.
  if (verboseBodiesEnabled()) {
    logEvent("parse_request_body_verbose", {
      reqId,
      mode: body.mode,
      bodyPreview: truncateForLog(rawBody),
    });
  }

  const geminiCfg = requireEnv(["GEMINI_API_KEY"] as const);
  if (!geminiCfg.ok) {
    logError("gemini_config_missing", { reqId, missingEnv: geminiCfg.missing.join(",") });
    return finish(errorResponse(503, "service_unavailable"), { reason: "config_missing_gemini_api_key" });
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
        timezone: body.timezone,
      });
      const raw = await callGemini({
        apiKey: geminiCfg.values.GEMINI_API_KEY,
        model,
        systemInstruction: SYSTEM_PREAMBLE,
        contents,
        responseSchema: buildParseResponseSchema(),
        timeoutMs,
        reqId,
      });
      const result = validateParsedTaskArray(raw);
      if (!result) {
        logError("parse_output_invalid", { reqId, tier: authResult.tier, mode: "parse" });
        return finish(errorResponse(502, "upstream_error"), { reason: "model_output_invalid" });
      }
      logEvent("parse_request", {
        reqId,
        userIdHash,
        tier: authResult.tier,
        status: 200,
        mode: "parse",
        transcriptChars: body.transcript.length,
        openTaskTitleCount: body.openTaskTitles.length,
        hasTimezone: body.timezone !== undefined, // boolean only — never the raw value, see module doc comment
        taskCount: result.tasks.length,
        droppedCount: result.droppedCount,
        quotaUsed,
        latencyMs: Math.round(performance.now() - startedAt),
      });
      return finish(jsonResponse(200, result.tasks), { reason: "success" });
    }

    if (body.mode === "breakdown") {
      const contents = buildBreakdownContents({
        taskTitle: body.taskTitle,
        notes: body.notes,
        sourceTranscript: body.sourceTranscript,
        deadline: body.deadline,
        existingSubtasks: body.existingSubtasks,
      });
      const raw = await callGemini({
        apiKey: geminiCfg.values.GEMINI_API_KEY,
        model,
        systemInstruction: SYSTEM_PREAMBLE,
        contents,
        responseSchema: buildBreakdownResponseSchema(),
        timeoutMs,
        reqId,
      });
      const steps = validateBreakdownSteps(raw);
      if (!steps) {
        logError("parse_output_invalid", { reqId, tier: authResult.tier, mode: "breakdown" });
        return finish(errorResponse(502, "upstream_error"), { reason: "model_output_invalid" });
      }
      logEvent("parse_request", {
        reqId,
        userIdHash,
        tier: authResult.tier,
        status: 200,
        mode: "breakdown",
        taskTitleChars: body.taskTitle.length,
        // Booleans/counts only for the new context fields — never their content, same
        // "hasTimezone"-style convention `parse` mode already uses right above for the same reason.
        hasSourceTranscript: body.sourceTranscript !== undefined,
        hasDeadline: body.deadline !== undefined,
        existingSubtaskCount: body.existingSubtasks?.length ?? 0,
        stepCount: steps.length,
        quotaUsed,
        latencyMs: Math.round(performance.now() - startedAt),
      });
      return finish(jsonResponse(200, { steps }), { reason: "success" });
    }

    if (body.mode === "stuck") {
      if (body.reason === "too_big") {
        // REDESIGNED (anh Khôi, 2026-07-29, same day as the first version, after he challenged
        // it): no longer reuses breakdown's 3-9 step machinery — see `NEXT_ACTION_SYSTEM_PREAMBLE`'s
        // doc comment (`_shared/gemini.ts`) for why a full plan under near-zero context is
        // fabrication dressed as advice. This branch now asks for and validates exactly ONE next
        // physical action, its own prompt/schema/validator, symbol-for-symbol distinct from the
        // `breakdown` branch above.
        const contents = buildNextActionContents({
          taskTitle: body.taskTitle,
          notes: body.notes,
          sourceTranscript: body.sourceTranscript,
          deadline: body.deadline,
          existingSubtasks: body.existingSubtasks,
        });
        const raw = await callGemini({
          apiKey: geminiCfg.values.GEMINI_API_KEY,
          model,
          systemInstruction: NEXT_ACTION_SYSTEM_PREAMBLE,
          contents,
          responseSchema: buildNextActionResponseSchema(),
          timeoutMs,
          reqId,
        });
        const message = validateNextActionMessage(raw);
        if (!message) {
          logError("parse_output_invalid", { reqId, tier: authResult.tier, mode: "stuck", reason: "too_big" });
          return finish(errorResponse(502, "upstream_error"), { reason: "model_output_invalid" });
        }
        logEvent("parse_request", {
          reqId,
          userIdHash,
          tier: authResult.tier,
          status: 200,
          mode: "stuck",
          reason: "too_big",
          taskTitleChars: body.taskTitle.length,
          hasSourceTranscript: body.sourceTranscript !== undefined,
          hasDeadline: body.deadline !== undefined,
          existingSubtaskCount: body.existingSubtasks?.length ?? 0,
          // PRIVACY: never log `message` itself (model-generated text describing the user's own
          // task) — only its length, same convention `dread` below and every other body-content
          // field in this file already follows.
          messageChars: message.length,
          quotaUsed,
          latencyMs: Math.round(performance.now() - startedAt),
        });
        return finish(jsonResponse(200, { message }), { reason: "success" });
      }

      // body.reason === "dread" (the only other value `validateStuckRequest` accepts). UNCHANGED
      // prompt/schema/validator by the 2026-07-29 redesign above — only gains the same optional
      // context fields `breakdown`/`too_big` now also forward.
      const contents = buildDreadContents({
        taskTitle: body.taskTitle,
        notes: body.notes,
        sourceTranscript: body.sourceTranscript,
        deadline: body.deadline,
        existingSubtasks: body.existingSubtasks,
      });
      const raw = await callGemini({
        apiKey: geminiCfg.values.GEMINI_API_KEY,
        model,
        systemInstruction: DREAD_SYSTEM_PREAMBLE,
        contents,
        responseSchema: buildDreadResponseSchema(),
        timeoutMs,
        reqId,
      });
      const message = validateDreadMessage(raw);
      if (!message) {
        // Malformed/over-cap/empty output -> the SAME opaque 502 `breakdown`'s own invalid-output
        // path returns right above — the client's `dreadDetailed` (`CloudParser.swift`) already
        // treats any non-200 identically to "no suggestion available" (its own static fallback
        // sentence takes over), so this never reaches the user as raw/garbage content.
        logError("parse_output_invalid", { reqId, tier: authResult.tier, mode: "stuck", reason: "dread" });
        return finish(errorResponse(502, "upstream_error"), { reason: "model_output_invalid" });
      }
      logEvent("parse_request", {
        reqId,
        userIdHash,
        tier: authResult.tier,
        status: 200,
        mode: "stuck",
        reason: "dread",
        taskTitleChars: body.taskTitle.length,
        hasSourceTranscript: body.sourceTranscript !== undefined,
        hasDeadline: body.deadline !== undefined,
        existingSubtaskCount: body.existingSubtasks?.length ?? 0,
        // PRIVACY: never log `message` itself (it's model-generated text describing the user's
        // own task) — only its length, same convention `transcriptChars`/`taskTitleChars` follow
        // everywhere else in this file for user-authored/model-generated body content.
        messageChars: message.length,
        quotaUsed,
        latencyMs: Math.round(performance.now() - startedAt),
      });
      return finish(jsonResponse(200, { message }), { reason: "success" });
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
        reqId,
      });
      resolved = validateResolveCompletion(raw, body.candidates.length);
      if (!resolved) {
        // Gemini responded, but the JSON didn't pass validateResolveCompletion (bad intent, bad
        // confidence, out-of-range index, etc.) — distinct failure mode from the upstream-call
        // failure below, logged separately so operators can tell "model misbehaved" apart from
        // "upstream unreachable".
        logError("parse_output_invalid", { reqId, tier: authResult.tier, mode: "resolve_completion" });
      }
    } catch (err) {
      // Upstream failure (timeout/transport/non-2xx/malformed JSON) also folds into a safe
      // "none" 200 for the same reason as an invalid model response above — see comment there.
      // Still logged as a failure so operators can see upstream health; `err.message` is safe to
      // log here because every `GeminiUpstreamError` message is one of a small set of FIXED
      // literal strings this codebase writes (see ../_shared/gemini.ts), never a fragment of the
      // upstream response body itself.
      logError("parse_upstream_failure", {
        reqId,
        tier: authResult.tier,
        mode: "resolve_completion",
        errorType: err instanceof GeminiUpstreamError ? "gemini_upstream" : "unexpected",
        ...errorDetails(err),
        latencyMs: Math.round(performance.now() - startedAt),
      });
      resolved = undefined;
    }
    // PRIVACY: never log transcript, candidate titles, matchTitle, or any user id here — only
    // counts/status/latency + the hashed user id, matching every other log line in this route.
    const out: ResolveCompletionOut = resolved ?? { intent: "none", confidence: 0 };
    logEvent("parse_request", {
      reqId,
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
    return finish(jsonResponse(200, out), { reason: "success" });
  } catch (err) {
    // Covers GeminiUpstreamError (non-2xx, timeout, transport, malformed JSON text) and anything
    // else thrown from the `parse`/`breakdown` branches above (`resolve_completion` has its own
    // inner try/catch and never rethrows). `err.message` is safe to log — see the comment on the
    // `resolve_completion` catch above for why (fixed literal strings, never upstream body
    // fragments) — never forwarded to the HTTP client either way (opaque 502).
    logError("parse_upstream_failure", {
      reqId,
      tier: authResult.tier,
      errorType: err instanceof GeminiUpstreamError ? "gemini_upstream" : "unexpected",
      ...errorDetails(err),
      latencyMs: Math.round(performance.now() - startedAt),
    });
    return finish(errorResponse(502, "upstream_error"), { reason: "gemini_upstream_failure" });
  }
}
