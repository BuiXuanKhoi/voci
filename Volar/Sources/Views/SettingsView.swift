// Sources/Views/SettingsView.swift — Settings window: 5 tabs (General/Hotkeys/Notifications/
// Appearance/About), ported from `design/volar-extras.jsx`'s `VolarSettings`. Native-first: a
// custom top tab strip (icon + label, accent-tinted when selected) switches a `@State tab` with
// the tab content below. Most rows here are local, cosmetic `@State` (reminder defaults,
// notification toggles, etc.) — the frozen `AppState` (spec §4) does not own these preferences,
// only `accent` and `density`, which this view binds for real via `@Bindable`. "Launch at login"
// is the one exception below that list: it's wired for real to `SMAppService` via `LoginItem.swift`,
// not local `@State` at all.
import SwiftUI
import AppKit
import ServiceManagement
import Speech
import StoreKit
import UniformTypeIdentifiers

struct SettingsView: View {
    private enum Tab: String, CaseIterable, Identifiable, Equatable {
        case general, hotkeys, notifications, appearance, integrations, account, about
        var id: String { rawValue }

        var icon: VolarIconName {
            switch self {
            case .general: return .settings
            case .hotkeys: return .cmd
            case .notifications: return .bell
            case .appearance: return .sparkle
            case .integrations: return .bolt
            // No dedicated "person/account" glyph exists in `VolarIconName` (`Design/VolarIcon.swift`,
            // not in this task's owned files — adding a case would require editing it). `.check`
            // is the closest available stand-in (reads as "verified identity"); flagged in backlog.md
            // as a follow-up for whoever next owns that file.
            case .account: return .check
            case .about: return .project
            }
        }

        var label: String {
            switch self {
            case .general: return "General"
            case .hotkeys: return "Hotkeys"
            case .notifications: return "Notifications"
            case .appearance: return "Appearance"
            case .integrations: return "Integrations"
            case .account: return "Account"
            case .about: return "About"
            }
        }
    }

    @State private var tab: Tab = .general

    // Cosmetic-only local settings state (not part of the frozen AppState API).
    @State private var defaultDuration = 30
    @State private var hyperfocusInterrupt = 90
    @State private var showMorningFrog = true
    @State private var captureAppContext = true

    @State private var showReminders = true
    @State private var notifSound = true
    @State private var focusModeAware = false

    @State private var themeChoice = "dark"

    // "Launch at login" — unlike every `@State` above this line, this is NOT cosmetic/local: it
    // mirrors the REAL `SMAppService.mainApp.status` (`LoginItem.swift`), re-read fresh in
    // `.onAppear` below rather than cached across app launches, since the user can flip it from
    // System Settings behind Volar's back at any time (see `LoginItem.swift`'s header comment).
    @State private var loginItemStatus: SMAppService.Status = .notFound
    @State private var loginItemError: String?

    // Account tab (Task 4, account-auth.md contract) — purely local UI state for the sign-in
    // forms; the actual session/tier/quota state lives on `AppState` (`accountEmail`,
    // `accountTier`, `subscriptionStatus`, `accountBusy`, `accountError`), same split as every
    // other tab's cosmetic `@State` vs. the frozen `AppState` API.
    @State private var accountEmailInput = ""
    @State private var accountCodeInput = ""
    @State private var accountCodeSent = false
    @State private var showDeleteAccountConfirm = false
    /// Backlog "1 free month of Pro" promo codes (Task 3, redeem contract). Local `@State`, same
    /// convention as `accountEmailInput`/`accountCodeInput` above — the FIELD text is view-local,
    /// the actual redeem call + success/failure state lives on `appState` (`redeemPromoCode(_:)`/
    /// `lastRedeemedUntil`/`accountError`).
    @State private var promoCodeInput = ""

    @Environment(AppState.self) private var appState
    // Settings is its own scene (a separate `Window`/`Settings` group from the main window per
    // VolarApp.swift) — the guided-tour overlay (agent A, Views/Tour/*) lives IN the main window,
    // so "Show tour" below must explicitly bring that window forward or the click appears to do
    // nothing while Settings just sits there.
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var appState = appState

