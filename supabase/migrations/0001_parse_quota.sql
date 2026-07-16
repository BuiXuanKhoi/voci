-- 0001_parse_quota.sql
-- Backing store for /functions/v1/parse metering (contracts/parse-proxy.md).
--
-- Two counter tables, both accessed ONLY through the SECURITY DEFINER RPC functions below so
-- that the increment is a single atomic SQL statement (no read-modify-write race between
-- concurrent requests from the same device/subscriber hammering the endpoint in parallel).
--
-- RLS is enabled on both tables with NO policies at all: PostgREST's anon/authenticated roles
-- (and any future client-side Supabase key) get zero rows and zero writes, full stop. The Edge
-- Function talks to Postgres exclusively via the service_role key (which bypasses RLS by
-- Postgres/PostgREST design) calling the RPC functions below, which are themselves further
-- locked to service_role via REVOKE/GRANT EXECUTE. This is defense in depth: even if a
-- misconfigured client ever shipped an anon/authenticated key capable of reaching this schema,
-- it could not read or forge quota counters.

-- ---------------------------------------------------------------------------------------------
-- Free tier: per-device daily counter. key_hash = SHA-256(App Attest keyId), hex-encoded, never
-- the raw device identifier. utc_date is the calendar day in UTC (see auth.ts / quota.ts doc
-- comments for why the day boundary is defined in UTC, not device-local time).
-- ---------------------------------------------------------------------------------------------
create table if not exists public.parse_quota (
    key_hash   text        not null,
    utc_date   date        not null,
    count      integer     not null default 0,
    updated_at timestamptz not null default now(),
    primary key (key_hash, utc_date)
);

-- primary key already gives a unique index on (key_hash, utc_date); this second index supports
-- the periodic cleanup query (DELETE ... WHERE utc_date < cutoff) without a seq scan.
create index if not exists parse_quota_utc_date_idx on public.parse_quota (utc_date);

alter table public.parse_quota enable row level security;
-- Intentionally no policies: RLS with zero policies == zero access for anon/authenticated.

-- ---------------------------------------------------------------------------------------------
-- Paid tier: soft rate limit (PARSE_PAID_RPM), keyed by SHA-256(bundleId ":" originalTransactionId)
-- from the verified StoreKit JWS. minute_bucket is a UTC-minute string, e.g. "2026-07-16T00:05".
-- ---------------------------------------------------------------------------------------------
create table if not exists public.parse_rate_limit (
    key_hash      text        not null,
    minute_bucket text        not null,
    count         integer     not null default 0,
    updated_at    timestamptz not null default now(),
    primary key (key_hash, minute_bucket)
);

create index if not exists parse_rate_limit_bucket_idx on public.parse_rate_limit (minute_bucket);

alter table public.parse_rate_limit enable row level security;
-- Intentionally no policies: RLS with zero policies == zero access for anon/authenticated.

-- ---------------------------------------------------------------------------------------------
-- Atomic increment-and-read for the free-tier daily counter. Single statement: Postgres takes the
-- row lock implicitly during the INSERT .. ON CONFLICT .. DO UPDATE, so two concurrent requests
-- for the same (key_hash, utc_date) serialize instead of racing a read-modify-write.
-- ---------------------------------------------------------------------------------------------
create or replace function public.parse_quota_increment(p_key_hash text, p_utc_date date)
returns integer
language sql
security definer
set search_path = public
as $$
    insert into public.parse_quota (key_hash, utc_date, count, updated_at)
    values (p_key_hash, p_utc_date, 1, now())
    on conflict (key_hash, utc_date)
    do update set count = public.parse_quota.count + 1, updated_at = now()
    returning count;
$$;

revoke all on function public.parse_quota_increment(text, date) from public;
revoke all on function public.parse_quota_increment(text, date) from anon;
revoke all on function public.parse_quota_increment(text, date) from authenticated;
grant execute on function public.parse_quota_increment(text, date) to service_role;

-- ---------------------------------------------------------------------------------------------
-- Same pattern for the paid-tier per-minute rate limit.
-- ---------------------------------------------------------------------------------------------
create or replace function public.parse_rate_increment(p_key_hash text, p_minute_bucket text)
returns integer
language sql
security definer
set search_path = public
as $$
    insert into public.parse_rate_limit (key_hash, minute_bucket, count, updated_at)
    values (p_key_hash, p_minute_bucket, 1, now())
    on conflict (key_hash, minute_bucket)
    do update set count = public.parse_rate_limit.count + 1, updated_at = now()
    returning count;
$$;

revoke all on function public.parse_rate_increment(text, text) from public;
revoke all on function public.parse_rate_increment(text, text) from anon;
revoke all on function public.parse_rate_increment(text, text) from authenticated;
grant execute on function public.parse_rate_increment(text, text) to service_role;

-- ---------------------------------------------------------------------------------------------
-- NOTE (follow-up, not implemented here): neither table is ever pruned. parse_rate_limit in
-- particular grows one row per (device-or-subscriber, minute) forever. Deploy a pg_cron job
-- (e.g. daily) doing:
--   delete from public.parse_quota where utc_date < (current_date - interval '30 days');
--   delete from public.parse_rate_limit where minute_bucket < to_char(now() - interval '1 day', 'YYYY-MM-DD"T"HH24:MI');
-- Tracked as a backend follow-up (see final report / backlog).
-- ---------------------------------------------------------------------------------------------
