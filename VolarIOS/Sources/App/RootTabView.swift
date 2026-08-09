// Sources/App/RootTabView.swift — 3-tab shell + mic FAB + capture sheet + Focus cover
// (plan §2.1/§2.2/§2.3, §6 agent A2).
import SwiftUI
// `UITabBarAppearance`/`UIBlurEffect`/`UIColor`/`UITabBar.appearance()` in `configureTabBarAppearance()`
// below are UIKit, not SwiftUI — this file is iOS-only (`VolarIOS/Sources/App`), so a direct,
// unconditional `import UIKit` is correct here (unlike `Shared/App/AppState.swift`, which needs
// `#if canImport(UIKit)` because that file also compiles on macOS).
import UIKit

/// The three tabs (plan §2.1). Order matches the design prototype minus "Projects": the data model
/// has no project concept (`TaskItem` — `Shared/Model/TaskItem.swift` — carries no project field;
/// `design/volar-mobile.jsx`'s `MobileTabBar` only renders that tab against hardcoded sample data),
/// so it is dropped rather than ported to a dead end.
enum RootTab: Hashable {
    case today, upcoming, settings
}

struct RootTabView: View {
    @Environment(AppState.self) private var appState: AppState
    @State private var selectedTab: RootTab = .today

    /// Mic FAB clearance above the system tab bar. `design/volar-mobile.jsx`'s `MicButton` sits at
    /// `bottom: 96` inside its 844pt-tall mock, which is hand-tuned against that file's OWN custom-
    /// drawn `MobileTabBar` (a fixed ~78pt bar). This app uses the SYSTEM `TabView`/tab bar instead
    /// (plan §2.1: "iOS 17 floor → dùng `TabView { ... .tabItem { Label(...) } }`"), whose real
    /// on-device height (49pt content + safe-area home-indicator inset, which varies by device) this
    /// file cannot query without a toolchain to test against. `54` approximates "system tab bar
    /// content height (~49pt) + a small gap" and intentionally does NOT try to thread the actual
    /// safe-area bottom inset through — verify the FAB clears the tab bar (and doesn't float too
    /// high above it) on a real device/simulator and adjust.
    // UNVERIFIED: tab bar height not measured on-device; tune this constant at Cổng iOS verify.
    private static let fabBottomInset: CGFloat = 54

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                TodayIOSView()
                    .tabItem {
                        Label("Today", systemImage: VolarIconName.today.systemName)
                    }
                    .tag(RootTab.today)

                UpcomingPlaceholderView()
                    .tabItem {
                        Label("Upcoming", systemImage: VolarIconName.upcoming.systemName)
                    }
                    .tag(RootTab.upcoming)