        VStack(spacing: 0) {
            tabStrip

            ScrollView {
                Group {
                    switch tab {
                    case .general: generalTab
                    case .hotkeys: hotkeysTab
                    case .notifications: notificationsTab
                    case .appearance: appearanceTab(appState: appState)
                    case .integrations: integrationsTab
                    case .account: accountTab
                    case .about: aboutTab
                    }
                }
                .padding(22)
            }
        }
        .frame(minWidth: 560, minHeight: 460)
        .background(VolarColor.bg)
        .onAppear {
            // Real status, re-read every time Settings opens — never trust a stale value left
            // over from the last time this view appeared, since the user may have toggled Login
            // Items from System Settings while Settings was closed. See `LoginItem.swift`.
            loginItemStatus = LoginItem.status
        }
    }

    // MARK: - Tab strip

    private var accentColors: Accent { appState.accent.accent }

    private var tabStrip: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases) { t in
                let selected = t == tab
                Button {
                    tab = t
                } label: {
                    VStack(spacing: 4) {
                        VolarIcon(t.icon, size: 18, color: selected ? accentColors.solid : VolarColor.textSec, weight: .regular)
                        Text(t.label)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(selected ? accentColors.solid : VolarColor.textSec)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .frame(minWidth: 72)
                    .background(selected ? accentColors.surface : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background(VolarColor.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(VolarColor.border).frame(height: 0.5)
        }
    }

    // MARK: - General

    /// All locales `SFSpeechRecognizer` supports on this Mac (includes vi-VN), sorted by their
    /// localized display name so the picker below reads naturally instead of by raw identifier.
    private var speechLocales: [(id: String, name: String)] {
        SFSpeechRecognizer.supportedLocales()
            .map { ($0.identifier, Locale.current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Short status text for the WhisperKit model row: download/load progress or the reason it
    /// can't run, so picking the engine doesn't silently fall back to Apple with no explanation.
    private var whisperKitStatusText: String {
        guard WhisperKitEngine.isSupported else { return "Requires Apple Silicon" }
        switch appState.whisper.state {
        case .notReady: return "Not downloaded"
        case .preparing: return "Downloading model…"
        case .ready: return "Ready"
        case .failed(let message): return message
        }
    }

    private var whisperKitStatusHint: String {
        WhisperKitEngine.isSupported
            ? "First use downloads a small on-device model (~145MB) and caches it. Falls back to Apple until it's ready."
            : "WhisperKit needs an Apple Silicon Mac. Volar will use Apple's on-device recognizer instead."
    }

    private var generalTab: some View {
        VStack(spacing: 12) {
            SettingsRow(label: "Speech engine", hint: "On-device (Apple, WhisperKit) stays private and free. Groq is cloud — it sends your audio for the best multilingual/Vietnamese accuracy.") {
                // `SpeechEngineChoice` (AppState.swift) doesn't declare Hashable, so — same
                // convention as the Density picker below — bind through its `String` rawValue
                // instead of the enum itself.
                Picker("", selection: Binding(
                    get: { appState.speechEngineChoice.rawValue },
                    set: { if let choice = SpeechEngineChoice(rawValue: $0) { appState.setSpeechEngine(choice) } }
                )) {
                    ForEach(SpeechEngineChoice.allCases) { choice in
                        Text(choice.label).tag(choice.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(accentColors.solid)
                .frame(width: 200)
            }
            if appState.speechEngineChoice == .whisperKit {
                SettingsRow(label: "WhisperKit model", hint: whisperKitStatusHint) {
                    Text(whisperKitStatusText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(VolarColor.textSec)
                }
            }
            if appState.speechEngineChoice == .groq, !GroqEngine.isConfigured {
                SettingsRow(label: "Groq status", hint: "Groq cloud transcription is a Pro feature — sign in and upgrade in the Account tab to enable it. Until then Volar uses Apple on-device recognition.") {
                    Text("Not configured — using Apple on-device")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(VolarColor.textSec)
                }
            }
            SettingsRow(label: "Task parsing", hint: "On-device stays private and free (Apple on-device model when available, otherwise a built-in heuristic). Cloud AI sends only the TEXT of what you said (never audio) to our proxy for higher-quality parsing of trickier phrasing.") {
                // `ParseEnginePreference` doesn't declare Hashable — same convention as the Speech
                // engine / Density pickers, bind through its `String` rawValue instead of the enum.
                Picker("", selection: Binding(
                    get: { appState.parseEnginePreference.rawValue },
                    set: { if let pref = ParseEnginePreference(rawValue: $0) { appState.setParseEngine(pref) } }
                )) {
                    ForEach(ParseEnginePreference.allCases) { pref in
                        Text(pref.label).tag(pref.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(accentColors.solid)
                .frame(width: 200)
            }
            if appState.parseEnginePreference == .cloud, !ConfigParseCredentialProvider.isConfigured {
                SettingsRow(label: "Cloud parsing status", hint: "Sign in (Account tab) to enable cloud parsing — every signed-in account gets a daily quota, free or Pro. Until you sign in, Volar quietly uses on-device parsing.") {
                    Text("Not configured — using on-device")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(VolarColor.textSec)
                }
            }
            SettingsRow(label: "Recognition language", hint: "The language Volar listens for when you capture a task by voice, including Vietnamese.") {
                Picker("", selection: Binding(
                    get: { appState.recognitionLocaleID },
                    set: { appState.setRecognitionLocale($0) }
                )) {
                    // "Automatic (multilingual)" first, ahead of the localized-name-sorted locale
                    // list below, for anyone who code-switches between languages (e.g. vi↔en) —
                    // see `AppState.autoRecognitionLocaleID`'s doc comment. Labeled in English (not
                    // localized) to match every other row in this list, which are Apple's
                    // localized locale names rather than translated UI strings.
                    Text("Automatic (multilingual)").tag(AppState.autoRecognitionLocaleID)
                    ForEach(speechLocales, id: \.id) { loc in
                        Text(loc.name).tag(loc.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(accentColors.solid)
                .frame(width: 200)
            }
            launchAtLoginRow
            SettingsRow(label: "Default task duration", hint: "Block this much time when a task has no explicit length.") {
                Segmented(value: $defaultDuration, options: [
                    .init(id: 15, label: "15"), .init(id: 30, label: "30"), .init(id: 60, label: "60 min"),
                ])
            }
            SettingsRow(label: "Hyperfocus interrupt after", hint: "Volar checks in if you've been deep on one task this long.") {
                Segmented(value: $hyperfocusInterrupt, options: [
                    .init(id: 60, label: "60"), .init(id: 90, label: "90"), .init(id: 120, label: "120 min"),
                ])
            }
            SettingsRow(label: "Show morning frog prompt", hint: "A daily question at first launch: what's the ONE task that matters most?") {
                VolarToggle(isOn: $showMorningFrog)
            }
            SettingsRow(label: "Guided tour", hint: "Walk through capture, the task list, and focus mode again.") {
                Button("Show tour") {
                    appState.replayTour()
                    // Load-bearing: Settings is a separate `Window` scene from the main window
                    // (see the `openWindow` doc comment on this view's property), and the tour
                    // overlay is drawn inside the main window's view tree — without this call the
                    // tour would start invisibly behind Settings and the click would look like a
                    // no-op.
                    openWindow(id: "main")
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(VolarColor.textPri)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(VolarColor.veil(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .volarHairline(cornerRadius: 7)
            }
            SettingsRow(label: "Capture foreground app context", hint: "Tags new tasks with the app you were in when you captured them.") {
                VolarToggle(isOn: $captureAppContext)
            }
            calendarAccessRow
            if appState.calendarAccess.status == .granted {
                calendarMirrorRow
            }
        }
    }

    /// Wired for real to `SMAppService.mainApp` (`LoginItem.swift`) — see that file's header
    /// comment for why `loginItemStatus` is re-read live rather than cached. The toggle's `isOn`
    /// binding calls `LoginItem.setEnabled(_:)` synchronously in its `set:` (no `Task` hop needed
    /// — `SMAppService`'s register/unregister calls are synchronous) and immediately re-reads
    /// `status` afterward, so the switch always reflects what macOS actually did, not what the
    /// user merely requested. `.requiresApproval` is a real, ordinary post-register state (macOS
    /// posts its own "Volar added a login item" notification and the login item doesn't actually
    /// fire until the user approves it in System Settings) — surfaced here as its own explanatory
    /// row + "Open Login Items…" button rather than treated as a toggle failure.
    @ViewBuilder
    private var launchAtLoginRow: some View {
        SettingsRow(
            label: "Launch at login",
            hint: "Volar opens automatically when you log in to your Mac."
        ) {
            VStack(alignment: .trailing, spacing: 4) {
                VolarToggle(isOn: Binding(
                    get: { loginItemStatus == .enabled },
                    set: { newValue in
                        do {
                            try LoginItem.setEnabled(newValue)
                            loginItemError = nil
                        } catch {
                            loginItemError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        }
                        // Re-read live status regardless of success/failure — a throw can still
                        // leave `SMAppService` in a different state than before the call (e.g.
                        // partial unregister), so this is the one honest source of truth either way.
                        loginItemStatus = LoginItem.status
                    }
                ))
                if let loginItemError {
                    Text(loginItemError)
                        .font(.system(size: 11))
                        .foregroundStyle(VolarColor.reschedule)
                        .lineLimit(2)
                }
            }
        }
        if loginItemStatus == .requiresApproval {
            HStack(spacing: 10) {
                Text("macOS needs your approval to finish enabling this.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(VolarColor.textSec)
                settingsPillButton("Open Login Items…") {
                    LoginItem.openLoginItemsSettings()
                }
            }
            .padding(.horizontal, 18)
        }
    }

    /// Real EventKit permission status — replaces a former dead prototype toggle ("Calendar
    /// integration" / "Mirror tasks... into your Mac Calendar") that had no backing implementation
    /// at all (a local `@State` bool wired to nothing, and an "Open in Calendar" button with an
    /// empty action). `appState.calendarAccess` (agent A's addition to `AppState`, per this
    /// feature's cross-agent contract) is the single source of truth for status — this row never
    /// keeps its own copy of it. This row is just PERMISSION status; whether Volar actually WRITES
    /// anything is a separate, opt-in decision surfaced in `calendarMirrorRow` below (shown only
    /// once access is granted — asking about mirroring before Volar can even read the calendar
    /// would be premature).
    @ViewBuilder
    private var calendarAccessRow: some View {
        SettingsRow(
            label: "Calendar access",
            hint: "Volar reads your calendar to see which blocks are actually free, and — once you turn on mirroring below — writes tasks into a calendar it creates called \"Volar\". It never touches your other calendars, and nothing leaves your Mac."
        ) {
            VStack(alignment: .trailing, spacing: 4) {
                calendarAccessControl
                if let lastError = appState.calendarAccess.lastError {
                    Text(lastError)
                        .font(.system(size: 11))
                        .foregroundStyle(VolarColor.textMut)
                        .lineLimit(2)
                }
            }
        }
    }

    /// One-way (Volar → Calendar) mirroring opt-in. `appState.calendarSync` owns `mirrorEnabled` —
    /// bound here via an explicit `Binding(get:set:)` rather than a raw `$appState.calendarSync...`
    /// path, matching this file's existing convention for every other enum/nested-object-backed
    /// control (`speechEngineChoice`/`parseEnginePreference`/etc. above) instead of introducing a
    /// new binding idiom for just this one row. `mirrorEnabled` is `private(set)` on `CalendarSync`
    /// (turning it off deletes real calendar events — a destructive action deliberately kept behind
    /// a named method, not a raw property set), so the setter here calls
    /// `AppState.setCalendarMirror(_:)` — which calls `CalendarSync.setMirrorEnabled(_:)` and then
    /// immediately reconciles — rather than assigning `appState.calendarSync.mirrorEnabled`
    /// directly (which no longer compiles).
    @ViewBuilder
    private var calendarMirrorRow: some View {
        SettingsRow(
            label: "Mirror tasks to Calendar",
            hint: "Tasks with a scheduled time appear as events in a separate calendar named \"Volar\" — Volar never touches your other calendars. Turning this off removes the events it created."
        ) {
            VStack(alignment: .trailing, spacing: 4) {
                VolarToggle(isOn: Binding(
                    get: { appState.calendarSync.mirrorEnabled },
                    set: { appState.setCalendarMirror($0) }
                ))
                if let lastError = appState.calendarSync.lastError {
                    Text(lastError)
                        .font(.system(size: 11))
                        .foregroundStyle(VolarColor.textMut)
                        .lineLimit(2)
                }
            }
        }
    }

    @ViewBuilder
    private var calendarAccessControl: some View {
        switch appState.calendarAccess.status {
        case .notDetermined:
            Button("Enable Calendar") {
                // FIX 6: routes through `AppState.enableCalendarAccess()` (awaits the real
                // EventKit prompt, then immediately reconciles the calendar mirror) instead of
                // calling `calendarAccess.requestAccess()` directly, so a fresh grant here takes
                // effect right away rather than waiting for the next task edit.
                Task { await appState.enableCalendarAccess() }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(VolarColor.textPri)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(VolarColor.veil(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .volarHairline(cornerRadius: 7)

        case .granted:
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Circle().fill(VolarColor.done).frame(width: 7, height: 7)
                    Text("Connected · \(appState.calendarAccess.calendarCount) calendars")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(VolarColor.textSec)
                }
                Button("Refresh") {
                    appState.calendarAccess.refreshStatus()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(VolarColor.textPri)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(VolarColor.veil(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .volarHairline(cornerRadius: 7)
            }

        case .denied, .restricted:
            // Hard "no red for status" rule (this project's convention) — calm neutral text, not
            // an alarm color, even though access is off.
            HStack(spacing: 10) {
                Text("Access is off")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(VolarColor.textSec)
                Button("Open System Settings") {
                    appState.calendarAccess.openSystemSettings()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(VolarColor.textPri)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(VolarColor.veil(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .volarHairline(cornerRadius: 7)
            }

        case .unavailable:
            Text("Unavailable on this Mac")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(VolarColor.textSec)
        }
    }

    // MARK: - Hotkeys

    private var hotkeysTab: some View {
        VStack(spacing: 12) {
            SettingsRow(label: "Quick capture", hint: "Press this combo from anywhere to toggle recording — press to start, press again to stop.") {
                KeyRecorder(keys: ["\u{2303}", "\u{2325}", "M"])
            }
            // Add a task by typing (⌃⌥T, `Sources/Speech/HotkeyManager.swift` /
            // `Sources/Views/TextCapturePanel.swift`) — the typed equivalent of Quick capture
            // above, for when speaking isn't an option (a meeting, a café, an open-plan office).
            // Same `SettingsRow`/`KeyRecorder` structure as every other row in this tab.
            SettingsRow(label: "Add a task by typing", hint: "Press this combo from anywhere to open a small text box — type, hit Return, done. No speaking required.") {
                KeyRecorder(keys: ["\u{2303}", "\u{2325}", "T"])
            }
            SettingsRow(label: "Task breakdown (long press)", hint: "Hold the same hotkey \u{2265}1.5s to have AI split the task into steps.") {
                HStack(spacing: 8) {
                    Text("Long-press")
                        .font(.system(size: 11))
                        .foregroundStyle(VolarColor.textSec)
                    KeyBadge("\u{2303}")
                    KeyBadge("\u{2325}")
                    KeyBadge("M")
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Color.black.opacity(0.25))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .volarHairline(cornerRadius: 8)
            }
            SettingsRow(label: "Show Volar window", hint: "Bring the main window to the front.") {
                KeyRecorder(keys: ["\u{2303}", "\u{2325}", "V"])
            }
            SettingsRow(label: "Toggle Focus Lock", hint: "Lock the current task as your only focus — Volar will gently interrupt if you drift.") {
                KeyRecorder(keys: ["\u{2303}", "\u{2325}", "F"])
            }
            SettingsRow(label: "Complete current task", hint: "When Focus Lock is active, mark the current task done without opening the window.") {
                KeyRecorder(keys: ["\u{2303}", "\u{2325}", "\u{21A9}"])
            }
        }
    }

    // MARK: - Notifications

    private var notificationsTab: some View {
        VStack(spacing: 16) {
            SettingsRow(label: "Show reminders", hint: "Send a macOS notification before each task.") {
                VolarToggle(isOn: $showReminders)
            }
            SettingsRow(label: "Sound", hint: "Subtle chime when a task is captured.") {
                VolarToggle(isOn: $notifSound)
            }
            SettingsRow(label: "Focus mode aware", hint: "Stay silent while macOS Focus is on.") {
                VolarToggle(isOn: $focusModeAware)
            }
            // Phase 4 (T033): the two rows below are wired for real to `AppState` (unlike the
            // toggles above, still cosmetic-only local `@State` — out of this task's scope).
            SettingsRow(
                label: "Default reminders before deadline",
                hint: "Applies to any task without its own custom reminder — the global default the reminder scheduler falls back to."
            ) {
                Segmented(
                    value: Binding(
                        get: { ReminderPolicyPreset(matching: appState.globalReminderPolicy) },
                        set: { appState.setGlobalReminderPolicy($0.policy) }
                    ),
                    options: ReminderPolicyPreset.allCases.map { SegmentOption(id: $0, label: $0.label) }
                )
            }
            SettingsRow(
                label: "Voice delivery",
                hint: "Visual notifications always show. Voice is an extra, on-device-spoken nudge for urgent or unacknowledged reminders."
            ) {
                Segmented(
                    value: Binding(
                        get: { appState.voiceDeliveryMode },
                        set: { appState.setVoiceDeliveryMode($0) }
                    ),
                    options: VoiceDeliveryMode.allCases.map { SegmentOption(id: $0, label: $0.label) }
                )
            }
        }
    }

    /// Named presets over the full `ReminderPolicy` shape (`Recurrence.swift`) so the Settings row
    /// above can stay a simple `Segmented` control rather than a free-form offsets editor — mirrors
    /// this file's existing convention for other multi-value settings (`Density`, `AmbientMode`).
    private enum ReminderPolicyPreset: String, CaseIterable, Identifiable, Hashable {
        case dayHourAt, hourAt, atOnly, none

        var id: String { rawValue }

        var label: String {
            switch self {
            case .dayHourAt: return "1 day, 1 hour, at deadline"
            case .hourAt: return "1 hour, at deadline"
            case .atOnly: return "At deadline"
            case .none: return "None"
            }
        }

        var policy: ReminderPolicy {
            switch self {
            case .dayHourAt: return .defaultPolicy
            case .hourAt: return ReminderPolicy(offsets: [-3600, 0], repeatEvery: nil)
            case .atOnly: return ReminderPolicy(offsets: [0], repeatEvery: nil)
            case .none: return ReminderPolicy(offsets: [], repeatEvery: nil)
            }
        }

        /// Falls back to `.dayHourAt` for a policy that doesn't match any named preset (e.g. one
        /// set by a future finer-grained editor) rather than crashing on an unrecognized shape.
        init(matching policy: ReminderPolicy) {
            self = Self.allCases.first { $0.policy == policy } ?? .dayHourAt
        }
    }

    // MARK: - Appearance

    private func appearanceTab(appState: AppState) -> some View {
        VStack(spacing: 16) {
            SettingsRow(label: "Theme", hint: "Volar is dark-only — the way Mac power users live.") {
                Segmented(value: $themeChoice, options: [
                    .init(id: "dark", label: "Dark"), .init(id: "system", label: "Match system", disabled: true),
                ])
            }
            SettingsRow(label: "Background", hint: "A live scene or your own image behind the glass. Task list and panels stay readable on top.") {
                Segmented(
                    value: Binding(
                        get: { appState.ambient },
                        set: { appState.setAmbient($0) }
                    ),
                    options: AmbientMode.allCases.map { SegmentOption(id: $0, label: $0.label) }
                )
            }
            if appState.ambient == .custom {
                SettingsRow(label: "Custom image", hint: "Choose a photo or wallpaper from your Mac.") {
                    HStack(spacing: 10) {
                        CustomImageThumbnail(url: appState.customImageURL)
                            .frame(width: 44, height: 30)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                        Button("Choose image…") { chooseImage(appState: appState) }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(VolarColor.textPri)
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background(VolarColor.card)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .volarHairline(cornerRadius: 7)

                        if appState.customImageURL != nil {
                            Button("Remove") {
                                SecureImageBookmark.clear()
                                appState.setCustomImage(nil)
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(VolarColor.textSec)
                        }
                    }
                }
            }
            SettingsRow(label: "Accent color", hint: "Used for active states and the capture button.") {
                HStack(spacing: 10) {
                    ForEach(VolarAccent.allCases) { candidate in
                        // `VolarAccent` (Theme.swift, frozen §3) doesn't declare Equatable, so
                        // compare via `rawValue` instead of `==`.
                        let selected = candidate.rawValue == appState.accent.rawValue
                        Circle()
                            .fill(candidate.accent.solid)
                            .frame(width: 22, height: 22)
                            .overlay(
                                Circle().stroke(selected ? Color.white : VolarColor.veil(0.2), lineWidth: 0.5)
                            )
                            .overlay(
                                Circle().stroke(candidate.accent.solid, lineWidth: selected ? 1.5 : 0)
                                    .padding(-2.5)
                            )
                            .onTapGesture {
                                // FIX 4: routes through `AppState.setAccent` (persists to
                                // UserDefaults) instead of a bare property assignment — a plain
                                // `appState.accent = candidate` never survived relaunch.
                                appState.setAccent(candidate)
                            }
                    }
                }
            }
            SettingsRow(label: "Density", hint: "How tight the rows pack.") {
                // `Density` (Theme.swift, frozen §3) doesn't declare Hashable/Equatable, so the
                // generic `Segmented<T: Hashable>` binds through a `String` id here instead of
                // the enum itself.
                Segmented(
                    value: Binding(
                        get: { densityID(appState.density) },
                        // FIX 4: routes through `AppState.setDensity` (persists to UserDefaults)
                        // instead of a bare property assignment — a plain `appState.density = ...`
                        // never survived relaunch.
                        set: { appState.setDensity(density(fromID: $0)) }
                    ),
                    options: [
                        .init(id: "cozy", label: "Cozy"),
                        .init(id: "comfy", label: "Comfy"),
                        .init(id: "roomy", label: "Roomy"),
                    ]
                )
            }
        }
    }

    /// Opens a file picker for the custom ambient background image. App Sandbox is ON (T002):
    /// `NSOpenPanel` grants a transient sandbox extension for whatever the user picks, which is
    /// enough for the current session, but persisting access across relaunches needs a
    /// security-scoped bookmark — `SecureImageBookmark.save` (AmbientBackground.swift) creates
    /// and persists that bookmark under its own UserDefaults key, alongside (not instead of)
    /// `appState.setCustomImage`'s existing raw-path persistence, which is left untouched.
    private func chooseImage(appState: AppState) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            SecureImageBookmark.save(for: url)
            appState.setCustomImage(url)
        }
    }

    private func densityID(_ density: Density) -> String {
        switch density {
        case .cozy: return "cozy"
        case .comfy: return "comfy"
        case .roomy: return "roomy"
        }
    }

    private func density(fromID id: String) -> Density {
        switch id {
        case "cozy": return .cozy
        case "roomy": return .roomy
        default: return .comfy
        }
    }

    // MARK: - Integrations (T044, phase6-contract.md §C: "Connect Claude Code")

    /// `true` once `ClaudeCodeConnector.detect()` finds `~/.claude` — the contract's "show only if
    /// Claude Code present" gate. Re-checked on `.task` (tab first shown) rather than cached across
    /// the whole Settings window session, so re-opening Settings after installing the CLI picks it
    /// up without relaunching Volar.
    @State private var claudeDetected = false
    /// Local UI-only "did THIS UI successfully connect" bookkeeping — `ClaudeCodeConnector` keeps
    /// no app-facing connect/disconnect state of its own (its doc comment: "the caller composes
    /// [State] from detect() plus its own bookkeeping"). Initialized from whether
    /// `ClaudeDirBookmark` has a saved grant, so it survives Settings being reopened.
    @State private var claudeConnected = false
    @State private var claudeConnectError: String?
    /// Set right before `sendTestSignal()` fires; cleared (and flips `testSignalReceived` on) the
    /// next time `appState.lastAppLinkAt` changes — see the `.onChange` below.
    @State private var testSignalAwaitingReceipt = false
    @State private var testSignalReceived = false
    /// M1: whether it's safe to offer "Send test signal" — `AppLinkHandler.handle`'s exactly-one-
    /// waiting-task rule can't be told a signal is a test, so it's only safe when nothing real is
    /// currently waiting to be wrongly resolved. `wipCount()` is the same live-derived count
    /// `MenuBarLabel`'s "⏳ N" badge uses (`DelegationTracker.wipCount()`, O(n) over tasks, cheap
    /// enough to read directly in this computed property rather than caching it).
    private var claudeTestSignalSafe: Bool {
        (appState.delegation?.wipCount() ?? 0) == 0
    }

    private var integrationsTab: some View {
        VStack(spacing: 12) {
            // WG4 (ship-blocker, reviewer fix): this used to gate the ENTIRE card — including the
            // "Connect…" button itself — on `claudeDetected`. Under App Sandbox, `detect()` returns
            // `false` on first run (the container home has no `~/.claude`;
            // `ClaudeCodeConnector.detect()`'s own doc comment says to treat `false` as "unknown,
            // offer the picker" — never as "hide the connect affordance"). `claudeCodeCard` already
            // internally branches connect-vs-disconnect on `claudeConnected` (the real gate — an
            // actual granted NSOpenPanel/bookmark, fully entitled regardless of sandbox detection),
            // so it's always shown; `claudeDetected` is used ONLY to soften the copy inside it now
            // (see `claudeConnectHint` below).
            claudeCodeCard
        }
        .task {
            claudeDetected = appState.claudeConnector.detect()
            claudeConnected = ClaudeDirBookmark.resolve() != nil
        }
        .onChange(of: appState.lastAppLinkAt) { _, _ in
            guard testSignalAwaitingReceipt else { return }
            testSignalAwaitingReceipt = false
            testSignalReceived = true
        }
    }

    /// WG4: the card's description line, softened by `claudeDetected` — never a gate on whether
    /// the card (or its Connect button) is shown at all, only on which sentence explains it.
    private var claudeConnectHint: String {
        guard !claudeConnected else {
            return "Installs a Stop hook so Claude Code tells Volar when an agent run finishes — Volar never reads Claude Code's own state, only receives this one signal (contracts/app-links.md)."
        }
        return claudeDetected
            ? "Found ~/.claude on this Mac — connect to install a Stop hook so Claude Code tells Volar when an agent run finishes."
            : "Choose your ~/.claude folder to connect. Volar couldn't confirm it's there automatically (normal under sandboxing) — it may still exist; pick it below."
    }

    /// The full "Connect Claude Code" card: preview → connect/disconnect → test-signal, all in one
    /// `VolarColor.card` block (rather than several `SettingsRow`s) since the preview code block
    /// and multi-step connect flow don't fit that row's fixed label/hint/control shape.
    private var claudeCodeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Connect Claude Code")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(VolarColor.textPri)
                Text(claudeConnectHint)
                    .font(.system(size: 12))
                    .foregroundStyle(VolarColor.textSec)
                    .lineSpacing(2)
            }

            Text(appState.claudeConnector.previewHookEntry())
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(VolarColor.instrument)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.25))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .volarHairline(cornerRadius: 8)

            if let claudeConnectError {
                Text(claudeConnectError)
                    .font(.system(size: 11.5))
                    .foregroundStyle(VolarColor.reschedule)
                    .lineLimit(3)
            }

            HStack(spacing: 8) {
                if claudeConnected {
                    // M1 (self-review "client-exploit", reviewer fix): `AppLinkHandler.handle` for
                    // `ai-done` resolves (marks needs-review) whenever EXACTLY ONE task is currently
                    // waiting on AI, regardless of whether the signal is a real Claude Code Stop
                    // hook or this test button — `ClaudeCodeConnector.sendTestSignal()` (out of this
                    // fix's file ownership) carries no marker distinguishing the two. Rather than
                    // let "Send test signal" silently clear a real in-flight delegation, it's only
                    // offered while there is nothing it COULD wrongly resolve (`wipCount() == 0`).
                    // (`AppLinkHandler.handle` also now treats a future `test=1`/`probe=1` param as
                    // receipt-only, forward-compatible if the connector is ever updated to send one
                    // — see that file's `handleAIDone`.)
                    if claudeTestSignalSafe {
                        settingsPillButton("Send test signal", solid: true) { sendClaudeTestSignal() }
                    }
                    settingsPillButton("Disconnect") { disconnectClaudeCode() }
                } else {
                    settingsPillButton("Connect…", solid: true) { connectClaudeCode() }
                }
            }

            if claudeConnected, !claudeTestSignalSafe {
                Text("Test signal hidden while a delegation is waiting — sending it now could mark a real task reviewed instead of just testing the connection.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(VolarColor.textMut)
                    .lineLimit(3)
            }

            if testSignalAwaitingReceipt {
                Text("Signal sent — waiting…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(VolarColor.textMut)
            } else if testSignalReceived {
                Text("\u{2713} received")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(VolarColor.done)
            }
        }
        .padding(16)
        .background(VolarColor.card)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .volarHairline(cornerRadius: 11)
    }

    private func settingsPillButton(_ title: String, solid: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(solid ? .white : VolarColor.textPri)
                .padding(.horizontal, 14)
                .frame(height: 30)
        }
        .buttonStyle(.plain)
        .background(solid ? accentColors.solid : VolarColor.surfaceHi)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(solid ? VolarColor.veil(0.18) : VolarColor.borderHi, lineWidth: 0.5)
        )
    }

    /// NSOpenPanel pre-targeted at `~/.claude`, granting the security-scoped bookmark
    /// `ClaudeCodeConnector.connect(bookmarkedClaudeDir:)` needs (App Sandbox). Mirrors
    /// `chooseImage`'s existing picker pattern above. `ClaudeDirBookmark.save` persists the grant
    /// under THIS file's own key (distinct from — and in addition to — the connector's own
    /// internal `detect()` bookkeeping bookmark, which is `private` to `ClaudeCodeConnector` and
    /// therefore unreachable from here; see `ClaudeDirBookmark`'s doc comment below for why a
    /// second bookmark store is the correct call, not duplication for its own sake).
    private func connectClaudeCode() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        // M2 (minor, reviewer fix): `FileManager.default.homeDirectoryForCurrentUser` under App
        // Sandbox resolves to the SANDBOX CONTAINER's home, not the user's real home — pre-targeting
        // `<container>/.claude` (which never exists) forced the user to navigate away every time.
        // `NSHomeDirectoryForUser(NSUserName())` looks the real home up via the directory-services
        // passwd entry directly, bypassing the sandbox's redirected `$HOME`, so it resolves to the
        // user's ACTUAL home. Falls back to the real home directory itself (letting the user
        // navigate from there) when `~/.claude` doesn't exist yet there, and never crashes/force-
        // unwraps if resolution fails outright — the panel just opens at its own default location.
        if let realHome = NSHomeDirectoryForUser(NSUserName()) {
            let realHomeURL = URL(fileURLWithPath: realHome, isDirectory: true)
            let claudeDir = realHomeURL.appendingPathComponent(".claude", isDirectory: true)
            panel.directoryURL = FileManager.default.fileExists(atPath: claudeDir.path) ? claudeDir : realHomeURL
        }
        panel.message = "Choose your ~/.claude folder so Volar can install the Claude Code hook."
        panel.prompt = "Grant Access"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try appState.claudeConnector.connect(bookmarkedClaudeDir: url)
            ClaudeDirBookmark.save(for: url)
            claudeConnected = true
            claudeConnectError = nil
        } catch {
            claudeConnectError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func disconnectClaudeCode() {
        guard let url = ClaudeDirBookmark.resolve() else {
            claudeConnectError = "Volar lost access to ~/.claude — reconnect once to disconnect cleanly."
            claudeConnected = false
            return
        }
        do {
            try appState.claudeConnector.disconnect(bookmarkedClaudeDir: url)
            ClaudeDirBookmark.clear()
            claudeConnected = false
            claudeConnectError = nil
        } catch {
            claudeConnectError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Fires `ClaudeCodeConnector.sendTestSignal()` (opens `volar://ai-done?cwd=...` via
    /// `NSWorkspace`, per contract B), then waits for the real inbound round trip —
    /// `appState.lastAppLinkAt` is stamped by `AppState.onAppLinkHandled()`, called from
    /// `VolarApp.swift`'s `.onOpenURL` right after `AppLinkHandler.handle(_:)` processes it — so
    /// "✓ received" reflects an actual signal, not a fixed timer.
    private func sendClaudeTestSignal() {
        testSignalReceived = false
        testSignalAwaitingReceipt = true
        appState.claudeConnector.sendTestSignal()
    }

    // MARK: - Account (Task 4, account-auth.md contract)

    private var accountTab: some View {
        VStack(spacing: 12) {
            accountCard
        }
    }

    /// Single card, same "one `VolarColor.card` block, not several `SettingsRow`s" reasoning as
    /// `claudeCodeCard` above — the sign-in forms and the signed-in summary don't fit that row's
    /// fixed label/hint/control shape.
    private var accountCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Account")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(VolarColor.textPri)
                Text(appState.accountEmail == nil
                     ? "Sign in to unlock Cloud parsing and Groq speech transcription. Volar's core (capture, tasks, reminders, focus) never requires an account."
                     : "Manage your Volar account, subscription, and daily AI quota.")
                    .font(.system(size: 12))
                    .foregroundStyle(VolarColor.textSec)
                    .lineSpacing(2)
            }

            if let email = appState.accountEmail {
                signedInAccountBody(email: email)
            } else {
                signedOutAccountBody
            }

            if let accountError = appState.accountError {
                Text(accountError)
                    .font(.system(size: 11.5))
                    .foregroundStyle(VolarColor.reschedule)
                    .lineLimit(4)
            }
        }
        .padding(16)
        .background(VolarColor.card)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .volarHairline(cornerRadius: 11)
    }

    private var signedOutAccountBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Dual-identity trap UX (backlog): a reminder of which method worked last time, so a
            // Pro subscriber who tries the OTHER method doesn't accidentally end up looking at a
            // brand-new, unrelated `free` account. Informational only — never blocks either button
            // below, both login paths stay fully available per product decision.
            if let method = appState.lastAuthMethod {
                Text("Last time you signed in with \(method.displayName).")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(VolarColor.textMut)
            }

            settingsPillButton("Sign in with Apple", solid: true) {
                appState.signInWithApple()
            }
            .disabled(appState.accountBusy)

            Text("or sign in with email")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(VolarColor.textMut)

            HStack(spacing: 8) {
                TextField("you@example.com", text: $accountEmailInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(VolarColor.textPri)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(Color.black.opacity(0.25))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .volarHairline(cornerRadius: 7)
                settingsPillButton("Send code") {
                    accountCodeSent = true
                    appState.sendEmailOTP(email: accountEmailInput)
                }
                .disabled(appState.accountBusy || accountEmailInput.isEmpty)
            }

            if accountCodeSent {
                HStack(spacing: 8) {
                    TextField("6-digit code", text: $accountCodeInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(VolarColor.textPri)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .frame(width: 120)
                        .background(Color.black.opacity(0.25))
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .volarHairline(cornerRadius: 7)
                    settingsPillButton("Verify", solid: true) {
                        appState.verifyEmailOTP(email: accountEmailInput, code: accountCodeInput)
                    }
                    .disabled(appState.accountBusy || accountCodeInput.count != 6)
                }
            }
        }
    }

    @ViewBuilder
    private func signedInAccountBody(email: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(email)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(VolarColor.textPri)
                tierBadge
            }

            if let status = appState.subscriptionStatus {
                Text("Parse: \(status.parseUsedToday)/\(status.parseLimit) lượt AI hôm nay")
                    .font(.system(size: 11.5))
                    .foregroundStyle(VolarColor.textSec)
                if appState.accountTier == .pro {
                    Text("Speech: \(status.speechUsedToday)/\(status.speechLimit) lượt hôm nay")
                        .font(.system(size: 11.5))
                        .foregroundStyle(VolarColor.textSec)
                }
            }

            if appState.accountTier == .free {
                upgradeSection
                // Dual-identity trap UX (backlog): this account genuinely reads `free` server-side
                // — but if the user bought Pro using the OTHER sign-in method, Apple's Hide My
                // Email relay can mean that purchase lives on a totally different `auth.users` row
                // than the one they're looking at right now. Informational only — deliberately NO
                // auto-sign-out button here, just a pointer at the fix.
                if let method = appState.lastAuthMethod {
                    Text("Already subscribed? Your Pro plan lives with the account you bought it on. If you subscribed using \(method.other.displayName), sign out and sign back in that way — Apple's Hide My Email can create a second, separate account.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(VolarColor.textSec)
                        .lineSpacing(2)
                }
            }

            redeemCodeRow

            HStack(spacing: 8) {
                settingsPillButton("Restore Purchases") { appState.restorePurchases() }
                    .disabled(appState.accountBusy)
                settingsPillButton("Manage Subscription") { openManageSubscriptions() }
                settingsPillButton("Sign out") { appState.signOutAccount() }
            }

            Button("Delete account", role: .destructive) {
                showDeleteAccountConfirm = true
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(VolarColor.destruct)
            .padding(.top, 4)
            .confirmationDialog(
                "Delete your Volar account? This cannot be undone — your tasks stay on this Mac, but your account, subscription link, and quota history are permanently removed.",
                isPresented: $showDeleteAccountConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete account", role: .destructive) { appState.deleteAccount() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    /// Backlog "1 free month of Pro" promo codes (Task 3, redeem contract). Only reachable from
    /// `signedInAccountBody` — redemption attaches the grant to the signed-in identity, so showing
    /// this to a signed-out user would just produce `AccountError.signedOut` on every tap; visible-
    /// but-disabled was considered and rejected in favor of just not rendering it, matching how
    /// `upgradeSection`/`Restore Purchases`/"Delete account" are ALSO signed-in-only rows on this
    /// same card rather than disabled placeholders — same-page precedent, not a new pattern.
    ///
    /// Styled identically to the email-OTP field/button pair directly above in
    /// `signedOutAccountBody` (same `Color.black.opacity(0.25)` field background, `volarHairline`,
    /// monospaced font matching the 6-digit code field, `settingsPillButton`) — deliberately no new
    /// visual treatment introduced for this row.
    private var redeemCodeRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Have a promo code?")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(VolarColor.textMut)
            HStack(spacing: 8) {
                TextField("PROMOCODE", text: $promoCodeInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(VolarColor.textPri)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(Color.black.opacity(0.25))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .volarHairline(cornerRadius: 7)
                    // Live-uppercase as the user types — cosmetic only (Task 1's
                    // `AccountService.redeemPromoCode` is the ONE place that actually normalizes
                    // what goes on the wire; this just keeps what's on screen matching what will be
                    // sent, since a pasted lowercase code otherwise LOOKS unnormalized until submit).
                    // Mutating the bound string directly here (rather than `.textCase(.uppercase)`,
                    // which only recases the RENDERED glyphs and would leave `promoCodeInput` itself
                    // mixed-case) is the straightforward option — no fight with the binding, since
                    // `TextField` already treats `$promoCodeInput` as the single source of truth.
                    .onChange(of: promoCodeInput) { _, newValue in
                        let upper = newValue.uppercased()
                        if upper != newValue { promoCodeInput = upper }
                    }
                settingsPillButton("Redeem", solid: true) {
                    appState.redeemPromoCode(promoCodeInput)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(appState.accountBusy || promoCodeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            // Success confirmation only — failures already surface through `accountCard`'s existing
            // `appState.accountError` `Text` right below this whole card, so this does NOT duplicate
            // that as a second error label (task brief's explicit instruction).
            if let until = appState.lastRedeemedUntil {
                Text("Pro until \(until.formatted(date: .abbreviated, time: .omitted))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(VolarColor.done)
            }
        }
    }

    private var tierBadge: some View {
        Text(appState.accountTier == .pro ? "Pro" : "Free")
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(appState.accountTier == .pro ? VolarColor.done : VolarColor.textSec)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background((appState.accountTier == .pro ? VolarColor.done : Color.white).opacity(0.14))
            .clipShape(Capsule())
    }

    /// The two "Volar Pro" products (contract §8) — prices always come from `product.displayPrice`
    /// (never a hardcoded "$6.99"), so this reads correctly in every storefront/currency.
    private var upgradeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Upgrade to Pro — 14-day free trial")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(VolarColor.textPri)
                .padding(.top, 4)
            productRow(appState.monthlyProduct, product: .monthly)
            productRow(appState.yearlyProduct, product: .yearly)
        }
    }

    @ViewBuilder
    private func productRow(_ product: Product?, product which: VolarProduct) -> some View {
        HStack {
            Text(product?.displayName ?? (which == .monthly ? "Monthly" : "Yearly"))
                .font(.system(size: 12))
                .foregroundStyle(VolarColor.textSec)
            Spacer()
            if let product {
                settingsPillButton(product.displayPrice, solid: true) {
                    appState.purchase(which)
                }
                .disabled(appState.accountBusy)
            } else {
                Text("Unavailable")
                    .font(.system(size: 11.5))
                    .foregroundStyle(VolarColor.textMut)
            }
        }
    }

    /// macOS has no `AppStore.showManageSubscriptions(in:)` equivalent (that StoreKit 2 call is
    /// iOS-only) — opening the App Store's own subscriptions management page via `NSWorkspace` is
    /// the standard macOS approach. // UNVERIFIED: not exercised on a real Mac.
    private func openManageSubscriptions() {
        guard let url = URL(string: "https://apps.apple.com/account/subscriptions") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - About

    private var aboutTab: some View {
        VStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [accentColors.solid, accentColors.hover], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 64, height: 64)
                .overlay {
                    VolarIcon(.mic, size: 32, color: .white, weight: .regular)
                }
                .shadow(color: accentColors.glow, radius: 20, y: 8)

            Text("Volar 1.0.2")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(VolarColor.textPri)

            Text("Voice-first task manager for Mac. Built in Cambridge.")
                .font(.system(size: 13))
                .foregroundStyle(VolarColor.textSec)

            HStack(spacing: 8) {
                Text("What's new")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(accentColors.solid)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(accentColors.surface)
                    .clipShape(Capsule())

                Text("Acknowledgements")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(VolarColor.textSec)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(VolarColor.veil(0.06))
                    .clipShape(Capsule())
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
    }
}

// MARK: - Private shared row/control views

/// Label + hint on the left, arbitrary control on the right. Ported from the prototype's
/// `SettingsRow`.
private struct SettingsRow<Content: View>: View {
    let label: String
    let hint: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(VolarColor.textPri)
                if let hint {
                    Text(hint)
                        .font(.system(size: 12))
                        .foregroundStyle(VolarColor.textSec)
                        .lineSpacing(2)
                }
            }
            Spacer(minLength: 12)
            content()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(VolarColor.card)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .volarHairline(cornerRadius: 11)
    }
}

/// Custom pill toggle (named `VolarToggle` — not `Toggle` — to avoid clashing with the SwiftUI
/// control). Ported from the prototype's `Toggle`.
private struct VolarToggle: View {
    @Binding var isOn: Bool

    @Environment(AppState.self) private var appState
    private var accentColors: Accent { appState.accent.accent }

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(isOn ? accentColors.solid : VolarColor.veil(0.12))
            .frame(width: 38, height: 22)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(.white)
                    .frame(width: 18, height: 18)
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                    .padding(2)
            }
            .shadow(color: isOn ? accentColors.glow.opacity(0.4) : .clear, radius: 8)
            .animation(VolarMotion.hover, value: isOn)
            .onTapGesture { isOn.toggle() }
    }
}

private struct SegmentOption<T: Hashable> {
    let id: T
    let label: String
    var disabled: Bool = false
}

/// Segmented control. Ported from the prototype's `Segmented`.
private struct Segmented<T: Hashable>: View {
    @Binding var value: T
    let options: [SegmentOption<T>]

    @Environment(AppState.self) private var appState
    private var accentColors: Accent { appState.accent.accent }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.id) { option in
                let selected = option.id == value
                Button {
                    guard !option.disabled else { return }
                    value = option.id
                } label: {
                    Text(option.label)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(option.disabled ? VolarColor.textMut : (selected ? accentColors.solid : VolarColor.textSec))
                        .opacity(option.disabled ? 0.5 : 1)
                        .padding(.horizontal, 12)
                        .frame(height: 24)
                        .background(selected ? accentColors.surface : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.black.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .volarHairline(cornerRadius: 8)
    }
}

/// Small preview swatch for the custom ambient background image, loaded via
/// `SecureImageBookmark.loadImage` (sandbox-safe — see AmbientBackground.swift) instead of a raw
/// `NSImage(contentsOf:)` call, and cached in `@State` so it decodes once per `url` change rather
/// than on every `body` evaluation of the surrounding `appearanceTab`.
private struct CustomImageThumbnail: View {
    let url: URL?

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                VolarColor.veil(0.06)
            }
        }
        .onAppear { reload() }
        .onChange(of: url) { _, _ in reload() }
    }

    private func reload() {
        image = SecureImageBookmark.loadImage(fallbackRawURL: url)
    }
}

/// Static key-combo chip with a trailing "Change" affordance. Ported from the prototype's
/// `KeyRecorder`. Re-binding the actual global hotkey is Phase 3 (`HotkeyManager`).
private struct KeyRecorder: View {
    let keys: [String]

    @Environment(AppState.self) private var appState
    private var accentColors: Accent { appState.accent.accent }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(keys, id: \.self) { KeyBadge($0) }
            Text("Change")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(accentColors.solid)
                .padding(.leading, 4)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Color.black.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .volarHairline(cornerRadius: 8)
    }
}

/// Security-scoped bookmark for the user-granted `~/.claude` directory (T044, App Sandbox), used
/// ONLY so this Settings UI can re-obtain a `URL` for `ClaudeCodeConnector.disconnect(
/// bookmarkedClaudeDir:)` across relaunches — `connect(bookmarkedClaudeDir:)` already persists its
/// OWN bookmark internally (`Orchestrator/ClaudeCodeConnector.swift`'s `persistBookmark`, under a
/// `private` UserDefaults key) purely for its own `detect()` fallback, but never exposes a way to
/// resolve that bookmark back to a `URL` for a later `disconnect` call. Mirrors
/// `AmbientBackground.swift`'s `SecureImageBookmark` byte-for-byte (same save/resolve/clear shape,
/// same `.withSecurityScope` bookmark options, same stale-bookmark re-mint-on-resolve behavior) —
/// a second small bookmark store, not a refactor of that one, since `SecureImageBookmark` is scoped
/// to the ambient-background image and this is a different grant entirely.
private enum ClaudeDirBookmark {
    private static let key = "volar.claudeDirBookmarkData.settingsUI"

    static func save(for url: URL) {
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            // Best-effort only, mirrors `SecureImageBookmark.save`: `connect(bookmarkedClaudeDir:)`
            // above already succeeded by the time this runs, so a save failure here only means a
            // later `disconnect` will need the user to reconnect first — never lost/corrupted state.
            print("[Volar.SettingsView.ClaudeDirBookmark] save failed: \(error)")
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// Resolves the saved bookmark back to a `URL`, re-minting it if stale. Never throws: any
    /// failure (missing bookmark, moved/deleted folder, tampered UserDefaults data) returns `nil`
    /// so callers fall back to "reconnect" rather than crashing.
    static func resolve() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        if isStale {
            save(for: url)
        }
        return url
    }
}

#Preview {
    SettingsView()
        .environment(AppState())
}
