# Volar Supabase backend

Serverless appendix for the Volar macOS app (spec `002-workflow-command-center`). Auth model is
**Supabase Auth accounts** — see
`../specs/002-workflow-command-center/contracts/account-auth.md` for the CHỐT wire contract this
code implements exactly (status codes, field names, gate order, schema). That contract supersedes
the device-based auth design in `contracts/parse-proxy.md` / `docs/product-vision-v2.md`.

Three functions:

- `POST /functions/v1/parse` — task parsing/breakdown (Gemini). Both `free` and `pro` accounts may
  call it; only the daily quota differs.
- `POST /functions/v1/groq/audio/transcriptions` — Groq Speech-to-Text proxy. Both `free` and `pro`
  accounts may call it; only the daily quota differs (`SPEECH_LIMIT_FREE` / `SPEECH_LIMIT_PRO`).
- `subscription` — four routes: `POST /link`, `GET /status`, `POST /delete-account`,
  `POST /redeem`. See `functions/subscription/index.ts`.

```text
supabase/
├── migrations/
│   ├── 0001_parse_quota.sql                    # SUPERSEDED — old device-keyed tables, dropped by 0002
│   ├── 0002_accounts_entitlements.sql          # entitlements (SUPERSEDED shape, see 0003) + usage_counters + consume_quota RPC
│   ├── 0003_entitlements_multi_source.sql      # entitlements -> one row per (user_id, source); current shape, see "Auth design" below
│   └── 0004_promo_codes.sql                    # promo_codes / promo_redemptions / promo_attempts + redeem_promo_code RPC; adds 'promo' to entitlements.source
└── functions/
    ├── parse/index.ts         # the parse/breakdown route
    ├── groq/index.ts          # the Groq Speech-to-Text proxy route (both tiers, tiered daily cap)
    ├── groq/README.md         # groq's own contract/threat-model/curl notes
    ├── subscription/index.ts  # /link, /status, /delete-account, /redeem
    └── _shared/               # auth.ts, appstore.ts, quota.ts, schema.ts, gemini.ts, env.ts,
                                # log.ts, http.ts
```

## Deploy

