// Sources/App/VolarIOSApp.swift — @main entry point for the iOS app (plan §2, §6 agent A2).
//
// Modeled on `Volar/Sources/App/VolarApp.swift` (macOS) with everything AppKit-only stripped:
// no `MenuBarExtra`, no `Settings` scene, no `NSApplicationDelegateAdaptor`/`AppDelegate`, no
// global hotkey, no floating `CapturePanel`. iOS has no menu-bar/hotkey/window-independent-observer
// story (plan §2's whole point) — everything the macOS `AppDelegate` did to survive its main window
// being closable (⌘W) is moot here: a `WindowGroup` scene on iOS is the only scene and is always
// live while the app is foregrounded, so this file inlines what `AppDelegate` did directly onto the
// scene via `.task`/`.onOpenURL`/`.onChange(of: scenePhase)`.
import SwiftUI
import UserNotifications

@main
struct VolarIOSApp: App {
    @State private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase

    /// Onboarding gate. `OnboardingIOSView` is Phase 2 (plan §6 Phase 2 / A2 instructions:
    /// "do NOT create it and do NOT reference a missing type") — until then this flag is set true
    /// unconditionally on first launch (see the `.task` below) so the app is actually runnable
    /// rather than gating on a sheet that doesn't exist yet. Key name matches the macOS app's own
    /// `hasOnboardedV1` `@AppStorage` key (`VolarApp.swift`) for continuity if/when a shared
    /// UserDefaults suite is ever introduced (not the case today — each app's `UserDefaults.standard`
    /// is sandboxed per-app-container regardless of key name).
    @AppStorage("hasOnboardedV1") private var hasOnboarded = false

    // TODO(Phase 2): the macOS app also gates a daily morning-frog prompt, a weekly stale-task
    // triage batch, and an evening sweep from this same call site (see `VolarApp.swift`'s `.task`).
    // Plan §6 puts `MorningFrogView`/`TriageView`/`SweepView` in Phase 4 for iOS (core-first v1
    // scope, plan §0.1/§6 explicitly excludes them) — none of those three gates are ported here.
    // Deliberate omission, not an oversight.

