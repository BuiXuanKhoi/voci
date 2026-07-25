# `groq` Edge Function — Groq Speech-to-Text proxy (paid-only)

Implements `POST /functions/v1/groq/audio/transcriptions` — the server-side proxy
`Volar/Sources/Speech/GroqTranscriptionClient.swift` talks to in production. The client always
appends `audio/transcriptions` to whatever base URL its `GroqCredentialProvider` returns; this
function's base URL (project ref's `/functions/v1/groq`) plus that suffix is the exact route
implemented here — **no client change was required or made**.

See `backlog.md`'s "CHỐT MÔ HÌNH FREEMIUM + BACKEND" section for the product decision this
implements, and `../parse/index.ts` / `../../README.md` for the sibling route this one mirrors in
structure, error shapes, and logging discipline.

## Why this exists (threat model, short version)

The Groq API key must never live in the app binary or cross the network to a client — a key
embedded in the app is trivially extracted (strings on the binary, MITM on the `Authorization`
header, memory dump) and Groq bills/rate-limits per key, so a leaked key is a direct cost and
abuse exposure. This function holds the key in Supabase Secrets, gates access by proof of an
active paid subscription, and forwards only the audio the caller already had.

## Auth: paid-only, no free tier

Unlike `../parse` (which has a free App-Attest-metered branch and a paid unmetered branch), this
route has **only** the paid branch: cloud speech-to-text is Pro-only in the freemium matrix (free
tier uses on-device WhisperKit, unlimited, at zero server cost). Every request must carry
`Authorization: Bearer <StoreKit JWS>`, verified by `../_shared/auth.ts`'s `verifyPaidAuth` — the
exact same function and code path `../parse` uses for its paid branch. Anything that isn't a valid
paid JWS (missing header, malformed JWS, wrong `alg`, failed signature/chain check, expired
transaction, or the App Store verifier config itself being incomplete) gets the same opaque
rejection shape `verifyPaidAuth` already produces for `/parse` — there is no groq-specific error
text that could help an attacker distinguish failure reasons.

Rate limiting reuses `../_shared/quota.ts`'s `checkPaidRateLimit` (`PARSE_PAID_RPM` env, default
20/min) keyed the same way `/parse`'s paid branch is keyed:
`SHA-256(bundleId:originalTransactionId)`. **This shares the same Postgres table
(`parse_rate_limit`) and RPC (`parse_rate_increment`) as `/parse`'s paid branch** — see "Known
gap" below.

## Request / response shape

- Method: `POST` only (`OPTIONS` answers `204` for preflight parity; any other method on the
  correct path is `405`). Any path not ending in `/audio/transcriptions` is `404` — routing is
  checked before auth, quota, or upstream work.
- Body: `multipart/form-data`, passed through to Groq's OpenAI-compatible
  `/audio/transcriptions` endpoint almost as-is. The only field this function ever strips is
  `language` — auto-detect (Vietnamese/English code-switching) is a product decision, not
  something a client (modified or not) gets to override. Everything else (`file`, `model`,
  `response_format`, ...) is forwarded unchanged, with the original filename preserved.
- On a 2xx upstream response, the JSON body is returned **verbatim** — the client decodes
  `{ "text": "..." }`, Groq/OpenAI's standard transcription shape.
- Upstream `429` -> `429 {"reason":"rate_limited"}`. Upstream `5xx` or a transport
  failure/timeout -> `502 {"reason":"upstream_error"}`. Any other non-2xx from Groq also collapses
  to `502 upstream_error` — **the upstream response body is never read into a log line or
  forwarded to the caller**, since it could contain account/billing detail belonging to the key's
  owner (us), not the caller.
- Missing `GROQ_API_KEY` (or any other required secret) -> `503 {"reason":"config_missing"}`,
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
buffers an unbounded body.

## Required secrets / env

| Var | Required | Description |
|---|---|---|
| `GROQ_API_KEY` | always | Groq API key. Never returned to clients; used server-side only, sent as `Authorization: Bearer` on the upstream request this function builds itself. |
| `GROQ_BASE_URL` | optional | Overrides the upstream base (default `https://api.groq.com/openai/v1`). Operator-set secret, not caller input — not an SSRF vector from the internet-facing side, but validated/handled as a config error if unparseable. |
| `GROQ_MAX_AUDIO_BYTES` | optional | Body size cap in bytes. Default `20971520` (20 MB). |
| `GROQ_UPSTREAM_TIMEOUT_MS` | optional | Upstream request timeout. Default `30000`. |
| `PARSE_PAID_RPM` | always (shared with `/parse`) | Soft per-minute rate limit for the paid tier — same env var and same table `/parse`'s paid branch uses. See "Known gap" below. |
| `SUPABASE_URL` / `SUPABASE_SERVICE_ROLE_KEY` | always | Injected automatically by the Edge Functions runtime; not set manually. |
| `APPSTORE_BUNDLE_ID` / `APPSTORE_ENVIRONMENT` / `APPSTORE_APP_APPLE_ID` / `APPSTORE_ROOT_CA_PEM` | always | Same StoreKit JWS verification config `/parse`'s paid branch needs — see `../../README.md`'s "Auth design" section. If `/parse` is already deployed with these set, this route needs no additional App Store config. |

