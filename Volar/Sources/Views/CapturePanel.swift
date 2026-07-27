// Sources/Views/CapturePanel.swift — floating NSPanel host for the capture UI (voice + typed)
//
// THE BUG: Volar is a menu-bar (`LSUIElement`) app. The global ⌃⌥M hotkey works system-wide, but
// before this file existed the ONLY mount point for `PopoverView` was inside `TodayView`, gated on
// `appState.captureState != .idle`. Since the main window is normally CLOSED for a menu-bar app,
// pressing the hotkey while the window was closed recorded audio into a UI nobody could see.
//
// THE FIX: `CapturePanelController` owns a borderless, non-activating `NSPanel` that hosts
// arbitrary SwiftUI content via `NSHostingView`, floats above every Space/full-screen app, and is
// driven by whatever state its owner chooses to watch (originally, and still primarily,
// `appState.captureState` from `AppDelegate` — see `VolarApp.swift`).
//
// TWO INSTANCES (⌃⌥T typed-capture popup, added alongside `Sources/Views/TextCapturePanel.swift`):
// this controller no longer hardcodes `PopoverView` — `init(content:)` takes whatever `AnyView` the
// caller wants hosted, so `VolarApp.swift`/`AppDelegate` now owns TWO separate
// `CapturePanelController` instances, one hosting `PopoverView` (voice capture, unchanged) and one
// hosting `TextCaptureView` (typed capture, new). They are MUTUALLY EXCLUSIVE BY CONSTRUCTION, not
// by anything in this file: `AppDelegate.syncCapturePanel()` (the voice controller's driver) hides
// the voice panel whenever `appState.textCapture != .closed`, and `observeTextCaptureState()`'s
// analogous sync method only ever shows the text panel while that same condition holds — this file
// itself has no idea the other controller/panel exists and enforces nothing about their exclusion.
import SwiftUI
import AppKit

/// A borderless `NSPanel` returns `canBecomeKey == false` by default (AppKit's own docs call this
/// out for the `.borderless` style mask). Capture needs key status so `PopoverView`'s existing
/// `.keyboardShortcut(.cancelAction)` / `.keyboardShortcut(.defaultAction)` buttons (Esc / Return)
/// actually receive those events — this override is required, not cosmetic.
@MainActor
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Owns the floating capture panel end-to-end: construction, sizing, positioning, and show/hide.
/// One instance lives for the app's lifetime (created lazily by `AppDelegate` the first time it's
/// needed — see `VolarApp.swift`), never recreated per-capture, which is what makes
/// `isReleasedWhenClosed = false` below load-bearing rather than decorative.
@MainActor
final class CapturePanelController {
    /// Fallback size used only if `NSHostingView.fittingSize` ever returns a degenerate (zero)
    /// size — e.g. before the hosting view has been laid out once. ~460pt matches the task brief's
    /// documented escape hatch for "if `fittingSize` proves unreliable"; `PopoverView` itself is a
    /// fixed 380pt-wide card plus this file's own padding, so 460 comfortably fits it without
    /// clipping even before a real measurement is available.
    private static let fallbackWidth: CGFloat = 460
    private static let fallbackHeight: CGFloat = 200

    /// How far below the top of the screen's `visibleFrame` the panel's TOP edge sits, expressed
    /// as a fraction of screen height — "upper third" per the task brief.
    private static let topInsetFraction: CGFloat = 0.18

    private let panel: KeyablePanel
    private let hostingView: NSHostingView<AnyView>

    /// `content` is whatever the caller built — `AnyView(PopoverView().environment(appState))` for
    /// the voice-capture instance, `AnyView(TextCaptureView().environment(appState))` for the
    /// typed-capture instance (both call sites live in `VolarApp.swift`/`AppDelegate`, matching the
    /// `.environment(appState)` pattern used everywhere else `AppState` is injected). `AnyView`
    /// rather than a generic `<Content: View>` parameter because this controller's own stored
    /// properties (`hostingView`) need a single concrete, nameable type regardless of which content
    /// a given instance hosts — and `.environment(_:)`'s concrete return type is itself an
    /// unspeakable opaque type, so callers already have to erase to `AnyView` before this
    /// initializer would even see a nameable type to be generic over.
    init(content: AnyView) {
        let hosting = NSHostingView(rootView: content)
        self.hostingView = hosting

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.fallbackWidth, height: Self.fallbackHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // CRITICAL: without this, closing/`orderOut`-ing the panel and later reshowing it would
        // deallocate the backing `NSWindow` out from under `hostingView`/this controller and crash
        // on the next `show()`. There is exactly one panel instance for the app's lifetime; it is
        // only ever hidden (`orderOut`), never actually closed.
        panel.isReleasedWhenClosed = false
        // `.canJoinAllSpaces` + `.fullScreenAuxiliary` are what let the panel surface over a
        // full-screen app and on whatever Space the user is currently on; `.transient` keeps it
        // out of the Cmd+Tab / Mission Control window lists, matching a Spotlight-style utility
        // panel rather than a real document window.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = hosting
        self.panel = panel
    }