    init() {
        // Degrade gracefully, exactly like `VolarApp.init()`: if the SwiftData container fails to
        // initialize for any reason, fall back to AppState's empty in-memory task list rather than
        // crashing at launch. There is no `AppDelegate` to hand this same instance to on iOS (no
        // second construction site exists here the way `VolarApp.init()` hands `state` to
        // `appDelegate.appState` for its window-independent observers) — this is the only place
        // `AppState` is constructed.
        let store = try? TaskStore()
        _appState = State(initialValue: AppState(store: store))
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(appState)
                // Dark-only per plan §4: "Dark-only: đặt `.preferredColorScheme(.dark)` ở root
                // scene. Không làm light mode." Twilight has no light variant to fall back to.
                .preferredColorScheme(.dark)
                .task {
                    // Starts the reminder scheduler rebuild, the overdue-reschedule scan, and the
                    // delegation-recheck timer (`AppState.activateServices()`, `Shared/App/
                    // AppState.swift`). On iOS this is a strict SUBSET of what it does on macOS:
                    // the global ⌃⌥M hotkey start (`hotkey.start(appState:)`) is wrapped
                    // `#if os(macOS)` inside `activateServices()` itself (plan §3 table) — there is
                    // no Carbon Event Manager / Accessibility-permission concept on iOS, so that
                    // half of the call is simply absent here, not something this file needs to
                    // skip or special-case.
                    appState.activateServices()

                    // Onboarding gate (see the property's doc comment above): no `OnboardingIOSView`
                    // exists yet, so the flag is simply flipped true on first run rather than left
                    // false forever (which would have nothing to show it, but would also mean this
                    // `@AppStorage` never settles into a meaningful state for Phase 2 to build on).
                    if !hasOnboarded {
                        hasOnboarded = true
                    }

                    // Notification authorization + category registration. On macOS these two calls
                    // live in `AppDelegate.applicationDidFinishLaunching` (`VolarApp.swift`) because
                    // that delegate method is guaranteed to run exactly once, early, regardless of
                    // window state; on iOS, this `WindowGroup`'s `.task` is the equivalent
                    // "run once at launch" hook (there is no `UIApplicationDelegateAdaptor` wired up
                    // in this app — nothing else needs one), so both calls move here unmodified.
                    //
                    // `@Sendable` on the completion closure is LOAD-BEARING, not decoration: per
                    // `VolarApp.swift`'s own comment on this exact call, a closure literal formed in
                    // a `@MainActor`-isolated context (this `.task` body runs on the main actor,
                    // like every other SwiftUI `.task`/view-modifier closure in this codebase) is
                    // otherwise INFERRED `@MainActor`-isolated — but `UNUserNotificationCenter`
                    // invokes this completion handler on its own background queue, and Swift 6's
                    // runtime isolation check traps (EXC_BREAKPOINT) the instant a MainActor-
                    // inferred closure is called off the main actor. Marking it `@Sendable`
                    // explicitly breaks that inference and makes the closure safely callable from
                    // any queue — the exact same failure mode/fix as `VolarApp.swift`'s
                    // `AppDelegate.applicationDidFinishLaunching` and the `SpeechCapture`
                    // authorization callback it cross-references.
                    UNUserNotificationCenter.current()
                        .requestAuthorization(options: [.alert, .sound]) { @Sendable _, _ in }
                    NotificationActions.registerCategories()
                }
                // Inbound `volar://capture` links (App Intents/Siri/widget capture entry points in
                // later phases; today just a manually-typed URL or a Shortcuts action). Mirrors
                // `AppDelegate.application(_:open:)` (`VolarApp.swift`) exactly: hand the URL to
                // `AppLinkHandler` (`Shared/Orchestrator/AppLinkHandler.swift` — copied into
                // `Shared/` specifically because it's pure `Foundation`+`VolarCore`, per plan §6
                // Phase 0's note "AppLinkHandler CÓ vào Shared/"), then call
                // `onAppLinkHandled()` so `AppState`'s own `@Observable` mirror (`tasks`,
                // `pendingDisambiguationTaskIDs`, `lastAppLinkAt`) catches up — `AppLinkHandler`
                // itself is a plain, non-`@Observable` class, so SwiftUI can't react to its internal
                // mutations without this second call. `.onOpenURL`'s closure is not `@Sendable` and
                // is invoked directly on the main thread by SwiftUI (same as `AppDelegate`'s method,
                // which is a plain `@MainActor` method body, not a crossed-actor closure), so no
                // `@MainActor` hop is needed here the way the notification-authorization closure
                // above needs one.
                .onOpenURL { url in
                    appState.appLinkHandler?.handle(url)
                    appState.onAppLinkHandled()
                }
                // iOS replacement for the macOS `NSWorkspace.didWakeNotification` sleep/wake
                // observer (`AppDelegate.registerWindowIndependentObservers()`, `VolarApp.swift`):
                // there is no sleep/wake on iOS, but the equivalent staleness problem exists —
                // reminders may have fired, or been acted on from the lock screen, while this app
                // was backgrounded/suspended, so `tasks` (and anything derived from it, e.g.
                // `activeTask`) can be stale by the time the user returns to the foreground.
                // `.active` is iOS's nearest analogue to "just wallet-out came back from being
                // asleep" — fires on cold launch AND every foreground return, which is a superset
                // of what's needed but harmless: `refreshFromStore()` is a plain re-fetch, not a
                // scheduling side effect, so calling it more often than strictly necessary is safe.
                // UNVERIFIED: not built/run on a device — confirm `scenePhase` transitions fire as
                // expected around lock-screen/Control-Center/incoming-call interruptions, not just
                // app-switcher backgrounding.
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        appState.refreshFromStore()
                    }
                }
        }
    }
}
