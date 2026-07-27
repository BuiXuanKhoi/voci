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
// only, and is itself a secret worth one free month, so it is never logged (see `/redeem` below).
//
// Privacy: never log access tokens, JWS, promo codes, email, or a raw user id — only a HASH of
// user_id (see ../_shared/auth.ts's `hashUserId`), status, and counts, via ../_shared/log.ts.

import { logEvent, logError } from "../_shared/log.ts";
import { errorResponse, jsonResponse, readBodyCapped, BodyTooLargeError } from "../_shared/http.ts";
import { createServiceRoleClient, hashUserId, verifyAccount, type Tier } from "../_shared/auth.ts";
import { verifyAppStoreJWS } from "../_shared/appstore.ts";
import { parseLimitFor, readUsageToday, speechLimitFor } from "../_shared/quota.ts";

const MAX_LINK_BODY_BYTES = 8 * 1024; // a JWS is a few KB at most; generous headroom
const MAX_JWS_LENGTH = 8000;

const MAX_REDEEM_BODY_BYTES = 1024; // `{"code":"..."}` — a promo code is short, generous headroom
const MAX_CODE_LENGTH = 64;

Deno.serve(async (req) => {
  const startedAt = performance.now();

  try {
    return await handle(req, startedAt);
  } catch (err) {
    // Last-resort net: nothing above should throw uncaught, but if it does, never leak the
    // exception message to the client and never let an unhandled rejection crash the isolate
    // without a response.
    logError("subscription_unhandled_error", {
      message: err instanceof Error ? err.name : "unknown",
      latencyMs: Math.round(performance.now() - startedAt),
    });
    return errorResponse(503, "service_unavailable");
  }
});

function handle(req: Request, startedAt: number): Promise<Response> | Response {
  const { pathname } = new URL(req.url);

  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: { allow: "GET, POST, OPTIONS" } });
  }

  if (pathname.endsWith("/link") && req.method === "POST") {
    return handleLink(req, startedAt);
  }
  if (pathname.endsWith("/status") && req.method === "GET") {
    return handleStatus(req, startedAt);
  }
  if (pathname.endsWith("/delete-account") && req.method === "POST") {
    return handleDeleteAccount(req, startedAt);
  }
  if (pathname.endsWith("/redeem") && req.method === "POST") {
    return handleRedeem(req, startedAt);
  }

  return errorResponse(404, "invalid_request");
}

// -------------------------------------------------------------------------------------------
// POST /subscription/link
// -------------------------------------------------------------------------------------------

