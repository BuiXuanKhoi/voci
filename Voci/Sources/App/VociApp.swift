// Sources/App/VociApp.swift — @main entry point: scenes, environment injection, delegate hookup
import SwiftUI
import AppKit
import Combine
import UserNotifications

@main
struct VociApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState: AppState
    @AppStorage("hasOnboardedV1") private var hasOnboarded = false
    /// Day key ("yyyy-MM-dd") the morning-frog sheet was last shown on — gates it to once/day.
    @AppStorage("morningFrogLastShown") private var frogLastShown = ""
    /// ISO year-week key ("2026-W29") the weekly stale-task triage batch (T034/FR-018) was last
    /// shown on — gates it to once/week, mirroring `frogLastShown`'s once/day pattern.
    @AppStorage("triageLastShownWeek") private var triageLastShownWeek = ""

    init() {
        // Degrade gracefully: if the SwiftData container fails to initialize for any reason,
        // fall back to AppState's empty in-memory task list rather than crashing at launch.
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
                    // Starts the global ⌃⌥M toggle-capture hotkey (degrades gracefully without
                    // Accessibility permission — see AppState.activateServices).
                    appState.activateServices()

                    // Daily morning-frog prompt: once per calendar day, once onboarding is done,
                    // and only when there's actually something open to pick from.
                    // POSIX locale + Gregorian so the day key is stable even if the user's
                    // system region uses a non-Gregorian calendar or changes over time.
                    let day = {
                        let f = DateFormatter()
                        f.locale = Locale(identifier: "en_US_POSIX")
                        f.calendar = Calendar(identifier: .gregorian)
                        f.dateFormat = "yyyy-MM-dd"
                        return f.string(from: Date())
                    }()
                    if hasOnboarded, frogLastShown != day, !appState.openTasks.isEmpty {
                        appState.showMorningFrog = true
                        frogLastShown = day
                    }

                    // T034/FR-018: weekly stale-task triage — once per ISO week, once onboarding
                    // is done, and only when there's actually something stale to review (skipped
                    // otherwise; `TriageView` itself also no-ops on an empty batch as a second
                    // line of defense).
                    let weekKey = {
                        var cal = Calendar(identifier: .iso8601)
                        cal.locale = Locale(identifier: "en_US_POSIX")
                        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
                        return "\(comps.yearForWeekOfYear ?? 0)-W\(comps.weekOfYear ?? 0)"
                    }()
                    if hasOnboarded, triageLastShownWeek != weekKey, !appState.staleTasks.isEmpty {
                        appState.showTriage = true
                        triageLastShownWeek = weekKey
                    }
                }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
                    // Constitution IV: sleep/wake recovery re-evaluates overdue `.scheduled`
                    // reminders and fires immediately if still due. `ReminderScheduler.init`
                    // (sibling-owned) ALSO registers its own wake observer, but on
                    // `NotificationCenter.default` — `NSWorkspace.didWakeNotification` actually
                    // posts on `NSWorkspace.shared.notificationCenter` (used here), so that
                    // internal observer may never fire (self-review "conflict", flagged in this
                    // task's final report). This `.onReceive` is the one guaranteed-correct path;
                    // `rebuildFromStorage()` is documented idempotent, so redundancy here is safe.
                    appState.scheduler?.rebuildFromStorage()
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
                .sheet(isPresented: Binding(
                    get: { appState.showMorningFrog },
                    set: { presented in if !presented { appState.showMorningFrog = false } }
                )) {
                    MorningFrogView(
                        onPick: { appState.pickFrog($0) },
                        onSkip: { appState.dismissMorningFrog() }
                    )
                    .environment(appState)
                    .frame(minWidth: 640, minHeight: 560)
                }
                .sheet(isPresented: Binding(
                    get: { appState.showBreakdown },
                    set: { presented in if !presented { appState.showBreakdown = false } }
                )) {
                    TaskBreakdownView(
                        onSave: { appState.saveBreakdown($0) },
                        onClose: { appState.showBreakdown = false }
                    )
                    .environment(appState)
                    .frame(minWidth: 480, minHeight: 560)
                }
                .sheet(isPresented: Binding(
                    get: { appState.detailTaskID != nil },
                    set: { presented in if !presented { appState.detailTaskID = nil } }
                )) {
                    TaskDetailView()
                        .environment(appState)
                        .frame(minWidth: 480, minHeight: 520)
                }
                .sheet(isPresented: Binding(
                    get: { appState.showTriage },
                    set: { presented in if !presented { appState.showTriage = false } }
                )) {
                    TriageView(
                        items: appState.staleTasks,
                        onKeep: { appState.triageKeep($0) },
                        onBreakdown: { appState.triageBreakdown($0) },
                        onDefer: { appState.triageDefer($0) },
                        onDrop: { appState.triageDrop($0) }
                    )
                    .environment(appState)
                    .frame(minWidth: 560, minHeight: 480)
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
            Button("New task (\u{2303}\u{2325}M)") {
                appState.startCapture()
                openWindow(id: "main")
            }
            SettingsLink {
                Text("Settings\u{2026}")
            }
            Button("Preview reminder") {
                appState.showReminderPreview()
            }
            Divider()
            Button("Quit Voci") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(8)
    }
}

/// Handles app-lifecycle setup an `LSUIElement` menu-bar app needs at launch. The global ⌃⌥M
/// hotkey is started from `AppState.activateServices()` (called from the main window's `.task`
/// above) rather than here, since `AppState` — and its `HotkeyManager` — don't exist yet at
/// `NSApplicationDelegate` construction time.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Best-effort; ignore the result/error — notifications are a nice-to-have, not required
        // for the app to function (see backlog: real notification scheduling not yet wired).
        // `@Sendable` is load-bearing: without it, a closure literal formed in this @MainActor
        // context is inferred MainActor-isolated, and Swift 6's runtime isolation check traps
        // (EXC_BREAKPOINT) when UserNotifications invokes it on its background queue — the same
        // failure mode as the SpeechCapture authorization callback.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { @Sendable _, _ in }

        // T033 (contracts/phase4-contract.md §A/§E): replaces the old auth-only setup with real
        // category registration — deadline (Done/Snooze 10m/Tomorrow), unblocked-ready, and
        // overdue-reschedule (tonight/tomorrow/weekend) actions (tasks.md T030,
        // `Sources/Reminders/NotificationActions.swift`, sibling-owned — its own doc comment names
        // this exact call site: "call this once from VociApp/AppDelegate ... alongside the existing
        // requestAuthorization call"). The matching `UNUserNotificationCenter.current().delegate =
        // ...` assignment is NOT here — it needs a live `ReminderScheduler`/`TaskStore`, neither of
        // which exists yet at this point in app launch (see the note below); that's wired instead
        // in `AppState.activateServices()`, called once `AppState`/`TaskStore` exist.
        NotificationActions.registerCategories()
    }
}
