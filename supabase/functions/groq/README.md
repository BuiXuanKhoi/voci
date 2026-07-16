# `groq` Edge Function — not implemented

This directory is a placeholder. The Groq speech-to-text proxy (`/functions/v1/groq`,
paid-tier audio transcription — see `Voci/Sources/Speech/GroqTranscriptionClient.swift` and its
`GroqCredentialProvider` abstraction, which already expects a proxy base URL + short-lived token
in production) is a **separate, not-yet-scheduled backlog item**.

See `backlog.md` in the repo root, section "CHỐT MÔ HÌNH FREEMIUM" / "Supabase Edge Function",
for the architecture decision this route will follow (StoreKit JWS gate, Groq key held only in
Supabase Secrets, same no-accounts/no-DeviceCheck-for-paid stance as `/parse`'s paid path).

Only `supabase/functions/parse/` is implemented as of this commit (spec
`002-workflow-command-center`, tasks T004 + T022).
