# `groq` Edge Function — Groq Speech-to-Text proxy (Pro-only)

Implements `POST /functions/v1/groq/audio/transcriptions` — the server-side proxy
`Volar/Sources/Speech/GroqTranscriptionClient.swift` talks to in production. The client always
appends `audio/transcriptions` to whatever base URL its credential provider returns; this
function's base URL (project ref's `/functions/v1/groq`) plus that suffix is the exact route
implemented here.

See `specs/002-workflow-command-center/contracts/account-auth.md` §1/§3 for the product decision
this implements (cloud speech is Pro-only in the freemium matrix), and `../parse/index.ts` /
`../../README.md` for the sibling route this one mirrors in structure, error shapes, and logging
discipline.

## Why this exists (threat model, short version)

The Groq API key must never live in the app binary or cross the network to a client — a key
embedded in the app is trivially extracted (strings on the binary, MITM on the `Authorization`
header, memory dump) and Groq bills/rate-limits per key, so a leaked key is a direct cost and abuse
exposure. This function holds the key in Supabase Secrets, gates access by a real Pro account, and
forwards only the audio the caller already had.

## Auth: account-based, Pro-only

Every request must carry `Authorization: Bearer <supabase access_token>`, verified by
`../_shared/auth.ts`'s `verifyAccount` — the exact same function `../parse` uses. A **free**
account authenticates successfully (the credential is valid) but is then rejected by a separate
tier check with `403 {"error":"upgrade_required"}` — the client is expected to fall back to
on-device WhisperKit silently on that response, at zero server cost. Anything that isn't a valid
account bearer (missing header, expired/garbage token, anon key presented as a bearer) gets the
same opaque `401` shape `verifyAccount` already produces for `/parse`.

Quota is a Pro-only daily cap (`SPEECH_LIMIT_PRO`, default 500/day), enforced via the atomic
`consume_quota` RPC keyed on `(user_id, route='speech', day)` — see `../_shared/quota.ts` and
`../../migrations/0002_accounts_entitlements.sql`. This is an INDEPENDENT counter from `/parse`'s
`route='parse'` bucket — the two routes can no longer 429 each other (this used to be a known gap
under the old device-keyed rate limiter, which shared one bucket across both routes; it's fixed by
giving `usage_counters` its own `route` column).

There is no StoreKit JWS on this (or any) request anymore — JWS is submitted only once, as the
BODY of `POST /subscription/link`, to attach/renew the Pro entitlement this route checks. See
`../_shared/appstore.ts` for where that verification lives now.

## Request / response shape

- Method: `POST` only (`OPTIONS` answers `204` for preflight parity; any other method or an
  incorrect path is rejected before any auth/quota/upstream work happens).
- Body: `multipart/form-data`, passed through to Groq's OpenAI-compatible
  `/audio/transcriptions` endpoint almost as-is. The `language` field (sent by the client when the
  user picked a specific locale in Settings' Recognition-language picker instead of "Automatic") is
  forwarded only if it is a strict two-letter lowercase ISO-639-1 code (`/^[a-z]{2}$/`) — anything
  else for that field is dropped, since it's untrusted client input. Omitting the field (the
  "Automatic" picker choice) still gets Groq's own auto-detect (needed for Vietnamese/English
  code-switching). Everything else (`file`, `model`, `response_format`, ...) is forwarded
  unchanged, with the original filename preserved.
- On a 2xx upstream response, the JSON body is returned **verbatim** — the client decodes
  `{ "text": "..." }`, Groq/OpenAI's standard transcription shape.
- Upstream `429` -> `429 {"error":"rate_limited"}`. Upstream `5xx` or a transport
  failure/timeout -> `502 {"error":"upstream_error"}`. Any other non-2xx from Groq also collapses
  to `502 upstream_error` — **the upstream response body is never read into a log line or
  forwarded to the caller**, since it could contain account/billing detail belonging to the key's
  owner (us), not the caller.
- Free-tier account -> `403 {"error":"upgrade_required"}`, opaque — client falls back to on-device.
- Daily Pro quota exhausted -> `429 {"error":"quota_exceeded","resetAt":"<next 00:00 UTC>"}`.
- Missing `GROQ_API_KEY` (or any other required secret) -> `503 {"error":"service_unavailable"}`,
  opaque — the response never names which env var is absent; the name is logged server-side only
  (`supabase functions logs groq`).

## Size cap

