// supabase/functions/subscription/index.ts — Edge Function for the account/subscription routes
//
// Implements specs/002-workflow-command-center/contracts/account-auth.md §3:
//   POST /functions/v1/subscription/link            — attach/renew a Pro entitlement
//   GET  /functions/v1/subscription/status           — current tier + today's usage
//   POST /functions/v1/subscription/delete-account   — Apple Guideline 5.1.1(v) hard delete
//   POST /functions/v1/subscription/redeem           — redeem a shared promo code for 1 month Pro
//
// All four routes require account auth (../_shared/auth.ts's `verifyAccount`) — the same
// Supabase Auth bearer every /parse and /groq request carries. StoreKit JWS is NEVER a bearer
// credential; it is submitted as the BODY of `/link` only, verified by ../_shared/appstore.ts. A
// promo code is likewise never a bearer credential — it is submitted as the BODY of `/redeem`
// only, and is itself a secret worth one free month, so it is never logged (see `/redeem` below),
// under ANY configuration, not even `LOG_VERBOSE_BODIES` (see that flag's own doc comment in
// ../_shared/log.ts — the generic "log request bodies in verbose mode" behavior does NOT apply
// to this file's two secret-carrying bodies; see the verbose-mode log calls below for what is
// logged instead: field NAMES and value LENGTHS only, never the JWS/code value itself).
//
// Privacy: never log access tokens, JWS, promo codes, email, or a raw user id — only a HASH of
// user_id (see ../_shared/auth.ts's `hashUserId`), status, and counts, via ../_shared/log.ts.
//
// Logging: every request gets a `reqId` (../_shared/log.ts's `newRequestId`), logged immediately in
// the top-level `Deno.serve` handler via `logRequestStart` (point 1 of 3, before route dispatch),
// threaded through every log call in this file plus every `_shared/` helper that logs on this
// request's behalf (`verifyAccount`, `createServiceRoleClient`, `verifyAppStoreJWS`), wrapped
// around every outbound Supabase/App-Store-verification call via `logUpstreamRequest`/
// `logUpstreamResponse` (point 2), and guaranteed on every return path — including the dispatcher's
// own OPTIONS/404 branches — via `finish()` (built by `makeFinisher` below), which calls
// `logRequestEnd` (point 3) exactly once per request.

import {
  errorDetails,
  logEvent,
  logError,
  logRequestEnd,
  logRequestStart,
  logUpstreamRequest,
  logUpstreamResponse,
  newRequestId,
  verboseBodiesEnabled,
  type LogFields,
} from "../_shared/log.ts";
import { errorResponse, jsonResponse, readBodyCapped, BodyTooLargeError } from "../_shared/http.ts";
import { createServiceRoleClient, hashUserId, verifyAccount, type Tier } from "../_shared/auth.ts";
import { verifyAppStoreJWS } from "../_shared/appstore.ts";
import { parseLimitFor, readUsageToday, speechLimitFor } from "../_shared/quota.ts";

const MAX_LINK_BODY_BYTES = 8 * 1024; // a JWS is a few KB at most; generous headroom
const MAX_JWS_LENGTH = 8000;

const MAX_REDEEM_BODY_BYTES = 1024; // `{"code":"..."}` — a promo code is short, generous headroom
const MAX_CODE_LENGTH = 64;

/** Builds the `finish()` closure every handler in this file uses for its returns: it calls
 *  `logRequestEnd` (point 3 of the 3 required log points) exactly once per call, tagged with the
 *  same `reqId`/`startedAt` for the whole request, so `logRequestEnd` cannot be forgotten on any
 *  individual return statement — including the dispatcher's own OPTIONS/404 branches, which
 *  otherwise bypass every per-route handler entirely. */
function makeFinisher(reqId: string, startedAt: number): (res: Response, fields?: LogFields) => Response {
  return (res: Response, fields: LogFields = {}): Response => {
    logRequestEnd(res.status, performance.now() - startedAt, { reqId, ...fields });
    return res;
  };
}

