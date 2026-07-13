// Sources/Speech/HotkeyManager.swift — global ⌃⌥Space hold-to-talk hotkey monitor
import AppKit

/// Registers a system-wide "hold ⌃⌥Space to talk" hotkey using `NSEvent` global + local
/// monitors: key-down starts capture, key-up stops/finishes it (hold-to-talk, per
/// `app-architecture.md` §1).
///
/// IMPORTANT — macOS **Accessibility permission**: `NSEvent.addGlobalMonitorForEvents` only
/// delivers key events system-wide (i.e. while some *other* app is frontmost) once the user has
/// granted this app access under System Settings → Privacy & Security → Accessibility. Without
/// it, the *local* monitor still fires while a Voci window/menu is key, but the hold-to-talk
/// gesture silently does nothing from anywhere else on the system — there is no API to detect or
/// prompt for this ahead of time from a global monitor, so `start()` does not attempt to check or
/// request it. This gap is tracked in `backlog.md`.
@MainActor
final class HotkeyManager {
    private static let hotkeyKeyCode: UInt16 = 49 // kVK_Space
    private static let hotkeyModifiers: NSEvent.ModifierFlags = [.control, .option]

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isDown = false

    private var onKeyDown: (() -> Void)?
    private var onKeyUp: (() -> Void)?

    /// Starts monitoring for ⌃⌥Space. `appState.startCapture()` (frozen §4 API) is called
    /// directly on key-down; `onKeyDown`/`onKeyUp` let the owner (Phase-3 app wiring) additionally
    /// drive `SpeechCapture` without `HotkeyManager` needing to know that type. Safe to call again
    /// without a prior `stop()` — any existing monitors are torn down first.
    func start(appState: AppState, onKeyDown: (() -> Void)? = nil, onKeyUp: (() -> Void)? = nil) {
        stop()
        self.onKeyDown = onKeyDown
        self.onKeyUp = onKeyUp

        // NSEvent monitor handlers are invoked on the main thread, but their closure type isn't
        // known to the compiler to be MainActor-isolated. To stay correct under Swift 6 strict
        // concurrency we pull only `Sendable` primitives out of the (non-`Sendable`) `NSEvent`
        // synchronously, then hop onto `@MainActor` explicitly to touch `self`/`appState`.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self, weak appState] event in
            guard let self, let appState else { return }
            let keyCode = event.keyCode
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isKeyDown = event.type == .keyDown
            Task { @MainActor in
                self.handle(keyCode: keyCode, modifiers: modifiers, isKeyDown: isKeyDown, appState: appState)
            }
        }

        // Local monitor covers the case where Voci's own window/menu is key — global monitors
        // never see events while the sending app *is* the frontmost app.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self, weak appState] event in
            guard let self, let appState else { return event }
            let keyCode = event.keyCode
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isKeyDown = event.type == .keyDown
            Task { @MainActor in
                self.handle(keyCode: keyCode, modifiers: modifiers, isKeyDown: isKeyDown, appState: appState)
            }
            return event // never swallow the key — other views may still want it
        }
    }

    /// Removes both monitors and clears any in-progress hold state.
    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        isDown = false
        onKeyDown = nil
        onKeyUp = nil
    }

    private func handle(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isKeyDown: Bool, appState: AppState) {
        guard keyCode == Self.hotkeyKeyCode else { return }

        if isKeyDown {
            guard modifiers == Self.hotkeyModifiers else { return }
            guard !isDown else { return } // ignore key-repeat while held
            isDown = true
            appState.startCapture()
            onKeyDown?()
        } else {
            // Deliberately NOT re-checking modifiers on key-up: users routinely release ⌃/⌥ a
            // beat before Space, so the Space key-up often arrives with the modifiers already
            // gone. Requiring the full combo here would leave `isDown` stuck true and the
            // hold-to-talk recording running forever. Any Space key-up while a hold is active
            // ends the hold.
            guard isDown else { return }
            isDown = false
            onKeyUp?()
        }
    }
}
