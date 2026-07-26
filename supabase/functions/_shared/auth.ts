// supabase/functions/_shared/auth.ts
//
// Account auth (Supabase Auth) — see
// specs/002-workflow-command-center/contracts/account-auth.md. This is a full rewrite for the
// 2026-07-26 pivot from device-based auth to real user accounts.
//
// DELETED, on purpose, no trace left: App Attest (`UnimplementedAppAttestKeyStore`,
// `verifyFreeAuth`, the `npm:appattest-checker-node` import) and the `PARSE_DEV_TOKEN` bypass
// (`tryDevTokenBypass`). Both existed only because there was no way to authenticate a real caller
// yet; a Supabase Auth account (free to create, no App Attest ceremony, no dev secret) replaces
// both needs entirely. Do NOT resurrect either — if a future contributor needs a throwaway test
// credential, the correct answer is "sign up a free account", not a new bypass.
//
// `verifyAccount(req)` is the single entry point every route uses:
//   1. Extract `Authorization: Bearer <token>` (shape checks only — no crypto here).
//   2. Verify the token is a REAL user's access token (not the public anon/publishable key) by
//      calling Supabase Auth's own `auth.getUser()` on a client built from `SUPABASE_URL` +
//      `SUPABASE_ANON_KEY`, with the CALLER's token forwarded as that client's own Authorization
//      header. GoTrue resolves `getUser()` against whichever token the client was built with; the
//      anon key is not a per-user JWT that resolves to a user, so this correctly rejects it.
//   3. Load `entitlements` (service-role client — RLS is enabled with zero policies on this table,
//      so only the service-role key can ever read it) and resolve the effective tier: `pro` only
//      if the row's `tier = 'pro'` AND `expires_at > now()`; `free` otherwise (including "no row at
//      all", which is the normal state for a free account that never subscribed).
//
// IMPORTANT — why `supabase/config.toml` still has `verify_jwt = false` for every route that calls
// `verifyAccount`: Supabase's platform gateway "verify JWT" gate only checks that the bearer token
// is SOME validly-signed JWT for this project — and the public anon/publishable key IS a validly
// signed JWT for this project (that is what makes it safe to ship inside a client app at all: it
// is public by design). If the gateway gate were turned on, a caller presenting the anon key as
// `Authorization` would sail through the gateway and reach the function with no real identity
// attached. So the gateway's JWT gate is NOT an authentication boundary here — `getUser()` below
// is: it is the one call that actually distinguishes "a real user's access token" from "the public
// anon key" from "garbage". This looks backwards at first glance (verify_jwt = false on an
// authenticated route!) — it is intentional; do not "fix" it by flipping it to true.

import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.110.6";
import { requireEnv } from "./env.ts";
import { errorResponse } from "./http.ts";
import { logError } from "./log.ts";

export type Tier = "free" | "pro";

export type AccountAuthResult =
  | { ok: true; userId: string; tier: Tier; expiresAt: string | null }
  | { ok: false; response: Response };

