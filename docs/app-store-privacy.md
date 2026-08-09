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

**Revised 2026-08-10 for feature 008 (device sync).** Sync changes this document more than any
previous feature has: it is the first time Volar stores the *content of the user's tasks* on
Volar's own server at rest, and the first time Volar keeps a per-device identifier. Two rows below
(**Identifiers › Device ID** and **User Content**) said the opposite before this revision and were
wrong from the moment sync landed in the codebase. Added to the baseline for that revision:
`specs/008-sync/design.md` (§3 what is and isn't synced, §6 retention, §8 the two gates, §9
privacy), `specs/008-sync/client-contract.md`, `supabase/migrations/0005_sync_schema.sql`, and the
Swift under `Shared/Sync/`.

> Volar's core loop (capture → task → reminder → focus) never requires an account and never talks
> to the network at all. Everything below is scoped to the **optional, opt-in** cloud paths: an
> account (Sign in with Apple or email OTP), the Pro subscription, cloud parse, cloud speech, and
> **device sync** — the last of which is the only one that leaves user content sitting on Volar's
> server after the request that carried it has finished.

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
- **Collected: Yes.** *(This row said "No" until 2026-08-10. That was correct when written and
  became false when feature 008 — device sync — landed. Read the whole entry; the reason it flipped
  is not the reason the old entry was watching for.)*
