// VolarIOS/Sources/Views/SettingsIOSView.swift — iOS Settings screen (Phase 1, agent A6).
//
// Native `NavigationStack` + `List` (`.insetGrouped`) — NOT a pixel-copy of the macOS Settings
// window (`Volar/Sources/Views/SettingsView.swift`, READ ONLY, source-of-truth for WHICH settings
// exist and what each one does). This view mirrors that file's *content* across 6 sections, but
// composes it the iOS-native way: List sections + footers instead of a custom tab strip and boxed
// `SettingsRow`s. Native-first is the stated fidelity choice for this project (docs/app-architecture.md).
//
// Design contract (specs/004-ios-port/plan.md §4, frozen for every Phase-1 agent, A2's contract):
//   - Colors/fonts/motion ONLY from `VolarColor` / `appState.accent.accent` / `VolarMotion` /
//     `Font.volar(size:weight:)` / `IOSMetrics`. Never a hardcoded hex, never
//     `Color.white.opacity(_:)` (use `VolarColor.veil(_:)` instead).
//   - Mint (`VolarColor.nowAccent*`) is reserved for the single NOW task and never appears here.
//     The accent-color swatches below are the one legitimate exception on this screen: they render
//     `VolarAccent.allCases`' own colors verbatim, which is correct per the contract.
//   - Dark-only. Every tappable element >= 44x44pt (`IOSMetrics.minTouch`).
//
// `IOSMetrics` (agent A2, `VolarIOS/Sources/Design/IOSMetrics.swift`) had NOT landed in the repo
// yet when this file was written (verified via Glob — only `VolarIOS/project.yml`/`Resources`/
// `Tests/_Placeholder.swift` exist so far). Every `IOSMetrics.*` reference below follows the frozen
// signature from the task contract exactly:
//   enum IOSMetrics {
//       static let screenTitle, eyebrow, nowTitle, rowTitle, meta, sectionHeader, caption: Font
//       static let titleTracking, eyebrowTracking, sectionTracking: CGFloat
//       static let screenPadH, cardPadH, cardRadius, nowCardRadius, sheetRadius, minTouch, fabSize: CGFloat
//       static func rowPadY(_ density: Density) -> CGFloat
//   }
// This is UNVERIFIED until that file exists and both compile together — flagged again in the
// self-review at the bottom of the PR description / final report.
import SwiftUI
import Speech
import StoreKit
import UIKit

struct SettingsIOSView: View {
    @Environment(AppState.self) private var appState

    // MARK: - Local UI-only state
    //
    // Mirrors `SettingsView.swift`'s own convention: these are cosmetic/local `@State` for the
    // multi-step sign-in forms only. The actual session/tier/quota/busy/error state lives on
    // `AppState` (`accountEmail`, `accountTier`, `subscriptionStatus`, `accountBusy`,
    // `accountError`) and is read directly below — this file does not invent a second state
    // machine for account/StoreKit flows.
    @State private var accountEmailInput = ""
    @State private var accountCodeInput = ""
    @State private var accountCodeSent = false
    @State private var showDeleteAccountConfirm = false
    /// Gates the one-time "this downloads ~145MB, do it on Wi-Fi" warning before actually calling
    /// `appState.setSpeechEngine(.whisperKit)` — see `voiceSection`'s doc comment on why this is a
    /// UI-level confirmation only, not real network-type gating.
    @State private var pendingWhisperKitConfirm = false

    private var accentColors: Accent { appState.accent.accent }

