// Sources/Views/CommandBar.swift — ⌘K command bar ("Volar Graphite" pass, design-spec §4.2)
//
// Cursor-style typed-task entry: a single input floating over the main window's content, opened
// with ⌘K (in-app `.keyboardShortcut`, wired in `VolarApp.swift` — NOT a global hotkey; the
// existing ⌃⌥M/⌃⌥T Carbon hotkeys in `Sources/Speech/HotkeyManager.swift` are untouched), dismissed
// with Esc. It is a dependency-free ALTERNATE ENTRY POINT into typed capture, not a new capture
// pipeline: "no speech, can't/won't speak right now" already has a surface —
// `Sources/Views/TextCapturePanel.swift`'s ⌃⌥T popup — and this reuses that surface's exact save
// path rather than re-deriving it. Presented as a plain, flat panel (design-spec §1.5 "phẳng là mặc
// định" — no `volarGlass`, this is not a surface floating over the desktop, it lives inside the
// main window) rather than a `.sheet`, so it never dims the content behind it into a modal.
//
// THE REUSE (self-review point 1 of this task's brief): `TextCaptureView.fieldRow`'s `.onSubmit`
// (`TextCapturePanel.swift`) does exactly two things — writes the typed string into
// `appState.textCaptureInput`, then calls `appState.submitTextCapture()`. That single method
// already owns the entire parse → (simple case: save immediately via the SAME `confirmSave()` the
// voice flow uses) / (complex case: hand off to the shared confirm-card review) pipeline — see
// `AppState.submitTextCapture()`'s own doc comment in `AppState.swift` for the full chain. This
// view calls that identical pair (`submit()` below) instead of touching `router`/`IntentRouter` or
// writing any parse/save logic of its own.
//
// WHY THIS VIEW CLOSES ITSELF THE INSTANT IT SUBMITS, RATHER THAN LINGERING TO SHOW ITS OWN
// Saving…/Added "…"/error STATE THE WAY `TextCaptureView` DOES: `submitTextCapture()` mutates
// `appState.textCapture` (`.editing` unused here → straight to `.saving` → `.saved`/`.failed`),
// and `VolarApp.swift`'s `AppDelegate.syncTextCapturePanel()` already mirrors THAT exact property,
// unconditionally, into a SEPARATE floating `NSPanel` (the ⌃⌥T popup's own window) any time
// `textCapture != .closed`. If this view also stayed open and rendered a second copy of that same
// state, the user would see two surfaces reporting one save at once. Instead: `submit()` closes the
// command bar synchronously — before `syncTextCapturePanel()`'s own deferred `Task { @MainActor in
// ... }` hop (see that method's doc comment for why it's deferred a run-loop turn) ever gets to run
// — and the existing floating panel takes over showing the rest of the flow exactly as it already
// does for ⌃⌥T. This reuses 100% of already-built feedback UI instead of a second copy of it, and
// is the reason `AppState`'s `showCommandBar` flag (added for this task) is presentation-only and
// never forks `textCapture`'s own state machine.
import SwiftUI

struct CommandBar: View {
    @Environment(AppState.self) private var appState: AppState

    /// UNVERIFIED (blind Swift, no Xcode on this machine — flagged per task brief): auto-focusing a
    /// `TextField` the moment a *conditionally-inserted SwiftUI overlay* (`if appState.showCommandBar
    /// { CommandBar() }` in `VolarApp.swift`) mounts has a DIFFERENT risk profile than
    /// `TextCaptureView`'s own `@FocusState` auto-focus: that view is hosted by a borderless
    /// `NSPanel` that is explicitly made key (`NSApp.activate` + `makeKeyAndOrderFront`, see
    /// `CapturePanelController.show()`) BEFORE SwiftUI mounts its content, guaranteeing the panel is
    /// already the key window when `.onAppear` fires. `CommandBar` has no such guarantee — it mounts
    /// inside the ALREADY-key main `Window` scene, so `.onAppear` setting `@FocusState = true` is
    /// relying on ordinary SwiftUI focus-system behavior for a view inserted via conditional overlay
    /// rather than window activation. Should work (this is the ordinary case `@FocusState` is built
    /// for), but has no precedent elsewhere in this codebase to point to — verify on a real Mac.
    @FocusState private var fieldFocused: Bool
    @State private var input: String = ""

    private let width: CGFloat = 560

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Type a task, or press ⌃⌥M to speak", text: $input)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(VolarColor.textPri)
                .focused($fieldFocused)
                .onSubmit(submit)

            hintRow
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: width)
        .background(VolarColor.surfaceHi)
        // `strokeBorder` (not `stroke`) is required here: `.stroke` centers the line on the
        // shape's path, so half its weight falls OUTSIDE the rounded rect and gets cut away by
        // the `.clipShape` below, rendering at half the intended weight. `strokeBorder` draws
        // entirely INSIDE the path, so the following clip can't eat any of it.
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(VolarColor.borderHi, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 24, x: 0, y: 14)
        .shadow(color: .black.opacity(0.30), radius: 4, x: 0, y: 1)
        // Esc carried by an invisible `.cancelAction`-bound button, same trick
        // `TextCaptureView.escCancelButton` uses — a zero-size button gives the hint row's "Esc"
        // copy below a REAL keyboard shortcut without adding any visible chrome of its own.
        .background(escCloseButton)
        .onAppear {
            // Fresh draft every time the bar opens (mirrors `AppState.openTextCapture()` resetting
            // `textCaptureInput = ""` on open) — `input` is local to this view instance, and a new
            // instance is what `if appState.showCommandBar { CommandBar() }` creates each time the
            // flag flips true, so this only ever runs on a genuine (re-)open, never mid-session.
            input = ""
            fieldFocused = true
        }
    }

    // MARK: - Hint row — single quiet line, `KeyBadge` chips reused verbatim from
    // `Sources/Views/Components.swift` (not re-derived — self-review point 1 of this task's brief
    // applies to `KeyBadge` too, not just `submitTextCapture()`).

    private var hintRow: some View {
        HStack(spacing: 6) {
            KeyBadge("⏎")
            Text("Add task").foregroundStyle(VolarColor.textMut)
            Text("·").foregroundStyle(VolarColor.textMut).opacity(0.5)
            KeyBadge("Esc")
            Text("Close").foregroundStyle(VolarColor.textMut)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(VolarColor.textMut)
    }

    private var escCloseButton: some View {
        Button("") { appState.closeCommandBar() }
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    // MARK: - Submit

    /// Return inside the field. Empty input closes the bar WITHOUT touching `submitTextCapture()`
    /// at all (design-spec brief: "Empty input on Return = dismiss, not a save") — deliberately not
    /// relying on `submitTextCapture()`'s own empty-string guard for this, since that guard just
    /// no-ops and leaves the bar sitting open with nothing typed, not the "dismiss" behavior asked
    /// for here.
    private func submit() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            appState.closeCommandBar()
            return
        }
        // THE REUSE: identical two-step `TextCaptureView.fieldRow`'s `.onSubmit` performs —
        // populate `textCaptureInput`, call `submitTextCapture()`. See this file's header comment
        // for why closing the bar happens BEFORE `submitTextCapture()` mutates `textCapture` (it
        // doesn't strictly have to happen first for correctness — the floating panel's own re-sync
        // is deferred a run-loop turn regardless — but closing first keeps the ordering obviously
        // safe rather than relying on that deferral).
        appState.closeCommandBar()
        appState.textCaptureInput = trimmed
        appState.submitTextCapture()
    }
}
