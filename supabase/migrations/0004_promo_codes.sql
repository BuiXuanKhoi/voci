-- 0004_promo_codes.sql
-- Backing store for "hand out a few 1-month-free codes" — the product owner is about to give away
-- a handful of promo codes by hand (Zalo, email, whatever). Design constraint that shapes every
-- object below: the code is SHARED, not per-user. One string, e.g. "VOLARLAUNCH", handed to many
-- different people, each of whom may redeem it exactly once. The uniqueness rule is therefore on
-- the PAIR (code, user) — never on the code alone, and never on the user alone (a user may hold
-- more than one promo code over time, see the stacking behavior in `redeem_promo_code` below).
--
-- Safe to re-run: every CREATE is `IF NOT EXISTS`, the `entitlements.source` CHECK is dropped and
-- re-added by name, and `redeem_promo_code` is `CREATE OR REPLACE`. This migration does NOT insert
-- any actual promo code row — codes are created separately (by whoever is handing them out), never
-- baked into a migration file that ends up in source control.

-- ---------------------------------------------------------------------------------------------
-- 1a. Widen `entitlements.source` to accept `'promo'` as a third, independent grant source.
--
-- WHY a new source and not a flag/column bolted onto an existing row: `entitlements` is already
-- one row per `(user_id, source)` specifically so that two billing systems (Apple StoreKit, the
-- web merchant-of-record) can never clobber each other's grant for the same user — that is the
-- entire point of migration 0003 (see its header comment: the Apple webhook and the MoR webhook
-- used to fight over one shared row). A promo month is a THIRD, independent grant with the exact
-- same failure mode if it shared a row with either: e.g. a user redeems a promo code, then later
-- their Apple subscription renews and its webhook upserts the `('apple')` row — if promo months
-- were tracked as a field on that same row instead of their own `source`, the Apple write (or the
-- promo write) would silently erase the other. Giving promo its own `source` value means it gets
-- its own row (`primary key (user_id, source)` already enforces this) and can never overwrite, or
-- be overwritten by, the user's `'apple'` or `'mor'` row. Effective tier stays "any-row-wins" per
-- `_shared/auth.ts` — a promo row and a paid row are just two more rows in the same any-row-wins
-- computation, added together in spirit (both count) but never merged into one row.
-- ---------------------------------------------------------------------------------------------
alter table public.entitlements drop constraint if exists entitlements_source_check;
alter table public.entitlements add constraint entitlements_source_check
  check (source in ('apple', 'mor', 'promo'));

-- ---------------------------------------------------------------------------------------------
-- 1b. promo_codes: one row per code STRING, not per person. `code` is the primary key and is
-- always stored UPPERCASE (the canonical form `redeem_promo_code` normalizes every incoming
-- attempt to before comparing) so "VolarLaunch", "volarlaunch", and "VOLARLAUNCH" are all the same
-- redemption target and can't be used to dodge the once-per-person rule via casing tricks.
--
-- `max_redemptions` caps how many DISTINCT PEOPLE may ever redeem this code — a cost ceiling set
-- by whoever hands the code out ("I'm only willing to eat 50 free months on this one"). This is a
-- SEPARATE concern from the once-per-person rule enforced by `promo_redemptions` below: a code
-- with `max_redemptions = 50` still only lets any single person redeem it once, and a code with
-- `max_redemptions = null` (unlimited people) still only lets any single person redeem it once.
-- `redeemed_count` is the running counter compared against that cap; it is maintained by
-- `redeem_promo_code`, never by the client.
--
-- `expires_at null` means the code itself never expires (distinct from a user's resulting Pro
-- grant expiring, which is `entitlements.expires_at` on their own row). `active` is a manual
-- kill-switch, independent of `expires_at`, for "this code leaked / was a mistake, stop honoring
-- it" without having to compute or backdate an expiry.
-- ---------------------------------------------------------------------------------------------
create table if not exists public.promo_codes (
  code            text primary key,
  grant_days      int not null default 30 check (grant_days > 0),
  max_redemptions int check (max_redemptions is null or max_redemptions > 0),
  redeemed_count  int not null default 0,
  expires_at      timestamptz,
  active          boolean not null default true,
  note            text,
  created_at      timestamptz not null default now()
);

alter table public.promo_codes enable row level security;
-- Intentionally no policies: RLS with zero policies == zero access for anon/authenticated. Only
-- the service-role key (used exclusively by the Edge Functions, never shipped to a client) can
-- read or write this table. Client code must never query it directly — in particular, a client
-- must never be able to list codes or check `redeemed_count`/`max_redemptions` directly, which
-- would turn this table into an oracle for guessing/enumerating codes.

