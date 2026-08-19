// Sources/Views/TodayView.swift — main window content: sidebar + Today list + greeting + frog/focus pill
// Ported from `design/volar-mac.jsx`'s `VolarMacApp`. Owns the in-window overlay stack (focus, ambient).
//
// FLOATING CAPTURE PANEL (feature 002 gap fix): `PopoverView` used to mount HERE, gated on
// `appState.captureState != .idle`, alongside a click-outside-to-cancel dimming scrim. Since this
// window is normally CLOSED (Volar is an `LSUIElement` menu-bar app), that made the ⌃⌥M capture UI
// invisible whenever the user wasn't already looking at the main window — see
// `Sources/Views/CapturePanel.swift`'s header for the full story. `PopoverView` now mounts in a
// floating `NSPanel` instead (driven by `AppDelegate` in `VolarApp.swift`), which is why both the
// scrim and the `PopoverView()` call are gone from this file; the panel is a system-wide overlay,
// so an in-window dim no longer makes sense (and cancel-on-click-outside was deliberately dropped
// too — the panel brief calls for recording to survive the user clicking elsewhere).
//
// STUDIO DARK RETHEME (2026-07, visual layer only): restructured the flat Now/Later/Completed list
// into the NOW/NEXT/LATER spatial grammar from `volar-redesign/command-deck.html` — one spotlit
// active task, one dimmed "next" peek, and a collapsed/capped "Later" drawer so the window never
// reads as a wall of rows (constitution V). Every `@State`/binding/action that existed before this
// pass is still here, just re-homed: the "Now" section's per-row checkbox/context-menu/tap-to-open
// live on in `NextPeekRow` (for the dimmed peek) and the reused `TaskRow` (inside the collapsible
// Later/Completed drawers); the single "active" task additionally gets a bespoke hero treatment
// (`nowSpotlight`) since `TaskRow`'s compact layout has no room for the hero title/chips/actions the
// design calls for. `TaskRow`/`Components.swift`/`AppState.swift` are all frozen — nothing outside
// this file changed.
import SwiftUI
import VolarCore

struct TodayView: View {
    @Environment(AppState.self) private var appState: AppState

    /// List v2 (design.md §5.7): "Later" starts with its first 5 rows already visible — a fully
    /// collapsed drawer was part of why the screen read as near-empty. `CollapsibleTaskSection`'s
    /// own `maxVisibleRows`/scroll cap still governs how many show once expanded; this only flips
    /// the drawer's OWN default state.
    @State private var laterExpanded = true
    /// NEW (retheme): "Completed" drawer, same collapsed-by-default convention as `laterExpanded`.
    @State private var completedExpanded = false

    /// Drives `SignInSheet` (main-window Sign-in entry point fix, 2026-07-28) — Settings ▸ Account
    /// used to be the ONLY place to sign in, which a brand-new user has no reason to ever open, so
    /// they'd never discover cloud speech/parsing or Pro. This flag backs a toolbar pill that's
    /// visible only while signed out (see the `ToolbarItemGroup` below).
    @State private var showSignInSheet = false

    private var accentColors: Accent { appState.accent.accent }

