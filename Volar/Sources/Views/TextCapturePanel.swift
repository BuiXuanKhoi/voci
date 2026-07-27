// Sources/Views/TextCapturePanel.swift — typed equivalent of PopoverView's voice capture (⌃⌥T)
//
// THE ASK (verbatim intent, task brief): "You're working on one screen, you suddenly remember a
// task, you hit a hotkey → a small text-input popup appears, you type it, hit Add task, and it
// becomes a task. Done." Voice capture (⌃⌥M, `PopoverView.swift`) already does this by speaking —
// this is the typed equivalent, for a meeting/café/open-plan office where speaking out loud isn't
// an option. It is the SAME capture pipeline (`AppState.submitTextCapture()` calls the exact same
// `router.parse` + `confirmSave()` the voice flow uses — see that method's doc comment) with a
// different input method and, deliberately, WITHOUT the confirm-card review pause: "type → Add
// task → done", not "type → review chips → save".
//
// Visual language is intentionally NOT a new one — same `VolarColor` tokens, corner radii,
// `volarGlass`/hairline treatment, spacing rhythm, and button styling as `PopoverView.swift`'s
// `actionsRow`/`errorActionsRow`, reused directly rather than re-derived. Hosted by its own
// `CapturePanelController` instance (`Sources/Views/CapturePanel.swift`), wired up in
// `VolarApp.swift` — see that file for the mutual-exclusion wiring against the voice popover.
import SwiftUI

/// Renders off `AppState.textCapture` (`AppState.swift`) — `.closed` is never actually visible
/// (the panel itself is hidden/ordered-out for that state by `AppDelegate`'s sync method; see
/// `VolarApp.swift`), but this view still renders SOMETHING sane for it (falls in with `.editing`
/// below) rather than assuming it can never be asked to.
struct TextCaptureView: View {
    @Environment(AppState.self) private var appState: AppState
    /// UNVERIFIED: auto-focusing a `TextField` via `@FocusState` the moment a borderless,
    /// non-activating `NSPanel`'s content is mounted has no existing precedent in this codebase —
    /// `PopoverView.swift` has no text field at all (its confirm-card title edit is a separate,
    /// already-visible-panel interaction, not an auto-focus-on-appear one). `CapturePanelController
    /// .show()` (`CapturePanel.swift`) already calls `NSApp.activate(ignoringOtherApps: true)` +
    /// `panel.makeKeyAndOrderFront(nil)` BEFORE SwiftUI mounts this view's content, so the panel
    /// should already be the key window by the time `.onAppear` runs below — which SHOULD be
    /// sufficient for `@FocusState = true` to actually place the caret without an extra click, but
    /// this has never been exercised on a real Mac from this machine. Verify at
    /// `docs/mac-verify-checklist.md`'s new section.
    @FocusState private var fieldFocused: Bool
    @State private var mounted = false

    private let width: CGFloat = 380