    /// Called by `AppDelegate` whenever `appState.captureState` changes to anything non-`.idle`.
    /// First call after construction (or after the panel was last hidden) does a full
    /// show: re-fit, reposition fresh (screen-with-mouse can change between captures), activate,
    /// take key. Subsequent calls while ALREADY visible (e.g. `.recording` -> `.parsing` ->
    /// `.parsed`, each a distinct `captureState` value that re-invokes this) only re-fit the
    /// panel's size to the new SwiftUI content — `PopoverView`'s parsed-task confirm card is much
    /// taller than the bare waveform, and `fittingSize` must be re-measured after every content
    /// change, not just once at construction. Deliberately does NOT reposition/reactivate on that
    /// path: re-stealing focus/refocusing on every capture-state tick (several times a second while
    /// parsing) would be disruptive, and the task brief's "recompute on every SHOW" only requires
    /// fresh positioning for an actual show, not for a same-session content resize.
    func presentOrRefit() {
        if panel.isVisible {
            fitToContent(anchorTopCenter: true)
        } else {
            show()
        }
    }

    private func show() {
        fitToContent(anchorTopCenter: false)
        reposition()
        // Deliberate trade-off: Volar is an accessory app (`LSUIElement`), so a borderless/
        // non-activating panel cannot reliably become key without the app itself being made
        // active first — without this call, Esc/Return would not consistently reach the panel.
        // This pulls focus away from whatever the user was typing into, exactly like Spotlight/
        // Raycast do when summoned — an accepted cost of a global-hotkey capture UI, not a bug.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Hides the panel without releasing it (see `isReleasedWhenClosed` above). Deliberately does
    /// NOT get called just because the panel loses key status — recording must survive the user
    /// clicking into another app; only an explicit return to `.idle` (cancel/save/error-dismissed)
    /// hides it. That wiring lives in `AppDelegate.syncCapturePanel()`, not here.
    func hide() {
        panel.orderOut(nil)
    }

    /// Re-measures `hostingView.fittingSize` and resizes the panel to match.
    ///
    /// UNVERIFIED: `NSHostingView.fittingSize` for a SwiftUI subtree that itself contains a
    /// `ScrollView`/`Menu`/custom `Layout` (`PopoverView`'s `FlowLayout` chip row, its dependency
    /// `Menu` picker) is not verified on this machine — no Swift toolchain/Xcode here to render
    /// and measure it. If it proves unreliable in practice (e.g. reports zero or an unstable
    /// value), the `fallbackWidth`/`fallbackHeight` constants above are the documented escape
    /// hatch this file already falls back to whenever the measurement comes back degenerate; a
    /// fully fixed size can be substituted by simply always taking that branch.
    private func fitToContent(anchorTopCenter: Bool) {
        let fitting = hostingView.fittingSize
        let width = fitting.width > 0 ? fitting.width : Self.fallbackWidth
        let height = fitting.height > 0 ? fitting.height : Self.fallbackHeight

        guard anchorTopCenter else {
            // Fresh show: exact origin doesn't matter here, `reposition()` runs immediately after
            // and fully recomputes it from the screen currently under the mouse.
            panel.setContentSize(NSSize(width: width, height: height))
            return
        }

        // Already-visible refit: keep the panel's top edge and horizontal center fixed while the
        // height/width change underneath, so a growing confirm card reads as "expanding downward
        // from the same anchored spot" rather than jumping to a new position.
        let old = panel.frame
        let top = old.maxY
        let centerX = old.midX
        let newFrame = NSRect(x: centerX - width / 2, y: top - height, width: width, height: height)
        panel.setFrame(newFrame, display: true)
    }

    /// Centers the panel horizontally on whichever screen currently contains the mouse pointer
    /// (falling back to `NSScreen.main` if that lookup somehow comes up empty — e.g. a display
    /// was just unplugged), and positions it vertically so its top edge sits `topInsetFraction`
    /// of that screen's `visibleFrame` height below the top — the "upper third" placement the
    /// task brief calls for. Recomputed from scratch on every `show()`, never cached, since the
    /// mouse (and therefore the target screen) can be anywhere by the next capture.
    private func reposition() {
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
        guard let screen = targetScreen else { return }

        let visible = screen.visibleFrame
        let size = panel.frame.size
        let originX = visible.midX - size.width / 2
        let topInset = visible.height * Self.topInsetFraction
        let originY = visible.maxY - topInset - size.height
        panel.setFrameOrigin(NSPoint(x: originX, y: originY))
    }
}