    var body: some View {
        ZStack {
            if appState.ambient != .none {
                AmbientBackground(mode: appState.ambient, imageURL: appState.customImageURL, intensity: 0.7)
                    .ignoresSafeArea()
            }

            // Panel-refactor (specs/005-cursor-retheme/panel-refactor.md §5 item 3): `detailPanel`
            // is a third CHILD of this `HStack`, not an overlay — it does not participate in, and
            // must not disturb, the tour-overlay-must-be-last ordering the big comment below (on
            // `.overlayPreferenceValue`) locks in. `FocusOverlay()` below is a sibling of this whole
            // `HStack` inside the outer `ZStack`, so it already paints over all three columns
            // (Sidebar/mainColumn/detailPanel) when focus mode is active — the panel never sits
            // beside it.
            HStack(spacing: 0) {
                Sidebar()
                mainColumn
                detailPanel
            }
            .animation(VolarMotion.state, value: appState.detailTaskID)

            if appState.focusActive {
                FocusOverlay()
            }
        }
        // 006-cues-and-waiting (design.md §2 Việc B): the "natural touch point" trigger for
        // `CueFiring.pending` — design.md's own words: "Ở điểm chạm tự nhiên (mở popover)". The
        // main window becoming visible is the closest equivalent this app has to that (see
        // `AppState.noteNaturalCueTouch`'s own doc comment for why `PopoverView`'s capture-flow
        // popup was deliberately NOT used instead). Not overlay-producing, so — unlike the two
        // `.overlay`/`.overlayPreferenceValue` modifiers below — its position in this chain carries
        // no z-order meaning; placed here, right after the `ZStack` closes, purely because it reads
        // most naturally as "the very first thing that happens once this view is on screen."
        .onAppear { appState.noteNaturalCueTouch() }
        // Reminder banner (`NotificationView`): a plain `.overlay`, attached BEFORE the guided
        // tour's `.overlayPreferenceValue` below — see that block's own comment for why ORDER
        // (not `.zIndex`) is what actually decides which of the two draws on top here.
        .overlay(alignment: .topTrailing) {
            if let banner = appState.reminderBanner {
                NotificationView(
                    title: banner.title,
                    timing: banner.timing,
                    onDone: { appState.dismissBanner() },
                    onSnooze: { appState.dismissBanner() },
                    onReschedule: { appState.dismissBanner() }
                )
                .padding(.top, 44)
                .padding(.trailing, 20)
                .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                .zIndex(20)
                .task(id: appState.reminderBanner?.id) {
                    guard appState.reminderBanner != nil else { return }
                    try? await _Concurrency.Task.sleep(for: .seconds(5))
                    appState.dismissBanner()
                }
            }
        }
        .animation(VolarMotion.state, value: appState.reminderBanner)
        // Guided tour (`Sources/Views/Tour/*`): every `.tourAnchor(_:)` call site this feature adds
        // (Sidebar's capture button + key badges, `mainColumn`'s task-list region, the two
        // "Start focus"/"Focus" buttons above) lives inside the `HStack`/`ZStack` above, so
        // attaching `.overlayPreferenceValue(TourAnchorKey.self)` HERE — on that same `ZStack` — is
        // what lets `TourAnchorKey.reduce` collect every one of them into a single `anchors`
        // dictionary before `TourOverlay` ever reads it. FIX 5 (z-order): `.zIndex` only orders
        // SIBLINGS within the same container — it does nothing across two separately-chained view
        // modifiers like this `.overlayPreferenceValue` and the reminder banner's `.overlay`
        // above, each of which wraps the accumulated view in a NEW view with its own content drawn
        // on top. What actually decides stacking order between the two is ATTACHMENT ORDER: this
        // block must be the LAST overlay-producing modifier in the chain (after both `if
        // appState.focusActive { FocusOverlay() }` above AND the reminder-banner `.overlay` right
        // above this comment) so the tour is unconditionally the topmost layer — otherwise a
        // reminder banner can render on top of the tour's own scrim, which previously happened
        // because this block was attached BEFORE the banner's `.overlay`. Keep this LAST among the
        // overlay-producing modifiers on this view if anything else is ever added here.
        .overlayPreferenceValue(TourAnchorKey.self) { anchors in
            if appState.tourActive {
                GeometryReader { proxy in
                    TourOverlay(anchors: anchors, proxy: proxy)
                }
                .transition(.opacity)
                .zIndex(60)
            }
        }
        .animation(VolarMotion.state, value: appState.tourActive)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                // FIX E: used to only flip a local `@State` flag, never actually starting/stopping
                // playback — `AppState.toggleAmbientSound()`/`ambientSound.isPlaying` (Phase-2C's
                // real `AmbientSound.swift`) already exist; this just wires the button to them.
                ToolButton(icon: appState.ambientSound.isPlaying ? .volume : .volumeOff, tint: appState.ambientSound.isPlaying) {
                    appState.toggleAmbientSound()
                }
                ToolButton(icon: .waveform) {
                    appState.readDayAloud()
                }
                ToolButton(icon: .search) {}
                ToolButton(icon: .plus, accent: true) {
                    appState.startCapture()
                }
                // Sign-in entry point from the main window (fix, 2026-07-28): before this, signing
                // in was reachable ONLY through Settings ▸ Account, which a first-time user has no
                // reason to ever open — so cloud speech/parsing and Pro were effectively
                // undiscoverable. Text pill (not a bare icon): `VolarIconName` has no "person/
                // account" glyph (see `SettingsView`'s `.account` tab-icon comment for the same gap),
                // and even if it did, a brand-new user has no learned association for it yet — the
                // word "Sign in" needs no icon to be understood. Hidden entirely once signed in
                // (Việc 3's brief: no avatar/email replacement, that's out of scope here).
                if appState.accountEmail == nil {
                    SignInToolPill { showSignInSheet = true }
                }
                // Settings entry point from the main window: previously reachable ONLY via the
                // menu-bar dropdown or the ⌘, shortcut (which requires the window to already be
                // key). See `SettingsToolButton`'s own doc comment below for why this isn't just
                // `ToolButton` with a `SettingsLink`-flavored action.
                SettingsToolButton()
            }
        }
        .sheet(isPresented: $showSignInSheet) {
            SignInSheet()
        }
    }

    // MARK: - Detail panel

    /// Task-detail inspector column (panel-refactor.md §5 item 3) — replaces the old `.sheet`
    /// (`VolarApp.swift` used to present `TaskDetailView` modally; that `.sheet` is gone). `@ViewBuilder`
    /// `if` (not a ternary/`opacity`) so the column is fully absent from the `HStack`'s layout when
    /// `detailTask` is `nil`, rather than reserving 340pt of empty space — and so the
    /// `.transition`/`.animation(VolarMotion.state, value: appState.detailTaskID)` pair on the
    /// `HStack` above actually has an insertion/removal edge to animate.
    ///
    /// Fixed 340pt width, `VolarColor.surface` background, 0.5pt `VolarColor.border` hairline on the
    /// LEADING edge — same "`Rectangle().fill(VolarColor.border).frame(width: 0.5)` via
    /// `.overlay(alignment:)`" idiom `Sidebar.swift` already uses for its own trailing hairline
    /// against `mainColumn`, just mirrored to the opposite edge since this column sits on the other
    /// side of the window.
    ///
    /// `TaskDetailView` itself renders `EmptyView()` when `appState.detailTask` is `nil` (its own
    /// `body` already guards that) — the `if` here is what makes the outer 340pt frame disappear
    /// too, not just its content.
    @ViewBuilder
    private var detailPanel: some View {
        if appState.detailTask != nil {
            TaskDetailView()
                .frame(width: 340)
                .frame(maxHeight: .infinity)
                .background(VolarColor.surface)
                .overlay(alignment: .leading) {
                    Rectangle().fill(VolarColor.border).frame(width: 0.5)
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }

    // MARK: - Main column

    private var mainColumn: some View {
        VStack(spacing: 0) {
            greetingHeader
                .padding(.horizontal, 28)
                .padding(.top, 20)
                .padding(.bottom, 8)

            // Guided tour, stop 2 (`Sources/Views/Tour/*`): tagged as ONE `Group` wrapping every
            // branch — rather than tagging only the `ScrollView` branch — so the anchor still
            // resolves for a brand-new user with zero tasks (`EmptyTodayCard`), which is exactly
            // the audience this stop most needs to reach. `Group` adds no layout of its own, so
            // this changes nothing about how any branch renders; `.tourAnchor` sits on `Group`
            // itself (not inside the `switch`) so it reads unambiguously as "this whole region is
            // the anchor," and so it stays outside the switch's own brace nesting.
            //
            // Section switch (2026-07-27, port of Windows TodayView.xaml.cs's own "Section switch"
            // comment): the main column now hosts three sections, not just Today. Upcoming/Inbox
            // reuse the same `TaskRow` every drawer below already uses — no new row view — and get
            // their own plain-text empty state (`sectionEmptyView`), distinct from Today's
            // mic-icon `EmptyTodayCard`.
            Group {
                switch appState.selectedSection {
                case .today:
                    if appState.openTasks.isEmpty {
                        EmptyTodayCard()
                    } else {
                        todayScrollView
                    }
                case .upcoming, .inbox:
                    if isSectionEmpty {
                        sectionEmptyView
                    } else {
                        sectionScrollView
                    }
                }
            }
            .tourAnchor(.taskList)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(mainBackground)
    }

    /// Today's NOW/NEXT/Later/Completed stack — unchanged content, just extracted out of
    /// `mainColumn`'s body so the new Upcoming/Inbox branches (`sectionScrollView`) can sit
    /// alongside it in the section `switch` above without duplicating this scroll view's shape.
    private var todayScrollView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: appState.density.sectionGap) {
                nowSpotlight

                // 006-cues-and-waiting (design.md §2 Việc B/C, §3): the two new ambient surfaces
                // this feature adds, both "renders nothing when there's nothing to show" like every
                // other banner in this stack. `cueBanner` prefers a just-fired `.wake` cue (set by
                // `AppState.recordAppBecameActive`, driven off real app activation) but also carries
                // a `.pending` dayEnd/unknown cue surfaced at this exact natural touch point — see
                // `.onAppear` below.
                if let banner = appState.cueBanner {
                    CueReminderRow(banner: banner)
                }
                if let decision = appState.waitingModeDecision {
                    WaitingModeRow(
                        decision: decision,
                        suggestedTitle: decision.suggestedTaskId.flatMap { id in
                            appState.tasks.first { $0.id == id }?.title
                        }
                    )
                }

                // FR-030: the one-time "want to split this up?" invite, whenever one's pending —
                // shared with `FocusOverlay`'s own copy of the same banner (both read the exact
                // same `AppState.switchBreakdownSuggestion`; see `SwitchBreakdownSuggestionBanner`,
                // `Sources/Views/FocusOverlay.swift`). Same "renders nothing when there's nothing to
                // show" convention as `DelegationAmbientSection()` right below.
                if let suggestion = appState.switchBreakdownSuggestion {
                    SwitchBreakdownSuggestionBanner(task: suggestion)
                }

                // "Stuck?" (anh Khôi, 2026-07-29): the "dread" reason's message/fallback banner,
                // the "too_big" reason's single next-action banner, and the "cant_start" reason's
                // 2-minute timer — shared with `FocusOverlay`'s own copies (`StuckDreadBanner`/
                // `StuckNextActionBanner`/`StuckTimerBanner`, `Sources/Views/FocusOverlay.swift`)
                // so wording/behavior can never drift between the two places "Stuck?" appears.
                // None of the three renders anything while idle (same "always safe to include
                // unconditionally" convention `DelegationAmbientSection()` right below documents
                // for itself). The `...id == appState.dashboardActiveTask?.id` guards keep each
                // banner scoped to whichever task the hero card is CURRENTLY showing — Stuck may
                // have been invoked from `FocusOverlay` on a different task while this view sits
                // underneath it.
                if let dreadTask = appState.stuckDreadTask, appState.stuckDreadState != .idle,
                   dreadTask.id == appState.dashboardActiveTask?.id {
                    StuckDreadBanner(task: dreadTask)
                }
                if let nextActionTask = appState.stuckNextActionTask, appState.stuckNextActionState != .idle,
                   nextActionTask.id == appState.dashboardActiveTask?.id {
                    StuckNextActionBanner(task: nextActionTask)
                }
                if appState.stuckTimerActive {
                    StuckTimerBanner()
                }

                // T043 (phase6-contract.md §C): ambient needs-review / WIP soft-limit /
                // ai-done disambiguation — renders nothing when there's genuinely nothing
                // to show (glance-and-dismiss, constitution V), so it's always safe to
                // include unconditionally here.
                DelegationAmbientSection()

                if let peek = peekTask {
                    NextPeekRow(task: peek)
                }

                if !laterListTasks.isEmpty {
                    // List v2 (design.md §5.6.1): NOW (`nowSpotlight`) and NEXT (`NextPeekRow`)
                    // occupy engine-order positions 1 and 2 without a `TaskRow` of their own, so
                    // this drawer's first row starts numbering at 3.
                    CollapsibleTaskSection(
                        title: "Later",
                        tasks: laterListTasks,
                        rowGap: appState.density.rowGap,
                        expanded: $laterExpanded,
                        startIndex: 3,
                        alwaysVisibleKind: .hard
                    )
                }

                if !appState.doneTasks.isEmpty {
                    CollapsibleTaskSection(
                        title: "Completed",
                        tasks: appState.doneTasks,
                        rowGap: appState.density.rowGap,
                        expanded: $completedExpanded
                    )
                }

                hotkeyFooter
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)
            .padding(.bottom, 18)
            .animation(VolarMotion.list, value: appState.tasks)
        }
    }

    /// Upcoming/Inbox body — same `TaskRow` every Today drawer already uses, so a task looks and
    /// behaves identically wherever it appears (checkbox, hover, context menu, open-detail).
    /// Upcoming adds a day-header per group (`AppState.upcomingGroups`); Inbox is a flat list —
    /// nothing to group by, see `TaskSections.swift`'s header comment. Mirrors Windows
    /// TodayView.xaml's `SectionScrollViewer` (`UpcomingGroupsItemsControl`/`InboxItemsControl`).
    @ViewBuilder
    private var sectionScrollView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: appState.density.sectionGap) {
                switch appState.selectedSection {
                case .upcoming:
                    ForEach(appState.upcomingGroups) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            // List v2 (design.md §5.4): every group-title label in this file is
                            // 11pt/.semibold/uppercase/tracking+0.5/`textSec` — `textMut` (3.4:1)
                            // is reserved for tertiary labels now, not section headers.
                            Text(group.header.uppercased())
                                .font(Font.volarMono(size: 11, weight: .semibold))
                                .tracking(0.5)
                                .foregroundStyle(VolarColor.textSec)
                            VStack(spacing: appState.density.rowGap) {
                                ForEach(group.tasks) { task in
                                    TaskRow(task: task, isActive: false)
                                }
                            }
                        }
                    }
                case .inbox:
                    VStack(spacing: appState.density.rowGap) {
                        ForEach(appState.inboxTasks) { task in
                            TaskRow(task: task, isActive: false)
                        }
                    }
                case .today:
                    EmptyView()
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)
            .padding(.bottom, 18)
        }
    }

    /// Upcoming/Inbox empty state — plain centered text, distinct from Today's mic-icon
    /// `EmptyTodayCard` (neither section has anything to illustrate beyond the copy itself).
    /// Mirrors Windows TodayView.xaml's `SectionEmptyText`.
    private var sectionEmptyView: some View {
        Text(sectionEmptyText)
            .font(.system(size: 13.5))
            .foregroundStyle(VolarColor.textSec)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 320)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// NEW (retheme): "deep ink stage" — a faint top-down radial lift over the flat ink base so the
    /// window reads as a stage with depth rather than a flat fill, matching `command-deck.html`'s
    /// `body` background. Built only from existing `VolarColor` tokens (`bg`/`surface`) — no new hex.
    @ViewBuilder
    private var mainBackground: some View {
        if appState.ambient != .none {
            Color.black.opacity(0.30)
        } else {
            ZStack {
                VolarColor.bg
                RadialGradient(
                    colors: [VolarColor.surface.opacity(0.55), Color.clear],
                    center: UnitPoint(x: 0.5, y: -0.15),
                    startRadius: 40,
                    endRadius: 640
                )
                .allowsHitTesting(false)
            }
        }
    }

    // MARK: - NOW / NEXT / LATER derivation (retheme, display-order only — no `AppState` change)

    /// Every open task except the one currently spotlit as NOW — same membership/order as the old
    /// flat `nowTasks + laterTasks` list (`appState.openTasks`), just minus whichever task is
    /// spotlit. Reads `appState.dashboardActiveTask`, NOT the raw engine `activeTask` — after a
    /// Switch (`nowSpotlight`'s new "Switch" button) the spotlit task is the replacement, not
    /// whatever the engine would otherwise still rank first, and this list must agree with the
    /// hero card about which one that is (the switched-away task belongs back in this list, the
    /// replacement must NOT still show up here too). If nothing is spotlit at all (e.g. everything
    /// open is gated on an unmet condition), nothing is excluded.
    private var remainingOpenTasks: [TaskItem] {
        guard let active = appState.dashboardActiveTask else { return appState.openTasks }
        return appState.openTasks.filter { $0.id != active.id }
    }

    /// The single dimmed "NEXT" peek — first of whatever's left after NOW.
    private var peekTask: TaskItem? { remainingOpenTasks.first }

    /// Everything else — rendered inside the collapsed/capped "Later" drawer via `TaskRow`, so it
    /// keeps every row action (checkbox/tap-to-open/context menu) unchanged.
    private var laterListTasks: [TaskItem] {
        guard !remainingOpenTasks.isEmpty else { return [] }
        return Array(remainingOpenTasks.dropFirst())
    }

    // MARK: - NOW spotlight

    /// The hero treatment for `appState.dashboardActiveTask` — the one thing on screen allowed to be
    /// amber. Bespoke (not `TaskRow`) because the design calls for a big centered title + chip row +
    /// primary action that `TaskRow`'s compact horizontal layout has no room for; every action
    /// `TaskRow` would have offered (tap-to-open-detail, mark done, breakdown, delete) is still wired
    /// here via the same `appState` calls, PLUS the new "Switch" action. Reads `dashboardActiveTask`
    /// rather than the raw engine `activeTask` so a Switch actually moves what this card shows (see
    /// that property's own doc comment for why the plain engine pick alone can never change here).
    /// Falls back to a calm placeholder if there's nothing eligible at all (never crashes/force-
    /// unwraps).
    @ViewBuilder
    private var nowSpotlight: some View {
        if let active = appState.dashboardActiveTask {
            VStack(spacing: 16) {
                // List v2 (design.md §5.3): "NOW" is a small chip, not a colored text label — the
                // hero's saturation budget is spent on this chip + the 3px leading bar in
                // `.background` below, never on a text color or a full-row fill.
                Text("NOW")
                    .font(Font.volarMono(size: 11, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(VolarColor.bg)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(VolarColor.nowAccent)
                    .clipShape(Capsule())

                Text(active.title)
                    .font(.system(size: 28, weight: .semibold))
                    .tracking(-0.7)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(VolarColor.textPri)
                    .shadow(color: VolarColor.nowGlow, radius: 18)
                    .lineLimit(3)

                // List v2 (design.md §5.6.1, coordinator follow-up 2026-08-19): NOW is the ONE
                // place "why is this first" matters most, and it's bespoke (not `TaskRow`) so it
                // never got a reason line in the first pass. Reuses `rankReasonLabel` from
                // `Components.swift` (owned by another agent) rather than a second formatter —
                // same rule `TaskRow`'s own reason display follows.
                if let label = rankReasonLabel(volarRankReason(for: active)) {
                    Text(label)
                        .font(.system(size: 12.5))
                        .foregroundStyle(VolarColor.textSec)
                }

                nowChips(for: active)

                HStack(spacing: 10) {
                    if !appState.focusActive {
                        Button {
                            appState.startFocus()
                        } label: {
                            Text("Start focus")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(VolarColor.bg)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                // Vùng bấm phủ đúng vùng nhìn thấy (luật anh Khôi chốt 2026-08-09).
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(
                            LinearGradient(
                                colors: [VolarColor.nowAccentSoft, VolarColor.nowAccent],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        // Guided tour, stop 3 primary anchor (`Sources/Views/Tour/*`): only ever
                        // rendered while `!appState.focusActive` (this whole `Button` sits inside
                        // that guard, immediately above), i.e. only while there's an eligible NOW
                        // task to focus on — see `TourAnchorID.focusPrimary`'s doc comment for why
                        // `frogPill`'s "Focus" button below is tagged as this stop's fallback.
                        .tourAnchor(.focusPrimary)
                    }

                    Button {
                        appState.toggleDone(active.id)
                    } label: {
                        Text(active.done ? "Mark not done" : "Done")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(VolarColor.textPri)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(VolarColor.surfaceHi)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(VolarColor.borderHi, lineWidth: 0.5)
                    )

                    // UNVERIFIED: authored on Windows, no Swift/Xcode toolchain here — this Switch
                    // button, its context-menu twin below, and the `dashboardActiveTask` rewiring
                    // above have not been compiled, run, or seen on screen. Needs a Mac visual pass
                    // (see final report's verify checklist) before shipping.
                    //
                    // Switch ("đổi gió") — equal footing with "Done" right above, not a secondary/
                    // hidden action (also mirrored in the context menu below, same as "Mark done"
                    // already is, but this button row is the primary, always-visible home for it).
                    // Deliberately the SAME neutral styling as "Done" (no accent fill, no icon, no
                    // red) — this is a completely normal thing to tap, not an admission of anything.
                    // Disabled (not hidden) when there's nowhere else open to switch to.
                    if !active.done {
                        Button {
                            appState.switchDashboardActiveTask()
                        } label: {
                            Text("Switch")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(VolarColor.textPri)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(VolarColor.surfaceHi)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(VolarColor.borderHi, lineWidth: 0.5)
                        )
                        .opacity(appState.canSwitchDashboardActiveTask ? 1 : 0.4)
                        .disabled(!appState.canSwitchDashboardActiveTask)
                        .help("Move on to something else — this task isn't done, it just steps out for now.")
                    }

                    // "Stuck?" (anh Khôi, 2026-07-29) — equal footing with "Done"/"Switch" right
                    // above, same neutral capsule styling (no accent, no icon, no warning color):
                    // an entirely ordinary thing to tap. Opens the same three-reason popover
                    // (`StuckReasonPicker`) `FocusOverlay`'s own "Stuck?" button uses — one shared
                    // definition, `Sources/Views/FocusOverlay.swift`.
                    if !active.done {
                        Button {
                            appState.openStuckPicker(for: active)
                        } label: {
                            Text("Stuck?")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(VolarColor.textPri)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(VolarColor.surfaceHi)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(VolarColor.borderHi, lineWidth: 0.5)
                        )
                        .popover(isPresented: Binding(
                            get: { appState.stuckPickerTask?.id == active.id },
                            set: { presented in if !presented { appState.dismissStuckPicker() } }
                        )) {
                            StuckReasonPicker(task: active)
                        }
                        .help("Name what kind of stuck this is — different kinds need different fixes.")
                    }

                    // T042 (phase6-contract.md §C): delegate affordance on the current (NOW) task
                    // — `AppState.delegateTask` adds the unsatisfied "waiting on AI" condition,
                    // which is what actually moves it out of this slot (constitution II: a
                    // delegation is never a completion). Cool `.instrument` tint (not the reserved
                    // NOW amber) since this is an instrument-class action, not the spotlight itself.
                    if !active.done {
                        Button {
                            appState.delegateTask(active.id)
                        } label: {
                            HStack(spacing: 6) {
                                VolarIcon(.bolt, size: 11, color: VolarColor.instrument, weight: .semibold)
                                Text("Delegate to Claude")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(VolarColor.textPri)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(VolarColor.instrumentDim.opacity(0.18))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(VolarColor.instrumentDim, lineWidth: 0.5)
                        )
                    }
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 44)
            .frame(maxWidth: .infinity, minHeight: 300)
            // Spotlight glow must sit BETWEEN the ink base and the text/chips — applying it here
            // (innermost, before the opaque `.background(VolarColor.bg)` below) instead of after
            // is what keeps the warm pool actually visible instead of hidden behind the opaque
            // card fill. UNVERIFIED: layering reasoned from SwiftUI's `.background`/`.overlay`
            // stacking order, not rendered on this machine (Windows, no Xcode).
            .volarSpotlight(isActive: true)
            // List v2 (design.md §5.3/§3.4): `nowSurface` (accent pha ~8% into `bg`), not a solid
            // `nowAccent` fill — white text on `#BF5AF2` is only 3.1:1, and a large saturated
            // block would break the "one saturated point on screen" rule the chip above already
            // spends. The 3px leading bar is the row's ONLY other saturated pixel. Put inside this
            // same `.background` (not a separate `.overlay`) so it gets clipped to the rounded
            // corners together with the fill below, instead of squaring off past them.
            .background(
                ZStack(alignment: .leading) {
                    VolarColor.nowSurface
                    Rectangle().fill(VolarColor.nowAccent).frame(width: 3)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(VolarColor.border, lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            // Same tap-to-open-detail convention as `TaskRow` — the primary/ghost buttons above
            // are their own `Button`s and consume their own tap first, same reasoning as
            // `TaskRow`'s doc comment on why a nested-Button row is safe here.
            .onTapGesture { appState.openDetail(active.id) }
            .contextMenu {
                Button("Break down into steps…") { appState.openBreakdown(for: active) }
                Button(active.done ? "Mark not done" : "Mark done") { appState.toggleDone(active.id) }
                if !active.done {
                    // Mirrors the button row's Switch exactly (same `AppState` call, same
                    // disabled-when-nowhere-else-to-go rule) — the button row is the primary,
                    // always-visible home for Switch; this is just the same convenience-duplicate
                    // treatment "Mark done" already gets here.
                    Button("Switch") { appState.switchDashboardActiveTask() }
                        .disabled(!appState.canSwitchDashboardActiveTask)
                    Button("Delegate to Claude…") { appState.delegateTask(active.id) }
                }
                Divider()
                Button("Delete", role: .destructive) { appState.deleteTask(active.id) }
            }
        } else {
            VStack(spacing: 8) {
                Text("Nothing ready right now")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(VolarColor.textSec)
                Text("Everything open is waiting on something else.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(VolarColor.textMut)
            }
            .frame(maxWidth: .infinity, minHeight: 140)
            .background(VolarColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(VolarColor.border, lineWidth: 0.5)
            )
        }
    }

    /// Chip row under the NOW title — remaining estimate, deadline, frog marker, dependency note.
    /// All derived from existing `TaskItem` fields (`durationLabel`/`timeBadge`/`frog`/`conditions`)
    /// already used elsewhere (`TaskRow`) — no new data/logic, just a different presentation.
    private func nowChips(for task: TaskItem) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let durationLabel = task.durationLabel {
                    SpotlightChip(key: "left", value: durationLabel)
                }
                if let timeBadge = task.timeBadge {
                    SpotlightChip(key: "due", value: timeBadge)
                }
                if task.frog {
                    SpotlightChip(value: "Hardest task today", style: .frog)
                }
                if !task.conditions.isEmpty {
                    SpotlightChip(key: "waiting", value: "on other work", style: .dependency)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: - Greeting header

    private var greetingHeader: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                // Section switch (2026-07-27, port of Windows TodayView.xaml.cs's own "Section
                // switch" comment): title now tracks `appState.selectedSection`.
                Text(sectionTitle)
                    .font(.system(size: 26, weight: .medium))
                    .tracking(-0.52)
                    .foregroundStyle(VolarColor.textPri)
                // Today keeps its own date + open/done counters; Upcoming/Inbox have no
                // "date · N open · N done" shape to fill, so they show `sectionSubtitleText`
                // instead (mirrors Windows `TodaySubtitleRow`/`SectionSubtitleText`'s mutually
                // exclusive visibility in TodayView.xaml.cs's `UpdateVisual`).
                if appState.selectedSection == .today {
                    // Counts are instrument readouts (mono, per the retheme brief) — same
                    // `appState.openTasks.count`/`appState.doneTasks.count` bindings as before, just
                    // split into separate `Text` fragments so the numbers can take `Font.volarMono`.
                    HStack(spacing: 4) {
                        Text(todayDateLabel)
                            .font(Font.volarMono(size: 12.5))
                            .monospacedDigit()
                        Text("·").foregroundStyle(VolarColor.textMut)
                        Text("\(appState.openTasks.count)")
                            .font(Font.volarMono(size: 12, weight: .medium))
                            .foregroundStyle(VolarColor.instrument)
                        Text("open")
                        Text("·").foregroundStyle(VolarColor.textMut)
                        Text("\(appState.doneTasks.count)")
                            .font(Font.volarMono(size: 12, weight: .medium))
                            .foregroundStyle(VolarColor.done)
                        Text("done")
                    }
                    .font(.system(size: 12.5))
                    .tracking(-0.0625)
                    .foregroundStyle(VolarColor.textSec)
                    .lineLimit(1)
                } else if let subtitle = sectionSubtitleText {
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .tracking(-0.0625)
                        .foregroundStyle(VolarColor.textSec)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if appState.focusActive {
                runningFocusPill
            } else {
                frogPill
            }
        }
    }

    // MARK: - Section switch (2026-07-27): Today/Upcoming/Inbox — port of Windows
    // TodayViewModel.SectionTitle/SectionSubtitle/SectionEmptyText/IsSectionEmpty
    // (ViewModels/TodayViewModel.cs:364-396). Copy is byte-for-byte identical to that source.

    private var sectionTitle: String {
        switch appState.selectedSection {
        case .today: return "Today"
        case .upcoming: return "Upcoming"
        case .inbox: return "Inbox"
        }
    }

    private var sectionSubtitleText: String? {
        switch appState.selectedSection {
        case .today:
            return nil
        case .upcoming:
            return appState.upcomingNavCount == 0
                ? "Nothing scheduled after today"
                : "\(appState.upcomingNavCount) scheduled after today"
        case .inbox:
            return appState.inboxNavCount == 0
                ? "Nothing waiting to be sorted"
                : "\(appState.inboxNavCount) with no date yet"
        }
    }

    private var sectionEmptyText: String {
        switch appState.selectedSection {
        case .upcoming:
            return "Nothing scheduled after today. Say a task with a date and it lands here."
        default:
            return "Inbox is empty. Anything you capture without a date waits here."
        }
    }

    private var isSectionEmpty: Bool {
        switch appState.selectedSection {
        case .upcoming: return appState.upcomingGroups.isEmpty
        case .inbox: return appState.inboxTasks.isEmpty
        case .today: return false
        }
    }

    private var todayDateLabel: String {
        Date.now.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    private var runningFocusPill: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(accentColors.solid)
                .frame(width: 5, height: 5)
                .shadow(color: accentColors.glow, radius: 4)
                .opacity(appState.focusPaused ? 1 : (pulseTick ? 0.35 : 1))
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                        pulseTick = true
                    }
                }

            Text(appState.frogTask?.title ?? "Focus")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(VolarColor.textPri)
                .lineLimit(1)
                .frame(maxWidth: 180, alignment: .leading)

            Text(fmtClock(appState.focusSecondsLeft))
                .font(Font.volarMono(size: 13, weight: .semibold))
                .monospacedDigit()
                .tracking(0.26)
                .foregroundStyle(accentColors.solid)

            Button {
                appState.toggleFocusPause()
            } label: {
                VolarIcon(appState.focusPaused ? .play : .pause, size: 10, color: VolarColor.textPri)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(VolarColor.veil(0.08))
            .clipShape(Circle())

            Button {
                appState.endFocus()
            } label: {
                VolarIcon(.stop, size: 9, color: VolarColor.textSec)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(VolarColor.veil(0.08))
            .clipShape(Circle())
        }
        .font(.system(size: 11.5))
        .foregroundStyle(VolarColor.textSec)
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(accentColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(accentColors.solid.opacity(0.27), lineWidth: 0.5)
        )
        .shadow(color: accentColors.glow.opacity(0.25), radius: 22)
    }

    private var frogPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(VolarColor.high)
                .frame(width: 5, height: 5)
                .shadow(color: VolarColor.high.opacity(0.5), radius: 3)

            HStack(spacing: 4) {
                Text("Frog").fontWeight(.medium).foregroundStyle(VolarColor.textPri)
                Text("· \(appState.frogTask?.title ?? "Ship the auth fix")")
            }

            Button {
                appState.startFocus()
            } label: {
                HStack(spacing: 5) {
                    VolarIcon(.play, size: 8, color: .white)
                    Text("Focus")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(accentColors.solid)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            // Guided tour, stop 3 fallback anchor: `frogPill` (unlike `nowSpotlight`'s "Start
            // focus" button above) has no `appState.activeTask`/`focusActive` guard, so this
            // "Focus" button is always on screen whenever the running-focus pill isn't — including
            // a brand-new user's empty-task state, which is exactly the case `.focusPrimary` can't
            // cover.
            .tourAnchor(.focusFallback)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(VolarColor.textSec)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        // Retheme: was a hardcoded red (0xFF6B6B) — both "no red, ever" and "no hardcoded hex" are
        // hard rules now, so this reuses the existing `VolarColor.high` (clay/terracotta) token,
        // which is also what the frog dot above already uses. Deliberately NOT `nowAccent` — amber
        // is reserved for the NOW spotlight alone, and this pill isn't it.
        .background(VolarColor.high.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(VolarColor.high.opacity(0.20), lineWidth: 0.5)
        )
    }

    // MARK: - Hotkey footer

    private var hotkeyFooter: some View {
        HStack(spacing: 10) {
            VolarIcon(.mic, size: 13, color: accentColors.solid, weight: .semibold)
            Text("Press")
            KeyBadge("⌃", accent: true)
            KeyBadge("⌥", accent: true)
            KeyBadge("M", accent: true)
            Text("and speak to add a task by voice.")
        }
        .font(.system(size: 12))
        .foregroundStyle(VolarColor.textSec)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(accentColors.solid.opacity(0.33), style: StrokeStyle(lineWidth: 0.5, dash: [4, 3]))
        )
    }

    /// Drives the running-focus pill's pulsing dot. Kept as an `@State` on the view (rather than
    /// `AppState`) since it's pure presentation, not app state.
    @State private var pulseTick = false

    private func fmtClock(_ seconds: Int) -> String {
        "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}

/// Gear entry point into Settings from the main window's toolbar. Visually matches
/// `Components.swift`'s `ToolButton` (28x28 hit target, 5pt-rounded hover tint, subtle press
/// scale) so it reads as one more tool alongside ambient/read-aloud/search/capture — but it wraps
/// `SettingsLink` (macOS 14+, opens the app's `Settings` scene) instead of a plain `Button`, for
/// two reasons: `SettingsLink` owns its action outright and has no `action:` closure parameter to
/// plug into `ToolButton`, and `ToolButton`/`ToolButtonStyle` both live in `Components.swift`,
/// which is frozen/off-limits for this task. `SettingsLink { Text(...) }` mirrors the exact usage
/// already in `VolarApp.swift`'s `MenuBarMenuContent` per the task brief; `ToolButtonStyle`'s
/// press-scale is small enough to re-declare locally (`SettingsToolButtonStyle` below) rather than
/// touching that file to make it non-private.
///
/// UNVERIFIED: whether `SettingsLink` actually honors a custom `ButtonStyle`/hover-driven
/// background the way a plain `Button` does isn't confirmed on this machine (no Xcode/Swift
/// toolchain to render it) — if it silently ignores `.buttonStyle(_:)` at runtime, the gear would
/// still open Settings correctly, just without the hover/press affordance matching its siblings.
private struct SettingsToolButton: View {
    @State private var isHovering = false

    var body: some View {
        SettingsLink {
            VolarIcon(.settings, size: 14, color: VolarColor.textSec, weight: .regular)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(SettingsToolButtonStyle())
        .background(isHovering ? VolarColor.veil(0.06) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .onHover { isHovering = $0 }
        .animation(VolarMotion.hover, value: isHovering)
        .accessibilityLabel("Settings")
    }
}

/// Local re-declaration of `Components.swift`'s private `ToolButtonStyle` — see
/// `SettingsToolButton`'s doc comment for why it isn't reused directly.
private struct SettingsToolButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(VolarMotion.press, value: configuration.isPressed)
    }
}

/// Toolbar "Sign in" pill — the new main-window entry point into `SignInSheet` (see this file's
/// `.toolbar` block above; visible only while `appState.accountEmail == nil`). Text rather than a
/// bare icon: `VolarIconName` has no person/account glyph (same gap `SettingsView`'s Account tab
/// works around), and a brand-new user wouldn't recognize one yet even if it existed — "Sign in"
/// reads on its own.
///
/// RETHEME (Graphite, spec §3.2, revised by design-owner follow-up): was an always-filled accent
/// capsule; a first pass flattened it to no fill at all, matching the icon-only `ToolButton`s
/// beside it — but that went too far. Before this pill existed, sign-in was only reachable through
/// Settings and was effectively undiscoverable, which is the whole reason the fill was added in the
/// first place. So this stays deliberately the one toolbar item carrying a fill at rest: a subtle
/// ~15% accent tint (`accent.surface`) with a soft accent-tinted border, not the solid capsule of
/// the old design and not the flat/borderless treatment of its `SettingsToolButton` sibling.
private struct SignInToolPill: View {
    let action: () -> Void

    @Environment(AppState.self) private var appState
    @State private var isHovering = false

    private var accentColors: Accent { appState.accent.accent }

    var body: some View {
        Button(action: action) {
            Text("Sign in")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(accentColors.solid)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(SettingsToolButtonStyle())
        .background(accentColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(accentColors.solid.opacity(isHovering ? 0.5 : 0.3), lineWidth: 0.5)
        )
        .onHover { isHovering = $0 }
        .animation(VolarMotion.hover, value: isHovering)
        .accessibilityLabel("Sign in")
    }
}

/// "All clear." empty state shown when there are no open tasks. Ported from `volar-mac.jsx`'s
/// `EmptyToday`. Private to `TodayView` — not part of the frozen component surface.
private struct EmptyTodayCard: View {
    @Environment(AppState.self) private var appState: AppState

    private var accentColors: Accent { appState.accent.accent }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(accentColors.surface)
                    .frame(width: 64, height: 64)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(accentColors.solid.opacity(0.20), lineWidth: 0.5)
                    )
                    .shadow(color: accentColors.glow.opacity(0.30), radius: 30)
                VolarIcon(.mic, size: 28, color: accentColors.solid, weight: .light)
            }

            Text("All clear.")
                .font(.system(size: 22, weight: .medium))
                .tracking(-0.33)
                .foregroundStyle(VolarColor.textPri)

            HStack(spacing: 4) {
                Text("Press")
                KeyBadge("⌃")
                KeyBadge("⌥")
                KeyBadge("M")
                Text("when you need to remember something.")
            }
            .font(.system(size: 13.5))
            .foregroundStyle(VolarColor.textSec)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 300)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// NEW (retheme): a single small chip for the NOW spotlight's chip row (remaining estimate,
/// deadline, frog marker, dependency note). Private to `TodayView` — visual-only, carries no
/// binding/action of its own (the spotlight card around it owns tap/context-menu).
private struct SpotlightChip: View {
    enum Style { case plain, frog, dependency }

    var key: String? = nil
    let value: String
    var style: Style = .plain

    var body: some View {
        HStack(spacing: 5) {
            if let key {
                Text(key)
                    .font(Font.volarMono(size: 10.5))
                    .foregroundStyle(keyColor)
            }
            Text(value)
                .font(.system(size: 12.5))
                .foregroundStyle(valueColor)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(VolarColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(
                    borderColor,
                    style: style == .dependency ? StrokeStyle(lineWidth: 0.5, dash: [3, 2]) : StrokeStyle(lineWidth: 0.5)
                )
        )
    }

    private var keyColor: Color {
        switch style {
        case .plain: return VolarColor.textMut
        case .frog: return VolarColor.nowAccentSoft
        case .dependency: return VolarColor.instrument
        }
    }

    private var valueColor: Color {
        switch style {
        case .plain: return VolarColor.textSec
        case .frog: return VolarColor.nowAccentSoft
        case .dependency: return VolarColor.textMut
        }
    }

    private var borderColor: Color {
        switch style {
        case .plain: return VolarColor.borderHi
        case .frog: return VolarColor.nowRing
        case .dependency: return VolarColor.instrumentDim
        }
    }
}

/// NEW (retheme): the single dimmed "NEXT" peek — everything except NOW is calm/collapsed, and this
/// is the one deliberate exception (a glance at what's coming, not a full row). Bespoke layout (not
/// `TaskRow`) to match `command-deck.html`'s peek treatment, but every action `TaskRow` offers is
/// preserved here via the same `appState` calls: checkbox -> `toggleDone`, tap -> `openDetail`,
/// context menu -> breakdown/toggle/delete, identical to `TaskRow`'s own context menu.
private struct NextPeekRow: View {
    let task: TaskItem

    @Environment(AppState.self) private var appState: AppState

    var body: some View {
        HStack(spacing: 14) {
            checkbox

            VStack(alignment: .leading, spacing: 3) {
                // List v2 (design.md §5.4): same header spec as `CollapsibleTaskSection`'s own
                // title label — 11pt/.semibold/uppercase/tracking+0.5/`textSec`.
                Text("NEXT")
                    .font(Font.volarMono(size: 11, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(VolarColor.textSec)
                Text(task.title)
                    .font(.system(size: 14.5))
                    .foregroundStyle(task.done ? VolarColor.textMut : VolarColor.textSec)
                    .strikethrough(task.done, pattern: .solid, color: VolarColor.veil(0.25))
                    .lineLimit(1)
                    .truncationMode(.tail)
                // List v2 (design.md §5.6.1, coordinator follow-up 2026-08-19): NEXT is the
                // other bespoke (non-`TaskRow`) row, same reasoning as `nowSpotlight`'s reason
                // line above — reuses `rankReasonLabel`, no second formatter.
                if !task.done, let label = rankReasonLabel(volarRankReason(for: task)) {
                    Text(label)
                        .font(.system(size: 11.5))
                        .foregroundStyle(VolarColor.textSec)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if let meta = task.durationLabel ?? task.timeBadge {
                Text(meta)
                    .font(Font.volarMono(size: 11.5))
                    .foregroundStyle(VolarColor.textMut)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
        .background(VolarColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(VolarColor.border, lineWidth: 0.5)
        )
        .opacity(0.62)
        .contentShape(Rectangle())
        .onTapGesture { appState.openDetail(task.id) }
        .contextMenu {
            Button("Break down into steps…") { appState.openBreakdown(for: task) }
            Button(task.done ? "Mark not done" : "Mark done") { appState.toggleDone(task.id) }
            Divider()
            Button("Delete", role: .destructive) { appState.deleteTask(task.id) }
        }
    }

    private var checkbox: some View {
        Button {
            appState.toggleDone(task.id)
        } label: {
            Circle()
                .strokeBorder(task.done ? VolarColor.textSec : VolarColor.veil(0.28), lineWidth: 1.5)
                .background(Circle().fill(task.done ? VolarColor.textSec : .clear))
                .frame(width: 15, height: 15)
                .overlay {
                    if task.done {
                        VolarIcon(.check, size: 9, color: VolarColor.bg, weight: .bold)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// List v2 (design.md §5.6.1/§6): the row-list "why does this rank here" reason — shared by
/// `nowSpotlight`, `NextPeekRow`, and every `CollapsibleTaskSection` call site below, since NOW/
/// NEXT/Later are the three places a reason line is asked for. Reuses `TaskItem.snapshot()` — the
/// exact `TaskItem` -> `VolarCore.Task` mapping `AppState.eligibleOrder`
/// (`Shared/App/AppState.swift`) already uses — instead of a second hand-rolled mapping; that
/// duplication is exactly the mistake `AppState.eligibleOrder`'s own doc comment says the codebase
/// already paid for once.
///
/// `now: Date()` read fresh on every call (coordinator follow-up 2026-08-19: checked for a shared
/// clock first) — `AppState.clock` exists but is `private`, this file has no other view-level
/// "now", and every caller here (`nowSpotlight`, `NextPeekRow` peek, the first 3 Later rows) is a
/// small, infrequently-recomputed set, not a hot loop — so a fresh `Date()` per call is the
/// simplest correct option, same as `AppState.eligibleOrder`'s own callers each pass their own
/// `now`. Revisit only if `AppState` ever exposes a public `now`/tick for views generally.
private func volarRankReason(for task: TaskItem) -> RankReason {
    VolarCore.rankReason(for: task.snapshot(), now: Date(), calendar: .current)
}

/// NEW (retheme): the collapsed-by-default, capped "Later"/"Completed" drawer — deliberately
/// toggled open rather than always rendering every row, so a long list never becomes the "30-row
/// wall" the constitution rules out. Every row inside is a real `TaskRow`, so nothing about
/// checkbox/tap-to-open/context-menu/breakdown changes — this only wraps that same `ForEach` in a
/// collapsible, height-capped container. `tasks`/`rowGap` are passed in rather than reached for via
/// `AppState` directly so this one struct serves both the Later and Completed call sites.
private struct CollapsibleTaskSection: View {
    let title: String
    let tasks: [TaskItem]
    let rowGap: CGFloat
    @Binding var expanded: Bool
    /// List v2 (design.md §5.6.1): 1-based engine-order index of `tasks[0]`. `nil` (default) for
    /// drawers whose tasks aren't part of the ranked open-task sequence — the Completed call site
    /// never passes this, since done tasks have no rank/number.
    var startIndex: Int? = nil
    /// specs/010-calendar-and-hard-deadlines/design.md §3.2 row 3: a `.hard` deadline must never
    /// end up in the collapsed/hidden part of a drawer — a real, penalty-backed deadline hidden
    /// by the app is exactly the failure mode this whole feature exists to stop (design.md §3.0:
    /// "một hạn có chế tài mà bị app giấu đi"). `nil` (default, the Completed call site) leaves
    /// every row inside the normal collapse/scroll behavior, unchanged — the "Later" call site
    /// below passes `.hard` so those rows render above the fold whether `expanded` is on or off.
    var alwaysVisibleKind: DeadlineKind? = nil

    /// `tasks`, paired with each element's TRUE position in `tasks` (not the filtered subset's
    /// local index) — both `pinnedRows`/`collapsibleRows` below read `offset` off of this so a
    /// row's rank number (`startIndex + offset`) never shifts just because pinning moved it out
    /// of the scrollable half.
    private var indexedTasks: [IndexedTask] {
        tasks.enumerated().map { IndexedTask(offset: $0.offset, task: $0.element) }
    }

    /// Struct chứ không phải tuple `(offset:task:)`: hai `ForEach` bên dưới cần định danh từng
    /// row, mà Swift KHÔNG cho key path trỏ vào phần tử tuple — `ForEach(pinnedRows, id: \.task.id)`
    /// là lỗi compile, không phải chuyện chạy sai. `Identifiable` để `ForEach(rows)` khỏi cần `id:`.
    private struct IndexedTask: Identifiable {
        let offset: Int
        let task: TaskItem
        var id: UUID { task.id }
    }

    /// design.md §3.1 — `deadlineKind` is meaningless without a `deadline` (same guard
    /// `SweepView.SweepRow.isHardDeadline` applies): a `.hard`-tagged task whose deadline has
    /// since been cleared has no outside date left to protect, so it must NOT be pinned above the
    /// fold forever. One predicate for both halves so pinned + collapsible always partition
    /// `indexedTasks` exactly — no row can go missing or render twice.
    private func isPinned(_ task: TaskItem) -> Bool {
        guard let alwaysVisibleKind else { return false }
        return task.deadline != nil && task.deadlineKind == alwaysVisibleKind
    }

    /// Always rendered, regardless of `expanded` — see `alwaysVisibleKind`'s doc comment.
    private var pinnedRows: [IndexedTask] {
        indexedTasks.filter { isPinned($0.task) }
    }

    /// Everything NOT pinned — these are the only rows subject to `expanded`/the scroll cap.
    private var collapsibleRows: [IndexedTask] {
        indexedTasks.filter { !isPinned($0.task) }
    }

    /// Roughly how many rows are visible before the drawer's own internal scroll takes over —
    /// "ranked, capped list — never a wall" without actually dropping any task from the data
    /// source (it's still reachable by scrolling once expanded). UNVERIFIED: `approxRowHeight` is
    /// an estimate of `TaskRow`'s rendered height (not measured — no Xcode on this machine); worst
    /// case a couple more/fewer rows are visible before scrolling than intended, which is a purely
    /// cosmetic drift, not a functional one.
    private let maxVisibleRows: CGFloat = 6
    private let approxRowHeight: CGFloat = 56

    /// Shared by both the always-visible pinned rows and the collapsible scroll region below, so
    /// the two never drift in how they build a `TaskRow` from an (offset, task) pair.
    @ViewBuilder
    private func row(_ offset: Int, _ task: TaskItem) -> some View {
        // List v2 (design.md §5.6.1/§5.6.2, coordinator follow-up 2026-08-19): `rowIndex` is this
        // row's 1-based engine-order position (nil when `startIndex` is nil, e.g. Completed, which
        // never shows a reason). NOW (1) and NEXT (2) already show their own reason line via
        // bespoke views above (`nowSpotlight`/`NextPeekRow`), not `TaskRow` — so for the "Later"
        // call site (`startIndex: 3`), the reason cutoff is 5, i.e. the first 3 rows OF THIS
        // DRAWER (global index 3, 4, 5). Below that it's noise, per design.md's "chỉ 3 row đầu".
        let rowIndex = startIndex.map { $0 + offset }
        TaskRow(
            task: task,
            isActive: false,
            index: rowIndex,
            reason: (rowIndex ?? .max) <= 5 ? volarRankReason(for: task) : nil
        )
        .transition(rowTransition)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            // Pinned rows (`.hard` deadlines, when `alwaysVisibleKind` is set) render OUTSIDE the
            // `expanded` gate below — see `alwaysVisibleKind`'s doc comment.
            if !pinnedRows.isEmpty {
                VStack(spacing: rowGap) {
                    ForEach(pinnedRows) { row($0.offset, $0.task) }
                }
                .padding(.horizontal, 14)
                .padding(.top, 4)
                .padding(.bottom, collapsibleRows.isEmpty ? 14 : 0)
            }

            if expanded && !collapsibleRows.isEmpty {
                ScrollView {
                    VStack(spacing: rowGap) {
                        ForEach(collapsibleRows) { row($0.offset, $0.task) }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, pinnedRows.isEmpty ? 4 : 0)
                    .padding(.bottom, 14)
                }
                .frame(maxHeight: min(CGFloat(collapsibleRows.count), maxVisibleRows) * (approxRowHeight + rowGap))
            }
        }
        .background(VolarColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(VolarColor.border, lineWidth: 0.5)
        )
    }

    /// Same insert/remove transition the old flat list used for every `TaskRow` — new rows drop in
    /// from just above, removed rows fade out and settle slightly smaller. Local to this struct
    /// (rather than shared from `TodayView`) since this is the only place a `TaskRow` `ForEach`
    /// still lives after the retheme.
    private var rowTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: -6)),
            removal: .opacity.combined(with: .scale(scale: 0.97))
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            // List v2 (design.md §5.4): 11pt/.semibold/uppercase/tracking+0.5/`textSec`.
            Text(title.uppercased())
                .font(Font.volarMono(size: 11, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(VolarColor.textSec)
            Text("\(tasks.count)")
                .font(Font.volarMono(size: 11))
                .foregroundStyle(VolarColor.textMut)
            Spacer()
            Button {
                withAnimation(VolarMotion.hover) { expanded.toggle() }
            } label: {
                Text(expanded ? "Hide" : "Show")
                    .font(Font.volarMono(size: 11, weight: .medium))
                    .foregroundStyle(VolarColor.textSec)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(VolarColor.surfaceHi)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(VolarColor.borderHi, lineWidth: 0.5)
            )
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }
}

/// T043 (phase6-contract.md §C): the ambient "needs review" surface for the AI-delegation
/// orchestrator — resurfaced delegations whose check-back came due
/// (`AppState.dueDelegationRechecks`, refreshed off a minute-scale timer/app activation;
/// constitution I: an ordinary in-app card, NEVER a system notification), the one-tap
/// ambiguous-`ai-done`-signal disambiguation card (`AppState.pendingDisambiguationTaskIDs`,
/// mirroring `AppLinkHandler.pendingDisambiguation`), and a gentle dismissible soft-limit hint once
/// too many delegations are in flight at once. Self-contained (reads `appState` via environment) so
/// `TodayView.mainColumn` only has to decide WHERE it sits. Renders zero height when there's
/// nothing to show — never a permanent fixture (constitution V, glance-and-dismiss).
private struct DelegationAmbientSection: View {
    @Environment(AppState.self) private var appState: AppState
    /// Session-local dismiss (not persisted): "gentle, dismissible" per the contract, not "never
    /// show again forever" — a genuinely large WIP count is worth re-surfacing on a fresh session.
    @State private var wipHintDismissed = false

    private static let wipSoftLimit = 4

    private var wipCount: Int { appState.delegation?.wipCount() ?? 0 }

    private var dueTasks: [TaskItem] {
        appState.dueDelegationRechecks.compactMap { id in appState.tasks.first { $0.id == id } }
    }

    private var disambiguationCandidates: [TaskItem] {
        appState.pendingDisambiguationTaskIDs.compactMap { id in appState.tasks.first { $0.id == id } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if wipCount > Self.wipSoftLimit, !wipHintDismissed {
                softLimitHint
            }
            if !disambiguationCandidates.isEmpty {
                disambiguationCard
            }
            ForEach(dueTasks) { task in
                needsReviewCard(task)
            }
        }
    }

    // MARK: - Soft-limit hint

    private var softLimitHint: some View {
        HStack(spacing: 10) {
            VolarIcon(.bolt, size: 12, color: VolarColor.instrument, weight: .semibold)
            (
                Text("\(wipCount)").font(Font.volarMono(size: 12.5).monospacedDigit())
                + Text(" tasks are out with Claude right now — review before delegating more?")
                    .font(.system(size: 12.5))
            )
                .foregroundStyle(VolarColor.textSec)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button {
                wipHintDismissed = true
            } label: {
                VolarIcon(.x, size: 9, color: VolarColor.textMut)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(VolarColor.instrumentDim.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(VolarColor.instrumentDim, lineWidth: 0.5)
        )
    }

    // MARK: - Disambiguation (`ai-done` matched more than one waiting task)

    private var disambiguationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("An AI run finished — which task was it?")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(VolarColor.textPri)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(disambiguationCandidates) { task in
                    Button {
                        appState.resolveAppLinkDisambiguation(taskId: task.id)
                    } label: {
                        Text(task.title)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(VolarColor.textPri)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 9)
                            .frame(height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(VolarColor.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(VolarColor.border, lineWidth: 0.5)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            }
            Button("None of these") {
                appState.dismissAppLinkDisambiguation()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(VolarColor.textMut)
        }
        .padding(12)
        .background(VolarColor.card)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(VolarColor.instrumentDim, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Needs-review card ([Done] / [Still waiting] / [Check later])

    private func needsReviewCard(_ task: TaskItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                VolarIcon(.clock, size: 11, color: VolarColor.instrument, weight: .semibold)
                Text("Check-in: \(task.title)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(VolarColor.textPri)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            HStack(spacing: 8) {
                ambientButton("Done", solid: true) { appState.resolveDelegationDone(task.id) }
                ambientButton("Still waiting") { appState.resolveDelegationStillWaiting(task.id) }
                ambientButton("Check later") { appState.resolveDelegationCheckLater(task.id) }
            }
        }
        .padding(12)
        .background(VolarColor.card)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(VolarColor.border, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func ambientButton(_ title: String, solid: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(solid ? Color.white : VolarColor.textPri)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(solid ? VolarColor.instrument : VolarColor.surfaceHi)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(solid ? Color.clear : VolarColor.borderHi, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - 006-cues-and-waiting: cue reminder + waiting-mode holder (T5, wire UI)
//
// Both rows below share `DelegationAmbientSection`'s own card shell (`VolarColor.card` +
// `VolarColor.border` hairline, 8pt corner radius) so the three ambient surfaces in this file read
// as one family, not three competing styles. Neither row carries an icon/color the way
// `softLimitHint`/`needsReviewCard` above do — design.md §3's anti-shame/anti-nag rule ("Cấm đỏ,
// cấm badge... giọng chữ điềm tĩnh") is why this is plain text with no accent tint at all, closer
// to `SweepView`'s calm copy than to an instrument-tinted status card.

/// `AppState.cueBanner`, read back verbatim — design.md §2 Việc B: "hiện đúng MỘT việc, kèm trích
/// NGUYÊN VĂN lời user." Never renders `CueKind`/`kind` (`CueBanner` itself doesn't even carry
/// one — see that struct's own doc comment) — only `verbatim`, plus a date-aware lead-in so the
/// copy never overclaims ("Tối qua anh nói…" only when `createdAt` really was yesterday).
private struct CueReminderRow: View {
    let banner: CueBanner

    /// UNVERIFIED (product-phrasing judgment call, not a Mac-only concern): design.md §2's own
    /// worked example is fixed as "Tối qua anh nói…", which reads naturally for the common case
    /// this cue exists for (say it near bedtime, `.wake` fires on the next ≥6h-gap session — almost
    /// always the next morning). But a cue can sit unfired for up to `TaskCue.expiresAt`'s 48h floor,
    /// so a literal "Tối qua" would be a false claim outside that common case. This checks the real
    /// day relationship instead of hardcoding the phrase, falling back to a time-neutral "Anh nói…"
    /// whenever "last night" isn't actually true — never a bug fix Mac verification would catch (no
    /// crash either way), just a calm-voice-accuracy call flagged for review.
    private var leadIn: String {
        Calendar.current.isDateInYesterday(banner.createdAt) ? "Tối qua anh nói" : "Anh nói"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(leadIn): \u{201C}\(banner.verbatim)\u{201D}")
                .font(.system(size: 12.5))
                .foregroundStyle(VolarColor.textSec)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(VolarColor.card)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(VolarColor.border, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// `AppState.waitingModeDecision`, read as one calm line — design.md §2 Việc C: "một dòng điềm
/// tĩnh: mốc đang được giữ + thời gian còn lại." Three distinct phrasings, matching
/// `WaitingMode.Decision.suggestedTaskId`'s own doc comment on why the "anchor is itself eligible"
/// case is NOT the same thing as "nothing fits":
///   - anchor is itself actionable right now (`anchorIsEligible`) → just the hold line, no second
///     suggestion (suggesting a substitute against the user's own deadline is the exact bug
///     `WaitingMode.swift`'s header comment documents fixing).
///   - a task fits the remaining time → name it, as an invitation ("Có thể tranh thủ…"), never an
///     instruction.
///   - nothing fits → say so plainly ("Chưa có việc nào khít") and stop — design.md §2: "không ép."
private struct WaitingModeRow: View {
    let decision: WaitingMode.Decision
    let suggestedTitle: String?

    private var lineText: String {
        let time = decision.anchorAt.formatted(.dateTime.hour().minute())
        let holding = "Đang giữ mốc \u{201C}\(decision.anchorTitle)\u{201D} lúc \(time) — còn \(decision.minutesUntil) phút."
        if decision.anchorIsEligible {
            return holding
        }
        guard let suggestedTitle else {
            return holding + " Chưa có việc nào khít."
        }
        return holding + " Có thể tranh thủ \u{201C}\(suggestedTitle)\u{201D}."
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(lineText)
                .font(.system(size: 12.5))
                .foregroundStyle(VolarColor.textSec)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(VolarColor.card)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(VolarColor.border, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