                SettingsIOSView()
                    .tabItem {
                        Label("Settings", systemImage: VolarIconName.settings.systemName)
                    }
                    .tag(RootTab.settings)
            }
            // App-wide accent tints the selected tab item (plan §4: mint is reserved for the NOW
            // task ONLY — the tab bar's active-state color must be `appState.accent.accent`, never
            // `VolarColor.nowAccent`).
            .tint(appState.accent.accent.solid)
            .onAppear(perform: configureTabBarAppearance)

            // Mic FAB: visible on Today & Upcoming, hidden on Settings (plan §2.1). `MicFAB` is
            // agent A4's file (`VolarIOS/Sources/Views/MicFAB.swift`) — referenced only; it is
            // assumed to read `AppState` from the environment (already injected by `VolarIOSApp`
            // above this view in the hierarchy) and drive capture itself via
            // `appState.toggleCapture()`.
            if selectedTab != .settings {
                MicFAB()
                    .padding(.bottom, Self.fabBottomInset)
                    .transition(.opacity)
            }
        }
        .animation(VolarMotion.state, value: selectedTab)
        // Capture sheet (plan §2.2): bottom sheet driven purely by `appState.captureState`, never a
        // locally-invented `@State` mirror of it. Dismissing the sheet (swipe-down, tap-outside at
        // `.medium`) lands in the `set` branch below with `presented == false`; routing that through
        // `cancelCapture()` (not just letting the sheet close visually) matters because
        // `captureState` is what the `get` closure reads to decide whether to show the sheet at
        // all — without this, an interactive dismiss would leave `captureState` in whatever
        // non-idle state it was in, and the sheet would immediately reopen next render.
        .sheet(isPresented: Binding(
            get: { appState.captureState != .idle },
            set: { presented in
                if !presented {
                    appState.cancelCapture()
                }
            }
        )) {
            CaptureSheet()
                .environment(appState)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
                .presentationCornerRadius(IOSMetrics.sheetRadius)
        }
        // TODO(Phase 2) — FOCUS MODE ON iOS IS DEFERRED (anh Khôi chốt 2026-07-27: "iphone focus
        // mode để sau đi"). The `.fullScreenCover` that presented `FocusIOSView` was removed rather
        // than left pointing at a type that does not exist — `VolarIOS/Sources/Views/FocusIOSView
        // .swift` and `AmbientCanvasIOS.swift` were never written, so referencing them here is a
        // hard compile error, not a stub.
        //
        // Nothing on iOS currently sets `appState.focusActive` (no view ports a "start focus"
        // affordance yet), so removing the presentation leaves no dead-end state: the flag simply
        // stays false. When Focus is picked back up, restore a `.fullScreenCover(isPresented:)`
        // bound to `appState.focusActive` whose `set:` calls `appState.endFocus()` on dismiss —
        // `endFocus()` is documented idempotent, so racing it against the view's own dismiss button
        // is safe. Design intent: full-screen cover, NOT a floating overlay window (iOS has no
        // multi-window concept the way `Volar/Sources/Views/FocusOverlay.swift` uses on macOS).
        // See plan §2.3.
    }

    /// One-time `UITabBarAppearance` proxy configuration (plan §4.2 "Chất liệu": tab bar =
    /// `.ultraThinMaterial` + hairline top border in `VolarColor.border`; §6 A2 instructions:
    /// "Read `Shared/Design/Glass.swift` first — reuse its helper rather than hand-rolling a
    /// material stack"). SwiftUI's `TabView` has no first-class modifier for "blur material +
    /// exact hairline color" prior to iOS 18's new Tab APIs (out of scope here, plan §2.1: "API
    /// `Tab {}` là iOS 18+" must not be used on the iOS 17 floor), so the system UIKit appearance
    /// proxy is the supported way to skin a *native* tab bar (kept, per the plan, rather than
    /// hiding the system bar and hand-drawing a replacement — that would forfeit `.tabItem`'s
    /// accessibility/Dynamic-Type/hit-testing behavior for a pixel-level win). `GlassLevel.standard`
    /// (`Shared/Design/Theme.swift`/`Glass.swift`) is reused for its documented "standard" blur
    /// intent rather than picking a raw `UIBlurEffect.Style` from scratch — `.systemUltraThinMaterialDark`
    /// is the closest UIKit blur family to SwiftUI's `.ultraThinMaterial` used elsewhere in this
    /// scale (§4.2 names `.ultraThinMaterial` specifically), forced to its `Dark` variant because
    /// this app is dark-only (`.preferredColorScheme(.dark)`, `VolarIOSApp.swift`) and must never
    /// silently pick up the system light appearance.
    // UNVERIFIED: `UITabBarAppearance`/`UIBlurEffect.Style.systemUltraThinMaterialDark` are real
    // public UIKit API (iOS 13+) but this exact configuration has not been run on a device/simulator
    // — confirm the hairline reads as `VolarColor.border` (not the system default separator) and
    // that the blur doesn't fight the mic FAB's own halo at Cổng iOS verify.
    private func configureTabBarAppearance() {
        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterialDark)
        appearance.backgroundColor = UIColor(VolarColor.bg.opacity(GlassLevel.standard.bgOpacity))
        appearance.shadowColor = UIColor(VolarColor.border)
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }
}

/// `UpcomingIOSView` is Phase 2 (plan §6 Phase 2 / A2 instructions: "does NOT exist. Create a
/// minimal inline placeholder INSIDE `RootTabView.swift`"). Private to this file rather than its
/// own new file, per those same instructions.
// TODO(Phase 2): replace with the real `UpcomingIOSView` — tasks from tomorrow onward, grouped by
// day (plan §2.1).
private struct UpcomingPlaceholderView: View {
    @Environment(AppState.self) private var appState: AppState

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Spacer()
                VolarIcon(.upcoming, size: 36, color: appState.accent.accent.solid, weight: .light)
                Text("Upcoming is coming soon.")
                    .font(IOSMetrics.rowTitle)
                    .foregroundStyle(VolarColor.textPri)
                Text("Tasks scheduled beyond today will show up here, grouped by day.")
                    .font(IOSMetrics.caption)
                    .foregroundStyle(VolarColor.textSec)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, IOSMetrics.screenPadH * 2)
                Spacer()
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(VolarColor.bg)
            .navigationTitle("Upcoming")
        }
    }
}