- **What it is NOT:** the prior DeviceCheck-token free tier and Apple App Attest are still deleted
  entirely and are not coming back through this row (`contracts/account-auth.md` §0, "App Attest bị
  xoá hoàn toàn"). Volar reads no hardware identifier, no IDFA, no IDFV, no serial number, and no
  fingerprint derived from device characteristics.
- **What it IS:** sync needs to tell one of the user's own machines from another, so `SyncEngine`
  generates a **random UUID the first time this device syncs** and keeps it. It is not derived from
  anything about the device — a freshly installed copy on the same Mac gets a different one.
  - Where it lives on device: `UserDefaults`, key `volar.sync.deviceId`
    (`Shared/Sync/SyncEngine.swift`, the `deviceId` lazy property; the key is pinned by
    `specs/008-sync/client-contract.md` §7).
  - How long it lives: **indefinitely** — it survives app relaunches, OS updates, and sign-out. It
    changes only if the app is deleted and reinstalled, or the user's defaults are reset.
  - How it travels: sent as `p_device` on **every** `sync_exchange` call
    (`POST /rest/v1/rpc/sync_exchange`), alongside `p_device_label`.
  - Where it is stored server-side, and for how long: `public.sync_devices (profile_id, device_id,
    label, first_seen, last_seen)`, `supabase/migrations/0005_sync_schema.sql`. **Retained
    indefinitely** — no expiry, no cleanup job. It is removed only when the user presses "Delete
    data on server" (`volar_sync_purge()`) or deletes their account, which cascades `auth.users` →
    `profiles` → `sync_devices`. The same identifier is also stamped onto each synced row as
    `tasks.origin_device` and `sync_rejects.origin_device`.
- **Linked to identity: Yes**, and there is no judgment call here (unlike the Audio Data row
  below): `sync_devices.profile_id` is a foreign key to `public.profiles.id`, and
  `profiles.id` **is** `auth.users.id`. The identifier is stored keyed to the account by
  construction, not merely observable alongside it.
- **Used for tracking: No.** It never leaves Volar's own Supabase project, is never shared with any
  third party, and is never used to correlate the user across other companies' apps or websites.
- **Purpose:** App Functionality only — (a) Settings lists which of the user's devices are
  currently syncing, with the last time each was seen (`design.md` §8.1/§8.2 — the list is the
  user's own visibility into their account); (b) `origin_device` makes a conflict in
  `sync_rejects` traceable to the machine that wrote the losing edit.
- **When it is NOT collected:** with no account there is no session, so `SyncClient.exchange`
  fails before any request is built and the identifier never leaves the device
  (`Shared/Sync/SyncClient.swift`). See the transmitted-while-gated-off caveat below for the
  free-account case.
- **The accompanying device label carries NO personal name — and that is now structural, not
  incidental.** Along with the UUID the client sends `p_device_label`, stored in
  `sync_devices.label`. As of 2026-08-10 `SyncEngine.deviceLabel` produces only
  `"Mac · macOS · A3F9"` / `"iPhone · iOS · A3F9"` — a hardcoded platform word, the OS name, and
  the first four characters of the `deviceId` UUID above (a suffix that keeps two machines of the
  same model apart in Settings and reveals nothing the server does not already receive in full as
  `p_device`).
  - **This was briefly a real exposure on macOS.** The property previously used
    `Host.current().localizedName`, which returns the *user-assigned* computer name — and macOS
    defaults that to one built from the account holder's name ("MacBook Pro của Khôi"). That is a
    person's name, stored against `profile_id`, retained indefinitely. Fixed by hardcoding `"Mac"`.
  - **iOS was never exposed**, but was changed anyway. `UIDevice.current.name` has, since iOS 16,
    returned the model name rather than the user-assigned one unless the app holds
    `com.apple.developer.device-information.user-assigned-device-name` — Volar requests no such
    entitlement (verified: no match anywhere in the repo) and targets iOS 17.0. The property now
    uses `UIDevice.current.model`, which is documented never to carry a user-assigned name, so the
    guarantee no longer depends on an entitlement staying un-added by a future contributor.
  - ⇒ **`Contact Info › Name` stays "No"**, and unlike before it is true by construction rather
    than by luck. `SyncEngine.deviceLabel` carries a 🔴 comment saying this label is what that
    answer rests on. If anyone ever puts a user-assignable name back into it, that answer changes.
- **Over-declaration caveat — narrowed 2026-08-10, answer unchanged.** `SyncEngine` now runs
  `SyncMerge.gate(state:)` before building any request, so a free account (or a Pro account with
  the switch off) no longer transmits `p_device` at all. Two residual cases keep this row at
  **Yes** rather than "only when sync is on": the identifier is still generated and stored locally
  regardless of tier, and the gate is a client-side pre-check that can only *refuse* — the server's
  RLS policy remains the real authority, so a state the client has not yet learned still resolves
  by attempting a round. Answering "Yes" costs nothing and does not depend on a client-side guard
  staying correct.

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

**Answer for App Store Connect: Collected — Yes, Linked to identity — Yes, Used for tracking — No,
Purpose — App Functionality.** There are now **two independent paths** that collect user content,
and they are not variations of each other: one sends text off-device to be processed and keeps
nothing, the other **stores the user's task content on Volar's server indefinitely**. Answering
this section from path 1 alone (as this document did before 2026-08-10) understates what the app
does by a wide margin.

#### Path 1 — cloud parse (`POST /functions/v1/parse`): transmitted, not retained

- **Collected — cloud-parse, opt-in:** Yes, on `POST /functions/v1/parse`, which is
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

#### Path 2 — device sync (`POST /rest/v1/rpc/sync_exchange`): **stored at rest, indefinitely**

*New with feature 008. This is a materially different privacy commitment from path 1, not a wider
version of it: parse sends a sentence, gets an answer, and forgets it. Sync makes the content of
the user's tasks **live on Volar's server** until the user removes it.*
(`specs/008-sync/design.md` §9 states the same thing in the design's own words: *"Bật sync = nội
dung task nằm ở trạng thái nghỉ trên server Volar. Đây là cam kết mới."*)

- **Collected: Yes — and only under TWO conditions, both required** (`design.md` §8, enforced in
  the RLS policy `volar_sync_allowed() = volar_is_pro() AND volar_sync_enabled()`, i.e. by the
  database, not merely by client code):
  1. the account has an active **Pro** subscription, **and**
  2. the user has themself turned on the account-level **"Sync across devices"** switch.
  The switch defaults **off**, and turning it on requires passing a confirmation screen
  (`Shared/Views/SyncEnableSheet.swift`) that says in plain words that the user's tasks —
  *including their verbatim spoken text* — will be uploaded, that the switch applies to the whole
  account rather than this one device, and that turning it back off does not delete what was
  already uploaded.
- **What is stored, exactly:** the whole task record, as a JSON blob, in `public.tasks.payload`
  (`supabase/migrations/0005_sync_schema.sql`; the wire shape is `TaskPayload` in
  `Shared/Sync/SyncPayload.swift`). The free-text fields in it are the ones that matter here:
  - `title` — what the user is trying to do, in their own words;
  - `details`, `notes`, `resumeNote` — longer free text the user typed or dictated;
  - **`sourceTranscript` — the verbatim text of the sentence the user spoke**, kept as-is;
  - `delegation.label` / `delegation.cwdHint` — who a task was handed to, which in practice is
    frequently **another person's name**, so a synced task can carry information about someone who
    is not the user;
  - `cue`, `conditions` — free-text trigger/context strings ("after standup", "when I open Xcode").
  Alongside those, the structured fields: `deadline`, `startTime`, `durationMinutes`, `priority`,
  `status`, `when`, `frog`, `recurrence`, `reminderOverride`, `parentId`, `createdAt`,
  `completedAt`, `isSensitive`.
  - **Completions:** `public.completions.payload` carries a `titleSnapshot` — the task's title
    frozen at the moment it was completed — so completed-task titles are stored too, as an
    append-only history that is never updated or deleted by ordinary use.
  - **Losing edits:** when two devices edited the same task while offline, the version that loses
    is not discarded but written verbatim into `public.sync_rejects.payload` (`design.md` §5's
    "black box"). That row contains the same free text as above.
- **Retention: indefinite, on purpose.** There is no expiry and no cleanup job. `design.md` §8.3 is
  explicit that **letting Pro lapse deletes nothing** and **turning the sync switch off deletes
  nothing** — the server copy is kept so the user can resume later without losing work. Data is
  removed only by:
  1. the user pressing **"Delete data on server"** in Settings (`volar_sync_purge()` — the only
     path in the whole system that deletes live rows; no scheduled job calls it), or
  2. **account deletion**, which cascades `auth.users` → `public.profiles` → `tasks`,
     `completions`, `sync_prefs`, `sync_devices`, `sync_rejects` (Apple Guideline 5.1.1(v) is
     satisfied by this cascade).
  - **Known gap, stated rather than glossed:** tasks the user deletes become tombstones and are
    *intended* to be swept from the server after 90 days, but that sweep is a `pg_cron` job that
    is **written down as a follow-up and not implemented** (`0005_sync_schema.sql`, closing NOTE
    §1–3; `pg_cron` has never been enabled on this project). Until it is, a deleted task's content
    stays on the server as well. Do not describe deleted tasks as removed after 90 days anywhere
    user-facing until that job actually exists.
- **Linked to identity: Yes — with no ambiguity.** Unlike the Audio Data and path-1 rows above,
  where "linked" is a judgment call about a bearer-authenticated request, here every stored row has
  a `profile_id` column that is a foreign key to `public.profiles.id`, and `profiles.id` **is**
  `auth.users.id`. The content is stored keyed to the account.
- **Not end-to-end encrypted — say so, do not imply otherwise.** In transit it is TLS; at rest it
  is whatever Postgres/Supabase provide. It is **not** encrypted with a key only the user holds, so
  Volar (and Supabase as its infrastructure provider) is technically able to read it. `design.md`
  §9 records that E2EE was considered and deliberately rejected: identity here is email OTP, so
  there is no password to derive a key from, and the alternatives (a recovery phrase, or escrowing
  the key on the server) either risk permanent data loss or provide no real protection.
- **Not logged.** `Shared/Sync/SyncClient.swift` never prints a request or response body — only
  status codes and already-classified failures; `design.md` §9 states `payload` must not be logged
  anywhere.
- **Not shared with any third party.** The data goes to Volar's own Supabase project and nowhere
  else. Sync moves content **between the user's own signed-in devices**; that is not disclosure to
  a third party. No LLM is involved at any point in this path — it is a plain Postgres upsert, so
  the model-training question that applies to path 1 does not arise here at all.
- **Used for tracking: No.** Never used for advertising, never shared with a data broker, never
  used to correlate the user across other companies' apps or websites.
- **Purpose:** App Functionality only (keep the user's own task list consistent across their own
  devices). Not Analytics, not Product Personalization, not Advertising.
- **Over-declaration caveat — resolved 2026-08-10, answer unchanged.** Until that date `SyncEngine`
  had no client-side gate: a signed-in **free** account, or a Pro account with the switch **off**,
  still sent a `sync_exchange` request carrying the device's pending task payloads —
  `sourceTranscript` included — which the RPC rejected (`sync_pro_required` / `sync_disabled`)
  before writing anything. Nothing was ever stored (the RPC is one transaction and the rejection
  aborts it), but the bytes reached Volar's server, which undercut the very consent screen design
  §8.1 exists to provide. `SyncMerge.gate(state:)` now blocks the round **before the outbox is
  gathered and before any request is built**, so on those accounts no task content leaves the
  device at all.
  - The answer above stays **Yes** regardless, and deliberately so: the gate is a client-side
    pre-check that can only *refuse*, the server's RLS policy is still the real authority, and a
    label answer should not rest on a guard in the client staying correct. What changed is the
    reasoning, not the row.
  - Note the gate's third state. When the client has never successfully read
    `volar_sync_state()` it neither transmits nor concludes anything — it must not tell a merely
    offline user they lack Pro. `volar_sync_state()` itself is deliberately ungated (design §8.2)
    so a locked-out device can always still learn *why*.

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
- **Contacts (via Contacts.framework):** Not collected — grepped for `Contacts.framework`,
  `CNContact`; no matches. (Volar's own reminders/task model is self-contained SwiftData, not a
  device Contacts integration.)
- **Calendar (via EventKit):** **Data Not Collected** (reasoning below — read this whole entry,
  the answer is not as simple as "unused" anymore). EventKit is linked
  (`Sources/Integrations/CalendarAccess.swift`, `Sources/Integrations/CalendarSync.swift`) and, as
  of this revision, Volar uses it for **both read and write** — this entry previously said
  read-only / "never writes"; that changed, and every claim below reflects the current code, not
  the old one.
  - **Why full access is requested:** `EKEventStore.requestFullAccessToEvents()` — macOS 14 has no
    read-only request API (`requestWriteOnlyAccessToEvents` grants write, not read), so full access
    is the only call that grants read at all. Volar now genuinely uses both halves of that grant.
  - **What Volar reads:** a **count** of the user's calendars (`store.calendars(for: .event).count`,
    `CalendarAccess.swift`) to show connection status in Settings. No event titles, times,
    locations, attendees, notes, or any other event content from the user's EXISTING calendars is
    ever read, stored, cached, logged, or transmitted.
  - **What Volar writes:** with the user's explicit opt-in (`CalendarSync.mirrorEnabled`, persisted
    UserDefaults key `volar.calendarMirrorEnabled`, **default off**), Volar creates its own calendar
    titled **"Volar"** and mirrors the user's own scheduled tasks into it as events — title, start
    time (`task.deadline`), and end time (deadline + duration, default 30 min). This is Volar's OWN
    data (the user's own tasks) being written into Volar's OWN calendar, not third-party event
    content being collected.
  - **Blast-radius containment — the two ownership guards (`CalendarSync.reconcile(tasks:)` and
    `removeAllMirroredEvents()`):** before touching (updating OR deleting) any existing `EKEvent`,
    the code checks (1) the event's `calendar.calendarIdentifier` equals the identifier of the
    calendar Volar itself created, and (2) the event's `url` equals a marker Volar stamped on it,
    `volar://task/<task-uuid>`, set at creation time. Either check failing means "not an event Volar
    created," and the code creates a fresh replacement rather than ever calling `save`/`remove` on
    it. This makes it structurally impossible — not just a policy statement — for Volar to modify or
    delete an event in any calendar it did not create, even if its own bookkeeping
    (`eventMap`/`volarCalendarID`, both in UserDefaults) is stale, lost, or tampered with. Volar
    never selects an existing calendar to reuse for this purpose either:
    `CalendarSync.ensureVolarCalendar()` explicitly refuses (throws) rather than falling back to a
    `.subscribed` or `.birthdays` source, or any source it can't confirm is genuinely writable —
    there is no code path where the "Volar" calendar could silently become an existing calendar the
    user already had.
  - **Sync direction:** strictly one-way, Volar's own tasks → the "Volar" calendar. Reading events
    FROM the calendar to create or modify tasks is explicitly out of scope and not implemented —
    `reconcile(tasks:)` never feeds anything back into `TaskItem`/`TaskStore`.
  - **Nothing leaves the device either way:** there is no network call anywhere in
    `CalendarAccess.swift` or `CalendarSync.swift`. Calendar data (read or written) never crosses
    off-device.
  - Calendar data is still not wired into the task-scheduling engine itself —
    `AppState.busyIntervals` stays hardcoded `[]` — mirroring OUT and reading busy-time IN are two
    separate, independently-gated features, and only the former exists today; see §2 below for what
    changes when the latter lands.
  - Backing entitlement: `com.apple.security.personal-information.calendars` (`Volar.entitlements`).
    Backing usage-description keys: `NSCalendarsFullAccessUsageDescription` (macOS 14+) and
    `NSCalendarsUsageDescription` (legacy fallback), both in `Info.plist` — both now describe read
    AND write, matching this entry.
  - **🔴 Re-derived 2026-08-10, because server-side sync shipped.** The previous revision of this
    entry rested its answer on the sentence *"nothing is transmitted off-device"* and instructed
    that the conclusion be **re-derived from scratch** — not assumed — if server-side sync ever
    landed. Feature 008 landed. That sentence is no longer true of the app as a whole, so it can no
    longer carry this entry. The answer below was rebuilt against the sync code rather than
    inherited, and it happens to land in the same place for different reasons:
    1. **Nothing EventKit-sourced enters the sync payload.** `TaskPayload`
       (`Shared/Sync/SyncPayload.swift`) is a field-for-field list with no calendar, event,
       `EKEvent`, or event-identifier field in it; a search of the whole `Shared/Sync/` directory
       for `calendar`/`event`/`EKEvent` returns no data-carrying hit. The only thing Volar ever
       reads from the user's other calendars remains a **count** used for a Settings status line —
       it is never stored, so there is nothing for sync to pick up even in principle.
    2. **`CalendarSync`'s own bookkeeping is deliberately excluded.** The mapping from tasks to
       mirrored events (`eventMap`) and the created calendar's identifier (`volarCalendarID`) live
       in `UserDefaults`, and `specs/008-sync/design.md` §3 lists settings/`UserDefaults` in the
       **not synced** column with a stated reason (per-device state). So no event identifier — not
       even one belonging to an event Volar created itself — reaches the server.
    3. **What sync DOES transmit, stated plainly so this isn't read as a loophole:** the task's own
       `deadline`, `startTime` and `durationMinutes` — which are exactly the values `CalendarSync`
       *derives* a mirrored event from. Someone reading a synced payload can therefore reconstruct
       when a mirrored "Volar" calendar event would sit. That is not calendar data being collected:
       those fields are Volar's own task fields, they exist whether or not the user ever granted
       calendar access, the mirror is downstream of them rather than their source, and they are
       already declared under **User Content › Path 2** above. Declaring them a second time as
       Calendar data would be inaccurate in the other direction.
  - **Nutrition-label answer: still "Data Not Collected" for Calendar** — now on the narrower and
    more durable ground that **no data obtained from EventKit ever leaves the device**, rather than
    the old, now-false ground that nothing leaves the device at all. Apple's "Data Collected"
    categories are about data gathered BY the developer; Volar's calendar read is a local status
    count that is never stored or transmitted, and Volar's calendar write is the user's own task
    data going into a calendar Volar itself created.
  - **What would flip this answer** (check these specifically, not "does the app use sync"):
    (a) any `EKEvent` identifier, calendar identifier, or `CalendarSync` mapping entering
    `TaskPayload` or any other synced structure; (b) busy-time reading landing
    (`AppState.busyIntervals` stops being hardcoded `[]`) **and** those intervals being persisted
    onto a synced model; (c) any future decision to sync `UserDefaults`, which would sweep
    `eventMap`/`volarCalendarID` along with it by default. Any one of the three means calendar-
    derived data leaves the device linked to an account, and this entry must be re-answered again.
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
- **Wire calendar data into the task engine** (e.g. `AppState.busyIntervals` stops being hardcoded
  `[]` and starts reading real event start/end times from the user's OWN existing calendars, for
  scheduling suggestions — a materially different feature from `CalendarSync`'s mirror-OUT, which
  only ever writes into the app-created "Volar" calendar and reads nothing from any other one) → the
  Calendar entry above changes from "reads only a count from other calendars" to "reads event
  start/end times from other calendars" — even though start/end times without titles/attendees may
  still be low-risk, re-check whether the nutrition label answer changes from "Data Not Collected"
  to "Data Used but Not Linked to You" or similar, and update the Calendar entry's wording
  accordingly.
- **Add any server-side sync of calendar/event data, or any code path that transmits Volar's
  mirrored "Volar" calendar events off-device** → the Calendar entry's nutrition-label reasoning
  ("nothing is transmitted off-device") becomes false the moment this ships; re-derive the label
  answer from scratch per that entry's own closing note, do not assume "Data Not Collected" still
  holds. *(Partly triggered already: feature 008 made "nothing is transmitted off-device" false for
  the app as a whole, and the Calendar entry was re-derived on 2026-08-10 on narrower grounds — no
  EventKit-sourced data leaves the device. The three specific flips are listed there.)*
- **Add a field to `TaskPayload`** (`Shared/Sync/SyncPayload.swift`) → that field is now stored on
  Volar's server, keyed to the account, indefinitely. Ask what it contains before adding it: a
  free-text field extends the User Content › Path 2 list; an identifier of any kind may open a new
  Identifiers row; anything sourced from EventKit flips the Calendar entry outright. The wire shape
  is the label's boundary — this is the single highest-leverage line to review in the whole sync
  feature.
- **Sync anything that is currently in the "not synced" column of `design.md` §3** — `UserDefaults`
  /settings, focus sessions, `ReminderRecord`, and above all **`ParseCorrection`** → `ParseCorrection`
  holds verbatim transcripts kept for on-device parser correction and carries an explicit written
  promise that it never leaves the machine (`ParseCorrection.swift`, FR-044). Syncing it would turn
  "a transcript held briefly to parse one sentence" into "a training-shaped corpus at rest on
  Volar's server", which is a different promise, not a bigger one. Requires anh Khôi's separate
  sign-off per `design.md` §3, and a rewrite of User Content › Path 2 if it ever happens.
- **Change what `p_device_label` sends** (`SyncEngine.deviceLabel`) → this property is the sole
  basis for answering `Contact Info › Name: No`. It currently emits only a hardcoded platform word,
  the OS name, and four characters of the app-generated device UUID. Putting **any** user-assignable
  value back into it — `Host.current().localizedName`, `UIDevice.current.name` plus the
  `user-assigned-device-name` entitlement, or a user-typed nickname — makes declaring
  `Contact Info › Name: Yes` mandatory. The property carries a 🔴 comment saying so; read it before
  touching that line.
- **Implement the 90-day tombstone sweep, or any other server-side retention job** (`0005`'s
  closing NOTE §1–3, currently unimplemented — `pg_cron` has never been enabled on this project) →
  the User Content › Path 2 retention paragraph's "known gap" note must be updated, and only then
  may any user-facing text claim deleted tasks are removed from the server after 90 days.
- **Weaken or remove the client-side gate `SyncMerge.gate(state:)`** → this is what currently stops
  a free (or switched-off) account from transmitting task content for the server to reject. Both
  "over-declaration caveat" paragraphs above describe the world with it in place. In particular, do
  not "simplify" its third state: a client that has never read `volar_sync_state()` must transmit
  nothing AND conclude nothing, and `volar_sync_state()` must itself stay ungated. The *answers*
  stay Yes either way; the reasoning does not survive.
- **Turn sync on by default, drop the confirmation sheet, or make Pro alone sufficient without the
  user's own switch** → the User Content › Path 2 framing of "two conditions, both required,
  default off, confirmed on a screen that says so" becomes false. This is the sync equivalent of
  the `allowServerFallback` row below and carries far more weight, because this path retains data
  rather than passing it through.
- **Apply migration `0005` and enable sync in a shipped build** → until that happens no user content
  has ever actually reached a Volar server through this path (see §3). The label must be correct at
  submission regardless, but the "never yet exercised in production" note in §3 stops being true
  and should be removed rather than left to rot.
- **Widen `CalendarSync`'s write scope beyond the app-created "Volar" calendar** (e.g. letting it
  update an event in a calendar it didn't create) → this would break the entire "structurally
  impossible to touch a foreign calendar" claim in the Calendar entry above; treat any such change
  as requiring a full re-review of that entry, the two ownership guards it describes, and probably
  a re-think of whether the feature is safe to ship at all.
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
- "Linked to identity: Yes" for Audio Data / User Content **Path 1** is the conservative reading of
  Apple's guidance given bearer-token-authenticated requests; Apple's own review team is the final
  authority on this specific judgment call. This caveat does **not** extend to User Content Path 2
  (sync) or to Identifiers › Device ID — those are stored with an account foreign key and are
  linked by construction, with nothing left to judge.

### Added 2026-08-10 with feature 008 (sync)

- **Sync has never run against production, and `0005` has not been applied.**
  `supabase/migrations/0005_sync_schema.sql` — which creates `profiles`, `tasks`, `completions`,
  `sync_prefs`, `sync_devices`, `sync_rejects` — is written but **not applied**, and the Swift under
  `Shared/Sync/` has **never been compiled** (Windows dev machine, no Swift/Xcode). Everything in
  the two revised rows above is derived from reading the migration and the client contract, not
  from observing a running system. Re-verify both rows once sync has actually run on a Mac against
  a real project, before submission.
- **~~Defect: task payloads transmitted while the gate is closed~~ — FIXED 2026-08-10.**
  `SyncEngine` attached unconditionally and polled with no client-side Pro/switch check, so a free
  (or switched-off) account uploaded its pending task payloads, `sourceTranscript` included, for
  the server to reject. `SyncMerge.gate(state:)` now runs before any request is built. Both
  affected rows above keep their conservative "Yes"; only their reasoning narrowed. ⚠️ The fix is
  Swift and therefore **UNVERIFIED** — it has never been compiled or run. Re-confirm on a Mac that
  a free account genuinely issues no `sync_exchange` call before treating this as closed.
- **~~Open decision: `p_device_label` may carry a personal name~~ — RESOLVED 2026-08-10.**
  macOS was sending the user-assigned computer name; it now sends a hardcoded `"Mac"`, and iOS
  moved from `UIDevice.current.name` to `.model`. `Contact Info › Name` stays **No** and is now
  true structurally. Also UNVERIFIED — confirm the label string on a real Mac and iPhone.
- **Whether Supabase (as infrastructure provider) counts as a "third party" for App Store Connect's
  sharing question.** The position taken above is no — Supabase hosts Volar's own database and
  processes data on Volar's behalf, the same way a hosting provider does, and Apple's questionnaire
  is aimed at disclosure to *other* parties for their own purposes. Not independently verified
  against Apple's current wording. If the label ends up needing a "Data shared with third parties"
  answer, this is the row it would come from.
- **Both items that previously blocked submission are now resolved** (see the two struck rows
  above). Nothing in this document is waiting on a decision from anh Khôi; what remains is
  verification on a Mac.