## Known gap: shared rate-limit budget with `/parse`

`checkPaidRateLimit` keys on `SHA-256(bundleId:originalTransactionId)` and writes to the same
`parse_rate_limit` table / `parse_rate_increment` RPC that `/parse`'s paid branch uses, with the
same `PARSE_PAID_RPM` limit applied to the combined count. A paying user's speech traffic and
parse traffic currently draw from **one shared per-minute budget**, not two independent ones — a
burst of transcription requests can transiently 429 a parse call from the same subscriber (or vice
versa). This is a soft abuse bound either way (not a real per-day quota), so it is not a
correctness bug, but it means the two routes cannot be tuned independently. Recommendation (not
implemented here): give this route its own bucket — either a distinct RPC/table
(`groq_rate_limit`) or a distinct minute-bucket key prefix (e.g. `"groq:" + rateLimitKeyHash`)
passed through a `checkPaidRateLimit` overload — before traffic on either route grows enough for
the shared budget to matter in practice.

## Manual verification (no test harness in this repo)

Run locally first: `supabase start && supabase functions serve groq --env-file ./supabase/.env.local --no-verify-jwt`
(the `--no-verify-jwt` flag is required for the same reason documented in `../../README.md` — this
route does its own auth, not Supabase's gateway JWT check).

**1. Unauthorized is rejected** (no `Authorization` header — expect `401 {"reason":"auth_missing"}`):

```bash
curl -sS -o /dev/null -w '%{http_code}\n' \
  http://127.0.0.1:54321/functions/v1/groq/audio/transcriptions \
  -H "Content-Type: multipart/form-data; boundary=x" \
  --data-binary $'--x\r\nContent-Disposition: form-data; name="model"\r\n\r\nwhisper-large-v3-turbo\r\n--x--\r\n'
```

Also verify a garbage JWS is rejected the same way (expect `401 {"reason":"auth_invalid"}`, not a
500 or a different shape):

```bash
curl -sS -o /dev/null -w '%{http_code}\n' \
  http://127.0.0.1:54321/functions/v1/groq/audio/transcriptions \
  -H "Authorization: Bearer not-a-real-jws" \
  -H "Content-Type: multipart/form-data; boundary=x" \
  --data-binary $'--x\r\nContent-Disposition: form-data; name="model"\r\n\r\nwhisper-large-v3-turbo\r\n--x--\r\n'
```

**2. Oversized body is rejected** (expect `413 {"reason":"payload_too_large"}`, and note the
request is rejected on the `Content-Length` header alone — the server never reads 21 MB off disk
to prove this):

```bash
head -c 21000000 /dev/urandom > /tmp/oversized.raw
curl -sS -o /dev/null -w '%{http_code}\n' \
  http://127.0.0.1:54321/functions/v1/groq/audio/transcriptions \
  -H "Authorization: Bearer <any-storekit-jws>" \
  -F "model=whisper-large-v3-turbo" \
  -F "file=@/tmp/oversized.raw;filename=big.wav"
```

Also verify a request with no `Content-Length` at all is rejected the same way — e.g. via
chunked transfer-encoding (`curl --data-binary @- < /tmp/oversized.raw` while forcing
`Transfer-Encoding: chunked` with `-H "Transfer-Encoding: chunked"` and `--no-buffer`), expecting
the same `413`, never a hang or an unbounded read.

**3. A valid paid request reaches Groq** (expect `200` with `{"text": "..."}`, and confirm via
`supabase functions logs groq` that the log line contains only `status`, `audioBytes`, `rpmCount`,
`latencyMs` — never the transcript text or the filename):

```bash
curl -sS http://127.0.0.1:54321/functions/v1/groq/audio/transcriptions \
  -H "Authorization: Bearer <valid-sandbox-storekit-jws>" \
  -F "model=whisper-large-v3-turbo" \
  -F "response_format=json" \
  -F "file=@/path/to/sample.wav;filename=sample.wav"
```

Also confirm the `language` field is actually stripped: send `-F "language=vi"` alongside the
above and verify from Groq's response that auto-detect still ran (i.e. behavior is identical with
or without that field) — the field must never reach Groq's request from this proxy.
