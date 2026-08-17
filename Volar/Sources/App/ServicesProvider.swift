// Sources/App/ServicesProvider.swift — the macOS Services menu entry ("New Task in Volar").
//
// WHAT THIS BUYS (backlog "Đường vào Volar" [I2]): select text anywhere on the Mac — an email, a
// Slack message, a PR description, a PDF — right-click, "New Task in Volar". No window, no app
// switch, no retyping. This is the cheapest possible capture surface: the OS draws the menu, the OS
// delivers the text, and Volar adds one class and one Info.plist array.
//
// WHY THIS IS SCREEN-PRESENT, AND THEREFORE CONFIRM-CARD-GATED: the user just right-clicked. Their
// eyes are on the screen, one glance costs a second, and a mis-parsed date is catchable. That is
// the opposite of the Siri/Shortcuts case (`Shared/Intents/`), which reads the parse back aloud
// because nobody is looking. Same rule, different channel — see `IntentBridge.swift`'s header.
//
// SO THIS ROUTES THROUGH `AppLinkHandler.onCapture`, exactly as `docs/app-links.md` §`capture`
// already specifies for "the Services/share-extension path (FR-040)": that closure is wired in
// `AppState.init` to `proceedToCapture(transcript:)`, the same parser + confirm-card pipeline voice
// capture uses. Nothing about parsing, saving or confirming is re-implemented here — this file only
// gets text off a pasteboard and hands it over.
//
// UNVERIFIED: written on Windows with no Swift toolchain. Not compiled, not run. The Services menu
// in particular cannot be verified any other way — macOS only offers a service after the built app
// has been seen by `pbs` (the pasteboard server), which in practice means: build, run once, then
// look in another app's right-click menu. A stale registration is the normal failure mode; the fix
// is `/System/Library/CoreServices/pbs -flush` and a relaunch.
import AppKit
import Foundation

/// Receives text from the system Services menu.
///
/// `NSObject` subclass with an `@objc` method because the Services machinery dispatches by selector
/// name — the `NSMessage` string in `Info.plist`'s `NSServices` entry must match `captureText`
/// exactly, minus the argument labels. Renaming one without the other silently produces a menu item
/// that does nothing.
final class VolarServicesProvider: NSObject {

    /// Installs the provider and asks the OS to re-read this app's `NSServices` declaration.
    ///
    /// `NSUpdateDynamicServices()` is what makes a freshly-built app's service show up without a
    /// logout; without it the entry typically appears only after `pbs` next rescans on its own
    /// schedule, which is what makes this feature feel broken during development.
    ///
    /// The returned instance must be retained by the caller — `NSApplication.servicesProvider` is
    /// an `unowned(unsafe)`-style reference and does NOT keep the provider alive.
    /// `@MainActor` because `NSApplication.shared` is — under Swift 6 strict concurrency a
    /// nonisolated static function may not touch it. The only caller
    /// (`applicationDidFinishLaunching`) is already on the main actor, so this costs nothing.
    @discardableResult
    @MainActor
    static func install() -> VolarServicesProvider {
        let provider = VolarServicesProvider()
        NSApplication.shared.servicesProvider = provider
        NSUpdateDynamicServices()
        return provider
    }

    /// `NSMessage` = `captureText` in `Info.plist`.
    ///
    /// The signature (pasteboard, userData, error pointer) is fixed by the Services protocol; the
    /// `error` pointer is how a service reports failure back to the OS, which surfaces it to the
    /// user — so an empty selection says so rather than failing silently.
    @objc func captureText(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        guard let raw = pboard.string(forType: .string) else {
            error.pointee = "Volar couldn't read the selected text." as NSString
            return
        }
        // Same 2000-character ceiling `AppLinkHandler.handleCapture` imposes on `volar://capture`,
        // and for the same reason: a capture entry point must not be able to smuggle a larger
        // payload into the parse pipeline than the pipeline's own cap allows. Applied here rather
        // than trusting the seam, because a selection can trivially be a whole document.
        let text = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
        guard !text.isEmpty else {
            error.pointee = "Nothing was selected." as NSString
            return
        }

        // Services callbacks arrive on the main thread, but hop explicitly rather than assume it:
        // `AppState` is `@MainActor`-isolated and this method cannot be, since its selector shape is
        // dictated by AppKit.
        _Concurrency.Task { @MainActor in
            guard let app = AppState.shared else { return }
            // `source` is folded into the transcript by the closure itself (see `AppState.init`'s
            // CAPTURE SEAM comment) — it becomes the "(via …)" suffix the parser keeps as notes,
            // which is how a task remembers it came from a selection rather than a spoken sentence.
            app.appLinkHandler?.onCapture?(text, "Services")
        }
    }
}