Deno.serve(async (req) => {
  const startedAt = performance.now();
  const reqId = newRequestId();
  // Logged as the very first thing, before route dispatch, so an early-rejected request (unknown
  // route, wrong method) still leaves a trace.
  logRequestStart(req, reqId);

  try {
    return await handle(req, startedAt, reqId);
  } catch (err) {
    // Last-resort net: nothing above should throw uncaught, but if it does, never leak the
    // exception message to the client and never let an unhandled rejection crash the isolate
    // without a response.
    logError("subscription_unhandled_error", { reqId, ...errorDetails(err) });
    const res = errorResponse(503, "service_unavailable");
    logRequestEnd(res.status, performance.now() - startedAt, { reqId, reason: "unhandled_exception" });
    return res;
  }
});

function handle(req: Request, startedAt: number, reqId: string): Promise<Response> | Response {
  const { pathname } = new URL(req.url);
  const finish = makeFinisher(reqId, startedAt);

  if (req.method === "OPTIONS") {
    return finish(new Response(null, { status: 204, headers: { allow: "GET, POST, OPTIONS" } }), {
      reason: "cors_preflight",
    });
  }

  if (pathname.endsWith("/link") && req.method === "POST") {
    return handleLink(req, startedAt, reqId);
  }
  if (pathname.endsWith("/status") && req.method === "GET") {
    return handleStatus(req, startedAt, reqId);
  }
  if (pathname.endsWith("/delete-account") && req.method === "POST") {
    return handleDeleteAccount(req, startedAt, reqId);
  }
  if (pathname.endsWith("/redeem") && req.method === "POST") {
    return handleRedeem(req, startedAt, reqId);
  }

  return finish(errorResponse(404, "invalid_request"), { reason: "unknown_route" });
}

// -------------------------------------------------------------------------------------------
// POST /subscription/link
// -------------------------------------------------------------------------------------------