    var body: some View {
        NavigationStack {
            List {
                accountSection
                subscriptionSection
                appearanceSection
                voiceSection
                privacySection
                aboutSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(VolarColor.bg.ignoresSafeArea())
            .navigationTitle("Settings")
            .tint(accentColors.solid)
            .alert("Delete your Volar account?", isPresented: $showDeleteAccountConfirm) {
                Button("Delete", role: .destructive) { appState.deleteAccount() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This cannot be undone — your tasks stay on this iPhone, but your account, subscription link, and quota history are permanently removed.")
            }
            .alert("Download the WhisperKit model?", isPresented: $pendingWhisperKitConfirm) {
                Button("Download & Enable") { appState.setSpeechEngine(.whisperKit) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("WhisperKit needs a one-time on-device model download (about 145MB) before it can transcribe. This can take a while and use meaningful cellular data — we recommend doing this on Wi-Fi. Volar does not check your connection type before starting the download; that gating isn't implemented yet.")
            }
        }
    }

    // MARK: - Shared row/section helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(IOSMetrics.sectionHeader)
            .tracking(IOSMetrics.sectionTracking)
            .foregroundStyle(VolarColor.textMut)
    }

    private func footerText(_ s: String) -> some View {
        Text(s)
            .font(IOSMetrics.caption)
            .foregroundStyle(VolarColor.textSec)
    }

    // MARK: - 1. Account
    // Ported from `SettingsView.swift`'s `accountTab`/`accountCard` (Task 4, account-auth.md).
    // Signed-out: Sign in with Apple + email OTP. Signed-in: email, tier badge, quota, sign out,
    // delete account. Every action below calls straight into the existing `AppState` methods —
    // no second auth state machine, per the task contract.

    private var accountSection: some View {
        Section {
            if let email = appState.accountEmail {
                signedInAccountRows(email: email)
            } else {
                signedOutAccountRows
            }
            if appState.accountBusy {
                HStack(spacing: 8) {
                    ProgressView().tint(accentColors.solid)
                    Text("Working…").font(IOSMetrics.caption).foregroundStyle(VolarColor.textSec)
                }
            }
            if let accountError = appState.accountError {
                Text(accountError)
                    .font(IOSMetrics.caption)
                    .foregroundStyle(VolarColor.reschedule)
            }
        } header: {
            sectionHeader("Account")
        } footer: {
            footerText(appState.accountEmail == nil
                ? "Sign in to unlock Cloud parsing and Groq speech transcription. Volar's core (capture, tasks, reminders, focus) never requires an account."
                : "Manage your Volar account, subscription, and daily AI quota.")
        }
        .listRowBackground(VolarColor.card)
    }

    @ViewBuilder
    private var signedOutAccountRows: some View {
        Button {
            appState.signInWithApple()
        } label: {
            Text("Sign in with Apple")
                .font(IOSMetrics.rowTitle)
                .frame(maxWidth: .infinity, minHeight: IOSMetrics.minTouch)
                .foregroundStyle(.white)
        }
        .listRowBackground(accentColors.solid)
        .disabled(appState.accountBusy)

        VStack(alignment: .leading, spacing: 8) {
            Text("or sign in with email")
                .font(IOSMetrics.caption)
                .foregroundStyle(VolarColor.textMut)

            HStack(spacing: 10) {
                TextField("you@example.com", text: $accountEmailInput)
                    .foregroundStyle(VolarColor.textPri)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                Button("Send code") {
                    accountCodeSent = true
                    appState.sendEmailOTP(email: accountEmailInput)
                }
                .font(IOSMetrics.caption)
                .foregroundStyle(accentColors.solid)
                .disabled(appState.accountBusy || accountEmailInput.isEmpty)
            }
            .frame(minHeight: IOSMetrics.minTouch)

            if accountCodeSent {
                HStack(spacing: 10) {
                    TextField("6-digit code", text: $accountCodeInput)
                        .foregroundStyle(VolarColor.textPri)
                        .keyboardType(.numberPad)
                    Button("Verify") {
                        appState.verifyEmailOTP(email: accountEmailInput, code: accountCodeInput)
                    }
                    .font(IOSMetrics.caption)
                    .foregroundStyle(accentColors.solid)
                    .disabled(appState.accountBusy || accountCodeInput.count != 6)
                }
                .frame(minHeight: IOSMetrics.minTouch)
            }
        }
    }

    @ViewBuilder
    private func signedInAccountRows(email: String) -> some View {
        HStack {
            Text(email).font(IOSMetrics.rowTitle).foregroundStyle(VolarColor.textPri)
            Spacer()
            tierBadge
        }

        if let status = appState.subscriptionStatus {
            Text("Parse: \(status.parseUsedToday)/\(status.parseLimit) AI calls today")
                .font(IOSMetrics.caption)
                .foregroundStyle(VolarColor.textSec)
            if appState.accountTier == .pro {
                Text("Speech: \(status.speechUsedToday)/\(status.speechLimit) calls today")
                    .font(IOSMetrics.caption)
                    .foregroundStyle(VolarColor.textSec)
            }
        }

        Button("Restore Purchases") { appState.restorePurchases() }
            .foregroundStyle(accentColors.solid)
            .disabled(appState.accountBusy)
            .frame(minHeight: IOSMetrics.minTouch)
        Button("Manage Subscription") { openManageSubscriptions() }
            .foregroundStyle(accentColors.solid)
            .frame(minHeight: IOSMetrics.minTouch)
        Button("Sign out") { appState.signOutAccount() }
            .foregroundStyle(VolarColor.textPri)
            .frame(minHeight: IOSMetrics.minTouch)
        Button("Delete account") { showDeleteAccountConfirm = true }
            .foregroundStyle(VolarColor.destruct)
            .frame(minHeight: IOSMetrics.minTouch)
    }

    private var tierBadge: some View {
        Text(appState.accountTier == .pro ? "Pro" : "Free")
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(appState.accountTier == .pro ? VolarColor.done : VolarColor.textSec)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                (appState.accountTier == .pro ? VolarColor.done : VolarColor.veil(1)).opacity(0.14)
            )
            .clipShape(Capsule())
    }

    /// macOS uses `NSWorkspace.shared.open(.../account/subscriptions)`. iOS has a native StoreKit 2
    /// equivalent — `AppStore.showManageSubscriptions(in:)` — which is the better native-first
    /// choice here (no need to leave the app for a web page). // UNVERIFIED: iOS-only API, not
    /// exercised on a real device/simulator from this machine; the scene lookup mirrors
    /// `AccountService.swift`'s existing `presentationAnchor` iOS branch (already landed, same
    /// `UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first` pattern).
    private func openManageSubscriptions() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        Task { @MainActor in
            try? await AppStore.showManageSubscriptions(in: scene)
        }
    }