`Content-Length` is checked and rejected (`413 payload_too_large`) before any buffering if it is
missing or exceeds `GROQ_MAX_AUDIO_BYTES` (default `20971520` = 20 MB — under Groq's own
documented 25 MB request limit, matching `GroqTranscriptionClient.swift`'s client-side
`maxAudioBytes` guard). The real enforcement is not the header alone: the body is read via a
streaming byte counter (`../_shared/http.ts`'s `readBodyCappedBytes`) that aborts the read the
moment actual bytes exceed the cap, so a missing/understated `Content-Length` under chunked
transfer-encoding cannot smuggle an oversized body past this check. Nothing in this function ever
buffers an unbounded body. This check — like the rest of "read & validate body" — runs AFTER auth,
tier, and quota have all passed (contract §4 gate order), so an unauthenticated or over-quota
caller never gets this function to buffer their audio at all.

## Required secrets / env

| Var | Required | Description |
|---|---|---|
| `GROQ_API_KEY` | always | Groq API key. Never returned to clients; used server-side only, sent as `Authorization: Bearer` on the upstream request this function builds itself. |
| `GROQ_BASE_URL` | optional | Overrides the upstream base (default `https://api.groq.com/openai/v1`). Operator-set secret, not caller input — not an SSRF vector from the internet-facing side, but validated/handled as a config error if unparseable. |
| `GROQ_MAX_AUDIO_BYTES` | optional | Body size cap in bytes. Default `20971520` (20 MB). |
| `GROQ_UPSTREAM_TIMEOUT_MS` | optional | Upstream request timeout. Default `30000`. |
| `SPEECH_LIMIT_PRO` | optional | Daily cap for this route. Default `500`. |
| `SUPABASE_URL` / `SUPABASE_ANON_KEY` / `SUPABASE_SERVICE_ROLE_KEY` | always | Injected automatically by the Edge Functions runtime; not set manually. |

## Manual verification (no test harness in this repo)

Run locally first: `supabase start && supabase functions serve groq --env-file ./supabase/.env.local --no-verify-jwt`
(the `--no-verify-jwt` flag is required for the reason documented in `../../README.md`'s "Auth
design" section — this route does its own account auth, not Supabase's gateway JWT check).

**1. Unauthorized is rejected** (no `Authorization` header — expect `401 {"error":"auth_missing"}`):

```bash
curl -sS -o /dev/null -w '%{http_code}\n' \
  http://127.0.0.1:54321/functions/v1/groq/audio/transcriptions \
  -H "Content-Type: multipart/form-data; boundary=x" \
  --data-binary $'--x\r\nContent-Disposition: form-data; name="model"\r\n\r\nwhisper-large-v3-turbo\r\n--x--\r\n'
```

Also verify a garbage bearer token is rejected the same way (expect `401
{"error":"auth_invalid"}`, not a 500 or a different shape):

```bash
curl -sS -o /dev/null -w '%{http_code}\n' \
  http://127.0.0.1:54321/functions/v1/groq/audio/transcriptions \
  -H "Authorization: Bearer not-a-real-token" \
  -H "Content-Type: multipart/form-data; boundary=x" \
  --data-binary $'--x\r\nContent-Disposition: form-data; name="model"\r\n\r\nwhisper-large-v3-turbo\r\n--x--\r\n'
```

**2. A free account is rejected** (valid access token, but the account's entitlements row is
either absent or `tier != 'pro'` — expect `403 {"error":"upgrade_required"}`):

```bash
curl -sS -o /dev/null -w '%{http_code}\n' \
  http://127.0.0.1:54321/functions/v1/groq/audio/transcriptions \
  -H "Authorization: Bearer <valid-free-account-access-token>" \
  -H "Content-Type: multipart/form-data; boundary=x" \
  --data-binary $'--x\r\nContent-Disposition: form-data; name="model"\r\n\r\nwhisper-large-v3-turbo\r\n--x--\r\n'
```

**3. Oversized body is rejected** (expect `413 {"error":"payload_too_large"}`, and note the
request is rejected on the `Content-Length` header alone — the server never reads 21 MB off disk
to prove this):

```bash
head -c 21000000 /dev/urandom > /tmp/oversized.raw
curl -sS -o /dev/null -w '%{http_code}\n' \
  http://127.0.0.1:54321/functions/v1/groq/audio/transcriptions \
  -H "Authorization: Bearer <valid-pro-account-access-token>" \
  -F "model=whisper-large-v3-turbo" \
  -F "file=@/tmp/oversized.raw;filename=big.wav"
```

**4. A valid Pro request reaches Groq** (expect `200` with `{"text": "..."}`, and confirm via
`supabase functions logs groq` that the log line contains only a hashed `userIdHash`, `status`,
`audioBytes`, `quotaUsed`, `latencyMs` — never the transcript text, the filename, or the raw user
id):

```bash
curl -sS http://127.0.0.1:54321/functions/v1/groq/audio/transcriptions \
  -H "Authorization: Bearer <valid-pro-account-access-token>" \
  -F "model=whisper-large-v3-turbo" \
  -F "response_format=json" \
  -F "file=@/path/to/sample.wav;filename=sample.wav"
```

Also confirm the `language` field's validation: `-F "language=vi"` alongside the above should
reach Groq unchanged (transcription behaves as if `vi` were hinted); `-F "language=vietnamese"` or
`-F "language=VI"` (not a strict two-letter lowercase code) should be dropped before forwarding,
same as if the field were absent — i.e. Groq's own auto-detect runs instead.
