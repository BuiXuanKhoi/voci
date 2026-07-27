-- 0003_entitlements_multi_source.sql
-- Fixes a money-losing bug in 0002's `entitlements` table, not a refactor.
--
-- 0002 modeled `entitlements` as ONE ROW PER USER (`user_id` primary key), with
-- `original_transaction_id text unique` across the whole table. The product now sells on TWO
-- platforms: macOS via Apple StoreKit, and Windows via a web checkout through a merchant-of-record
-- (Lemon Squeezy). Both platforms write entitlements for the SAME user. With one row per user, the
-- two webhooks fight over that single row: a user buys Pro on Mac, then cancels a trial on the web,
-- and the MoR webhook writes `tier = 'free'` onto that one row — ERASING the Pro they actually paid
-- Apple for.
--
-- Fix: one row per `(user_id, source)`. The effective tier is "pro if ANY of the user's rows is pro
-- and unexpired" (computed in `_shared/auth.ts`, see the comment above `entitlements` below — it is
-- NOT stored). Entitlements from different sources are never summed or added together.
--
-- Safe to re-run (`drop ... if exists`, `create ... if not exists` where applicable — the table
-- itself is unconditionally dropped and recreated, matching how 0002 treated 0001).
--
-- SAFETY (verified against the live database immediately before writing this migration):
-- `entitlements` has 0 rows, `usage_counters` has 0 rows, `auth.users` has 0 users. Nothing has ever
-- been sold — the App Store Connect products do not exist yet. So this migration drops and
-- recreates `entitlements` outright with NO backfill and NO data-preservation logic, exactly the
-- way 0002 dropped 0001's device-keyed tables. Do not add backfill code later for this migration;
-- it would be dead code implying data existed at the time this ran, which it did not.

-- ---------------------------------------------------------------------------------------------
-- Drop and recreate `entitlements` under the new (user_id, source) shape. This cascades nothing
-- else: `usage_counters` (0002) has no foreign key into `entitlements` and is untouched by this
-- migration.
-- ---------------------------------------------------------------------------------------------
drop table if exists public.entitlements;

-- ---------------------------------------------------------------------------------------------
-- entitlements: one row per (Supabase Auth user, billing source) — NOT one row per user. A `free`
-- user who has never subscribed on ANY platform has NO rows at all; `_shared/auth.ts`'s
-- `verifyAccount` treats "no rows" the same as "no row is pro", which is the normal state for an
-- account that never subscribed.
--
-- `source`: which billing system owns this row. `'apple'` = StoreKit / Mac App Store; `'mor'` = the
-- merchant-of-record web checkout used by the Windows build (Lemon Squeezy). The CHECK constraint
-- is deliberately narrow so a typo'd source from a future webhook (a third platform added carelessly,
-- or a copy-paste bug) fails loudly with a constraint violation instead of silently creating a third,
-- invisible entitlement source nothing else knows to look for.
--
-- `external_id`: the billing system's OWN subscription identifier — Apple's `originalTransactionId`
-- for `'apple'`, the MoR's own subscription id for `'mor'`. This replaces 0002's
-- `original_transaction_id` column, generalized to whichever source wrote the row.
--
-- `primary key (user_id, source)`: this is what makes the two webhooks unable to clobber each
-- other. Apple's webhook always upserts the `('apple')` row for a user; the MoR's webhook always
-- upserts the `('mor')` row for the same user; neither can overwrite the other's row anymore. This
-- is the conflict target for every upsert into this table (see `subscription/index.ts`'s `/link`
-- route).
--
-- `unique (source, external_id)`: replaces 0002's table-wide `original_transaction_id unique`,
-- scoped BY SOURCE now because an Apple transaction id and a MoR subscription id live in different
-- namespaces and could theoretically collide as strings (they are opaque identifiers minted by two
-- unrelated third parties). This constraint is LOAD-BEARING beyond just data hygiene: it is what
-- still lets `POST /subscription/link` detect "this Apple subscription is already claimed by a
-- DIFFERENT account" from a single upsert's 23505 unique-violation, instead of a separate
-- read-then-write check that would race. Do not drop or weaken this constraint without replacing
-- that detection path.
--
-- "Effective tier" is intentionally NOT a column on this table — it is computed per request in
-- `_shared/auth.ts` as "any row pro and unexpired", and rows from different sources are never added
-- together. A user with an Apple row pro-until-March and a MoR row pro-until-June is Pro until June
-- (the later of the two), not until September — durations from different sources never stack.
-- ---------------------------------------------------------------------------------------------
create table public.entitlements (
  user_id     uuid        not null references auth.users(id) on delete cascade,
  source      text        not null check (source in ('apple', 'mor')),
  external_id text        not null,
  tier        text        not null default 'free' check (tier in ('free', 'pro')),
  product_id  text,
  expires_at  timestamptz,
  updated_at  timestamptz not null default now(),
  primary key (user_id, source),
  unique (source, external_id)
);

alter table public.entitlements enable row level security;
-- Intentionally no policies: RLS with zero policies == zero access for anon/authenticated. Only
-- the service-role key (used exclusively by the Edge Functions, never shipped to a client) can
-- read or write this table. Client code must never query it directly.

-- ---------------------------------------------------------------------------------------------
-- `usage_counters` and `consume_quota` are unaffected by this migration — they belong to 0002 and
-- are not redefined here. Nothing about the multi-source entitlements change touches per-route
-- daily quota accounting.
-- ---------------------------------------------------------------------------------------------