-- ---------------------------------------------------------------------------------------------
-- 1c. promo_redemptions — THIS TABLE IS the "once per person" rule, not a log of it.
--
-- The composite primary key `(code, user_id)` is the enforcement mechanism itself, not a
-- convenience index added after the fact. Two concurrent redeem requests from the SAME user for
-- the SAME code race to `insert into promo_redemptions (code, user_id) values (...)`; Postgres
-- guarantees exactly one of those inserts wins and the other fails with a `23505` unique-violation
-- on this primary key — there is no read-then-write window in between for the loser to slip
-- through. `redeem_promo_code` below relies on this directly: it does a bare INSERT and catches
-- `unique_violation`. Do NOT "optimize" this into `select ... where not exists (...) then insert`
-- — that reintroduces exactly the race this primary key exists to close (two concurrent selects
-- can both see "not redeemed yet" before either insert commits, and both would then proceed to
-- grant the entitlement).
-- ---------------------------------------------------------------------------------------------
create table if not exists public.promo_redemptions (
  code        text not null references public.promo_codes(code) on delete cascade,
  user_id     uuid not null references auth.users(id) on delete cascade,
  redeemed_at timestamptz not null default now(),
  primary key (code, user_id)
);

alter table public.promo_redemptions enable row level security;
-- Intentionally no policies — same reasoning as `promo_codes` above.

-- ---------------------------------------------------------------------------------------------
-- 1d. promo_attempts — brute-force guard, per (user, UTC day).
--
-- A shared promo code is, by construction, a single guessable string that any signed-in account
-- can attempt against `redeem_promo_code` — and a correct guess is a free month of Pro. Without a
-- cap, an attacker with a free account could script through a wordlist against `/subscription/
-- redeem` all day. This table counts attempts (successful or not) per `(user_id, day)`, so the
-- cap is per-ACCOUNT, matching how `usage_counters` (0002) already caps `/parse` and `/groq` per
-- account per UTC day — same day-boundary convention (Postgres `current_date`, i.e. UTC, not
-- device-local midnight).
-- ---------------------------------------------------------------------------------------------
create table if not exists public.promo_attempts (
  user_id uuid not null references auth.users(id) on delete cascade,
  day     date not null,
  count   int  not null default 0,
  primary key (user_id, day)
);

alter table public.promo_attempts enable row level security;
-- Intentionally no policies — same reasoning as `promo_codes` above.

-- ---------------------------------------------------------------------------------------------
-- 1e. redeem_promo_code — the entire redemption, atomically, in one function call.
--
-- `status` is exactly one of: 'ok' | 'invalid' | 'already' | 'exhausted' | 'rate_limited'.
-- `subscription/index.ts`'s `POST /redeem` route maps these onto the locked HTTP contract; an
-- unrecognized status here must never happen, and the caller treats anything it doesn't recognize
-- as a 503, never as success.
--
-- Step order matters and mirrors the brief exactly:
--   1. Normalize `p_code` to `upper(trim(...))`. Empty (including a null input, via `coalesce`)
--      is rejected immediately as 'invalid' — no point spending an attempt-counter slot or a row
--      lock on a request that could never possibly match anything.
--   2. Atomic per-day attempt counter. Uses the EXACT SAME pattern as `consume_quota` in
--      0002_accounts_entitlements.sql: a single `insert ... on conflict (user_id, day) do update
--      set count = promo_attempts.count + 1 where promo_attempts.count < p_max_attempts returning
--      count into v_attempt_count`. Copy 0002's correctness reasoning verbatim: `allowed` (here,
--      "not rate limited") MUST be derived from whether that statement actually returned a row
--      (`v_attempt_count is not null`), NEVER from comparing the resulting count against
--      `p_max_attempts`. Once the counter saturates at `p_max_attempts`, the `WHERE count <
--      p_max_attempts` guard means the UPDATE branch stops writing at exactly that value forever
--      after — so a `count <= p_max_attempts` style comparison would read as "still allowed" on
--      every subsequent call, silently disabling the rate limit the instant it is first hit. The
--      single trustworthy signal is "did this statement's guarded branch actually fire", which
--      `v_attempt_count is null` (no row returned) answers directly, exactly as `consume_quota`
--      does for `v_allowed`.
--   3. Look up the code `for update` — a row lock, because `redeemed_count` on this row is about
--      to change and two concurrent redeemers of the SAME code must not both read a stale
--      `redeemed_count` and both think there's room left under `max_redemptions`. Missing,
--      inactive, and expired ALL collapse onto the identical 'invalid' status. This is
--      deliberate: distinguishing "no such code" from "that code exists but is expired" from
--      "that code exists but was deactivated" is a distinction that is only useful to someone
--      probing/enumerating which codes exist and in what state — a legitimate redeemer never
--      needs to know which of the three happened, they just need to know "that didn't work".
--   4. `max_redemptions` cap check — how many DISTINCT PEOPLE, not how many total attempts. Only
--      reached once a code is confirmed valid, so a redeemed-out code still reports plain
--      'invalid'-equivalent... no: it reports its own distinct 'exhausted' status, because "this
--      code is fine but the cost ceiling is reached" IS meaningfully different information for
--      the redeemer (unlike step 3's collapse, which exists purely to deny an attacker
--      information; there is no enumeration risk in telling a legitimate holder of a real,
--      currently-valid code that it is full).
--   5. Insert into `promo_redemptions` — see that table's own comment above: this bare INSERT,
--      caught for `unique_violation`, IS the once-per-person enforcement. Not a convenience.
--   6. Bump `promo_codes.redeemed_count` — happens only after step 5 succeeded, so a losing
--      concurrent duplicate (caught at step 5) never double-counts here.
--   7. Grant/stack the entitlement — see the inline comment on the upsert itself below for the
--      `external_id` trap and the stacking arithmetic.
--   8. Return 'ok' with the resulting `expires_at` and `grant_days`.
-- ---------------------------------------------------------------------------------------------
create or replace function public.redeem_promo_code(
  p_user uuid,
  p_code text,
  p_max_attempts int default 10
)
returns table(status text, expires_at timestamptz, granted_days int)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code          text;
  v_attempt_count int;
  v_promo         record;
  v_new_expires   timestamptz;
