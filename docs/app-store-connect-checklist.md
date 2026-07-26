# App Store Connect Checklist — manual, web-only steps

Everything below happens in a browser (App Store Connect, Apple Developer portal, Supabase
dashboard) or requires a decision only anh Khôi can make. None of it can be done by an agent
working in this repo — no CLI/API here reaches those consoles from this environment. Ordered so
each step's prerequisites are already satisfied by the time you reach it.

Bundle id used throughout: **`tech.kioh.Volar`** (reverse-DNS of the studio domain `kioh.tech`,
product page `kioh.tech/products/volar`) — set in `Volar/project.yml` and
`Volar/Resources/Info.plist` as of this task. URL scheme stays `volar://` (unchanged).

Legend: **[BLOCKS FIRST BUILD]** = needed before `xcodegen generate && xcodebuild` will even
produce a runnable/signed build on your Mac. **[BLOCKS SUBMISSION]** = only needed before you
press "Submit for Review"; the app builds and runs fine without it in the meantime.

---

## 1. Reserve the app name "Volar" — [BLOCKS SUBMISSION]
1. App Store Connect → Apps → **+** → New App.
2. Platform: macOS (add iOS later if/when you ship that too — the bundle id and entitlements here
   are macOS-first per `Volar/project.yml`'s `deploymentTarget: macOS: "14.0"`).
3. Name: **"Volar"**. Apple is the final arbiter of uniqueness across the whole store (not just
   what you can find by searching) — reserving it here doesn't guarantee it clears review.
4. **Fallback if "Volar" is taken:** keep the app's internal name/bundle as Volar (no code
   change needed) but set the *App Store display name* to something disambiguated, e.g.
   **"Volar — Voice Tasks"**. This is a metadata-only field in App Store Connect, separate from
   `CFBundleName`/`CFBundleDisplayName` in the binary — no repo change required either way.
5. SKU: any internal identifier you like (e.g. `volar-macos`), not user-visible.
6. Primary language / bundle id: pick `tech.kioh.Volar` from the App ID dropdown — this requires
   step 2 below to already exist.

## 2. Register the App ID `tech.kioh.Volar` — [BLOCKS FIRST BUILD for a *signed* run; unsigned
   local builds work without this, but Sign in with Apple needs it to test at all]
1. developer.apple.com → Certificates, Identifiers & Profiles → Identifiers → **+**.
2. Type: App IDs → App.
3. Bundle ID: **Explicit**, `tech.kioh.Volar` (must match `project.yml`'s
   `PRODUCT_BUNDLE_IDENTIFIER` / `Info.plist`'s `CFBundleIdentifier` exactly).
4. Capabilities: check **Sign in with Apple**.
5. Save, then in Xcode (or via `xcodegen generate` + Xcode's automatic signing) make sure the
   provisioning profile picked up the capability — if using automatic signing, Xcode will offer to
   add the entitlement to the App ID itself the first time you build with
   `com.apple.developer.applesignin` present in `Volar.entitlements` (already added by this task).

## 3. Configure Sign in with Apple for Supabase — [BLOCKS the Apple sign-in flow specifically;
   email OTP sign-in works without this]
1. developer.apple.com → Identifiers → **Services IDs** → **+** → create a Services ID (this is
   different from the App ID above; it's what represents "Sign in with Apple" to web-facing
   OAuth flows like Supabase's).
2. Enable "Sign in with Apple" on that Services ID, and configure it with:
   - **Return URL**: the Supabase Auth callback, `https://nuzrpipwacravfgsiacv.supabase.co/auth/v1/callback`
     (per `contracts/account-auth.md` §2's base URL — confirm this project ref is still current
     before pasting it in).
   - **Domain**: your Supabase project's domain (`nuzrpipwacravfgsiacv.supabase.co`) or your own
     domain if you've set up a custom Supabase domain.
3. Create a **Sign in with Apple private key** (Keys → **+** → enable "Sign in with Apple",
   associate it with the App ID from step 2) and download the `.p8` file **once** — Apple will
   not let you download it again.
4. **These three values — Team ID, Key ID, and the `.p8` private key contents — go into the
   Supabase dashboard (Authentication → Providers → Apple), NOT into this repo.** There is
   nothing in `Volar/` or `supabase/` that should ever hold Apple's private key.
5. Also register the Services ID as the "Client ID" and the Services ID + Team ID pairing per
   Supabase's own Apple-provider setup docs — Supabase's UI walks through the exact field names.

## 4. Create the "Volar Pro" subscription group — [BLOCKS SUBMISSION, not first build]
1. App Store Connect → your app → Monetization → Subscriptions → **+** to create the subscription
   group, name it **"Volar Pro"**.
2. Add two auto-renewable subscriptions inside that group:
   - `tech.kioh.Volar.pro.monthly` — **$6.99 / month**.
   - `tech.kioh.Volar.pro.yearly` — **$49.99 / year**.
   (Product IDs must match `contracts/account-auth.md` §8 exactly — the server-side StoreKit JWS
   verification checks `productId` against what it expects.)
3. On **both** products, add an introductory offer: **14-day free trial** (per-Apple-ID, once per
   subscription group — Apple enforces the "once per group" part automatically).
4. Apple auto-generates local-currency prices for every storefront, including Vietnam (VND).
   **Manually eyeball the VND (and a couple of other storefronts you care about) once generated**
   — Apple's tier-based auto-conversion occasionally lands on an odd-looking number; adjust
   manually per-territory if needed. `contracts/account-auth.md` §8 flags this as something to
   double check, not something to trust blindly.
5. Fill in the subscription's localized display name/description (user-facing on the purchase
   sheet) and the required "subscription terms" App Store metadata (auto-renewal disclosure, etc.
   — Apple requires standard subscription-disclosure text, which App Store Connect mostly
   generates for you from the pricing you enter).

## 5. App Store Server API key → Supabase secrets — [BLOCKS Pro entitlement linking; app still
   builds/runs on the free tier without it]