    // MARK: - 2. Subscription
    // Ported from `SettingsView.swift`'s `upgradeSection`/`productRow` — same two `VolarProduct`s,
    // prices always read from `product.displayPrice` (never hardcoded) so this is correct in every
    // storefront/currency.

    private var subscriptionSection: some View {
        Section {
            if appState.accountEmail == nil {
                Text("Sign in above to subscribe.")
                    .font(IOSMetrics.caption)
                    .foregroundStyle(VolarColor.textMut)
            } else if appState.accountTier == .pro {
                HStack {
                    VolarIcon(.check, size: 14, color: VolarColor.done)
                    Text("You're on Volar Pro").font(IOSMetrics.rowTitle).foregroundStyle(VolarColor.textPri)
                }
            } else {
                productRow(appState.monthlyProduct, which: .monthly)
                productRow(appState.yearlyProduct, which: .yearly)
            }
        } header: {
            sectionHeader("Subscription")
        } footer: {
            footerText("Volar Pro — 14-day free trial. Unlocks Cloud AI task parsing and Groq cloud speech transcription with a daily quota.")
        }
        .listRowBackground(VolarColor.card)
    }

    @ViewBuilder
    private func productRow(_ product: Product?, which: VolarProduct) -> some View {
        HStack {
            Text(product?.displayName ?? (which == .monthly ? "Monthly" : "Yearly"))
                .font(IOSMetrics.rowTitle)
                .foregroundStyle(VolarColor.textPri)
            Spacer()
            if let product {
                Button(product.displayPrice) { appState.purchase(which) }
                    .font(IOSMetrics.rowTitle)
                    .foregroundStyle(accentColors.solid)
                    .disabled(appState.accountBusy)
            } else {
                Text("Unavailable").font(IOSMetrics.caption).foregroundStyle(VolarColor.textMut)
            }
        }
        .frame(minHeight: IOSMetrics.minTouch)
    }

    // MARK: - 3. Appearance
    // Ported from `SettingsView.swift`'s `appearanceTab`: accent swatches, density, background
    // (ambient) mode. Deliberately DOES NOT port the `NSOpenPanel` custom-image picker (see the
    // omission list in the final report) — `.custom` is filtered out of the Background picker so
    // it can never be selected with no way to actually choose an image.

