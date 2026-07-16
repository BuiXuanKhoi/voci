# Voci Supabase backend

Serverless appendix for the Voci macOS app (spec `002-workflow-command-center`). Currently
implements one route: `POST /functions/v1/parse` — see
`../specs/002-workflow-command-center/contracts/parse-proxy.md` for the wire contract this code
implements exactly (status codes, field names, caps). `groq/` is a documented placeholder
(separate backlog item, not implemented).

```text
supabase/
├── migrations/
│   └── 0001_parse_quota.sql   # parse_quota + parse_rate_limit tables, atomic RPC increments
└── functions/
    ├── parse/index.ts         # the route
    ├── groq/README.md         # not implemented — pointer to backlog
    └── _shared/                # auth.ts, quota.ts, schema.ts, gemini.ts, env.ts, log.ts, http.ts
```

## Deploy

Requires the [Supabase CLI](https://supabase.com/docs/guides/cli) and a linked project.

```bash
supabase login
supabase link --project-ref <your-project-ref>

# Apply the migration (parse_quota / parse_rate_limit tables + RPC functions)
supabase db push

# Set secrets (see full list below) — repeat `supabase secrets set` per key, or use --env-file
supabase secrets set --env-file ./supabase/.env.deploy   # never commit this file

# Deploy the function
supabase functions deploy parse
```

`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` do **not** need to be set manually — the Edge
Functions runtime injects them automatically for every deployed function. Everything else below
must be set explicitly via `supabase secrets set`.

## Required secrets / env

The function fails closed (typed `503 config_missing`, naming exactly which keys are absent —
never a silent bypass) for any auth path whose config is missing. Nothing here is optional if you
want that path to work; both auth paths can be configured independently (e.g. ship paid-only
first).

| Var | Required for | Description |
|---|---|---|
| `GEMINI_API_KEY` | all requests | Gemini API key. Never returned to clients; used server-side only. |
| `PARSE_MODEL` | optional | Overrides the default Flash-Lite class model (`gemini-3.1-flash-lite` at time of writing — **verify this id is still current in Google AI Studio before deploy**, Gemini retires model ids on a rolling basis). |
| `PARSE_UPSTREAM_TIMEOUT_MS` | optional | Gemini request timeout. Default `20000`. |
| `PARSE_DAILY_QUOTA` | free-tier auth | Free-tier daily parse cap per device. Default `50`. Tune without redeploying the function — just update the secret. |
| `PARSE_PAID_RPM` | paid-tier auth | Soft per-minute rate limit for the unmetered paid tier (abuse bound, not a real quota). Default `20`. |
| `APPSTORE_BUNDLE_ID` | paid (JWS) auth | Your app's bundle id, checked against the verified transaction. |
| `APPSTORE_ENVIRONMENT` | paid (JWS) auth | `Sandbox` or `Production`. |
| `APPSTORE_APP_APPLE_ID` | paid (JWS) auth, **Production only** | Numeric App Store id, required by `SignedDataVerifier` in Production. |
| `APPSTORE_ROOT_CA_PEM` | paid (JWS) auth | One or more Apple root certificates, PEM, concatenated. Download from the "Apple Root Certificates" section of https://www.apple.com/certificateauthority/ — **do not hand-type or reconstruct these from memory; use the exact files Apple publishes.** |
| `APPATTEST_TEAM_ID` | free (App Attest) auth | Your Apple Developer Team ID. |
| `APPATTEST_BUNDLE_ID` | free (App Attest) auth | App bundle id (combined with team id as `appId` for App Attest). |
| `APPATTEST_ENV` | free (App Attest) auth | `development` or `production`. |

## Auth design

### Paid: StoreKit JWS (`Authorization: Bearer <jws>`)

Verified with Apple's official `@apple/app-store-server-library` (npm, pinned `3.1.0`) —
`SignedDataVerifier.verifyAndDecodeTransaction`, which validates the x5c certificate chain in the
JWS header against the Apple root certs you provide, checks `alg` (this code additionally
pins/rejects non-`ES256` before calling the library, belt-and-suspenders), and decodes the
transaction payload. Unmetered, but soft-rate-limited (`PARSE_PAID_RPM`) keyed by
`SHA-256(bundleId:originalTransactionId)` to bound abuse of an otherwise-unlimited path.

**Assumption flagged for reconciliation against the Swift client (`CloudParser`, spec task
T021):** this code assumes the client sends a `Transaction.jwsRepresentation` from
`Transaction.currentEntitlements` (proof of an active purchase — has `originalTransactionId`), not
an `AppTransaction` JWS (proof of app install — no transaction id). If the client sends
`AppTransaction` instead, swap `verifyAndDecodeTransaction` for `verifyAndDecodeAppTransaction` in
`_shared/auth.ts` (`verifyPaidAuth`) and derive the rate-limit key from a different stable field.

**Needs before this path can go live:** `APPSTORE_BUNDLE_ID`, `APPSTORE_ENVIRONMENT`,
`APPSTORE_ROOT_CA_PEM` (and `APPSTORE_APP_APPLE_ID` in Production) set as secrets; App Store
Connect must have an app record (for the bundle id / Apple ID) even in Sandbox testing.

### Free: App Attest (`X-Device-Token: <token>`)

**Design note — why App Attest, not raw DeviceCheck, despite the contract text saying
"DeviceCheck":** a raw `DCDevice.generateToken()` token is a bearer credential Apple validates,
but carries no stable per-device identifier — two tokens from the same physical device cannot be
linked to each other, which makes "N free parses per device per day" impossible to enforce with
DeviceCheck alone. App Attest's `keyId` (from a one-time `DCAppAttestService.generateKey()` +
`attestKey()` ceremony) *is* stable per device+app-install, so `SHA-256(keyId)` becomes the
counter key: it identifies "a device that passed Apple's attestation once," never a person, never
reused across apps. Each request then carries a fresh `assertion` (from `generateAssertion()`)
over that request, so the token itself isn't a replayable static secret either.

