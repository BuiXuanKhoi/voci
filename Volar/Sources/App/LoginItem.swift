// Sources/App/LoginItem.swift — thin wrapper over `ServiceManagement`'s `SMAppService.mainApp`,
// the macOS 13+ API for registering/unregistering "Volar launches at login" (replaces the old
// deprecated `SMLoginItemSetEnabled`/`LSSharedFileList` approach entirely).
//
// SOURCE OF TRUTH: `SMAppService.mainApp.status`, read fresh every time, NOT a UserDefaults
// mirror. The user can flip this off from System Settings ▸ General ▸ Login Items at any moment,
// entirely behind the app's back — a cached UserDefaults copy would go stale the instant that
// happens and keep telling `SettingsView` "ON" when the OS already turned it off. Every read in
// this file (and in `SettingsView`) MUST go through `status`/`isEnabled` live, never through a
// stored property.
//
// Deployment target is macOS 14.0 (`Info.plist`'s `LSMinimumSystemVersion`) and `SMAppService` has
// existed since macOS 13.0, so no `@available` guard is needed anywhere in this file.
import AppKit
import ServiceManagement

/// `@MainActor` because `SettingsView` (this file's only caller) reads/writes it from its own
/// `@MainActor` view code, and `SMAppService`'s methods are synchronous, non-`Sendable`-sensitive
/// calls that don't need to hop off the main actor — no reason to introduce concurrency here.
@MainActor
enum LoginItem {
    /// Live status, straight from `SMAppService` — see this file's header comment for why this
    /// (and not a cached bool) is the only thing callers should trust.
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    /// `true` only for the fully-approved, fully-enabled state. Deliberately NOT `true` for
    /// `.requiresApproval` — that state means macOS has NOT actually started launching Volar at
    /// login yet (see `setEnabled(_:)`'s doc comment), so a toggle bound to `isEnabled` correctly
    /// reads OFF until the user approves it in System Settings.
    static var isEnabled: Bool { status == .enabled }

    /// Registers or unregisters Volar as a login item. Both `register()`/`unregister()` are
    /// synchronous and throw on failure (e.g. sandbox/entitlement issues, or the user having just
    /// disabled it from System Settings in a way that makes re-registration transiently fail) —
    /// callers must catch and surface the error rather than assume success.
    ///
    /// IMPORTANT: after `register()` returns without throwing, `status` is commonly
    /// `.requiresApproval`, NOT `.enabled` — this is a real, ordinary state, not a failure. macOS
    /// shows a system notification ("Volar" added a login item) and the login item only actually
    /// starts firing once the user approves it in System Settings ▸ General ▸ Login Items. Callers
    /// must re-read `status` after calling this (never assume the call itself flipped it to
    /// `.enabled`) and handle `.requiresApproval` as its own UI state.
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// Deep-links straight to System Settings ▸ General ▸ Login Items, for the "Open Login
    /// Items…" affordance shown while `status == .requiresApproval`.
    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