async function handleLink(req: Request, startedAt: number, reqId: string): Promise<Response> {
  const finish = makeFinisher(reqId, startedAt);

  const contentType = (req.headers.get("content-type") ?? "").toLowerCase();
  if (!contentType.startsWith("application/json")) {
    return finish(errorResponse(415, "invalid_request"), { reason: "wrong_content_type" });
  }

  const authResult = await verifyAccount(req, reqId);
  if (!authResult.ok) {
    logEvent("subscription_link_auth_rejected", {
      reqId,
      status: authResult.response.status,
      latencyMs: Math.round(performance.now() - startedAt),
    });
    return finish(authResult.response, { reason: "auth_rejected" });
  }
  const userIdHash = await hashUserId(authResult.userId);

  let rawBody: string;
  try {
    rawBody = await readBodyCapped(req, MAX_LINK_BODY_BYTES);
  } catch (err) {
    if (err instanceof BodyTooLargeError) {
      return finish(errorResponse(413, "payload_too_large"), { reason: "body_too_large" });
    }
    logError("subscription_link_body_read_failed", { reqId, ...errorDetails(err) });
    return finish(errorResponse(400, "invalid_request"), { reason: "body_read_failed" });
  }

  let parsedJson: unknown;
  try {
    parsedJson = JSON.parse(rawBody);
  } catch (err) {
    logError("subscription_link_json_parse_failed", { reqId, ...errorDetails(err) });
    return finish(errorResponse(400, "invalid_request"), { reason: "json_parse_failed" });
  }

  const jws = isPlainObject(parsedJson) ? parsedJson.jws : undefined;
  if (typeof jws !== "string" || jws.length === 0 || jws.length > MAX_JWS_LENGTH) {
    logEvent("subscription_link_body_rejected", { reqId, reason: "jws_shape_invalid" });
    return finish(errorResponse(400, "invalid_request"), { reason: "jws_shape_invalid" });
  }

  // Verbose-only, and DELIBERATELY NOT a truncated body preview like ../parse's equivalent: the
  // JWS is a secret credential (see module doc comment), so even under `LOG_VERBOSE_BODIES` this
  // logs only the field NAME and the value's LENGTH, never the value itself.
  if (verboseBodiesEnabled()) {
    logEvent("subscription_link_body_verbose", { reqId, bodyFields: "jws", jwsLength: jws.length });
  }

  const verifyStartedAt = performance.now();
  logUpstreamRequest("appstore_verify", "internal://app-store-server-library/verifyAndDecodeTransaction", "POST", {
    reqId,
  });
  const verified = await verifyAppStoreJWS(jws, reqId);
  logUpstreamResponse(
    "appstore_verify",
    verified.ok ? 200 : verified.status,
    performance.now() - verifyStartedAt,
    { reqId },
  );
  if (!verified.ok) {
    logEvent("subscription_link_verify_failed", {
      reqId,
      userIdHash,
      status: verified.status,
      latencyMs: Math.round(performance.now() - startedAt),
    });
    return finish(errorResponse(verified.status, verified.code), { reason: "jws_verify_failed" });
  }

  const supabase = createServiceRoleClient(reqId);
  if (!supabase) {
    return finish(errorResponse(503, "service_unavailable"), { reason: "service_role_client_unavailable" });
  }

  try {
    // Upsert keyed on the PK `(user_id, source)` — this route always writes the caller's `'apple'`
    // row (migration 0003_entitlements_multi_source.sql); it never touches a `'mor'` row belonging
    // to the same user, so a Windows/MoR entitlement can't be clobbered by a Mac/StoreKit link and
    // vice versa. `unique (source, external_id)` carries its OWN unique constraint that is NOT the
    // conflict target here, so if this Apple `originalTransactionId` already belongs to a DIFFERENT
    // user's `'apple'` row, Postgres raises a unique-violation (23505) and the whole statement
    // aborts atomically — no separate read-then-write race between "check who owns this id" and
    // "write the row". A renewal (same user, same originalTransactionId) hits the `(user_id,
    // source)` conflict target and simply updates that user's own row, which is never a violation
    // of `unique (source, external_id)` against itself.
    const dbStartedAt = performance.now();
    logUpstreamRequest("supabase_db", "postgrest://entitlements", "UPSERT", { reqId });
    const { error } = await supabase
      .from("entitlements")
      .upsert(
        {
          user_id: authResult.userId,
          source: "apple",
          external_id: verified.transaction.originalTransactionId,
          tier: "pro",
          product_id: verified.transaction.productId,
          expires_at: verified.transaction.expiresDate,
          updated_at: new Date().toISOString(),
        },
        { onConflict: "user_id,source" },
      );
    logUpstreamResponse("supabase_db", error ? 500 : 200, performance.now() - dbStartedAt, {
      reqId,
      errorCode: error?.code,
    });

    if (error) {
      if (error.code === "23505") {
        logEvent("subscription_link_conflict", {
          reqId,
          userIdHash,
          latencyMs: Math.round(performance.now() - startedAt),
        });
        return finish(errorResponse(409, "subscription_already_linked"), { reason: "entitlement_conflict" });
      }
      logError("subscription_link_upsert_failed", {
        reqId,
        userIdHash,
        message: error.message,
        errorCode: error.code,
        latencyMs: Math.round(performance.now() - startedAt),
      });
      return finish(errorResponse(503, "service_unavailable"), { reason: "entitlement_upsert_failed" });
    }
  } catch (err) {
    logError("subscription_link_exception", { reqId, userIdHash, ...errorDetails(err) });
    return finish(errorResponse(503, "service_unavailable"), { reason: "entitlement_upsert_exception" });
  }

  logEvent("subscription_link", {
    reqId,
    userIdHash,
    status: 200,
    latencyMs: Math.round(performance.now() - startedAt),
  });
  return finish(
    jsonResponse(200, {
      tier: "pro",
      expiresAt: verified.transaction.expiresDate,
      productId: verified.transaction.productId,
    }),
    { reason: "success" },
  );
}

// -------------------------------------------------------------------------------------------
// GET /subscription/status
// -------------------------------------------------------------------------------------------