**Wire format** the client must send in `X-Device-Token` (base64url of):

```json
{ "keyId": "<base64 Data from generateKey>",
  "assertion": "<base64 Data from generateAssertion>",
  "clientDataHashB64": "<base64 SHA-256 the client signed over>" }
```

**Current status — structural checks only, cryptographic verification gated to `503`:** this
route validates the token's *shape* unconditionally (well-formed base64, correct byte lengths for
`keyId`/`clientDataHashB64` — malformed tokens get a cheap `401`, never counted against quota).
The final step — verifying `assertion`'s signature against the public key Apple attested for
`keyId` — needs a public-key registry populated by a **one-time attestation/registration ceremony**
(`attestKey()` + server-side `verifyAttestation`) that **does not exist yet**: there is no
`/attest/register` endpoint and no key-storage table in this deliverable (only `/parse` was in
scope — see `specs/002-workflow-command-center/tasks.md` T004/T022). Until that registry exists,
`verifyFreeAuth` in `_shared/auth.ts` fails closed with `503 config_missing` for otherwise
well-formed tokens — **never** a silent "treat unverified as verified." See
`_shared/auth.ts`'s `AppAttestKeyStore` interface / `UnimplementedAppAttestKeyStore` — swap in a
real Postgres-backed store once the registration ceremony is built (tracked as a follow-up).

**Needs before this path can go live:** `APPATTEST_TEAM_ID`, `APPATTEST_BUNDLE_ID`,
`APPATTEST_ENV` secrets, **plus** the registration endpoint + key-storage table (not built here).

## Quota tuning

`PARSE_DAILY_QUOTA` (free) and `PARSE_PAID_RPM` (paid) are both read fresh from env on every
request — retune by updating the secret, no redeploy needed. The daily counter resets at **00:00
UTC**, not device-local midnight (`_shared/quota.ts` computes the day from
`Date.prototype.toISOString()`, which always normalizes to UTC). Both counters are stored in
Postgres and incremented atomically in one round trip via `parse_quota_increment` /
`parse_rate_increment` (SQL `INSERT ... ON CONFLICT ... DO UPDATE SET count = count + 1`) — see
`migrations/0001_parse_quota.sql`. Neither table is pruned yet; a `pg_cron` cleanup job is a
tracked follow-up (comment in the migration file).

## curl examples

Paid (StoreKit JWS):

```bash
curl -sS https://<project-ref>.supabase.co/functions/v1/parse \
  -H "Authorization: Bearer <storekit-jws>" \
  -H "Content-Type: application/json" \
  -d '{
        "transcript": "gọi cho khách hàng lúc 3 giờ chiều mai",
        "locale_hint": "vi",
        "now": "2026-07-16T09:00:00+07:00",
        "open_task_titles": []
      }'
```

Free (App Attest device token):

```bash
DEVICE_TOKEN=$(printf '%s' '{"keyId":"<base64>","assertion":"<base64>","clientDataHashB64":"<base64>"}' | base64 | tr '+/' '-_' | tr -d '=')

curl -sS https://<project-ref>.supabase.co/functions/v1/parse \
  -H "X-Device-Token: $DEVICE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
        "transcript": "email John after finishing the report",
        "locale_hint": "en",
        "now": "2026-07-16T09:00:00Z",
        "open_task_titles": ["Finish quarterly report"]
      }'
```

Breakdown mode (either auth header works the same way):

```bash
curl -sS https://<project-ref>.supabase.co/functions/v1/parse \
  -H "Authorization: Bearer <storekit-jws>" \
  -H "Content-Type: application/json" \
  -d '{"mode":"breakdown","task_title":"Write the Q3 report","notes":"needs sales numbers"}'
```

## Local development

```bash
supabase start
supabase functions serve parse --env-file ./supabase/.env.local --no-verify-jwt
```

`--no-verify-jwt` is required: this route uses its own two auth modes (JWS / App Attest), not
Supabase's built-in anon/authenticated JWT gate — the default gate would reject every request
before it reaches `index.ts`.
