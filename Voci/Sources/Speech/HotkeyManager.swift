// Sources/Speech/HotkeyManager.swift — global ⌃⌥M toggle-to-talk hotkey (Carbon, sandbox-safe)
import Carbon.HIToolbox

/// Registers a system-wide "press ⌃⌥M to toggle capture (press to start, press again to stop)"
/// hotkey using Carbon's `RegisterEventHotKey`/`InstallEventHandler` — replaces the prior
/// `NSEvent.addGlobalMonitorForEvents` implementation (feature 002, research.md R3).
///
/// Why the switch: `NSEvent.addGlobalMonitorForEvents` only delivers events system-wide once the
/// user has granted **Accessibility** permission, which is unacceptable under Mac App Store
/// review + App Sandbox (Voci.entitlements now sets `com.apple.security.app-sandbox`).
/// `RegisterEventHotKey` is a first-class Carbon Event Manager API: sandbox-legal, needs no
/// permission prompt at all, and — unlike the old global+local monitor pair — fires uniformly
/// regardless of which app is frontmost, INCLUDING Voci itself. That means there is no equivalent
/// of the old "local monitor" needed here; one registration covers every case.
///
/// Public API and toggle semantics are UNCHANGED from the pre-Carbon version (commit ee75841):
/// same class name, same `start(appState:onKeyDown:onKeyUp:)` / `stop()` signatures, same ⌃⌥M
/// (Control+Option+M) toggle-to-talk behavior, same auto-repeat guard, same "onKeyUp is stored
/// but intentionally never invoked" behavior (toggle mode never needed it — see `handle` below).
/// `AppState` call sites (`AppState.activateServices()`, which calls `hotkey.start(appState: self)`
/// with no closures) are untouched.
///
/// UNVERIFIED (authored on a Windows machine with no Xcode/Carbon to compile against — verify on
/// Mac): `import Carbon.HIToolbox` availability/name, `EventHandlerUPP`'s exact Swift-imported
/// closure signature, `EventTypeSpec`'s memberwise-init argument labels, whether
/// `GetApplicationEventTarget()`/`GetEventKind()` return optionals, and that none of the Carbon
/// Event Manager hot-key APIs used here are deprecated-and-removed on the macOS 14 SDK floor (they
/// are old but, per research R3, still the only sandbox-legal system-wide hotkey mechanism as of
/// this writing).
@MainActor
final class HotkeyManager {
    // MARK: - Hotkey identity (⌃⌥M — Control+Option+M, same combo as before)

    /// `kVK_ANSI_M` = 46, the same raw key code the previous `NSEvent`-based implementation used.
    private static let hotkeyKeyCode = UInt32(kVK_ANSI_M)
    /// Carbon's legacy Menu-Manager-style modifier bitmask (`controlKey`/`optionKey` from
    /// `<HIToolbox/Events.h>`), NOT `NSEvent.ModifierFlags` — a different constant space than the
    /// old implementation used, but the same physical combo (Control+Option).
    private static let hotkeyModifiers = UInt32(controlKey | optionKey)
    /// Four-char-code "app signature" + a local id, just a tag Carbon uses to identify which
    /// hotkey fired (only one is ever registered by this class, but the ID is still required by
    /// the API and is useful for defensively verifying the event in `handleCarbonEvent`).
    private static let hotkeyID = EventHotKeyID(signature: fourCharCode("Voci"), id: 1)

    /// Packs up to 4 ASCII characters into the `OSType`/`FourCharCode` Carbon expects for a
    /// hotkey signature — a plain arithmetic helper, no Carbon API involved.
    private static func fourCharCode(_ s: String) -> UInt32 {
        var result: UInt32 = 0
        for scalar in s.unicodeScalars.prefix(4) {
            result = (result << 8) | (scalar.value & 0xFF)
        }
        return result
    }

    // MARK: - Carbon handles (torn down in `stop()` and mirrored in `deinit`)

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    /// The `Unmanaged.passRetained(self)` pointer handed to Carbon as `userData` so the
    /// C-function-pointer callback (which cannot capture Swift context) can recover `self`.
    /// Retained on `start()`, released on `stop()`/`deinit` — the only way this class avoids
    /// either a dangling pointer (if released too early) or a retain-cycle-shaped leak (if never
    /// released at all).
    private var retainedSelfPointer: UnsafeMutableRawPointer?

    private var isDown = false
    private var onKeyDown: (() -> Void)?
    private var onKeyUp: (() -> Void)?
    /// Stored (weak) because the Carbon callback only receives `self` via `userData` — unlike the
    /// old NSEvent-monitor closures, it has no way to also capture `appState` directly, so
    /// `start()` now stashes it here instead. Weak to avoid `HotkeyManager` keeping `AppState`
    /// alive (matches the old code's `[weak appState]` capture).
    private weak var appState: AppState?

