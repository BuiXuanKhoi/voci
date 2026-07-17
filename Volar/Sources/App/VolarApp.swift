// Sources/App/VolarApp.swift — @main entry point: scenes, environment injection, delegate hookup
import SwiftUI
import AppKit
import UserNotifications

@main
struct VolarApp: App {
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
        let state = AppState(store: store)
        _appState = State(initialValue: state)

        // F1/F2 integration fix: hand the SAME AppState instance to the AppDelegate so its
        // window-independent observers (registered in `applicationDidFinishLaunching`, see
        // AppDelegate below) operate on this one instance rather than a second one. There is
        // exactly one AppState in the app — this line and `_appState` above are the only two
        // places `AppState(...)` is constructed/held. `@NSApplicationDelegateAdaptor`'s default
        // initializer expression (declared above `appState`) runs before this custom `init()`
        // body executes, so `appDelegate` already exists here and this assignment lands before
        // `applicationDidFinishLaunching` fires later on the run loop.
        appDelegate.appState = state
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

        Window("Volar", id: "main") {
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

                    // WG-B (ship-blocker, FR-021): evening sweep — `maybeShowEveningSweep()` itself
                    // already self-gates on ISO-day (once/day, via `sweepLastShownDayKey`) and a
                    // non-empty `sweepItems`; this call site adds the one gate it can't do on its
                    // own — only offer the sweep in the evening (hour >= 18), so it's never sprung
                    // on someone opening the window at 9am.
                    let hour = Calendar.current.component(.hour, from: Date())
                    if hasOnboarded, hour >= 18 {
                        appState.maybeShowEveningSweep()
                    }
                }
                // F1/F2 integration fix: the three window-independent observers that used to live
                // here (`.volarTasksDidChange` refresh, `.onOpenURL`, and sleep/wake recovery) were
                // moved to `AppDelegate` below — this `Window` scene is normally CLOSED (Volar is
                // an `LSUIElement` menu-bar app), so `.onReceive`/`.onOpenURL` attached to it were
                // torn down along with the window and silently stopped firing. `AppDelegate` is
                // app-lifetime (registered via `@NSApplicationDelegateAdaptor` above) and shares
                // this exact `appState` instance (wired in `init()` above), so those three concerns
                // now fire whether or not this window is open. What's left on this scene — sheets,
                // the onboarding/frog/triage/sweep gates below — genuinely needs a visible window.
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
                .sheet(isPresented: Binding(
                    get: { appState.showSweep },
                    set: { presented in if !presented { appState.dismissSweep() } }
                )) {
                    SweepView(
                        items: appState.sweepItems,
                        onComplete: { appState.sweepComplete($0) },
                        onSkip: { appState.sweepSkip($0) },
                        onDismiss: { appState.dismissSweep() }
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
/// component: "Open Volar" / "New task" / "Settings…" / "Quit".
private struct MenuBarMenuContent: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button("Open Volar") {
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
            Button("Quit Volar") {
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
///
/// F1/F2 integration fix: this is also now the home for the three concerns that must survive the
/// main `Window("Volar")` scene being closed — Volar is normally a menu-bar-only app, so anything
/// attached to that scene (`.onReceive`/`.onOpenURL`) is torn down while it's closed. `AppDelegate`
/// itself is app-lifetime (owned by `@NSApplicationDelegateAdaptor` for the whole run), so
/// observers registered here keep firing regardless of window state.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set once, in `VolarApp.init()`, right after the single `AppState` instance is constructed
    /// — see that init's doc comment. Not a `let` because `NSApplicationDelegateAdaptor` builds
    /// this object before `AppState` exists; by the time `applicationDidFinishLaunching` (or
    /// `application(_:open:)`) actually runs, `init()` has already returned and this is set.
    /// `?.`-guarded everywhere it's used below so a hypothetical launch ordering slip degrades
    /// gracefully (no crash) rather than force-unwrapping.
    var appState: AppState?

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
        // this exact call site: "call this once from VolarApp/AppDelegate ... alongside the existing
        // requestAuthorization call"). The matching `UNUserNotificationCenter.current().delegate =
        // ...` assignment is NOT here — it needs a live `ReminderScheduler`/`TaskStore`, neither of
        // which exists yet at this point in app launch (see the note below); that's wired instead
        // in `AppState.activateServices()`, called once `AppState`/`TaskStore` exist.
        NotificationActions.registerCategories()

        // F1/F2 integration fix: window-independent observers, moved here from the `Window`
        // scene's `.onReceive` modifiers so they fire even while the window is closed (see this
        // class's doc comment and VolarApp's final report).
        registerWindowIndependentObservers()
    }

    /// Moved verbatim (behaviorally) from `Window("Volar")`'s `.onReceive` modifiers in
    /// `VolarApp.body` — only the delivery mechanism changed (app-lifetime `NotificationCenter`
    /// observer tokens instead of a SwiftUI view's `.onReceive`), not what each handler does.
    private func registerWindowIndependentObservers() {
        // WG-C (FR-020 gap fix): `ReminderScheduler.handleAction`'s notification "Done" action
        // mutates `TaskStore` directly (bypassing `AppState.toggleDone` by design — FR-014/015/016
        // forbid that path from touching the app/window), which otherwise leaves `appState.tasks`
        // — and `MenuBarLabel.activeTask`, derived from it — stale until some unrelated mutation
        // refreshes it. `addObserver(forName:object:queue:.main)`'s `using` block is typed
        // `@Sendable` and is NOT inferred `@MainActor` despite this class being `@MainActor` (same
        // gotcha as `requestAuthorization` above), even though `queue: .main` guarantees it runs on
        // the main thread — so hop explicitly rather than touching `appState` directly in the
        // closure body.
        NotificationCenter.default.addObserver(
            forName: .volarTasksDidChange, object: nil, queue: .main
        ) { @Sendable [weak self] _ in
            Task { @MainActor in
                self?.appState?.refreshFromStore()
            }
        }

        // Constitution IV: sleep/wake recovery re-evaluates overdue `.scheduled` reminders and
        // fires immediately if still due. `ReminderScheduler.init` (sibling-owned) ALSO registers
        // its own wake observer, but on `NotificationCenter.default` — `NSWorkspace
        // .didWakeNotification` actually posts on `NSWorkspace.shared.notificationCenter` (used
        // here), so that internal observer may never fire (self-review "conflict", flagged in this
        // task's final report). This is the one guaranteed-correct path; `rebuildFromStorage()` is
        // documented idempotent, so redundancy here (vs. the sibling-owned observer, if it ever
        // does fire) is safe. Registered once, here, for the app's lifetime — not duplicated on the
        // `Window` scene anymore, so there's no risk of double wake-recovery scheduling.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { @Sendable [weak self] _ in
            Task { @MainActor in
                self?.appState?.scheduler?.rebuildFromStorage()
            }
        }
    }

    /// Phase 6 (US4, phase6-contract.md §C): inbound `volar://` app links (`ai-done`/`capture`).
    /// Moved here from the `Window` scene's `.onOpenURL` — `.onOpenURL` only delivers while a
    /// scene is actually open, which defeats it for an `LSUIElement` menu-bar app whose window is
    /// normally closed; this AppKit-level delegate method is the app-lifetime equivalent and
    /// receives the same `GURL` Apple events regardless of window state. Routes through
    /// `AppLinkHandler.handle(_:)` (Orchestrator/AppLinkHandler.swift, sibling-owned/landed), which
    /// is inbound-only/idempotent/non-destructive per contracts/app-links.md — never completes a
    /// task itself; an ambiguous match becomes a disambiguation candidate list, same as before.
    /// `appState.onAppLinkHandled()` mirrors the handler's resulting state (pending
    /// disambiguation, ambient recheck queue, test-signal receipt) into `AppState`'s own
    /// `@Observable` surface, exactly as the old `.onOpenURL` did right after `handle(_:)`.
    /// `?.` degrades gracefully in the no-store fallback (`appLinkHandler` is `nil` there, same as
    /// `scheduler`). // UNVERIFIED
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            appState?.appLinkHandler?.handle(url)
            appState?.onAppLinkHandled()
        }
    }
}