1. App Store Connect → Users and Access → Integrations → **App Store Server API** → generate a
   key. Note the **Issuer ID**, the **Key ID**, and download the `.p8` file (again, one-time
   download).
2. These feed the `APPSTORE_*` secrets the edge functions already expect (see
   `supabase/functions/_shared/auth.ts`'s `APPSTORE_ENV_NAMES` /
   `supabase/README.md`'s env-var table) — set them via `supabase secrets set` (CLI), not the
   dashboard's UI-only path, so they stay reproducible from a command history. **Do not commit the
   `.p8` file or its contents anywhere in this repo.**
3. Also set `APPSTORE_BUNDLE_ID=tech.kioh.Volar` (the JWS-verification code checks the verified
   transaction's bundle id against this — the account-auth.md rewrite still binds/verifies
   `bundleId` at `/subscription/link`, see contract §3) and `APPSTORE_ENVIRONMENT` (`Sandbox` while
   testing, `Production` once live) — confirm these two match whatever the current edge-function
   code expects by the time this step is done, since the account-auth.md-driven rewrite of
   `supabase/functions/` was in progress concurrently with this checklist.

## 6. Supabase secrets — set two, unset one — [BLOCKS cloud parse / cloud speech working end to
   end; on-device paths work regardless]
```
supabase secrets set GEMINI_API_KEY=<your key>
supabase secrets set GROQ_API_KEY=<your key>
supabase secrets unset PARSE_DEV_TOKEN
```
- `PARSE_DEV_TOKEN` is a leftover dev-bypass from before accounts existed
  (`contracts/account-auth.md` §0/§7: "Xoá: PARSE_DEV_TOKEN") — unsetting it is a **security**
  step, not just cleanup: leaving it set would leave a bypass live in production.
- Use the Supabase **CLI** for all of this (`supabase secrets set/unset`), not the MCP
  `deploy_edge_function`/dashboard tool — CLI is faster and doesn't require pasting whole function
  bodies through a tool call.

## 7. Fill the privacy nutrition label — [BLOCKS SUBMISSION]
1. App Store Connect → your app → App Privacy → answer the questionnaire straight from
   `docs/app-store-privacy.md` (this task's companion doc) — it maps every question to Volar's
   actual behavior with source citations.
2. Pay special attention to the one flagged judgment call in that doc (Audio Data / User Content
   "Linked to identity" — recommended answer: Yes) and the "Assumptions / not independently
   verified" section at the bottom before you finalize.
3. Re-run this step any time you touch anything listed in that doc's "If you change X, revisit
   this label" section.

## 8. Account deletion (Guideline 5.1.1(v)) — [BLOCKS SUBMISSION]
- Apple requires in-app account deletion for any app that supports account creation — this is not
  optional, and its absence is a guaranteed rejection.
- Per `contracts/account-auth.md` §3, the server side is `POST /functions/v1/subscription/delete-account`
  (service-role admin delete of `auth.users`, cascading to `entitlements`/`usage_counters` via FK).
  The client-side entry point is intended to live under **Settings › Account** (delete button →
  confirm → call that endpoint → clear Keychain → return to signed-out state).
- **Verify before submission that this button actually exists and works** — as of this checklist
  being written, the Account subsystem (`Volar/Sources/Account/`) had only its wire-model files in
  place; the full sign-in/delete-account UI may still have been in progress in a parallel work
  stream. Don't assume this is done just because the contract describes it — click it on your Mac
  build and confirm the account is actually gone (check `auth.users` in the Supabase dashboard)
  before you submit.

---

## Quick reference: what blocks what

| Step | Blocks first build? | Blocks submission? |
|---|---|---|
| 1. Reserve "Volar" name | No | Yes |
| 2. Register App ID + Sign in with Apple capability | Only signed/testable Apple sign-in | Yes |
| 3. Supabase Apple provider config | Only the Apple sign-in flow | Yes |
| 4. "Volar Pro" subscription group + prices | No | Yes |
| 5. App Store Server API key → Supabase | Only Pro entitlement linking | Yes |
| 6. `GEMINI_API_KEY`/`GROQ_API_KEY` set, `PARSE_DEV_TOKEN` unset | Only cloud parse/speech | Yes (security: unset must happen) |
| 7. Privacy nutrition label | No | Yes |
| 8. Account deletion verified working | No | Yes |