    /// Starts monitoring for ⌃⌥M. `appState.toggleCapture()` is called directly on key-down;
    /// `onKeyDown`/`onKeyUp` let the owner additionally drive `SpeechCapture` without
    /// `HotkeyManager` needing to know that type (`onKeyUp` is accepted for API compatibility but
    /// — same as before Carbon — is never actually invoked; toggle mode has no use for key-up).
    /// Safe to call again without a prior `stop()` — any existing registration is torn down first.
    func start(appState: AppState, onKeyDown: (() -> Void)? = nil, onKeyUp: (() -> Void)? = nil) {
        stop()
        self.appState = appState
        self.onKeyDown = onKeyDown
        self.onKeyUp = onKeyUp

        let selfPointer = Unmanaged.passRetained(self).toOpaque()
        retainedSelfPointer = selfPointer

        // One handler covers both press and release so `isDown` bookkeeping (auto-repeat guard,
        // same as the old code) still works; `handleCarbonEvent` reads the event *kind* to tell
        // them apart instead of relying on separate callbacks.
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        var handlerRef: EventHandlerRef?
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            HotkeyManager.carbonEventHandler,
            2,
            &eventTypes,
            selfPointer,
            &handlerRef
        )
        guard installStatus == noErr else {
            print("[Voci.HotkeyManager] InstallEventHandler failed: status \(installStatus)")
            Unmanaged<HotkeyManager>.fromOpaque(selfPointer).release()
            retainedSelfPointer = nil
            return
        }
        eventHandlerRef = handlerRef

        var registeredHotKeyRef: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            Self.hotkeyKeyCode,
            Self.hotkeyModifiers,
            Self.hotkeyID,
            GetApplicationEventTarget(),
            0,
            &registeredHotKeyRef
        )
        guard registerStatus == noErr else {
            print("[Voci.HotkeyManager] RegisterEventHotKey failed: status \(registerStatus)")
            // Roll back the handler + retained pointer so a failed start never leaves dangling
            // Carbon state or a leaked retain behind.
            RemoveEventHandler(handlerRef)
            eventHandlerRef = nil
            Unmanaged<HotkeyManager>.fromOpaque(selfPointer).release()
            retainedSelfPointer = nil
            return
        }
        hotKeyRef = registeredHotKeyRef
    }

    /// Unregisters the hotkey, removes the event handler, and releases the retained `self`
    /// pointer handed to Carbon — clears all in-progress hold state. Idempotent: safe to call
    /// when nothing is registered (e.g. a repeated `stop()`, or a `start()` that failed partway).
    func stop() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
        eventHandlerRef = nil
        if let retainedSelfPointer {
            Unmanaged<HotkeyManager>.fromOpaque(retainedSelfPointer).release()
        }
        retainedSelfPointer = nil
        isDown = false
        onKeyDown = nil
        onKeyUp = nil
        appState = nil
    }

    /// Mirrors `stop()`'s Carbon teardown for the case where this instance is deallocated without
    /// an explicit `stop()` call. Deliberately does NOT call `stop()` itself: `stop()` is
    /// `@MainActor`-isolated (the whole class is), and Swift does not allow synchronously calling
    /// an isolated method from a nonisolated `deinit`. Direct stored-property access is fine here
    /// per Swift's deinit exception (no concurrent access can race a deinitializing instance), and
    /// `UnregisterEventHotKey`/`RemoveEventHandler`/`Unmanaged.release()` are plain C calls with no
    /// actor isolation of their own — so this stays within what a nonisolated deinit can do.
    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
        if let retainedSelfPointer {
            Unmanaged<HotkeyManager>.fromOpaque(retainedSelfPointer).release()
        }
    }

    /// Same logic as the pre-Carbon `handle(keyCode:modifiers:isKeyDown:appState:)`, minus the
    /// keyCode/modifiers checks — Carbon only ever calls back for the exact combo registered in
    /// `start()`, so there is nothing left to filter here.
    private func handle(isKeyDown: Bool) {
        guard let appState else { return }
        if isKeyDown {
            // Defensive: Carbon hot keys are not expected to redeliver `kEventHotKeyPressed` on
            // OS-level key-repeat the way raw `NSEvent .keyDown` did, but this guard costs
            // nothing and keeps the exact same anti-double-toggle behavior as before.
            guard !isDown else { return }
            isDown = true
            appState.toggleCapture() // toggle: press to start, press again to stop+parse
            onKeyDown?()
        } else {
            isDown = false
            // onKeyUp intentionally not invoked — matches pre-Carbon behavior: toggle mode has no
            // use for key-up, and AppState.activateServices() never passes a closure for it.
        }
    }

    /// The actual Carbon callback. Must be a context-free `@convention(c)` function (or, as here,
    /// a closure literal with no captures assigned to a `static let` of the matching type) since
    /// Carbon invokes it as a raw C function pointer — it cannot capture `self`. `self` instead
    /// travels through `userData`, using the `Unmanaged` retained-pointer pattern set up in
    /// `start()`. Recovers the event kind (pressed vs. released) directly from the event via
    /// `GetEventKind`, then hops to `@MainActor` — same `Task { @MainActor in ... }` pattern the
    /// pre-Carbon `NSEvent` monitor closures used to cross from a non-actor-isolated callback
    /// context into `HotkeyManager`'s (and `AppState`'s) MainActor-isolated state.
    private static let carbonEventHandler: EventHandlerUPP = { _, eventRef, userData in
        guard let eventRef, let userData else { return noErr }
        let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
        let isKeyDown = GetEventKind(eventRef) == UInt32(kEventHotKeyPressed)
        Task { @MainActor in
            manager.handle(isKeyDown: isKeyDown)
        }
        return noErr
    }
}
