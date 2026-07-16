// Sources/Views/SettingsView.swift — Settings window: 5 tabs (General/Hotkeys/Notifications/
// Appearance/About), ported from `design/volar-extras.jsx`'s `VolarSettings`. Native-first: a
// custom top tab strip (icon + label, accent-tinted when selected) switches a `@State tab` with
// the tab content below. Most rows here are local, cosmetic `@State` (Launch at login, reminder
// defaults, notification toggles, etc.) — the frozen `AppState` (spec §4) does not own these
// preferences, only `accent` and `density`, which this view binds for real via `@Bindable`.
import SwiftUI
import AppKit
import Speech
import UniformTypeIdentifiers

struct SettingsView: View {
    private enum Tab: String, CaseIterable, Identifiable, Equatable {
        case general, hotkeys, notifications, appearance, integrations, about
        var id: String { rawValue }

        var icon: VolarIconName {
            switch self {
            case .general: return .settings
            case .hotkeys: return .cmd
            case .notifications: return .bell
            case .appearance: return .sparkle
            case .integrations: return .bolt
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
            case .about: return "About"
            }
        }
    }

    @State private var tab: Tab = .general

    // Cosmetic-only local settings state (not part of the frozen AppState API).
    @State private var launchAtLogin = true
    @State private var defaultDuration = 30
    @State private var hyperfocusInterrupt = 90
    @State private var showMorningFrog = true
    @State private var captureAppContext = true
    @State private var calendarIntegration = false

    @State private var showReminders = true
    @State private var notifSound = true
    @State private var focusModeAware = false

    @State private var themeChoice = "dark"

    @Environment(AppState.self) private var appState

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
                    case .about: aboutTab
                    }
                }
                .padding(22)
            }
        }
        .frame(minWidth: 560, minHeight: 460)
        .background(VolarColor.bg)
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
            SettingsRow(label: "Recognition language", hint: "The language Volar listens for when you capture a task by voice, including Vietnamese.") {
                Picker("", selection: Binding(
                    get: { appState.recognitionLocaleID },
                    set: { appState.setRecognitionLocale($0) }
                )) {
                    ForEach(speechLocales, id: \.id) { loc in
                        Text(loc.name).tag(loc.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(accentColors.solid)
                .frame(width: 200)
            }
            SettingsRow(label: "Launch at login", hint: "Volar starts in the background and lives in your menu bar.") {
                VolarToggle(isOn: $launchAtLogin)
            }
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
            SettingsRow(label: "Capture foreground app context", hint: "Tags new tasks with the app you were in when you captured them.") {
                VolarToggle(isOn: $captureAppContext)
            }
            SettingsRow(label: "Calendar integration", hint: "Mirror tasks with scheduled times into your Mac Calendar.") {
                HStack(spacing: 10) {
                    VolarToggle(isOn: $calendarIntegration)
                    Button("Open in Calendar") {}
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(VolarColor.textPri)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(Color.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .volarHairline(cornerRadius: 7)
                }
            }
        }
    }

    // MARK: - Hotkeys

    private var hotkeysTab: some View {
        VStack(spacing: 12) {
            SettingsRow(label: "Quick capture", hint: "Press this combo from anywhere to toggle recording — press to start, press again to stop.") {
                KeyRecorder(keys: ["\u{2303}", "\u{2325}", "M"])
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
                                Circle().stroke(selected ? Color.white : Color.white.opacity(0.2), lineWidth: 0.5)
                            )
                            .overlay(
                                Circle().stroke(candidate.accent.solid, lineWidth: selected ? 1.5 : 0)
                                    .padding(-2.5)
                            )
                            .onTapGesture {
                                appState.accent = candidate
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
                        set: { appState.density = density(fromID: $0) }
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

    private var integrationsTab: some View {
        VStack(spacing: 12) {
            if claudeDetected {
                claudeCodeCard
            } else {
                SettingsRow(
                    label: "Claude Code",
                    hint: "Volar didn't find a ~/.claude folder on this Mac. Install the Claude Code CLI, then reopen Settings."
                ) {
                    Text("Not found")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(VolarColor.textMut)
                }
            }
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

    /// The full "Connect Claude Code" card: preview → connect/disconnect → test-signal, all in one
    /// `VolarColor.card` block (rather than several `SettingsRow`s) since the preview code block
    /// and multi-step connect flow don't fit that row's fixed label/hint/control shape.
    private var claudeCodeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Connect Claude Code")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(VolarColor.textPri)
                Text("Installs a Stop hook so Claude Code tells Volar when an agent run finishes — Volar never reads Claude Code's own state, only receives this one signal (contracts/app-links.md).")
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
                    settingsPillButton("Send test signal", solid: true) { sendClaudeTestSignal() }
                    settingsPillButton("Disconnect") { disconnectClaudeCode() }
                } else {
                    settingsPillButton("Connect…", solid: true) { connectClaudeCode() }
                }
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
                .stroke(solid ? Color.white.opacity(0.18) : VolarColor.borderHi, lineWidth: 0.5)
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
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
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
                    .background(Color.white.opacity(0.06))
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
            .fill(isOn ? accentColors.solid : Color.white.opacity(0.12))
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
                Color.white.opacity(0.06)
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