begin
  -- Step 1: normalize; reject empty (including null input) before touching any counter or table.
  v_code := upper(trim(coalesce(p_code, '')));
  if v_code = '' then
    return query select 'invalid'::text, null::timestamptz, null::int;
    return;
  end if;

  -- Step 2: atomic per-(user, UTC day) attempt counter — same pattern, same reasoning, as
  -- `consume_quota` in 0002_accounts_entitlements.sql. Do not "simplify" this into a
  -- select-then-compare; see the doc comment above this function for exactly why that is wrong.
  insert into public.promo_attempts as pa (user_id, day, count)
  values (p_user, current_date, 1)
  on conflict (user_id, day)
    do update set count = pa.count + 1
    where pa.count < p_max_attempts
  returning pa.count into v_attempt_count;

  if v_attempt_count is null then
    return query select 'rate_limited'::text, null::timestamptz, null::int;
    return;
  end if;

  -- Step 3: look up the code under a row lock (`for update`) — `redeemed_count` is about to
  -- change, and this lock is what makes concurrent redemptions of the SAME code by DIFFERENT
  -- users serialize instead of racing on the `max_redemptions` check in step 4.
  -- EVERY column reference below is table-qualified, and `pc.expires_at` is aliased to
  -- `code_expires_at`, ON PURPOSE. `returns table(status, expires_at, granted_days)` puts those
  -- three names in scope AS PLPGSQL VARIABLES, so a bare `expires_at` here is ambiguous between
  -- the OUT parameter and `promo_codes.expires_at` and Postgres raises 42702 at RUNTIME (not at
  -- create time — `create function` accepted the ambiguous version happily, and every redeem call
  -- failed with 503 until it was caught by actually invoking it). Same reason the entitlements
  -- upsert below aliases its target `as e`. Do not "simplify" these qualifications away.
  select pc.code, pc.grant_days, pc.max_redemptions, pc.redeemed_count,
         pc.expires_at as code_expires_at, pc.active
    into v_promo
    from public.promo_codes pc
    where pc.code = v_code
    for update;

  if not found then
    -- No such code. Same 'invalid' status as "expired" and "deactivated" below — see the doc
    -- comment above this function for why that collapse is deliberate (anti-enumeration).
    return query select 'invalid'::text, null::timestamptz, null::int;
    return;
  end if;

  if not v_promo.active
     or (v_promo.code_expires_at is not null and v_promo.code_expires_at <= now()) then
    return query select 'invalid'::text, null::timestamptz, null::int;
    return;
  end if;

  -- Step 4: cost ceiling — how many DISTINCT PEOPLE may hold this code, separate from the
  -- once-per-person rule enforced at step 5.
  if v_promo.max_redemptions is not null and v_promo.redeemed_count >= v_promo.max_redemptions then
    return query select 'exhausted'::text, null::timestamptz, null::int;
    return;
  end if;

  -- Step 5: THE once-per-person rule. A bare insert, not a select-then-insert — see
  -- `promo_redemptions`'s own comment above for why. Two concurrent redeems of this SAME code by
  -- this SAME user race here; Postgres lets exactly one win and the other lands in this
  -- `exception when unique_violation` branch.
  begin
    insert into public.promo_redemptions (code, user_id) values (v_code, p_user);
  exception
    when unique_violation then
      return query select 'already'::text, null::timestamptz, null::int;
      return;
  end;

  -- Step 6: only reached once step 5's insert actually committed-in-transaction, so a losing
  -- concurrent duplicate never bumps this.
  update public.promo_codes pc set redeemed_count = pc.redeemed_count + 1 where pc.code = v_code;

  -- Step 7: grant/stack the Pro entitlement.
  --
  -- `external_id = v_code || ':' || p_user::text` — NOT the bare code. `entitlements` carries
  -- `unique (source, external_id)` from migration 0003. If `external_id` were just the code
  -- string, that constraint would allow only ONE ROW IN THE ENTIRE SYSTEM per code (since
  -- `source = 'promo'` is the same for everyone) — the second person to redeem the exact same
  -- shared code would hit a 23505 unique-violation on THIS insert, after already successfully
  -- passing step 5, which is exactly backwards (the whole point of this feature is that many
  -- different people redeem the SAME code string). Folding `p_user` into `external_id` makes it
  -- unique PER PERSON, so N different people redeeming the same code produces N different
  -- `entitlements` rows (one per user, each with source='promo'), which is what `unique (source,
  -- external_id)` is supposed to allow.
  --
  -- Stacking: `expires_at` for this insert-or-update is computed as
  --   greatest(now(), coalesce(<this user's existing 'promo' row's expires_at>, now()))
  --     + (grant_days || ' days')::interval
  -- so redeeming a second, different promo code while a promo month is still live EXTENDS the
  -- existing grant instead of resetting it, and a user whose OLD promo grant already expired
  -- starts counting fresh from `now()` rather than getting a grant back-dated off a stale expiry
  -- (`greatest` with `now()` handles both). The existing-row lookup happens INSIDE the `on
  -- conflict do update set expires_at = ...` expression itself (referencing `entitlements.
  -- expires_at`, i.e. the row as Postgres has it locked at update time) rather than in a separate
  -- preceding SELECT, precisely so a concurrent second redemption (a different code, same user,
  -- landing in the same instant) can't read a stale `expires_at` and stomp the other's stacked
  -- result — the whole read-and-add happens under the row lock the UPDATE itself takes.
  --
  -- Conflict target is `(user_id, source)` — the primary key `entitlements` already has (0003) —
  -- so this can only ever touch THIS user's `'promo'` row. It is structurally incapable of
  -- touching that same user's `'apple'` or `'mor'` row: those live at different primary keys and
  -- are never named in this statement.
  insert into public.entitlements as e
    (user_id, source, external_id, tier, product_id, expires_at, updated_at)
  values (
    p_user,
    'promo',
    v_code || ':' || p_user::text,
    'pro',
    'promo:' || v_code,
    now() + (v_promo.grant_days || ' days')::interval,
    now()
  )
  on conflict (user_id, source) do update
  set external_id = excluded.external_id,
      tier        = 'pro',
      product_id  = excluded.product_id,
      expires_at  = greatest(now(), coalesce(e.expires_at, now()))
                      + (v_promo.grant_days || ' days')::interval,
      updated_at  = now()
  returning e.expires_at into v_new_expires;

  -- Step 8.
  return query select 'ok'::text, v_new_expires, v_promo.grant_days;
end;
$$;

revoke all on function public.redeem_promo_code(uuid, text, int) from public;
revoke all on function public.redeem_promo_code(uuid, text, int) from anon;
revoke all on function public.redeem_promo_code(uuid, text, int) from authenticated;
grant execute on function public.redeem_promo_code(uuid, text, int) to service_role;

-- ---------------------------------------------------------------------------------------------
-- NOTE (follow-up, not implemented here): `promo_attempts` is never pruned, same as
-- `usage_counters` (0002's follow-up note) and `parse_quota`/`parse_rate_limit` (0001's). Tracked
-- as a backend follow-up (see backlog.md) rather than solved here.
-- ---------------------------------------------------------------------------------------------
