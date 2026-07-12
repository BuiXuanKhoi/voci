// Sources/App/VociApp.swift — @main entry point: scenes, environment injection, delegate hookup
import SwiftUI
import AppKit
import UserNotifications

@main
struct VociApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState: AppState
    @AppStorage("hasOnboardedV1") private var hasOnboarded = false

    init() {
        // Degrade gracefully: if the SwiftData container fails to initialize for any reason,
        // fall back to AppState's in-memory SampleData.tasks rather than crashing at launch.
        let store = try? TaskStore()
        _appState = State(initialValue: AppState(store: store))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenuContent()
                .environment(appState)
        } label: {
            MenuBarLabel()
                .environment(appState)
        }
        .menuBarExtraStyle(.window)

        Window("Voci", id: "main") {
            TodayView()
                .environment(appState)
                .frame(minWidth: 820, minHeight: 560)
                .task {
                    // Starts the global ⌃⌥Space hold-to-talk hotkey (degrades gracefully without
                    // Accessibility permission — see AppState.activateServices).
                    appState.activateServices()
                }
                .sheet(isPresented: Binding(
                    get: { !hasOnboarded },
                    set: { presented in if !presented { hasOnboarded = true } }
                )) {
                    OnboardingView(onComplete: { hasOnboarded = true })
                        .environment(appState)
                        .interactiveDismissDisabled(true)
                        .frame(minWidth: 640, minHeight: 440)
                }
        }

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}

/// `MenuBarExtra`'s dropdown content (the "window" style menu). Kept private to this file rather
/// than a new file under `Sources/Views/` since it's pure app-assembly glue, not a design-frozen
/// component: "Open Voci" / "New task" / "Settings…" / "Quit".
private struct MenuBarMenuContent: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button("Open Voci") {
                openWindow(id: "main")
            }
            Button("New task (\u{2303}\u{2325}Space)") {
                appState.startCapture()
                openWindow(id: "main")
            }
            SettingsLink {
                Text("Settings\u{2026}")
            }
            Divider()
            Button("Quit Voci") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(8)
    }
}

/// Handles app-lifecycle setup an `LSUIElement` menu-bar app needs at launch. The global ⌃⌥Space
/// hotkey is started from `AppState.activateServices()` (called from the main window's `.task`
/// above) rather than here, since `AppState` — and its `HotkeyManager` — don't exist yet at
/// `NSApplicationDelegate` construction time.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Best-effort; ignore the result/error — notifications are a nice-to-have, not required
        // for the app to function (see backlog: real notification scheduling not yet wired).
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}
