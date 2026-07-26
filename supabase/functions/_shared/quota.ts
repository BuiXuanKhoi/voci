// supabase/functions/_shared/quota.ts
//
// Account-based daily quota, keyed on (user_id, route, day) — see
// specs/002-workflow-command-center/contracts/account-auth.md §1/§6. Both `/parse` and `/groq`
// (the "speech" route) call `consumeQuota`, which wraps the atomic `consume_quota` SQL RPC
// (supabase/migrations/0002_accounts_entitlements.sql) — a single INSERT ... ON CONFLICT DO UPDATE
// statement, so the increment-and-check is race-free under concurrent requests from the same user
// (no read-modify-write gap for two parallel requests to exploit).
//
// `route` is `'parse' | 'speech'` — this closes a known defect in the old device-keyed design:
// `/groq` and `/parse` used to share ONE rate-limit bucket, so a burst on one route could 429 the
// other. The `route` column on `usage_counters` (and this module's `route` param) gives each route
// its own independent daily counter.
//
// UTC day boundary: the `consume_quota` SQL function uses Postgres's own `current_date`, and
// `readUsageToday` below mirrors that with `Date.prototype.toISOString().slice(0, 10)` — always
// UTC regardless of the server's local timezone. Quota resets at 00:00 UTC, not device-local
// midnight — documented here and in README.md so nobody "fixes" it into a timezone-dependent
// boundary later.

import type { SupabaseClient } from "npm:@supabase/supabase-js@2.110.6";
import { readEnvInt } from "./env.ts";

export type Route = "parse" | "speech";

export const DEFAULT_PARSE_LIMIT_FREE = 20;
export const DEFAULT_PARSE_LIMIT_PRO = 500;
export const DEFAULT_SPEECH_LIMIT_PRO = 500;

/** `/parse` is available to both tiers, just with a different daily cap. */
export function parseLimitFor(tier: "free" | "pro"): number {
  return tier === "pro"
    ? readEnvInt("PARSE_LIMIT_PRO", DEFAULT_PARSE_LIMIT_PRO)
    : readEnvInt("PARSE_LIMIT_FREE", DEFAULT_PARSE_LIMIT_FREE);
}

/** `/groq` (speech) is Pro-only (contract §1) — there is no free-tier speech limit to compute. */
export function speechLimitForPro(): number {
  return readEnvInt("SPEECH_LIMIT_PRO", DEFAULT_SPEECH_LIMIT_PRO);
}

function nextUtcMidnightIso(now: Date): string {
  const next = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() + 1, 0, 0, 0, 0));
  return next.toISOString();
}

export type QuotaCheck =
  | { allowed: true; used: number; limit: number }
  | { allowed: false; used: number; limit: number; resetAt: string };

/** Atomically increments AND checks the (user_id, route, day) counter in one round trip via the
 *  `consume_quota` RPC. Throws on any DB error so the caller maps it to an opaque 5xx — a DB
 *  failure must never be interpreted as "quota ok, let the request through". */
export async function consumeQuota(
  supabase: SupabaseClient,
  userId: string,
  route: Route,
  limit: number,
  now: Date,
): Promise<QuotaCheck> {
  const { data, error } = await supabase.rpc("consume_quota", {
    p_user: userId,
    p_route: route,
    p_limit: limit,
  });
  if (error) {
    throw new Error(`consume_quota failed: ${error.message}`);
  }
  // A `returns table(...)` RPC comes back through PostgREST as an array of rows.
  const row = Array.isArray(data) ? data[0] : data;
  const allowed = row?.allowed === true;
  const usedRaw = row?.used;
  const used = typeof usedRaw === "number" ? usedRaw : Number(usedRaw ?? 0);
  if (!allowed) {
    return { allowed: false, used, limit, resetAt: nextUtcMidnightIso(now) };
  }
  return { allowed: true, used, limit };
}

/** Read-only usage lookup for `GET /subscription/status` — does NOT increment the counter. Missing
 *  row (no requests yet today) reports 0, not an error. */
export async function readUsageToday(
  supabase: SupabaseClient,
  userId: string,
  route: Route,
  now: Date,
): Promise<number> {
  const utcDate = now.toISOString().slice(0, 10);
  const { data, error } = await supabase
    .from("usage_counters")
    .select("count")
    .eq("user_id", userId)
    .eq("route", route)
    .eq("day", utcDate)
    .maybeSingle();
  if (error) {
    throw new Error(`usage_counters lookup failed: ${error.message}`);
  }
  const row = data as { count: number } | null;
  return typeof row?.count === "number" ? row.count : 0;
}
