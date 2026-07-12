// Sources/Views/SettingsView.swift — Settings window: 5 tabs (General/Hotkeys/Notifications/
// Appearance/About), ported from `design/voci-extras.jsx`'s `VociSettings`. Native-first: a
// custom top tab strip (icon + label, accent-tinted when selected) switches a `@State tab` with
// the tab content below. Most rows here are local, cosmetic `@State` (Launch at login, reminder
// defaults, notification toggles, etc.) — the frozen `AppState` (spec §4) does not own these
// preferences, only `accent` and `density`, which this view binds for real via `@Bindable`.
import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    private enum Tab: String, CaseIterable, Identifiable, Equatable {
        case general, hotkeys, notifications, appearance, about
        var id: String { rawValue }

        var icon: VocIconName {
            switch self {
            case .general: return .settings
            case .hotkeys: return .cmd
            case .notifications: return .bell
            case .appearance: return .sparkle
            case .about: return .project
            }
        }

        var label: String {
            switch self {
            case .general: return "General"
            case .hotkeys: return "Hotkeys"
            case .notifications: return "Notifications"
            case .appearance: return "Appearance"
            case .about: return "About"
            }
        }
    }

    @State private var tab: Tab = .general

    // Cosmetic-only local settings state (not part of the frozen AppState API).
    @State private var launchAtLogin = true
    @State private var defaultDuration = 30
    @State private var defaultReminder = 15 // minutes; 0 == "None"
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
                    case .about: aboutTab
                    }
                }
                .padding(22)
            }
        }
        .frame(minWidth: 560, minHeight: 460)
        .background(VociColor.bg)
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
                        VocIcon(t.icon, size: 18, color: selected ? accentColors.solid : VociColor.textSec, weight: .regular)
                        Text(t.label)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(selected ? accentColors.solid : VociColor.textSec)
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
        .background(VociColor.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(VociColor.border).frame(height: 0.5)
        }
    }

    // MARK: - General

    private var generalTab: some View {
        VStack(spacing: 12) {
            SettingsRow(label: "Launch at login", hint: "Voci starts in the background and lives in your menu bar.") {
                VociToggle(isOn: $launchAtLogin)
            }
            SettingsRow(label: "Default task duration", hint: "Block this much time when a task has no explicit length.") {
                Segmented(value: $defaultDuration, options: [
                    .init(id: 15, label: "15"), .init(id: 30, label: "30"), .init(id: 60, label: "60 min"),
                ])
            }
            SettingsRow(label: "Default reminder before deadline", hint: "When to nudge you before a task is due.") {
                Segmented(value: $defaultReminder, options: [
                    .init(id: 5, label: "5"), .init(id: 15, label: "15"),
                    .init(id: 30, label: "30 min"), .init(id: 0, label: "None"),
                ])
            }
            SettingsRow(label: "Hyperfocus interrupt after", hint: "Voci checks in if you've been deep on one task this long.") {
                Segmented(value: $hyperfocusInterrupt, options: [
                    .init(id: 60, label: "60"), .init(id: 90, label: "90"), .init(id: 120, label: "120 min"),
                ])
            }
            SettingsRow(label: "Show morning frog prompt", hint: "A daily question at first launch: what's the ONE task that matters most?") {
                VociToggle(isOn: $showMorningFrog)
            }
            SettingsRow(label: "Capture foreground app context", hint: "Tags new tasks with the app you were in when you captured them.") {
                VociToggle(isOn: $captureAppContext)
            }
            SettingsRow(label: "Calendar integration", hint: "Mirror tasks with scheduled times into your Mac Calendar.") {
                HStack(spacing: 10) {
                    VociToggle(isOn: $calendarIntegration)
                    Button("Open in Calendar") {}
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(VociColor.textPri)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(Color.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .vociHairline(cornerRadius: 7)
                }
            }
        }
    }

    // MARK: - Hotkeys

    private var hotkeysTab: some View {
        VStack(spacing: 12) {
            SettingsRow(label: "Quick capture", hint: "Hold this combo from anywhere to start recording.") {
                KeyRecorder(keys: ["\u{2303}", "\u{2325}", "Space"])
            }
            SettingsRow(label: "Task breakdown (long press)", hint: "Hold the same hotkey \u{2265}1.5s to have AI split the task into steps.") {
                HStack(spacing: 8) {
                    Text("Long-press")
                        .font(.system(size: 11))
                        .foregroundStyle(VociColor.textSec)
                    KeyBadge("\u{2303}")
                    KeyBadge("\u{2325}")
                    KeyBadge("Space")
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Color.black.opacity(0.25))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .vociHairline(cornerRadius: 8)
            }
            SettingsRow(label: "Show Voci window", hint: "Bring the main window to the front.") {
                KeyRecorder(keys: ["\u{2303}", "\u{2325}", "V"])
            }
            SettingsRow(label: "Toggle Focus Lock", hint: "Lock the current task as your only focus — Voci will gently interrupt if you drift.") {
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
                VociToggle(isOn: $showReminders)
            }
            SettingsRow(label: "Sound", hint: "Subtle chime when a task is captured.") {
                VociToggle(isOn: $notifSound)
            }
            SettingsRow(label: "Focus mode aware", hint: "Stay silent while macOS Focus is on.") {
                VociToggle(isOn: $focusModeAware)
            }
        }
    }

    // MARK: - Appearance

    private func appearanceTab(appState: AppState) -> some View {
        VStack(spacing: 16) {
            SettingsRow(label: "Theme", hint: "Voci is dark-only — the way Mac power users live.") {
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
                        Group {
                            if let url = appState.customImageURL, let nsImage = NSImage(contentsOf: url) {
                                Image(nsImage: nsImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            } else {
                                Color.white.opacity(0.06)
                            }
                        }
                        .frame(width: 44, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                        Button("Choose image…") { chooseImage(appState: appState) }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(VociColor.textPri)
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background(VociColor.card)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .vociHairline(cornerRadius: 7)

                        if appState.customImageURL != nil {
                            Button("Remove") { appState.setCustomImage(nil) }
                                .buttonStyle(.plain)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(VociColor.textSec)
                        }
                    }
                }
            }
            SettingsRow(label: "Accent color", hint: "Used for active states and the capture button.") {
                HStack(spacing: 10) {
                    ForEach(VociAccent.allCases) { candidate in
                        // `VociAccent` (Theme.swift, frozen §3) doesn't declare Equatable, so
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

    /// Opens a file picker for the custom ambient background image. Not sandboxed today, so a
    /// plain file path (via `NSOpenPanel.url`) is fine — no security-scoped bookmark needed. If
    /// sandboxing is ever enabled for this app, this will need to start/stop a security-scoped
    /// bookmark around every `NSImage(contentsOf:)` load instead of a raw path.
    private func chooseImage(appState: AppState) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
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

    // MARK: - About

    private var aboutTab: some View {
        VStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [accentColors.solid, accentColors.hover], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 64, height: 64)
                .overlay {
                    VocIcon(.mic, size: 32, color: .white, weight: .regular)
                }
                .shadow(color: accentColors.glow, radius: 20, y: 8)

            Text("Voci 1.0.2")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(VociColor.textPri)

            Text("Voice-first task manager for Mac. Built in Cambridge.")
                .font(.system(size: 13))
                .foregroundStyle(VociColor.textSec)

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
                    .foregroundStyle(VociColor.textSec)
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
                    .foregroundStyle(VociColor.textPri)
                if let hint {
                    Text(hint)
                        .font(.system(size: 12))
                        .foregroundStyle(VociColor.textSec)
                        .lineSpacing(2)
                }
            }
            Spacer(minLength: 12)
            content()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(VociColor.card)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .vociHairline(cornerRadius: 11)
    }
}

/// Custom pill toggle (named `VociToggle` — not `Toggle` — to avoid clashing with the SwiftUI
/// control). Ported from the prototype's `Toggle`.
private struct VociToggle: View {
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
            .animation(.easeOut(duration: 0.15), value: isOn)
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
                        .foregroundStyle(option.disabled ? VociColor.textMut : (selected ? accentColors.solid : VociColor.textSec))
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
        .vociHairline(cornerRadius: 8)
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
        .vociHairline(cornerRadius: 8)
    }
}

#Preview {
    SettingsView()
        .environment(AppState())
}
