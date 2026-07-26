# App Store Connect — Privacy Nutrition Label Worksheet

Spec task **T053** (`specs/002-workflow-command-center/plan.md`). Maps every question the App
Store Connect "App Privacy" questionnaire asks to Volar's *actual* behavior, with a citation to
the source file/contract for each claim, so this can be re-verified against the real code rather
than trusted blindly.

**A wrong label here is a rejection risk (or worse, a post-approval compliance issue), so every
row below either cites the exact file/line that justifies it, or is flagged as a judgment call for
anh Khôi to confirm before submission.**

Baseline used for "what does the app do": `specs/002-workflow-command-center/contracts/account-auth.md`
(2026-07-26, supersedes the old App Attest / StoreKit-JWS-as-bearer design), plus
`contracts/parse-proxy.md`, `supabase/functions/groq/README.md`, and the current Swift sources
under `Volar/Sources/Speech/`, `Volar/Sources/Account/`, `Volar/Sources/Parsing/`.

> Volar's core loop (capture → task → reminder → focus) never requires an account and never talks
> to the network at all. Everything below is scoped to the **optional, opt-in** cloud paths: an
> account (Sign in with Apple or email OTP), the Pro subscription, cloud parse, and cloud speech.

---

## 1. Data types Apple's questionnaire will ask about

### Contact Info › Email Address
- **Collected:** Yes, but only if the user creates an account.
- **How:** Email OTP sign-up (`POST /auth/v1/otp` / `/auth/v1/verify`), or the address Apple
  hands back on Sign in with Apple — which may be the user's real address or Apple's private
  relay address, depending on what the user chose in the Apple sign-in sheet. Apple only returns
  the email on the **first** authorization; Supabase persists it into `auth.users` after that, and
  the client is expected to read it from `session.user.email`, never assume the credential itself
  carries it on repeat logins.
  Source: `contracts/account-auth.md` §2 ("Apple chỉ trả email lần đăng nhập ĐẦU TIÊN..."),
  `Volar/Sources/Account/AccountModels.swift` (`AccountUser.email`, doc comment repeats the same
  constraint).
- **Linked to identity:** Yes — it's the account identifier itself.
- **Used for tracking:** No.
- **Purpose:** App Functionality (account creation, sign-in, entitlement lookup). Not Analytics,
  not Advertising, not Product Personalization.

### Identifiers › User ID
- **Collected:** Yes, once an account exists.
- **What:** The Supabase `auth.users` UUID (`AccountUser.id`), which is also the primary key of
  the `entitlements` and `usage_counters` tables server-side.
  Source: `contracts/account-auth.md` §6 (`entitlements.user_id`, `usage_counters.user_id`),
  `Volar/Sources/Account/AccountModels.swift`.
- Also present, but as a secondary linked identifier rather than a separate "collected" item: the
  StoreKit `originalTransactionId`, stored server-side as `entitlements.original_transaction_id
  UNIQUE` to bind one subscription to one account (first-claim-wins) and to detect renewals.
  Source: `contracts/account-auth.md` §3 (`POST /subscription/link`), §6.
- **Linked to identity:** Yes.
- **Used for tracking:** No — this ID is never shared with a third party or used to correlate
  activity across other companies' apps/websites; it only round-trips between the client and
  Volar's own Supabase project.
- **Purpose:** App Functionality (identify the account for quota/tier gating).

### Identifiers › Device ID
- **Collected:** No. The prior design (DeviceCheck-token free tier + Apple App Attest) has been
  **deleted entirely** in favor of account-based identity; there is no device fingerprint/token
  collected anywhere in the current architecture.
  Source: `contracts/account-auth.md` §0 ("App Attest bị xoá hoàn toàn").
  *(If App Attest or DeviceCheck is ever reintroduced, this row must flip to Yes.)*

### Purchases
- **Collected:** Yes — subscription tier and status (`free`/`pro`, `expiresAt`, `productId`).
  Source: `contracts/account-auth.md` §3 (`GET /subscription/status`,
  `POST /subscription/link`), §6 (`entitlements.tier`, `.product_id`, `.expires_at`).
- **Linked to identity:** Yes (keyed by `user_id`).
- **Used for tracking:** No.
- **Purpose:** App Functionality (gate Pro features: cloud speech, higher parse quota). Not used
  for advertising or shared with data brokers/ad networks.

