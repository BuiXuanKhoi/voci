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
        // SCENE ORDER IS LOAD-BEARING (changed 2026-07-26 together with dropping LSUIElement from
        // Info.plist): `Window` is declared FIRST so SwiftUI treats it as the primary scene and
        // opens it at launch. Previously `MenuBarExtra` came first, which — combined with
        // LSUIElement — is what made the app launch with no visible window at all. `MenuBarExtra`
        // now sits below the `Window` scene; it still works exactly the same, it just isn't the
        // scene SwiftUI opens on launch. Moving it back above `Window` would silently restore the
        // old no-window-at-launch behavior. // UNVERIFIED: not built on a Mac yet — confirm at
        // Cổng 1 that the window actually appears on a cold launch.
        Window("Volar", id: "main") {
            TodayView()
                .environment(appState)
                .frame(minWidth: 820, minHeight: 560)
                .task {
                    // Starts the global ⌃⌥M toggle-capture hotkey (degrades gracefully without
                    // Accessibility permission — see AppState.activateServices).
                    // F1/F2 fix: ALSO called from `AppDelegate.applicationDidFinishLaunching` below
                    // — the window opens at launch as of 2026-07-26, but the user can still close it
                    // (⌘W) and leave Volar running from the menu bar, so relying solely on this
                    // `.task` would leave the hotkey/rebuild/overdue-scan/delegation-timer dead for
                    // the rest of that session. The double call is intentional and safe: `hotkey.start` tears down any
                    // existing registration first, `startDelegationTimer` invalidates any existing
                    // timer first, and `rebuildFromStorage`/the overdue scan are both idempotent.
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
                // moved to `AppDelegate` below — this `Window` scene can be CLOSED by the user at
                // any time (⌘W leaves Volar alive in the menu bar), so `.onReceive`/`.onOpenURL`
                // attached to it were torn down along with the window and silently stopped firing.
                // Still true after the 2026-07-26 switch to opening this window at launch: "opens at
                // launch" is not "always open". `AppDelegate` is
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

        // Declared AFTER `Window` on purpose — see the scene-order note at the top of `body`.
        MenuBarExtra {
            MenuBarMenuContent()
                .environment(appState)
        } label: {
            MenuBarLabel()
                .environment(appState)
        }
        .menuBarExtraStyle(.window)

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

/// Handles app-lifecycle setup at launch. The global ⌃⌥M hotkey is started from
/// `AppState.activateServices()` (called from the main window's `.task` above) rather than here,
/// since `AppState` — and its `HotkeyManager` — don't exist yet at `NSApplicationDelegate`
/// construction time.
///
/// F1/F2 integration fix: this is also the home for the three concerns that must survive the main
/// `Window("Volar")` scene being closed. As of 2026-07-26 that window opens at launch (LSUIElement
/// dropped from Info.plist, `Window` declared first in `body`), but the user can still close it with
/// ⌘W and leave Volar running from the menu bar — at which point anything attached to that scene
/// (`.onReceive`/`.onOpenURL`) is torn down. `AppDelegate` itself is app-lifetime (owned by
/// `@NSApplicationDelegateAdaptor` for the whole run), so observers registered here keep firing
/// regardless of window state.
///
/// It also owns the two window-presentation entry points that having a Dock icon requires:
/// `showMainWindow()` (launch) and `applicationShouldHandleReopen` (Dock icon click).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set once, in `VolarApp.init()`, right after the single `AppState` instance is constructed
    /// — see that init's doc comment. Not a `let` because `NSApplicationDelegateAdaptor` builds
    /// this object before `AppState` exists; by the time `applicationDidFinishLaunching` (or
    /// `application(_:open:)`) actually runs, `init()` has already returned and this is set.
    /// `?.`-guarded everywhere it's used below so a hypothetical launch ordering slip degrades
    /// gracefully (no crash) rather than force-unwrapping.
    var appState: AppState?

    /// Feature 002 gap fix: owns the floating capture panel (`Sources/Views/CapturePanel.swift`)
    /// for the app's lifetime. Created lazily, on the first `syncCapturePanel()` call, rather than
    /// here in `init`/`applicationDidFinishLaunching` — `CapturePanelController.init` needs a real
    /// `AppState` to inject into `PopoverView`'s `.environment(...)`, and (per this class's own
    /// doc comment above) `appState` isn't guaranteed assigned until `VolarApp.init()` has run,
    /// which — for this property specifically — has already happened by the time
    /// `applicationDidFinishLaunching` fires. Lazy construction here is just the more defensive
    /// choice: it also tolerates `observeCaptureState()` firing before that assignment somehow did.
    private var capturePanelController: CapturePanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // F1/F2 fix (MAJOR, liveness): `activateServices()` used to be reachable ONLY from the main
        // `Window`'s `.task` above, which never ran while the app launched with that window closed
        // (the normal case back when this was an LSUIElement menu-bar-only app). That
        // left the global ⌃⌥M hotkey, `rebuildFromStorage()`, the FR-016 overdue scan, and the
        // delegation timer all dead until the user happened to open the window. Calling it here too
        // — right after `appState` is guaranteed assigned (`VolarApp.init()` sets it before this
        // delegate method can fire) — closes that gap. The double call (here + the `Window`'s
        // `.task`) is intentional and safe; see that call site's own comment for why each half of
        // `activateServices()` tolerates being invoked twice.
        appState?.activateServices()

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

        // Feature 002 gap fix: starts the `captureState` -> floating-panel mirroring described on
        // `observeCaptureState()` below. Same "window-independent" motivation as the observers
        // just above — this is what makes ⌃⌥M capture visible even while `Window("Volar")` is
        // closed (still reachable via ⌘W even though the window now opens at launch).
        observeCaptureState()

        // 2026-07-26: guarantee the main window is actually on screen at launch. Dropping
        // LSUIElement + declaring `Window` as the first scene in `VolarApp.body` SHOULD be enough
        // on its own — but that is a SwiftUI-internal ordering behavior we cannot verify from
        // Windows, and "app opens and nothing appears" is exactly the App Review rejection this
        // change exists to prevent. So this is a deliberate belt-and-braces second path: if SwiftUI
        // already opened and fronted the window, `showMainWindow()` is a no-op re-front; if it
        // didn't, this is what puts it on screen.
        //
        // Deferred one run-loop turn: SwiftUI may not have materialized the scene's NSWindow yet
        // at `applicationDidFinishLaunching` time, so looking for it synchronously here can find
        // nothing at all.
        Task { @MainActor in
            self.showMainWindow()
        }
    }

    /// Brings Volar's main document-style window to the front, activating the app if needed.
    ///
    /// Window lookup is by exclusion rather than by identifier: SwiftUI does not expose a stable,
    /// documented `NSWindow.identifier` for a `Window(id:)` scene, so matching on `"main"` would be
    /// relying on an implementation detail that can change between OS releases. Instead we skip the
    /// two window kinds this app is known to also own — `NSPanel` (the floating `CapturePanel`, and
    /// the `MenuBarExtra` dropdown, both panels) and anything that cannot become the main window
    /// (the status-bar item's backing window) — and take the first real window that's left.
    ///
    /// No-ops safely if nothing matches, rather than force-unwrapping: a missing window here should
    /// degrade to "menu bar still works", never to a crash on launch.
    // UNVERIFIED: written on Windows without an AppKit toolchain. Confirm on Mac that a cold launch
    // shows the window exactly once (not two windows, no flicker) — see docs/app-store-submission-guide.md Cổng 1.
    private func showMainWindow() {
        let mainWindow = NSApp.windows.first { window in
            !(window is NSPanel) && window.canBecomeMain
        }
        guard let mainWindow else { return }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow.makeKeyAndOrderFront(nil)
    }

    /// Now that Volar has a Dock icon (LSUIElement removed 2026-07-26), clicking that icon while no
    /// window is open must bring the window back — otherwise the click appears to do nothing and the
    /// app reads as broken. AppKit only asks this delegate; without implementing it, a SwiftUI
    /// `Window` scene the user closed with ⌘W stays closed forever and the menu bar is the only way
    /// back in.
    ///
    /// Returning `true` lets AppKit perform its own default reopen handling (unminiaturize/restore)
    /// as well; `showMainWindow()` covers the case where the window exists but is merely hidden
    /// behind other apps.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            showMainWindow()
        }
        return true
    }

    /// Drives `CapturePanelController` purely off `appState.captureState`, without touching
    /// `AppState.swift` itself (off-limits for this task — another agent owns it right now).
    /// `withObservationTracking`'s `onChange` closure fires exactly ONCE per call and — critically
    /// — fires BEFORE the new value is actually committed to the observed property, so reading
    /// `appState.captureState` synchronously inside `onChange` would still observe the OLD value.
    /// Hopping into `Task { @MainActor in ... }` defers the read to the next run-loop turn, by
    /// which point the mutation has landed; re-invoking `observeCaptureState()` from inside that
    /// same hop is what re-arms tracking for the NEXT change (skip it and this would fire exactly
    /// once, ever, and the panel would silently stop following `captureState` after the very first
    /// capture).
    private func observeCaptureState() {
        withObservationTracking {
            _ = appState?.captureState
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.syncCapturePanel()
                self?.observeCaptureState()
            }
        }
    }

    /// Lazily creates `capturePanelController` (see that property's doc comment for why lazy),
    /// then shows/refits or hides it to match the CURRENT `appState.captureState` — `.idle` hides,
    /// anything else shows (first time) or re-fits (already visible; see
    /// `CapturePanelController.presentOrRefit()`'s own doc comment for that distinction).
    private func syncCapturePanel() {
        guard let appState else { return }
        if capturePanelController == nil {
            capturePanelController = CapturePanelController(appState: appState)
        }
        guard let controller = capturePanelController else { return }

        if appState.captureState == .idle {
            controller.hide()
        } else {
            controller.presentOrRefit()
        }
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