Requires the [Supabase CLI](https://supabase.com/docs/guides/cli) and a linked project.

```bash
supabase login
supabase link --project-ref <your-project-ref>

# Apply migrations (entitlements / usage_counters tables + consume_quota RPC, entitlements later
# redefined by 0003 as one row per (user_id, source); also drops the old device-keyed
# parse_quota / parse_rate_limit objects from 0001; 0004 adds 'promo' as a third entitlements
# source plus promo_codes / promo_redemptions / promo_attempts and the redeem_promo_code RPC —
# see "Promo codes" below)
supabase db push

# Set secrets (see full list below) — repeat `supabase secrets set` per key, or use --env-file
supabase secrets set --env-file ./supabase/.env.deploy   # never commit this file

# Deploy the functions
supabase functions deploy parse
supabase functions deploy groq
supabase functions deploy subscription
```

`SUPABASE_URL`, `SUPABASE_ANON_KEY`, and `SUPABASE_SERVICE_ROLE_KEY` do **not** need to be set
manually — the Edge Functions runtime injects them automatically for every deployed function.
Everything else below must be set explicitly via `supabase secrets set`.

If you are retiring the old device-based deployment, also remove the now-unused secret:

```bash
supabase secrets unset PARSE_DEV_TOKEN APPATTEST_TEAM_ID APPATTEST_BUNDLE_ID APPATTEST_ENV
```

(`PARSE_DEV_TOKEN` and the App Attest test-bypass this project used before real accounts existed
have been deleted from the code entirely — see `functions/_shared/auth.ts`'s module doc comment.)

## Required secrets / env

The function fails closed (typed `503 {"error":"service_unavailable"}`) for any missing config —
never a silent bypass. The HTTP response body is deliberately opaque: no key names, no upstream
detail, no "which check failed" (see `functions/_shared/http.ts`'s `ApiErrorCode` — every error body
is `{"error":"<code>"}`, from a fixed list, plus `resetAt` on 429). The specific missing key names
are logged server-side instead (see `_shared/log.ts`), so an operator can `supabase functions logs
<name>` to see exactly what's absent.

| Var | Required for | Description |
|---|---|---|
| `SUPABASE_URL` / `SUPABASE_ANON_KEY` / `SUPABASE_SERVICE_ROLE_KEY` | all requests, all functions | Injected automatically by the Edge Functions runtime; not set manually. `ANON_KEY` is used (with the caller's own token layered on top) purely to call `auth.getUser()` — see `_shared/auth.ts`'s module doc comment for why this is safe and why `verify_jwt = false` in `config.toml` is intentional. |
| `GEMINI_API_KEY` | `parse` | Gemini API key. Never returned to clients; used server-side only. |
| `PARSE_MODEL` | optional | Overrides the default Flash-Lite class model (`gemini-3.1-flash-lite` at time of writing — **verify this id is still current in Google AI Studio before deploy**, Gemini retires model ids on a rolling basis). |
| `PARSE_UPSTREAM_TIMEOUT_MS` | optional | Gemini request timeout. Default `20000`. |
| `PARSE_LIMIT_FREE` | optional | Free-tier daily `/parse` cap per account. Default `20`. |
| `PARSE_LIMIT_PRO` | optional | Pro-tier daily `/parse` cap per account (fair-use, not a hard sales limit). Default `500`. |
| `SPEECH_LIMIT_FREE` | optional | Free-tier daily `/groq` cap per account. Default `20`. |
| `SPEECH_LIMIT_PRO` | optional | Pro-tier daily `/groq` cap per account. Default `500`. |
| `GROQ_API_KEY` | `groq` | Groq API key for the Speech-to-Text proxy. See `functions/groq/README.md` for this function's full env list (`GROQ_BASE_URL`, `GROQ_MAX_AUDIO_BYTES`, `GROQ_UPSTREAM_TIMEOUT_MS`). |
| `APPSTORE_BUNDLE_ID` | `subscription` (`/link`) | Your app's bundle id, checked against the verified StoreKit transaction. |
| `APPSTORE_ENVIRONMENT` | `subscription` (`/link`) | `Sandbox` or `Production`. |
| `APPSTORE_APP_APPLE_ID` | `subscription` (`/link`), **Production only** | Numeric App Store id, required by `SignedDataVerifier` in Production. |
| `APPSTORE_ROOT_CA_PEM` | `subscription` (`/link`) | One or more Apple root certificates, PEM, concatenated. Download from the "Apple Root Certificates" section of https://www.apple.com/certificateauthority/ — **do not hand-type or reconstruct these from memory; use the exact files Apple publishes.** |

## Auth design

Every route authenticates the same way: `Authorization: Bearer <supabase access_token>`, a real
Supabase Auth session token the client obtained by signing in (Apple, or email OTP — see contract
§2; those calls go straight to Supabase GoTrue, not through any of these functions).
`_shared/auth.ts`'s `verifyAccount(req)`:

1. Extracts the bearer token (shape checks only).
2. Verifies it is a REAL user token — not the public anon/publishable key — by building a
   Supabase client from `SUPABASE_URL` + `SUPABASE_ANON_KEY` with the CALLER's token as that
   client's own `Authorization` header, then calling `auth.getUser()`. A real user token resolves
   to a user; the anon key does not. **This is why `config.toml` keeps `verify_jwt = false`**: the
   platform gateway's JWT check only verifies "is this some validly-signed JWT for this project",
   and the public anon key IS one — so gateway-level verification would accept the anon key as
   authentication, which it is not. `verifyAccount`'s `getUser()` call is the actual authentication
   boundary, done inside the function itself.
3. Loads `entitlements` (service-role client — RLS-enabled, zero policies, service-role only) and
   resolves the effective tier. Since `migrations/0003_entitlements_multi_source.sql`, `entitlements`
   is one row per `(user_id, source)` — `'apple'` (StoreKit / Mac App Store) and `'mor'` (the
   merchant-of-record web checkout used by the Windows build) can both exist for the same user — so
   this loads ALL of that user's rows, not a single row. The effective tier is "any-row-wins": `pro`
   if AT LEAST ONE row has `tier = 'pro' AND expires_at > now()`, else `free` (including "no rows at
   all", the normal state for a free account that never subscribed on any platform). Entitlements
   from different sources are never summed — a user Pro-until-March on Apple and Pro-until-June on
   the MoR is Pro until June, not until September.

StoreKit JWS verification (`_shared/appstore.ts`, using Apple's official
`@apple/app-store-server-library`, pinned `3.1.0`) is a SEPARATE concern from bearer auth: it is
only ever called from `subscription/index.ts`'s `/link` route, where a JWS is submitted **once**
(and again on each renewal) as the request BODY to attach/refresh a Pro entitlement on the caller's
already-authenticated account. It is never a bearer credential on any route.

**Needs before `/link` can go live:** `APPSTORE_BUNDLE_ID`, `APPSTORE_ENVIRONMENT`,
`APPSTORE_ROOT_CA_PEM` (and `APPSTORE_APP_APPLE_ID` in Production) set as secrets; App Store Connect
must have an app record (for the bundle id / Apple ID) even in Sandbox testing.

## Quota

`PARSE_LIMIT_FREE`, `PARSE_LIMIT_PRO`, `SPEECH_LIMIT_FREE`, `SPEECH_LIMIT_PRO` are all read fresh from env on every
request — retune by updating the secret, no redeploy needed. The daily counter resets at **00:00
UTC**, not device-local midnight (`_shared/quota.ts` / the `consume_quota` SQL function both use
UTC). Counters are stored in Postgres and incremented atomically in one round trip via the
`consume_quota` RPC (`INSERT ... ON CONFLICT ... DO UPDATE SET count = count + 1 WHERE count <
limit`) — see `migrations/0002_accounts_entitlements.sql`. `/parse` and `/groq` ("speech") each have
their OWN independent daily counter (keyed by a `route` column) — this closes a defect the old
device-keyed design had, where both routes shared one bucket and could 429 each other.
`usage_counters` is never pruned yet; a `pg_cron` cleanup job is a tracked follow-up (comment in the
migration file / backlog.md).

## Promo codes

`migrations/0004_promo_codes.sql` adds a SHARED promo-code redemption path: one code string (e.g.
`"VOLARLAUNCH"`), created directly in `promo_codes` (never via a migration — codes are not
committed to source control), that MANY different accounts can each redeem ONCE for a Pro grant.

- `promo_codes` — one row per code string, stored uppercase. `grant_days` (default 30), an
  optional `max_redemptions` cap (how many DISTINCT PEOPLE may redeem it — a cost ceiling, separate
  from the once-per-person rule below), an optional `expires_at`, and an `active` kill switch.
- `promo_redemptions` — primary key `(code, user_id)`. This table's composite primary key IS the
  once-per-person enforcement mechanism (not just a log): a bare `insert`, caught for a `23505`
  unique-violation, is how `redeem_promo_code` detects "this user already redeemed this code".
- `promo_attempts` — per-`(user_id, day)` brute-force counter (a shared code is guessable; a
  correct guess is a free month), same atomic increment-and-check shape as `consume_quota`.
- `redeem_promo_code(p_user, p_code, p_max_attempts default 10)` — one `security definer` RPC that
  does the entire redemption atomically: normalize the code, check/bump the attempt counter, lock
  and validate the code row, check `max_redemptions`, insert the once-per-person redemption row,
  bump `redeemed_count`, and upsert a `source = 'promo'` row onto `entitlements` (stacking: a
  second redemption while a promo grant is still live EXTENDS it rather than resetting it; an
  expired old promo grant does not eat the new one). `external_id` is `'<code>:<user_id>'`, not the
  bare code — `entitlements` carries `unique (source, external_id)` from 0003, so a bare code would
  let only ONE person in the whole system hold a `'promo'` row. `entitlements.source`'s CHECK
  constraint is widened from 0003's `('apple', 'mor')` to include `'promo'` as a third, independent
  grant source (its own row per `(user_id, source)`, exactly like `'apple'`/`'mor'` — see the
  migration file's own comment for why a promo month cannot safely be a flag on an existing row).
- `POST /functions/v1/subscription/redeem` (`functions/subscription/index.ts`) is the only caller
  of this RPC. It maps the RPC's `status` onto the HTTP contract below; an unrecognized status is
  always a `503`, never a success. The submitted code is NEVER logged and NEVER echoed back in any
  response body, success or failure — only `userIdHash`, the outcome status, and latency are
  logged, matching this whole backend's logging discipline (`_shared/log.ts`).

| Case | HTTP | Body |
|---|---|---|
| success | 200 | `{"tier":"pro","expiresAt":"<ISO8601>","grantedDays":30,"source":"promo"}` |
| bad/missing body | 400 | `{"error":"invalid_request"}` |
| no/invalid token | 401 | existing auth shapes (`auth_missing` / `auth_invalid`) |
| unknown/expired/inactive code | 404 | `{"error":"code_invalid"}` |
| already redeemed by this user | 409 | `{"error":"already_redeemed"}` |
| code hit `max_redemptions` | 410 | `{"error":"code_exhausted"}` |
| too many wrong attempts today | 429 | `{"error":"too_many_attempts"}` |
| anything else | 503 | `{"error":"service_unavailable"}` |

These four new codes (`code_invalid`, `already_redeemed`, `code_exhausted`, `too_many_attempts`)
are specific to `/redeem` and deliberately NOT added to `_shared/http.ts`'s `ApiErrorCode` list —
`/redeem` builds those particular response bodies itself.

Codes are created directly against the database (never via a migration, never committed to source
control), e.g.:

```sql
insert into public.promo_codes (code, grant_days, max_redemptions, note)
values ('VOLARLAUNCH', 30, 50, 'launch giveaway 2026-07');
```

## curl examples

```bash
ACCESS_TOKEN="<supabase access_token from a signed-in session>"

curl -sS https://<project-ref>.supabase.co/functions/v1/parse \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
        "transcript": "gọi cho khách hàng lúc 3 giờ chiều mai",
        "locale_hint": "vi",
        "now": "2026-07-16T09:00:00+07:00",
        "open_task_titles": [],
        "timezone": "Asia/Ho_Chi_Minh"
      }'
```

Breakdown mode:

```bash
curl -sS https://<project-ref>.supabase.co/functions/v1/parse \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"mode":"breakdown","task_title":"Write the Q3 report","notes":"needs sales numbers"}'
```

Link a subscription:

```bash
curl -sS https://<project-ref>.supabase.co/functions/v1/subscription/link \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"jws":"<signedTransaction from StoreKit 2>"}'
```

Check status:

```bash
curl -sS https://<project-ref>.supabase.co/functions/v1/subscription/status \
  -H "Authorization: Bearer $ACCESS_TOKEN"
```

Delete account (Apple Guideline 5.1.1(v)):

```bash
curl -sS -X POST https://<project-ref>.supabase.co/functions/v1/subscription/delete-account \
  -H "Authorization: Bearer $ACCESS_TOKEN"
```

Redeem a promo code:

```bash
curl -sS https://<project-ref>.supabase.co/functions/v1/subscription/redeem \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"code":"VOLARLAUNCH"}'
```

## Local development

```bash
supabase start
supabase functions serve parse --env-file ./supabase/.env.local --no-verify-jwt
```

`--no-verify-jwt` is required: these routes do their own auth (`verifyAccount`), not Supabase's
built-in gateway JWT gate — see "Auth design" above for why the gateway check is not the real
authentication boundary here. The default gate would reject every request before it reaches
`index.ts` (or worse, accept the anon key as if it were a user).