### Audio Data (User Content)
- **Collected — cloud path only:** Yes, **exclusively** on the Groq cloud-speech route
  (`POST /functions/v1/groq/audio/transcriptions`), which is **Pro-tier only**. A free account (or
  no account) gets `403 upgrade_required` and the client silently falls back to on-device
  recognition — no audio is sent.
  Source: `contracts/account-auth.md` §1/§3, `supabase/functions/groq/README.md` ("Auth:
  account-based, Pro-only"), `Volar/Sources/Speech/GroqEngine.swift`,
  `Volar/Sources/Speech/GroqTranscriptionClient.swift`.
- **NOT collected — on-device paths:** `Volar/Sources/Speech/SpeechCapture.swift` (Apple's
  `SFSpeechRecognizer`) defaults to `requiresOnDeviceRecognition = true` and WhisperKit runs
  fully on-device; neither transmits audio anywhere.
- **Caveat worth flagging explicitly (do not silently drop this):** `SpeechCapture` has a second,
  user-opt-in path — `allowServerFallback` (Settings toggle, persisted as
  `AppState.allowServerRecognition` / `UserDefaults` key `volar.allowServerRecognition`, default
  **off**) — that, when the user explicitly consents (offered only when on-device Dictation is
  unavailable on their Mac), routes audio to **Apple's own** speech-recognition servers, not
  Volar's and not Groq's. This is Apple's first-party framework behavior (the same as Siri
  dictation elsewhere in macOS), governed by Apple's own privacy policy, not a Volar-operated
  data flow — but because it is a real path where audio leaves the device, it is documented here
  for completeness rather than folded silently into "on-device only."
  Source: `Volar/Sources/Speech/SpeechCapture.swift` line ~36 ("falls back to Apple's server-based
  recognition only when the caller has explicitly set `allowServerFallback = true`"),
  `Volar/Sources/App/AppState.swift` (`allowServerRecognition`, `useServerRecognition()`).
- **Linked to identity — judgment call, recommend Yes:** The Groq-proxy request carries the
  user's Supabase bearer token (needed for the Pro-tier check and the per-user quota counter), so
  the request is authenticated/attributable to an account for its duration even though the audio
  itself is never written to a database and the function never logs transcript/audio content
  (`supabase/functions/groq/README.md`: log lines contain only a hashed `userIdHash`, `status`,
  `audioBytes`, `quotaUsed`, `latencyMs`). Apple's own guidance treats data as "linked" if it's
  associated with an identifiable account at collection time, even if not persisted afterward — so
  the conservative (safer) label is **Linked to identity: Yes**, not "Data Not Linked to You."
  **Confirm this call before submission** — it's the one row in this doc with real ambiguity.
- **Retention:** Not retained by Volar or by Groq beyond what's needed to produce the transcript
  (per the proxy's server obligations — no logging of audio/transcript bodies).
- **Purpose:** App Functionality only (produce a transcript). Never Analytics, never Advertising,
  never used to build a profile.
- **Used for tracking:** No.

### User Content (transcripts / text)
- **Collected — cloud-parse only, opt-in:** Yes, on `POST /functions/v1/parse`, which is
  text-only (never accepts audio — `contracts/parse-proxy.md`: "Text only. Audio is never
  accepted by this route"). This is the cloud NLP path that turns an utterance into structured
  task fields; it is separate from, and independent of, the Groq speech path above.
- **Not collected when:** the user hasn't configured cloud parse (`ConfigParseCredentialProvider`
  has no token → `CloudParser` reports unavailable → on-device heuristic parser runs instead, no
  network call at all). Source: `Volar/Sources/Parsing/ConfigParseCredentialProvider.swift`.
- **Linked to identity:** Yes, same reasoning as Audio Data above — the request is bearer-
  authenticated for quota/tier purposes.
- **Retention:** Server obligation is "Do not log transcript bodies; log counts + latency only"
  (`contracts/parse-proxy.md`, "Server obligations" §3; also account-auth.md §5's blanket "Không
  bao giờ log: access_token, JWS, email, transcript, audio").
- **Used for tracking:** No. **Never** used for ads, and never used to train a shared/public
  model as far as this app's contracts specify (the LLM provider is a server-side config detail
  behind the proxy — if that provider's terms include using submitted content for model training,
  that would need to be re-verified against the provider's DPA and reflected here; not verified as
  part of this task).
- **Purpose:** App Functionality (parse a voice utterance into a task) only.

### What is explicitly NOT collected
State these as "No" across the board in App Store Connect:
- **Analytics/Usage Data:** No analytics SDK is integrated anywhere in the app (checked: no
  Firebase, Mixpanel, Amplitude, Segment, AppsFlyer, or similar dependency in `Volar/project.yml`
  or anywhere under `Volar/Sources/`).
- **Diagnostics (crash logs, performance data):** No crash-reporting SDK (no Sentry/Crashlytics/
  etc.) is integrated.
- **Advertising Data / Advertising Identifier:** Not collected; no ad SDK, no IDFA usage.
- **Tracking across apps/websites owned by other companies ("Used to Track You"):** **No**, for
  every data type above — nothing collected by Volar is shared with a data broker or used to
  correlate the user across unrelated apps/companies for ads. Answer "No" to the top-level App
  Tracking Transparency-adjacent question in App Store Connect.
- **Location:** Not collected — no CoreLocation/`CLLocationManager` usage anywhere in the app.
- **Contacts / Calendar (via Contacts.framework/EventKit):** Not collected — grepped for
  `Contacts.framework`, `CNContact`, `EventKit`; no matches. (Volar's own reminders/task model is
  self-contained SwiftData, not a device Contacts/Calendar integration.)
- **Health & Fitness, Financial Info (beyond Purchases), Sensitive Info, Browsing History, Search
  History:** Not collected — nothing in the app's scope touches any of these categories.
- **Device ID / App Attest / DeviceCheck:** Removed entirely, see the Identifiers row above.

---

## 2. If you change X, revisit this label

- **Add any analytics/crash-reporting SDK** → re-answer Analytics/Diagnostics and re-check
  whether that SDK's own data collection (e.g. device identifiers, IP-based geolocation) adds new
  rows.
- **Reintroduce DeviceCheck/App Attest, or any device-fingerprint-based rate limiting** → add back
  an "Identifiers › Device ID" row.
- **Change the LLM provider behind `/parse`, or that provider's data-retention/training terms** →
  re-verify the "not used to train a shared model" claim in the User Content section; that claim
  was NOT independently verified against the provider's DPA as part of this task.
- **Persist audio or transcript bodies server-side for debugging, QA, or model fine-tuning** → the
  "not retained" claims in both Audio Data and User Content sections become false; update
  immediately, this is the single highest-risk drift for this doc.
- **Add any sharing of account data with a third party** (e.g. a support/helpdesk tool that sees
  email + user id) → add a "Third-Party Advertising" or "Other" row as appropriate, and reconsider
  the "not shared" framing throughout.
- **Default `allowServerFallback`/`allowServerRecognition` to `true`, or remove the explicit
  consent gate before offering it** → the Audio Data section's framing of that path as "opt-in,
  off by default" becomes false and must be corrected.
- **Add tracking/ads (IDFA, ad SDK, cross-app identifier sharing)** → every "Used to Track You: No"
  answer above must be revisited, not just the new feature's own row.

## 3. Assumptions / not independently verified

- Whether the LLM provider behind `/parse` (Gemini, per `contracts/parse-proxy.md`'s "initial:
  Gemini Flash") or Groq's own terms of service treat submitted audio/text as usable for model
  training. The contracts say Volar's own proxy does not log/retain it, but the upstream
  provider's own data-handling policy was not reviewed as part of this task.
  **Action for anh Khôi:** confirm Groq's and the parse LLM provider's DPA/retention terms before
  finalizing the label, in case Apple would consider the "linked to identity" answer different for
  the upstream provider's own processing.
- The exact `Settings › Account` UI (sign-in/sign-out/delete-account screen) was, as of this
  writing, only partially implemented in the codebase (`Volar/Sources/Account/AccountModels.swift`
  and `KeychainStore.swift` exist; the full sign-in flow / delete-account button were not found
  yet — other work on the account feature was in flight concurrently with this task). The
  *behavior* described above is per the account-auth.md contract that flow is being built against,
  not independently confirmed against a finished UI. Re-check this doc once that flow ships.
- "Linked to identity: Yes" for Audio Data / User Content is the conservative reading of Apple's
  guidance given bearer-token-authenticated requests; Apple's own review team is the final
  authority on this specific judgment call.
