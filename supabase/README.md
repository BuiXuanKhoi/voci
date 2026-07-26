# Volar Supabase backend

Serverless appendix for the Volar macOS app (spec `002-workflow-command-center`). Auth model is
**Supabase Auth accounts** — see
`../specs/002-workflow-command-center/contracts/account-auth.md` for the CHỐT wire contract this
code implements exactly (status codes, field names, gate order, schema). That contract supersedes
the device-based auth design in `contracts/parse-proxy.md` / `docs/product-vision-v2.md`.

Three functions:

- `POST /functions/v1/parse` — task parsing/breakdown (Gemini). Both `free` and `pro` accounts may
  call it; only the daily quota differs.
- `POST /functions/v1/groq/audio/transcriptions` — Groq Speech-to-Text proxy. **Pro-only**; a free
  account gets `403 upgrade_required` and falls back to on-device WhisperKit.
- `subscription` — three routes: `POST /link`, `GET /status`, `POST /delete-account`. See
  `functions/subscription/index.ts`.

```text
supabase/
├── migrations/
│   ├── 0001_parse_quota.sql            # SUPERSEDED — old device-keyed tables, dropped by 0002
│   └── 0002_accounts_entitlements.sql  # entitlements + usage_counters + consume_quota RPC
└── functions/
    ├── parse/index.ts         # the parse/breakdown route
    ├── groq/index.ts          # the Groq Speech-to-Text proxy route (Pro-only)
    ├── groq/README.md         # groq's own contract/threat-model/curl notes
    ├── subscription/index.ts  # /link, /status, /delete-account
    └── _shared/               # auth.ts, appstore.ts, quota.ts, schema.ts, gemini.ts, env.ts,
                                # log.ts, http.ts
```

## Deploy

Requires the [Supabase CLI](https://supabase.com/docs/guides/cli) and a linked project.

```bash
supabase login
supabase link --project-ref <your-project-ref>

# Apply migrations (entitlements / usage_counters tables + consume_quota RPC; also drops the old
# device-keyed parse_quota / parse_rate_limit objects from 0001)
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
   resolves the effective tier: `pro` only if `tier = 'pro' AND expires_at > now()`, else `free`
   (including "no row at all", the normal state for a free account).

StoreKit JWS verification (`_shared/appstore.ts`, using Apple's official
`@apple/app-store-server-library`, pinned `3.1.0`) is a SEPARATE concern from bearer auth: it is
only ever called from `subscription/index.ts`'s `/link` route, where a JWS is submitted **once**
(and again on each renewal) as the request BODY to attach/refresh a Pro entitlement on the caller's
already-authenticated account. It is never a bearer credential on any route.

**Needs before `/link` can go live:** `APPSTORE_BUNDLE_ID`, `APPSTORE_ENVIRONMENT`,
`APPSTORE_ROOT_CA_PEM` (and `APPSTORE_APP_APPLE_ID` in Production) set as secrets; App Store Connect
must have an app record (for the bundle id / Apple ID) even in Sandbox testing.

## Quota

`PARSE_LIMIT_FREE`, `PARSE_LIMIT_PRO`, `SPEECH_LIMIT_PRO` are all read fresh from env on every
request — retune by updating the secret, no redeploy needed. The daily counter resets at **00:00
UTC**, not device-local midnight (`_shared/quota.ts` / the `consume_quota` SQL function both use
UTC). Counters are stored in Postgres and incremented atomically in one round trip via the
`consume_quota` RPC (`INSERT ... ON CONFLICT ... DO UPDATE SET count = count + 1 WHERE count <
limit`) — see `migrations/0002_accounts_entitlements.sql`. `/parse` and `/groq` ("speech") each have
their OWN independent daily counter (keyed by a `route` column) — this closes a defect the old
device-keyed design had, where both routes shared one bucket and could 429 each other.
`usage_counters` is never pruned yet; a `pg_cron` cleanup job is a tracked follow-up (comment in the
migration file / backlog.md).

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
        "open_task_titles": []
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

## Local development

```bash
supabase start
supabase functions serve parse --env-file ./supabase/.env.local --no-verify-jwt
```

`--no-verify-jwt` is required: these routes do their own auth (`verifyAccount`), not Supabase's
built-in gateway JWT gate — see "Auth design" above for why the gateway check is not the real
authentication boundary here. The default gate would reject every request before it reaches
`index.ts` (or worse, accept the anon key as if it were a user).
