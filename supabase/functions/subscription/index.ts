// supabase/functions/subscription/index.ts — Edge Function for the account/subscription routes
//
// Implements specs/002-workflow-command-center/contracts/account-auth.md §3:
//   POST /functions/v1/subscription/link            — attach/renew a Pro entitlement
//   GET  /functions/v1/subscription/status           — current tier + today's usage
//   POST /functions/v1/subscription/delete-account   — Apple Guideline 5.1.1(v) hard delete
//
// All three routes require account auth (../_shared/auth.ts's `verifyAccount`) — the same
// Supabase Auth bearer every /parse and /groq request carries. StoreKit JWS is NEVER a bearer
// credential; it is submitted as the BODY of `/link` only, verified by ../_shared/appstore.ts.
//
// Privacy: never log access tokens, JWS, email, or a raw user id — only a HASH of user_id (see
// ../_shared/auth.ts's `hashUserId`), status, and counts, via ../_shared/log.ts.

import { logEvent, logError } from "../_shared/log.ts";
import { errorResponse, jsonResponse, readBodyCapped, BodyTooLargeError } from "../_shared/http.ts";
import { createServiceRoleClient, hashUserId, verifyAccount, type Tier } from "../_shared/auth.ts";
import { verifyAppStoreJWS } from "../_shared/appstore.ts";
import { parseLimitFor, readUsageToday, speechLimitForPro } from "../_shared/quota.ts";

const MAX_LINK_BODY_BYTES = 8 * 1024; // a JWS is a few KB at most; generous headroom
const MAX_JWS_LENGTH = 8000;

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
    // Single upsert keyed on the PK (`user_id`). `original_transaction_id` carries its OWN unique
    // constraint (migration 0002) that is NOT the conflict target here, so if this transaction id
    // already belongs to a DIFFERENT user's row, Postgres raises a unique-violation (23505) and
    // the whole statement aborts atomically — no separate read-then-write race between "check
    // who owns this id" and "write the row". A renewal (same user, same original_transaction_id)
    // simply updates that user's own row, which is never a conflict against itself.
    const { error } = await supabase
      .from("entitlements")
      .upsert(
        {
          user_id: authResult.userId,
          tier: "pro",
          product_id: verified.transaction.productId,
          original_transaction_id: verified.transaction.originalTransactionId,
          expires_at: verified.transaction.expiresDate,
          updated_at: new Date().toISOString(),
        },
        { onConflict: "user_id" },
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
  // Speech (Groq) is Pro-only (contract §1) — a free account has zero speech entitlement, so its
  // limit is reported as 0 rather than the Pro constant, and there's no need to even look up usage.
  const speechLimit = tier === "pro" ? speechLimitForPro() : 0;

  try {
    const parseUsedToday = await readUsageToday(supabase, authResult.userId, "parse", now);
    const speechUsedToday = tier === "pro"
      ? await readUsageToday(supabase, authResult.userId, "speech", now)
      : 0;

    logEvent("subscription_status", {
      userIdHash,
      tier,
      status: 200,
      latencyMs: Math.round(performance.now() - startedAt),
    });
    return jsonResponse(200, {
      tier,
      expiresAt: authResult.expiresAt,
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
    // Hard delete via the admin API (service-role only). `entitlements` / `usage_counters` both
    // reference `auth.users(id) on delete cascade` (migration 0002), so this alone removes every
    // trace of the account across all three tables in one operation — required by Apple Guideline
    // 5.1.1(v), so this must actually delete, never stub/soft-delete.
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

function isPlainObject(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}