async function handleStatus(req: Request, startedAt: number, reqId: string): Promise<Response> {
  const finish = makeFinisher(reqId, startedAt);

  const authResult = await verifyAccount(req, reqId);
  if (!authResult.ok) {
    logEvent("subscription_status_auth_rejected", {
      reqId,
      status: authResult.response.status,
      latencyMs: Math.round(performance.now() - startedAt),
    });
    return finish(authResult.response, { reason: "auth_rejected" });
  }
  const userIdHash = await hashUserId(authResult.userId);

  const supabase = createServiceRoleClient(reqId);
  if (!supabase) {
    return finish(errorResponse(503, "service_unavailable"), { reason: "service_role_client_unavailable" });
  }

  const now = new Date();
  const tier: Tier = authResult.tier;
  const parseLimit = parseLimitFor(tier);
  // Speech (Groq) is NO LONGER Pro-only as of 2026-07-27 — free accounts get a metered 20/day cap
  // (`SPEECH_LIMIT_FREE`) and Pro keeps 500 (`SPEECH_LIMIT_PRO`), the same two-tier shape `/parse`
  // has always had. This used to hardcode `0` for free, which is now a LIE the client would show
  // the user as "0 lượt" in Settings while `/groq` happily served them 20 — report the real cap.
  const speechLimit = speechLimitFor(tier);

  try {
    const parseStartedAt = performance.now();
    logUpstreamRequest("supabase_db", "postgrest://usage_counters", "SELECT", { reqId, route: "parse" });
    const parseUsedToday = await readUsageToday(supabase, authResult.userId, "parse", now);
    logUpstreamResponse("supabase_db", 200, performance.now() - parseStartedAt, { reqId, route: "parse" });

    // Read unconditionally now that both tiers can consume speech quota — the old `tier === "pro"`
    // short-circuit would report a free user's real usage as 0 forever.
    const speechStartedAt = performance.now();
    logUpstreamRequest("supabase_db", "postgrest://usage_counters", "SELECT", { reqId, route: "speech" });
    const speechUsedToday = await readUsageToday(supabase, authResult.userId, "speech", now);
    logUpstreamResponse("supabase_db", 200, performance.now() - speechStartedAt, { reqId, route: "speech" });

    logEvent("subscription_status", {
      reqId,
      userIdHash,
      tier,
      status: 200,
      latencyMs: Math.round(performance.now() - startedAt),
    });
    return finish(
      jsonResponse(200, {
        tier,
        // Same normalization as `/redeem` below, same reason: Postgres hands back microsecond
        // precision (`...06.01804+00:00`) and `ISO8601DateFormatter` + `.withFractionalSeconds` is
        // only documented for milliseconds. Both routes now emit the identical shape, so a client
        // can use ONE date parser for both — the previous mismatch (one route normalized, one not)
        // is exactly the kind of inconsistency that produces a parser that works until it doesn't.
        expiresAt: authResult.expiresAt ? new Date(authResult.expiresAt).toISOString() : null,
        parseUsedToday,
        parseLimit,
        speechUsedToday,
        speechLimit,
      }),
      { reason: "success" },
    );
  } catch (err) {
    logError("subscription_status_failure", {
      reqId,
      userIdHash,
      ...errorDetails(err),
      latencyMs: Math.round(performance.now() - startedAt),
    });
    return finish(errorResponse(503, "service_unavailable"), { reason: "usage_read_exception" });
  }
}

// -------------------------------------------------------------------------------------------
// POST /subscription/delete-account
// -------------------------------------------------------------------------------------------

async function handleDeleteAccount(req: Request, startedAt: number, reqId: string): Promise<Response> {
  const finish = makeFinisher(reqId, startedAt);

  const authResult = await verifyAccount(req, reqId);
  if (!authResult.ok) {
    logEvent("subscription_delete_auth_rejected", {
      reqId,
      status: authResult.response.status,
      latencyMs: Math.round(performance.now() - startedAt),
    });
    return finish(authResult.response, { reason: "auth_rejected" });
  }
  const userIdHash = await hashUserId(authResult.userId);

  const supabase = createServiceRoleClient(reqId);
  if (!supabase) {
    return finish(errorResponse(503, "service_unavailable"), { reason: "service_role_client_unavailable" });
  }

  try {
    // Hard delete via the admin API (service-role only). `entitlements` (migration 0003 — every row
    // for this user, across all sources) and `usage_counters` (migration 0002) both reference
    // `auth.users(id) on delete cascade`, so this alone removes every trace of the account across
    // all rows/tables in one operation — required by Apple Guideline 5.1.1(v), so this must
    // actually delete, never stub/soft-delete.
    const dbStartedAt = performance.now();
    logUpstreamRequest("supabase_auth_admin", "supabase_auth_admin://deleteUser", "POST", { reqId });
    const { error } = await supabase.auth.admin.deleteUser(authResult.userId);
    logUpstreamResponse("supabase_auth_admin", error ? 500 : 200, performance.now() - dbStartedAt, {
      reqId,
      errorCode: error?.code,
    });
    if (error) {
      logError("subscription_delete_failed", {
        reqId,
        userIdHash,
        message: error.message,
        errorCode: error.code,
        latencyMs: Math.round(performance.now() - startedAt),
      });
      return finish(errorResponse(503, "service_unavailable"), { reason: "delete_failed" });
    }
  } catch (err) {
    logError("subscription_delete_exception", { reqId, userIdHash, ...errorDetails(err) });
    return finish(errorResponse(503, "service_unavailable"), { reason: "delete_exception" });
  }

  logEvent("subscription_delete", {
    reqId,
    userIdHash,
    status: 200,
    latencyMs: Math.round(performance.now() - startedAt),
  });
  return finish(jsonResponse(200, { deleted: true }), { reason: "success" });
}