    private var appearanceSection: some View {
        Section {
            accentSwatchRow
                .padding(.vertical, IOSMetrics.rowPadY(appState.density))

            // `Density` (Theme.swift) is directly `Hashable` (unlike `SpeechEngineChoice`/
            // `ParseEnginePreference` below), so this binds straight to the enum — no rawValue
            // string workaround needed. It has no `CaseIterable` conformance though, so the 3
            // cases are spelled out explicitly (matches `SettingsView.swift`'s own `Segmented`
            // option list).
            Picker("Density", selection: Binding(
                get: { appState.density },
                set: { appState.setDensity($0) }
            )) {
                Text("Cozy").tag(Density.cozy)
                Text("Comfy").tag(Density.comfy)
                Text("Roomy").tag(Density.roomy)
            }
            .pickerStyle(.segmented)
            .frame(minHeight: IOSMetrics.minTouch)

            // `GlassLevel` is also directly `Hashable` but has no persisting setter on `AppState`
            // (unlike `accent`/`density`/`ambient`, which all have `setAccent`/`setDensity`/
            // `setAmbient`) — it's a plain `var`. Binding directly to it works at runtime but the
            // choice is NOT persisted to UserDefaults (no call site anywhere writes one for
            // `glass`), so it silently resets to `.standard` on next launch. Flagged in the final
            // report's "missing AppState API" note rather than fixed here (told not to add methods
            // to AppState).
            Picker("Glass", selection: Binding(
                get: { appState.glass },
                set: { appState.glass = $0 }
            )) {
                Text("Subtle").tag(GlassLevel.subtle)
                Text("Standard").tag(GlassLevel.standard)
                Text("Heavy").tag(GlassLevel.heavy)
            }
            .pickerStyle(.segmented)
            .frame(minHeight: IOSMetrics.minTouch)

            Picker("Background", selection: Binding(
                get: { appState.ambient },
                set: { appState.setAmbient($0) }
            )) {
                ForEach(AmbientMode.allCases.filter { $0 != .custom }) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .frame(minHeight: IOSMetrics.minTouch)
        } header: {
            sectionHeader("Appearance")
        } footer: {
            footerText("Volar is dark-only. A custom background photo isn't available on iPhone yet — the desktop picker relies on macOS-only APIs (NSOpenPanel/security-scoped bookmarks); pick a live scene instead.")
        }
        .listRowBackground(VolarColor.card)
    }

    /// `VolarAccent` is directly `Equatable` (Theme.swift), so this compares with `==` rather than
    /// via `rawValue` — unlike `SettingsView.swift`'s own comment on this exact row, which claims
    /// `VolarAccent` "doesn't declare Equatable." That comment appears stale against the actual
    /// current `Theme.swift` (which this task was told not to touch); either binding form compiles,
    /// this one is just more direct.
    ///
    /// The selection ring uses `VolarColor.textPri` rather than macOS's literal `Color.white`
    /// (`SettingsView.swift`'s equivalent row) — this file's frozen design contract says colors
    /// come ONLY from `VolarColor`/accent/`IOSMetrics`, so a raw system `Color.white` is avoided
    /// even though it renders effectively the same (`textPri` is `#EDF2F9`, near-white).
    private var accentSwatchRow: some View {
        HStack(spacing: 14) {
            ForEach(VolarAccent.allCases) { candidate in
                let selected = candidate == appState.accent
                Button {
                    appState.setAccent(candidate)
                } label: {
                    Circle()
                        .fill(candidate.accent.solid)
                        .frame(width: 28, height: 28)
                        .overlay(
                            Circle().stroke(selected ? VolarColor.textPri : VolarColor.veil(0.2), lineWidth: selected ? 2 : 0.5)
                        )
                }
                .frame(width: IOSMetrics.minTouch, height: IOSMetrics.minTouch)
                .contentShape(Rectangle())
            }
        }
    }

    // MARK: - 4. Voice
    // Ported from `SettingsView.swift`'s `generalTab` speech/parsing rows + `notificationsTab`'s
    // voice-delivery row. Per plan.md §0.1(D): iOS defaults to `.appleOnDevice`; picking WhisperKit
    // is gated behind a one-time confirmation (`pendingWhisperKitConfirm`) that states the ~145MB
    // download size and recommends Wi-Fi. That confirmation is a UI-level warning ONLY — it does
    // NOT check the actual connection type (no `NWPathMonitor`/cellular-vs-Wi-Fi gating here); real
    // download gating is explicitly a later task per the brief, and `AppState.setSpeechEngine`
    // itself has no such gate either (it just calls `whisper.prepare()` unconditionally).

    private var speechLocales: [(id: String, name: String)] {
        SFSpeechRecognizer.supportedLocales()
            .map { ($0.identifier, Locale.current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var whisperKitStatusText: String {
        switch appState.whisper.state {
        case .notReady: return "Not downloaded"
        case .preparing: return "Downloading model…"
        case .ready: return "Ready"
        case .failed(let message): return message
        }
    }

    private var voiceSection: some View {
        Section {
            // `SpeechEngineChoice` does NOT declare `Hashable` (only `Sendable, Equatable,
            // CaseIterable, Identifiable`) — same as `SettingsView.swift`'s own generalTab picker —
            // so this binds through the `String` rawValue instead of the enum itself.
            Picker("Speech engine", selection: Binding(
                get: { appState.speechEngineChoice.rawValue },
                set: { newRaw in
                    guard let newValue = SpeechEngineChoice(rawValue: newRaw) else { return }
                    if newValue == .whisperKit, appState.speechEngineChoice != .whisperKit {
                        pendingWhisperKitConfirm = true
                    } else {
                        appState.setSpeechEngine(newValue)
                    }
                }
            )) {
                ForEach(SpeechEngineChoice.allCases) { choice in
                    Text(choice.label).tag(choice.rawValue)
                }
            }
            .pickerStyle(.menu)
            .frame(minHeight: IOSMetrics.minTouch)

            if appState.speechEngineChoice == .whisperKit {
                HStack {
                    Text("WhisperKit model").font(IOSMetrics.rowTitle).foregroundStyle(VolarColor.textPri)
                    Spacer()
                    Text(whisperKitStatusText).font(IOSMetrics.caption).foregroundStyle(VolarColor.textSec)
                }
            }
            if appState.speechEngineChoice == .groq, !GroqEngine.isConfigured {
                footerText("Groq cloud transcription needs Volar Pro — sign in and upgrade above. Until then Volar uses Apple on-device recognition.")
            }

            Picker("Recognition language", selection: Binding(
                get: { appState.recognitionLocaleID },
                set: { appState.setRecognitionLocale($0) }
            )) {
                Text("Automatic (multilingual)").tag(AppState.autoRecognitionLocaleID)
                ForEach(speechLocales, id: \.id) { loc in
                    Text(loc.name).tag(loc.id)
                }
            }
            .pickerStyle(.navigationLink)
            .frame(minHeight: IOSMetrics.minTouch)

            Toggle(isOn: Binding(
                get: { appState.voiceFeedback },
                // `voiceFeedback` is a plain `var` with no dedicated setter/persistence on
                // AppState (unlike `accent`/`density`/`ambient`) — same caveat as `glass` above:
                // binds and works live, but does not survive relaunch.
                set: { appState.voiceFeedback = $0 }
            )) {
                Text("Voice feedback").font(IOSMetrics.rowTitle).foregroundStyle(VolarColor.textPri)
            }
            .tint(accentColors.solid)
            .frame(minHeight: IOSMetrics.minTouch)

            // `VoiceDeliveryMode` IS directly `Hashable` (Theme-adjacent enum in AppState.swift),
            // so this binds straight to it, no rawValue workaround needed.
            Picker("Voice delivery", selection: Binding(
                get: { appState.voiceDeliveryMode },
                set: { appState.setVoiceDeliveryMode($0) }
            )) {
                ForEach(VoiceDeliveryMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(minHeight: IOSMetrics.minTouch)
        } header: {
            sectionHeader("Voice")
        } footer: {
            footerText("Apple on-device is the default on iPhone — private, free, no download. WhisperKit is optional and downloads a model file first (see the warning when you pick it). Groq is cloud and needs Volar Pro.")
        }
        .listRowBackground(VolarColor.card)
    }

    // MARK: - 5. Privacy
    // Ported from `SettingsView.swift`'s server-recognition consent (`pendingServerConsent` /
    // `allowServerRecognition`) and cloud-parse consent (`cloudParseConsent` / `parseEnginePreference`).

    private var privacySection: some View {
        Section {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Server-based recognition").font(IOSMetrics.rowTitle).foregroundStyle(VolarColor.textPri)
                    Text("Off by default — Volar recognizes speech on-device only. Turning this on lets Apple's servers transcribe when on-device recognition isn't available; audio then leaves this iPhone.")
                        .font(IOSMetrics.caption)
                        .foregroundStyle(VolarColor.textSec)
                }
                Spacer(minLength: 8)
                // `allowServerRecognition` is `private(set)` on AppState — the ONLY way to flip it
                // is `useServerRecognition()`, which per its doc comment ALSO immediately calls
                // `startCapture()` (it's designed to be invoked from the in-flow consent prompt,
                // not a passive Settings switch). There is no public method to turn it back off.
                // Surfaced here as best-effort: tapping "Enable" starts a capture as a side effect
                // — a real UX wrinkle this file cannot fix without a new AppState method (flagged
                // in the final report rather than added, per the task's hard rule).
                if appState.allowServerRecognition {
                    Text("On").font(IOSMetrics.caption).foregroundStyle(VolarColor.textSec)
                } else {
                    Button("Enable") { appState.useServerRecognition() }
                        .font(IOSMetrics.caption)
                        .foregroundStyle(accentColors.solid)
                }
            }
            .frame(minHeight: IOSMetrics.minTouch)

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cloud task parsing").font(IOSMetrics.rowTitle).foregroundStyle(VolarColor.textPri)
                    Text("On-device stays private and free. Cloud AI sends only the TEXT of what you said — never audio — to our proxy for higher-quality parsing of trickier phrasing.")
                        .font(IOSMetrics.caption)
                        .foregroundStyle(VolarColor.textSec)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(
                    get: { appState.parseEnginePreference == .cloud },
                    set: { appState.setParseEngine($0 ? .cloud : .onDevice) }
                ))
                .labelsHidden()
                .tint(accentColors.solid)
            }
            .frame(minHeight: IOSMetrics.minTouch)

            if appState.parseEnginePreference == .cloud, !ConfigParseCredentialProvider.isConfigured {
                footerText("Sign in above to enable cloud parsing — every signed-in account gets a daily quota, free or Pro. Until you sign in, Volar quietly uses on-device parsing.")
            }
        } header: {
            sectionHeader("Privacy")
        } footer: {
            footerText("Volar's core (capture, tasks, reminders, focus) always works fully offline. These two switches only affect optional cloud features.")
        }
        .listRowBackground(VolarColor.card)
    }

    // MARK: - 6. About
    // Ported from `SettingsView.swift`'s `aboutTab`. That tab's "What's new"/"Acknowledgements"
    // pills are inert `Text` capsules on macOS too (no destination wired there either) — this repo
    // has no real Privacy Policy / Terms of Service URL anywhere (checked: no `https://` hit for
    // either in `docs/` or `Shared/`/`Volar/`), so rather than fabricate a placeholder domain that
    // would 404 in production, this section leaves those two as the same inert labels macOS has and
    // flags the gap below instead of inventing a URL.

    private var aboutSection: some View {
        Section {
            HStack {
                Text("Version").font(IOSMetrics.rowTitle).foregroundStyle(VolarColor.textPri)
                Spacer()
                Text(appVersionString).font(IOSMetrics.caption).foregroundStyle(VolarColor.textSec)
            }
            Text("Voice-first task manager for iPhone.")
                .font(IOSMetrics.caption)
                .foregroundStyle(VolarColor.textSec)
            HStack(spacing: 8) {
                Text("What's new")
                    .font(IOSMetrics.caption)
                    .foregroundStyle(accentColors.solid)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(accentColors.surface)
                    .clipShape(Capsule())
                Text("Acknowledgements")
                    .font(IOSMetrics.caption)
                    .foregroundStyle(VolarColor.textSec)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(VolarColor.veil(0.06))
                    .clipShape(Capsule())
            }
        } header: {
            sectionHeader("About")
        } footer: {
            footerText("No Privacy Policy / Terms of Service URL exists in this repo yet — add one (docs/app-store-privacy.md is the closest existing doc) before wiring a real Link here.")
        }
        .listRowBackground(VolarColor.card)
    }

    private var appVersionString: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }
}

#Preview {
    SettingsIOSView()
        .environment(AppState())
}
