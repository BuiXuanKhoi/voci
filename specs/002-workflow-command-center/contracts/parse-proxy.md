# Contract: Cloud Parse Proxy (`/functions/v1/parse`)

Supabase Edge Function, sibling of the planned `/functions/v1/groq` speech route. Client is
`CloudParser` behind the `IntentParsing` protocol. Provider (initial: Gemini Flash) is a
server-side config detail — the client contract never names it.

## Request

```
POST /functions/v1/parse
Authorization: Bearer <StoreKit-JWS>            (paid — unmetered)
   — or —
X-Device-Token: <DeviceCheck token>             (free — metered)
Content-Type: application/json

{ "transcript": "<text, ≤2000 chars>", "locale_hint": "vi|en|mixed",
  "now": "<ISO8601 with zone>", "open_task_titles": ["..."] }   // titles only, for taskDone linking
```

- **Text only. Audio is never accepted by this route** (constitution I).
- `open_task_titles` is optional and capped (≤100 titles) — sent only when the utterance
  contains dependency phrasing; contains no ids, notes, or dates.

## Response

`200` → `ParsedTask[]` JSON (schema mirrors the client `ParsedTask` Codable; **max 10 items**;
every attribute carries `confidence: 0…1`). The client validates/decodes; any violation →
heuristic fallback (constitution II — raw LLM output is never trusted).

`429 { "reason": "quota", "resetAt": ... }` → client silently falls back to heuristic and
shows the one-line gentle note (FR-012). `401` → invalid/expired auth → fallback, prompt
re-validation in Settings. `5xx` → fallback, no user-visible error beyond the note.

## Server obligations

1. Verify StoreKit JWS against App Store Server API **or** verify DeviceCheck token with Apple;
   reject requests carrying neither.
2. Free quota: counter per device per UTC day (default 50; env-tunable without deploy).
3. Do not log transcript bodies; log counts + latency only.
4. Enforce output schema (JSON-schema constrained generation) and the 10-task cap server-side.
5. Provider keys live in Supabase Secrets; never returned to clients.

## AI Breakdown (same route)

`{ "mode": "breakdown", "task_title": "...", "notes": "...?" }` → `{ "steps": [{title,
estimateMinutes}] }`, 3–9 steps of 5–15 minutes, first step trivially small. Same auth,
same metering (a breakdown call counts as one parse), same fallback (on-device FM first,
template heuristics last).
