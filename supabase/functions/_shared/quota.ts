// supabase/functions/_shared/quota.ts
//
// Free-tier daily quota (Postgres counter) + paid-tier soft rate limit. Both go through the
// SECURITY DEFINER RPC functions in supabase/migrations/0001_parse_quota.sql so the
// increment-and-read is ONE atomic SQL statement — no read-modify-write race when two requests
// for the same key land concurrently (see final report threat model, "quota bypass: parallel
// requests racing the counter").
//
// UTC day boundary: `utc_date` is computed from `new Date().toISOString().slice(0, 10)`.
// `Date.prototype.toISOString()` always normalizes to UTC regardless of the server's local
// timezone (Deno/V8 has no "local timezone" concept server-side beyond the OS default, which we
// never rely on), so the day boundary is unambiguous and does not depend on the deployment
// region. This means quota resets at 00:00 UTC, not device-local midnight — documented here and
// in README.md so nobody "fixes" it into a timezone-dependent boundary later.

import type { SupabaseClient } from "npm:@supabase/supabase-js@2.110.6";
import { readEnvInt } from "./env.ts";

export const DEFAULT_DAILY_QUOTA = 50;
export const DEFAULT_PAID_RPM = 20;

function utcDateString(now: Date): string {
  return now.toISOString().slice(0, 10); // YYYY-MM-DD, UTC
}

function utcMinuteBucket(now: Date): string {
  return now.toISOString().slice(0, 16); // YYYY-MM-DDTHH:MM, UTC
}

function nextUtcMidnightIso(now: Date): string {
  const next = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() + 1, 0, 0, 0, 0));
  return next.toISOString();
}

function nextUtcMinuteIso(now: Date): string {
  const next = new Date(Date.UTC(
    now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(),
    now.getUTCHours(), now.getUTCMinutes() + 1, 0, 0,
  ));
  return next.toISOString();
}

export type QuotaCheck =
  | { allowed: true; count: number; limit: number }
  | { allowed: false; count: number; limit: number; resetAt: string };

/** Free tier: increments and checks the per-device daily counter in ONE round trip (a PostgREST
 *  RPC call to the atomic `parse_quota_increment` SQL function). `PARSE_DAILY_QUOTA` env
 *  (default 50) is read fresh per-request so operators can retune it without a redeploy. */
export async function checkFreeQuota(
  supabase: SupabaseClient,
  quotaKeyHash: string,
  now: Date,
): Promise<QuotaCheck> {
  const limit = readEnvInt("PARSE_DAILY_QUOTA", DEFAULT_DAILY_QUOTA);
  const utcDate = utcDateString(now);
  const { data, error } = await supabase.rpc("parse_quota_increment", {
    p_key_hash: quotaKeyHash,
    p_utc_date: utcDate,
  });
  if (error) {
    // Propagate as a thrown error so the caller maps it to an opaque 502 — a DB failure must
    // never be interpreted as "quota ok, let the request through".
    throw new Error(`parse_quota_increment failed: ${error.message}`);
  }
  const count = typeof data === "number" ? data : Number(data);
  if (count > limit) {
    return { allowed: false, count, limit, resetAt: nextUtcMidnightIso(now) };
  }
  return { allowed: true, count, limit };
}

/** Paid tier: soft per-minute rate limit (bounds abuse of an unmetered path), same atomic RPC
 *  pattern keyed by SHA-256(bundleId:originalTransactionId) instead of the App Attest keyId. */
export async function checkPaidRateLimit(
  supabase: SupabaseClient,
  rateLimitKeyHash: string,
  now: Date,
): Promise<QuotaCheck> {
  const limit = readEnvInt("PARSE_PAID_RPM", DEFAULT_PAID_RPM);
  const bucket = utcMinuteBucket(now);
  const { data, error } = await supabase.rpc("parse_rate_increment", {
    p_key_hash: rateLimitKeyHash,
    p_minute_bucket: bucket,
  });
  if (error) {
    throw new Error(`parse_rate_increment failed: ${error.message}`);
  }
  const count = typeof data === "number" ? data : Number(data);
  if (count > limit) {
    return { allowed: false, count, limit, resetAt: nextUtcMinuteIso(now) };
  }
  return { allowed: true, count, limit };
}