async function handleLink(req: Request, startedAt: number): Promise<Response> {
  const contentType = (req.headers.get("content-type") ?? "").toLowerCase();
  if (!contentType.startsWith("application/json")) {
    return errorResponse(415, "invalid_request");
  }

  const authResult = await verifyAccount(req);
  if (!authResult.ok) {
    logEvent("subscription_link_auth_rejected", {
      status: authResult.response.status,
      latencyMs: Math.round(performance.now() - startedAt),
    });
    return authResult.response;
  }
  const userIdHash = await hashUserId(authResult.userId);

  let rawBody: string;
  try {
    rawBody = await readBodyCapped(req, MAX_LINK_BODY_BYTES);
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

  const jws = isPlainObject(parsedJson) ? parsedJson.jws : undefined;
  if (typeof jws !== "string" || jws.length === 0 || jws.length > MAX_JWS_LENGTH) {
    return errorResponse(400, "invalid_request");
  }

  const verified = await verifyAppStoreJWS(jws);
  if (!verified.ok) {
    logEvent("subscription_link_verify_failed", {
      userIdHash,
      status: verified.status,
      latencyMs: Math.round(performance.now() - startedAt),
    });
    return errorResponse(verified.status, verified.code);
  }

  const supabase = createServiceRoleClient();
  if (!supabase) {
    return errorResponse(503, "service_unavailable");
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

    if (error) {
      if (error.code === "23505") {
        logEvent("subscription_link_conflict", {
          userIdHash,
          latencyMs: Math.round(performance.now() - startedAt),
        });
        return errorResponse(409, "subscription_already_linked");
      }
      logError("subscription_link_upsert_failed", {
        userIdHash,
        message: error.message,
        latencyMs: Math.round(performance.now() - startedAt),
      });
      return errorResponse(503, "service_unavailable");
    }
  } catch (err) {
    logError("subscription_link_exception", {
      userIdHash,
      message: err instanceof Error ? err.name : "unknown",
      latencyMs: Math.round(performance.now() - startedAt),
    });
    return errorResponse(503, "service_unavailable");
  }

  logEvent("subscription_link", {
    userIdHash,
    status: 200,
    latencyMs: Math.round(performance.now() - startedAt),
  });
  return jsonResponse(200, {
    tier: "pro",
    expiresAt: verified.transaction.expiresDate,
    productId: verified.transaction.productId,
  });
}

// -------------------------------------------------------------------------------------------
// GET /subscription/status
// -------------------------------------------------------------------------------------------

async function handleStatus(req: Request, startedAt: number): Promise<Response> {
  const authResult = await verifyAccount(req);
  if (!authResult.ok) {
    logEvent("subscription_status_auth_rejected", {
      status: authResult.response.status,
      latencyMs: Math.round(performance.now() - startedAt),
    });
    return authResult.response;
  }
  const userIdHash = await hashUserId(authResult.userId);

  const supabase = createServiceRoleClient();
  if (!supabase) {
    return errorResponse(503, "service_unavailable");
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
    const parseUsedToday = await readUsageToday(supabase, authResult.userId, "parse", now);
    // Read unconditionally now that both tiers can consume speech quota — the old `tier === "pro"`
    // short-circuit would report a free user's real usage as 0 forever.
    const speechUsedToday = await readUsageToday(supabase, authResult.userId, "speech", now);

    logEvent("subscription_status", {
      userIdHash,
      tier,
      status: 200,
      latencyMs: Math.round(performance.now() - startedAt),
    });
    return jsonResponse(200, {
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
    });
  } catch (err) {
    logError("subscription_status_failure", {
      userIdHash,
      message: err instanceof Error ? err.message : "unknown",
      latencyMs: Math.round(performance.now() - startedAt),
    });
    return errorResponse(503, "service_unavailable");
  }
}

// -------------------------------------------------------------------------------------------
// POST /subscription/delete-account
// -------------------------------------------------------------------------------------------

async function handleDeleteAccount(req: Request, startedAt: number): Promise<Response> {
  const authResult = await verifyAccount(req);
  if (!authResult.ok) {
    logEvent("subscription_delete_auth_rejected", {
      status: authResult.response.status,
      latencyMs: Math.round(performance.now() - startedAt),
    });
    return authResult.response;
  }
  const userIdHash = await hashUserId(authResult.userId);

  const supabase = createServiceRoleClient();
  if (!supabase) {
    return errorResponse(503, "service_unavailable");
  }

  try {
    // Hard delete via the admin API (service-role only). `entitlements` (migration 0003 — every row
    // for this user, across all sources) and `usage_counters` (migration 0002) both reference
    // `auth.users(id) on delete cascade`, so this alone removes every trace of the account across
    // all rows/tables in one operation — required by Apple Guideline 5.1.1(v), so this must
    // actually delete, never stub/soft-delete.
    const { error } = await supabase.auth.admin.deleteUser(authResult.userId);
    if (error) {
      logError("subscription_delete_failed", {
        userIdHash,
        message: error.message,
        latencyMs: Math.round(performance.now() - startedAt),
      });
      return errorResponse(503, "service_unavailable");
    }
  } catch (err) {
    logError("subscription_delete_exception", {
      userIdHash,
      message: err instanceof Error ? err.name : "unknown",
      latencyMs: Math.round(performance.now() - startedAt),
    });
    return errorResponse(503, "service_unavailable");
  }

  logEvent("subscription_delete", {
    userIdHash,
    status: 200,
    latencyMs: Math.round(performance.now() - startedAt),
  });
  return jsonResponse(200, { deleted: true });
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

async function handleRedeem(req: Request, startedAt: number): Promise<Response> {
  const contentType = (req.headers.get("content-type") ?? "").toLowerCase();
  if (!contentType.startsWith("application/json")) {
    return errorResponse(415, "invalid_request");
  }

  const authResult = await verifyAccount(req);
  if (!authResult.ok) {
    logEvent("subscription_redeem_auth_rejected", {
      status: authResult.response.status,
      latencyMs: Math.round(performance.now() - startedAt),
    });
    return authResult.response;
  }
  const userIdHash = await hashUserId(authResult.userId);

  let rawBody: string;
  try {
    rawBody = await readBodyCapped(req, MAX_REDEEM_BODY_BYTES);
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

  // PRIVACY: `code` is a secret that grants a paid month — it must never appear in a log line or
  // an error response body from this point on, success or failure (module doc comment / task
  // privacy directive). Only its length is ever inspected here, never its value logged.
  const code = isPlainObject(parsedJson) ? parsedJson.code : undefined;
  if (typeof code !== "string" || code.length === 0 || code.length > MAX_CODE_LENGTH) {
    return errorResponse(400, "invalid_request");
  }

  const supabase = createServiceRoleClient();
  if (!supabase) {
    return errorResponse(503, "service_unavailable");
  }

  try {
    const { data, error } = await supabase.rpc("redeem_promo_code", {
      p_user: authResult.userId,
      p_code: code,
    });
    if (error) {
      logError("subscription_redeem_rpc_failed", {
        userIdHash,
        message: error.message,
        latencyMs: Math.round(performance.now() - startedAt),
      });
      return errorResponse(503, "service_unavailable");
    }

    // A `returns table(...)` RPC comes back through PostgREST as an array of rows — same shape
    // `../_shared/quota.ts`'s `consumeQuota` already unwraps for `consume_quota`.
    const row: RedeemRpcRow | undefined = Array.isArray(data) ? data[0] : data;
    const status = row?.status;

    switch (status) {
      case "ok": {
        logEvent("subscription_redeem", {
          userIdHash,
          status: "ok",
          latencyMs: Math.round(performance.now() - startedAt),
        });
        return jsonResponse(200, {
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
        });
      }
      case "invalid":
        logEvent("subscription_redeem_rejected", {
          userIdHash,
          status: "invalid",
          latencyMs: Math.round(performance.now() - startedAt),
        });
        return redeemErrorResponse(404, "code_invalid");
      case "already":
        logEvent("subscription_redeem_rejected", {
          userIdHash,
          status: "already",
          latencyMs: Math.round(performance.now() - startedAt),
        });
        return redeemErrorResponse(409, "already_redeemed");
      case "exhausted":
        logEvent("subscription_redeem_rejected", {
          userIdHash,
          status: "exhausted",
          latencyMs: Math.round(performance.now() - startedAt),
        });
        return redeemErrorResponse(410, "code_exhausted");
      case "rate_limited":
        logEvent("subscription_redeem_rejected", {
          userIdHash,
          status: "rate_limited",
          latencyMs: Math.round(performance.now() - startedAt),
        });
        return redeemErrorResponse(429, "too_many_attempts");
      default:
        // Unrecognized status from the RPC must map to 503, never to success — an unknown status
        // is treated as "something is wrong", not "assume ok".
        logError("subscription_redeem_unknown_status", {
          userIdHash,
          latencyMs: Math.round(performance.now() - startedAt),
        });
        return errorResponse(503, "service_unavailable");
    }
  } catch (err) {
    logError("subscription_redeem_exception", {
      userIdHash,
      message: err instanceof Error ? err.name : "unknown",
      latencyMs: Math.round(performance.now() - startedAt),
    });
    return errorResponse(503, "service_unavailable");
  }
}

// -------------------------------------------------------------------------------------------

function isPlainObject(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}