    var body: some View {
        let accent = appState.accent.accent

        VStack(alignment: .leading, spacing: 0) {
            hintRow(accent: accent)

            VStack(alignment: .leading, spacing: 10) {
                if case .saved(let titles) = appState.textCapture {
                    savedRow(titles)
                        .transition(.opacity)
                } else {
                    fieldRow
                        .transition(.opacity)

                    if case .failed(let message) = appState.textCapture {
                        Text(message)
                            .font(.system(size: 12))
                            .foregroundStyle(VolarColor.reschedule)
                            .lineLimit(2)
                            .transition(.opacity)
                    }

                    actionsRow(accent: accent)
                        .transition(.opacity)
                }
            }
            .padding(.top, 10)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(width: width)
        .volarGlass(level: .heavy, cornerRadius: 18)
        .shadow(color: .black.opacity(0.55), radius: 30, x: 0, y: 24)
        .scaleEffect(mounted ? 1 : 0.96)
        .opacity(mounted ? 1 : 0)
        .animation(VolarMotion.state, value: appState.textCapture)
        .onAppear {
            // Appear animation — same 0.96 -> 1 + fade spring `PopoverView` uses on its own
            // `.onAppear`, for visual consistency between the two capture surfaces.
            withAnimation(.spring(response: 0.2, dampingFraction: 0.86)) {
                mounted = true
            }
            fieldFocused = true
        }
        .onChange(of: appState.textCapture) { _, newValue in
            // `.onAppear` above only fires once per panel SHOW (`CapturePanelController.show()`,
            // not `presentOrRefit()`'s already-visible re-fit branch) — a `.failed -> .editing`
            // transition happening WITHIN one open (user dismisses the error copy and starts typing
            // the fix) needs its own re-focus trigger, since the panel itself never re-appears for
            // that transition. `AppState.submitTextCapture()`'s failure path deliberately never
            // resets `textCapture` back to `.editing` on its own (see that method's doc comment —
            // it stays `.failed` until the user acts), so this only fires for a genuine explicit
            // "try again" moment, never as a side effect of the failure itself.
            if newValue == .editing {
                fieldFocused = true
            }
        }
    }

    private var isBusy: Bool { appState.textCapture == .saving }

    private var isEmptyInput: Bool {
        appState.textCaptureInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Hint row (mirrors PopoverView.hintRow's "Esc cancel" affordance)

    private func hintRow(accent: Accent) -> some View {
        HStack(alignment: .center) {
            leftHint(accent: accent)
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                KeyBadge("Esc")
                Text("cancel").opacity(0.6)
            }
            .foregroundStyle(VolarColor.textMut)
        }
        .font(.system(size: 11.5))
        .background(escCancelButton)
    }

    /// Same "invisible `.cancelAction`-bound button carries the Esc shortcut" trick
    /// `PopoverView.escCancelButton` uses, for the identical reason: the hint row's "Esc cancel"
    /// copy needs a REAL keyboard shortcut behind it on every state (including `.saved`, which
    /// renders no other button at all) — a zero-size, invisible button carries it instead of
    /// adding new visible chrome.
    private var escCancelButton: some View {
        Button("") { appState.cancelTextCapture() }
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func leftHint(accent: Accent) -> some View {
        switch appState.textCapture {
        case .closed, .editing:
            Text("Add a task").foregroundStyle(VolarColor.textMut)
        case .saving:
            Text("Saving…").foregroundStyle(accent.solid)
        case .saved:
            Text("Saved").foregroundStyle(VolarColor.done)
        case .failed:
            Text("Didn't catch that").foregroundStyle(VolarColor.reschedule)
        }
    }

    // MARK: - Field

    /// The one-line-ish text field. `.onSubmit` (Return inside the field itself) AND the "Add
    /// task" button's own `.keyboardShortcut(.defaultAction)` below both route to
    /// `submitTextCapture()` — SwiftUI's focus/first-responder rules mean only one of the two
    /// actually fires for a given Return keypress (whichever currently has focus/is the default
    /// action), but wiring both is what makes Return "just work" regardless of whether focus is
    /// still in the field or has moved to the button, matching the task brief's "type → Add task →
    /// done" in one keystroke.
    private var fieldRow: some View {
        TextField(
            "What needs doing?",
            text: Binding(
                get: { appState.textCaptureInput },
                set: { appState.textCaptureInput = $0 }
            )
        )
        .textFieldStyle(.plain)
        .font(.system(size: 14))
        .foregroundStyle(VolarColor.textPri)
        .focused($fieldFocused)
        .disabled(isBusy)
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(VolarColor.card)
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(VolarColor.border, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onSubmit {
            appState.submitTextCapture()
        }
    }

    // MARK: - Actions (mirrors PopoverView.actionsRow's Save-button styling — solid accent fill,
    // spinner while busy, "↵" glyph, disabled state)

    private func actionsRow(accent: Accent) -> some View {
        Button {
            appState.submitTextCapture()
        } label: {
            Group {
                if isBusy {
                    Spinner(color: accent.solid, size: 14)
                } else {
                    HStack(spacing: 8) {
                        Text("Add task")
                        Text("↵").opacity(0.85).font(.system(size: 12))
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 34)
        }
        .buttonStyle(.plain)
        .background(isBusy ? accent.surface : accent.solid)
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(isBusy ? accent.surface : VolarColor.veil(0.18), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .shadow(color: isBusy ? .clear : accent.glow, radius: 10, x: 0, y: 4)
        // Disabled while empty (nothing typed yet) OR while a save is already in flight — matches
        // the task brief exactly ("Disabled while the field is empty or while a save is in flight").
        .disabled(isBusy || isEmptyInput)
        .keyboardShortcut(.defaultAction)
    }

    // MARK: - Saved confirmation

    private func savedRow(_ titles: [String]) -> some View {
        Text(savedLabel(titles))
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(VolarColor.done)
            .frame(height: 34)
    }

    /// "Added "Buy milk"" for one task, "Added 3 tasks" for a compound utterance ("mua sữa và gọi
    /// mẹ" -> 2 tasks in one typed line) — mirrors `PopoverView`'s analogous singular/plural split
    /// in its own `saveLabel`/`finishSaveUI` spoken confirmation.
    private func savedLabel(_ titles: [String]) -> String {
        if titles.count == 1 {
            return "Added \u{201c}\(titles.first ?? "")\u{201d}"
        }
        return "Added \(titles.count) tasks"
    }
}
