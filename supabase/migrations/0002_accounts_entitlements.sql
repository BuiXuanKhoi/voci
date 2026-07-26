-- 0002_accounts_entitlements.sql
-- Account-based auth/entitlements/quota — supersedes 0001_parse_quota.sql's device-keyed model.
-- See specs/002-workflow-command-center/contracts/account-auth.md §6 for the CHỐT schema this
-- implements exactly.
--
-- Safe to apply whether or not 0001 has run (every DROP is `IF EXISTS`), and safe to re-run
-- (every CREATE is `IF NOT EXISTS` / `CREATE OR REPLACE`). No traffic exists yet on the old
-- device-keyed tables, so this drops them outright with no backfill.

-- ---------------------------------------------------------------------------------------------
-- Drop the old device-keyed quota objects (0001). Functions first (nothing here CASCADEs through
-- them, but dropping in dependency order is cheap and avoids relying on cascade semantics).
-- ---------------------------------------------------------------------------------------------
drop function if exists public.parse_rate_increment(text, text);
drop function if exists public.parse_quota_increment(text, date);
drop table if exists public.parse_rate_limit;
drop table if exists public.parse_quota;

-- ---------------------------------------------------------------------------------------------
-- entitlements: one row per Supabase Auth user who has ever linked a subscription. A `free` user
-- who never subscribed has NO row at all — `_shared/auth.ts`'s `verifyAccount` treats "no row" the
-- same as an explicit `tier = 'free'`. `original_transaction_id` is UNIQUE across the whole table
-- (not just per-user) so that `POST /subscription/link` can rely on a single upsert's unique-
-- constraint violation to detect "this Apple subscription is already claimed by a different
-- account" (first-claim-wins) rather than a separate read-then-write check.
-- ---------------------------------------------------------------------------------------------
create table if not exists public.entitlements (
  user_id                 uuid primary key references auth.users(id) on delete cascade,
  tier                    text not null default 'free' check (tier in ('free', 'pro')),
  product_id              text,
  original_transaction_id text unique,
  expires_at              timestamptz,
  updated_at              timestamptz not null default now()
);

alter table public.entitlements enable row level security;
-- Intentionally no policies: RLS with zero policies == zero access for anon/authenticated. Only
-- the service-role key (used exclusively by the Edge Functions, never shipped to a client) can
-- read or write this table. Client code must never query it directly.

-- ---------------------------------------------------------------------------------------------
-- usage_counters: per-user, per-route, per-UTC-day request counter. `route` is a real column
-- (not folded into the key hash the way 0001 did it) specifically so `/parse` and `/groq`
-- ("speech") get INDEPENDENT daily budgets — closes the backlog item "groq và parse dùng chung
-- bucket" (contract §6).
-- ---------------------------------------------------------------------------------------------
create table if not exists public.usage_counters (
  user_id uuid not null references auth.users(id) on delete cascade,
  route   text not null check (route in ('parse', 'speech')),
  day     date not null,
  count   int  not null default 0,
  primary key (user_id, route, day)
);

alter table public.usage_counters enable row level security;
-- Intentionally no policies — same reasoning as `entitlements` above.

-- Supports admin/cleanup queries scoped by day without a seq scan (mirrors 0001's convention of
-- indexing the day/bucket column separately from the primary key).
create index if not exists usage_counters_day_idx on public.usage_counters (day);

-- ---------------------------------------------------------------------------------------------
-- Atomic increment-and-check for the daily per-(user, route) counter. ONE statement does the
-- mutation: `INSERT ... ON CONFLICT ... DO UPDATE ... WHERE count < p_limit`. Postgres takes the
-- row lock implicitly during that statement, so two concurrent requests for the same
-- (user_id, route, day) serialize instead of racing a read-modify-write — never read-then-write.
--
-- `allowed` MUST be derived from whether the INSERT/UPDATE actually wrote a row (i.e. whether
-- `RETURNING ... INTO v_count` produced anything), NOT from comparing the resulting count value
-- against `p_limit`. A value-comparison approach (`v_count <= p_limit`) is WRONG and was caught in
-- review before this shipped: once the counter is saturated, `count` stops changing at exactly
-- `p_limit` (every subsequent conflict fails the `WHERE count < p_limit` guard, so no further
-- write ever happens) — so `count <= p_limit` stays true FOREVER after the limit is first hit,
-- silently allowing unlimited requests past the cap. The only trustworthy signal is "did this
-- statement's WHERE-guarded branch fire or not", which `v_count is null` (no row returned) answers
-- directly.
--
-- Behavior when the limit is already hit: the `WHERE usage_counters.count < p_limit` guard means
-- the UPDATE branch performs no write and `RETURNING count` yields zero rows, so `v_count` is left
-- NULL by `INSERT ... RETURNING ... INTO` — that NULL is exactly the "not allowed" signal
-- (`v_allowed := false`). A separate, purely read-only SELECT then fetches the CURRENT count just
-- to report it (the caller's `used` value / client-facing "còn N lượt" display); it never gates
-- access.
--
-- `p_limit <= 0` is guarded explicitly up front: the very first request of the day is an
-- UNCONDITIONAL insert (the `ON CONFLICT` branch — where the limit guard actually lives — only
-- fires on the SECOND and later request for that (user, route, day)). Without this guard, a
-- limit of 0 (meant to hard-disable a route without a code change) would still let exactly one
-- request through per user per day before the guard ever had a chance to apply.
-- ---------------------------------------------------------------------------------------------
create or replace function public.consume_quota(p_user uuid, p_route text, p_limit int)
returns table(allowed boolean, used int)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count   int;
  v_allowed boolean;
begin
  if p_limit <= 0 then
    return query select false, 0;
    return;
  end if;

  insert into public.usage_counters (user_id, route, day, count)
  values (p_user, p_route, current_date, 1)
  on conflict (user_id, route, day)
    do update set count = usage_counters.count + 1
    where usage_counters.count < p_limit
  returning count into v_count;

  if v_count is null then
    -- The atomic insert/update above did NOT happen (limit already hit) — this is the one and
    -- only source of truth for "not allowed". The SELECT below is read-only and purely for
    -- reporting the current count; it never gates access.
    v_allowed := false;
    select uc.count into v_count
    from public.usage_counters uc
    where uc.user_id = p_user and uc.route = p_route and uc.day = current_date;
  else
    -- The statement above DID write (either the initial insert or a successful guarded update) —
    -- that write having happened at all is what "allowed" means.
    v_allowed := true;
  end if;

  return query select v_allowed, coalesce(v_count, 0);
end;
$$;

revoke all on function public.consume_quota(uuid, text, int) from public;
revoke all on function public.consume_quota(uuid, text, int) from anon;
revoke all on function public.consume_quota(uuid, text, int) from authenticated;
grant execute on function public.consume_quota(uuid, text, int) to service_role;

-- ---------------------------------------------------------------------------------------------
-- NOTE (follow-up, not implemented here): `usage_counters` is never pruned and grows one row per
-- (user, route, day) forever. Deploy a pg_cron job (e.g. daily) doing:
--   delete from public.usage_counters where day < (current_date - interval '90 days');
-- Tracked as a backend follow-up (see backlog.md).
-- ---------------------------------------------------------------------------------------------