// -------------------------------------------------------------------------------------------
// POST /subscription/redeem
// -------------------------------------------------------------------------------------------

// These four codes are NOT in `../_shared/http.ts`'s `ApiErrorCode` union (that file is out of
// scope for this change — see this file's module doc comment) — `errorResponse` there is typed
// to reject anything outside that fixed list, so this route builds its own response bodies for
// its own new codes via the untyped `jsonResponse` instead. Existing shared codes
// (`invalid_request`, `auth_missing`, `auth_invalid`, `payload_too_large`, `service_unavailable`)
// still go through the shared `errorResponse` exactly like every other route in this file.
type RedeemErrorCode = "code_invalid" | "already_redeemed" | "code_exhausted" | "too_many_attempts";

function redeemErrorResponse(status: number, code: RedeemErrorCode): Response {
  return jsonResponse(status, { error: code });
}

interface RedeemRpcRow {
  status?: string;
  expires_at?: string | null;
  granted_days?: number | null;
}

async function handleRedeem(req: Request, startedAt: number, reqId: string): Promise<Response> {
  const finish = makeFinisher(reqId, startedAt);

  const contentType = (req.headers.get("content-type") ?? "").toLowerCase();
  if (!contentType.startsWith("application/json")) {
    return finish(errorResponse(415, "invalid_request"), { reason: "wrong_content_type" });
  }

  const authResult = await verifyAccount(req, reqId);
  if (!authResult.ok) {
    logEvent("subscription_redeem_auth_rejected", {
      reqId,
      status: authResult.response.status,
      latencyMs: Math.round(performance.now() - startedAt),
    });
    return finish(authResult.response, { reason: "auth_rejected" });
  }
  const userIdHash = await hashUserId(authResult.userId);

  let rawBody: string;
  try {
    rawBody = await readBodyCapped(req, MAX_REDEEM_BODY_BYTES);
  } catch (err) {
    if (err instanceof BodyTooLargeError) {
      return finish(errorResponse(413, "payload_too_large"), { reason: "body_too_large" });
    }
    logError("subscription_redeem_body_read_failed", { reqId, ...errorDetails(err) });
    return finish(errorResponse(400, "invalid_request"), { reason: "body_read_failed" });
  }

  let parsedJson: unknown;
  try {
    parsedJson = JSON.parse(rawBody);
  } catch (err) {
    logError("subscription_redeem_json_parse_failed", { reqId, ...errorDetails(err) });
    return finish(errorResponse(400, "invalid_request"), { reason: "json_parse_failed" });
  }

  // PRIVACY: `code` is a secret that grants a paid month — it must never appear in a log line or
  // an error response body from this point on, success or failure (module doc comment / task
  // privacy directive), under ANY configuration including `LOG_VERBOSE_BODIES`. Only its length is
  // ever inspected/logged here, never its value.
  const code = isPlainObject(parsedJson) ? parsedJson.code : undefined;
  if (typeof code !== "string" || code.length === 0 || code.length > MAX_CODE_LENGTH) {
    logEvent("subscription_redeem_body_rejected", { reqId, reason: "code_shape_invalid" });
    return finish(errorResponse(400, "invalid_request"), { reason: "code_shape_invalid" });
  }

  // Verbose-only, and DELIBERATELY NOT a truncated body preview like ../parse's equivalent — see
  // `handleLink`'s identical comment above for why: `code` is a secret, so only its field NAME and
  // value LENGTH are ever logged, never the value.
  if (verboseBodiesEnabled()) {
    logEvent("subscription_redeem_body_verbose", { reqId, bodyFields: "code", codeLength: code.length });
  }

  const supabase = createServiceRoleClient(reqId);
  if (!supabase) {
    return finish(errorResponse(503, "service_unavailable"), { reason: "service_role_client_unavailable" });
  }

  try {
    const dbStartedAt = performance.now();
    logUpstreamRequest("supabase_db", "postgrest://rpc/redeem_promo_code", "POST", { reqId });
    const { data, error } = await supabase.rpc("redeem_promo_code", {
      p_user: authResult.userId,
      p_code: code,
    });
    logUpstreamResponse("supabase_db", error ? 500 : 200, performance.now() - dbStartedAt, {
      reqId,
      errorCode: error?.code,
    });
    if (error) {
      logError("subscription_redeem_rpc_failed", {
        reqId,
        userIdHash,
        message: error.message,
        errorCode: error.code,
        latencyMs: Math.round(performance.now() - startedAt),
      });
      return finish(errorResponse(503, "service_unavailable"), { reason: "redeem_rpc_failed" });
    }

    // A `returns table(...)` RPC comes back through PostgREST as an array of rows — same shape
    // `../_shared/quota.ts`'s `consumeQuota` already unwraps for `consume_quota`.
    const row: RedeemRpcRow | undefined = Array.isArray(data) ? data[0] : data;
    const status = row?.status;

    switch (status) {
      case "ok": {
        logEvent("subscription_redeem", {
          reqId,
          userIdHash,
          status: "ok",
          latencyMs: Math.round(performance.now() - startedAt),
        });
        return finish(
          jsonResponse(200, {
            tier: "pro",
            // Normalized through `Date.toISOString()` (exactly 3 fractional digits, `Z` suffix)
            // rather than forwarded raw. Postgres hands back MICROsecond precision
            // (`2026-08-26T05:25:47.413004+00:00`), and the macOS client parses this with
            // `ISO8601DateFormatter` + `.withFractionalSeconds`, which is only documented to handle
            // MILLIseconds — a 6-digit fraction can fail to parse, and a nil date there means the
            // user redeems a real month of Pro and the confirmation silently shows nothing. Cheaper
            // to emit a format every client can read than to make each client defend against ours.
            expiresAt: row?.expires_at ? new Date(row.expires_at).toISOString() : null,
            grantedDays: row?.granted_days ?? null,
            source: "promo",
          }),
          { reason: "success" },
        );
      }
      case "invalid":
        logEvent("subscription_redeem_rejected", {
          reqId,
          userIdHash,
          status: "invalid",
          latencyMs: Math.round(performance.now() - startedAt),
        });
        return finish(redeemErrorResponse(404, "code_invalid"), { reason: "code_invalid" });
      case "already":
        logEvent("subscription_redeem_rejected", {
          reqId,
          userIdHash,
          status: "already",
          latencyMs: Math.round(performance.now() - startedAt),
        });
        return finish(redeemErrorResponse(409, "already_redeemed"), { reason: "already_redeemed" });
      case "exhausted":
        logEvent("subscription_redeem_rejected", {
          reqId,
          userIdHash,
          status: "exhausted",
          latencyMs: Math.round(performance.now() - startedAt),
        });
        return finish(redeemErrorResponse(410, "code_exhausted"), { reason: "code_exhausted" });
      case "rate_limited":
        logEvent("subscription_redeem_rejected", {
          reqId,
          userIdHash,
          status: "rate_limited",
          latencyMs: Math.round(performance.now() - startedAt),
        });
        return finish(redeemErrorResponse(429, "too_many_attempts"), { reason: "too_many_attempts" });
      default:
        // Unrecognized status from the RPC must map to 503, never to success — an unknown status
        // is treated as "something is wrong", not "assume ok".
        logError("subscription_redeem_unknown_status", {
          reqId,
          userIdHash,
          rpcStatus: status ?? "undefined",
          latencyMs: Math.round(performance.now() - startedAt),
        });
        return finish(errorResponse(503, "service_unavailable"), { reason: "unknown_rpc_status" });
    }
  } catch (err) {
    logError("subscription_redeem_exception", { reqId, userIdHash, ...errorDetails(err) });
    return finish(errorResponse(503, "service_unavailable"), { reason: "redeem_exception" });
  }
}

// -------------------------------------------------------------------------------------------

function isPlainObject(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}