async function sha256Hex(input: string): Promise<string> {
  const bytes = new TextEncoder().encode(input);
  // Re-wrap in a fresh `Uint8Array` backed by a plain `ArrayBuffer`: under newer TS lib.dom types,
  // a generic `Uint8Array<ArrayBufferLike>` (which could be `SharedArrayBuffer`-backed) is not
  // assignable to `BufferSource`, and `crypto.subtle.digest` requires the narrower type.
  const digest = await crypto.subtle.digest("SHA-256", new Uint8Array(bytes));
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** Never log a raw user id (privacy hard rule — access tokens, JWS, email, transcript, audio, and
 *  raw user ids must never reach a log line). Every log call site logs this instead. */
export function hashUserId(userId: string): Promise<string> {
  return sha256Hex(`uid:${userId}`);
}

const BEARER_PREFIX = "Bearer ";
const MAX_TOKEN_LENGTH = 4000; // generous headroom over a real Supabase access token's length

function extractBearerToken(authorizationHeader: string | null): string | undefined {
  if (!authorizationHeader || !authorizationHeader.startsWith(BEARER_PREFIX)) return undefined;
  const token = authorizationHeader.slice(BEARER_PREFIX.length).trim();
  if (token.length === 0 || token.length > MAX_TOKEN_LENGTH) return undefined;
  return token;
}

const SUPABASE_ENV_NAMES = ["SUPABASE_URL", "SUPABASE_ANON_KEY", "SUPABASE_SERVICE_ROLE_KEY"] as const;

interface EntitlementsRow {
  tier: string;
  expires_at: string | null;
}

export async function verifyAccount(req: Request): Promise<AccountAuthResult> {
  const token = extractBearerToken(req.headers.get("authorization"));
  if (!token) {
    return { ok: false, response: errorResponse(401, "auth_missing") };
  }

  const cfg = requireEnv(SUPABASE_ENV_NAMES);
  if (!cfg.ok) {
    // Opaque to the caller (info-leak hardening) — the specific missing keys are only useful to
    // whoever owns the deployment, never to an unauthenticated internet caller.
    logError("account_config_missing", { missingEnv: cfg.missing.join(",") });
    return { ok: false, response: errorResponse(503, "service_unavailable") };
  }

  // Per-request client, bearer = the CALLER's token (never our own service-role/anon key) — see
  // module doc comment for why `auth.getUser()` here is the real authentication boundary.
  const userClient = createClient(cfg.values.SUPABASE_URL, cfg.values.SUPABASE_ANON_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `${BEARER_PREFIX}${token}` } },
  });

  let userId: string;
  try {
    const { data, error } = await userClient.auth.getUser();
    if (error || !data?.user?.id) {
      return { ok: false, response: errorResponse(401, "auth_invalid") };
    }
    userId = data.user.id;
  } catch {
    return { ok: false, response: errorResponse(401, "auth_invalid") };
  }

  const adminClient = createClient(cfg.values.SUPABASE_URL, cfg.values.SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });

  try {
    const { data, error } = await adminClient
      .from("entitlements")
      .select("tier, expires_at")
      .eq("user_id", userId)
      .maybeSingle();
    if (error) {
      logError("entitlements_lookup_failed", { message: error.message });
      return { ok: false, response: errorResponse(503, "service_unavailable") };
    }
    const row = data as EntitlementsRow | null;
    const isPro = !!row && row.tier === "pro" && !!row.expires_at &&
      new Date(row.expires_at).getTime() > Date.now();
    return {
      ok: true,
      userId,
      tier: isPro ? "pro" : "free",
      // `expires_at < now()` reports as plain `free` with a null expiry (contract §3 `/status`:
      // "expires_at < now() -> trả free (không cần cron hạ tier)") — no background job downgrades
      // the stored row; this is computed fresh on every call.
      expiresAt: isPro ? row!.expires_at : null,
    };
  } catch (err) {
    logError("entitlements_lookup_exception", { message: err instanceof Error ? err.name : "unknown" });
    return { ok: false, response: errorResponse(503, "service_unavailable") };
  }
}

/** Shared service-role client builder — every route needs one (quota RPCs, entitlements upserts,
 *  admin user deletion), and this keeps the "which env vars, what auth mode" decision in one place
 *  rather than re-derived per file. Returns `undefined` (never throws) when config is incomplete
 *  so callers can map that to a uniform `503 service_unavailable`. */
export function createServiceRoleClient(): SupabaseClient | undefined {
  const cfg = requireEnv(["SUPABASE_URL", "SUPABASE_SERVICE_ROLE_KEY"] as const);
  if (!cfg.ok) {
    logError("service_role_config_missing", { missingEnv: cfg.missing.join(",") });
    return undefined;
  }
  return createClient(cfg.values.SUPABASE_URL, cfg.values.SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });
}
