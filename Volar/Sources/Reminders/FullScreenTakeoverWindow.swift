// Sources/Reminders/FullScreenTakeoverWindow.swift — the last rung of Volar's escalation ladder
// (menu bar -> system notification (+ voice) -> THIS): a borderless, screen-covering `NSPanel`
// shown on every attached display when `ReminderScheduler.sweepForFullScreenEscalation()` decides
// (via the pure `FullScreenEscalationDecision.shouldEscalate`) that a real, at-or-after-deadline
// reminder has sat ignored in Notification Center for too long.
//
// Deliberately NOT `NSAlert`/`.runModal`/SwiftUI `.alert()`/anything modal — a blocking modal
// panel would freeze the WHOLE app (including its own menu-bar item and any other window) for as
// long as it's up, which is exactly the "kẹt máy" failure mode anh Khôi's contract forbids. This
// instead mirrors `CapturePanelController` (`Sources/Views/CapturePanel.swift`)'s own established
// borderless/non-activating `NSPanel` + `NSHostingView` pattern — read for reference, not edited
// by this task.
//
// UNVERIFIED — authored on Windows, no Swift/Xcode toolchain available here to build or run this.
// Needs a Mac pass before shipping (see this task's final report for the full verify checklist):
// the screen-covering panel's level/collectionBehavior actually surfacing above a full-screen app
// and on every Space, Esc key handling reaching a non-key secondary-screen panel, and the 60s
// auto-close timer.
import SwiftUI
import AppKit

/// Borderless panel that can become key so its Esc-to-snooze / button clicks actually reach it —
/// same rationale as `CapturePanel.swift`'s own `KeyablePanel`: a plain `.borderless` `NSPanel`
/// defaults `canBecomeKey` to `false` (AppKit's own documented behavior).
@MainActor
private final class KeyableScreenPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Owns zero-or-one active full-screen takeover presentations (one `NSPanel` per attached
/// `NSScreen`, all hosting the same content and wired to the same two callbacks) for the app's
/// lifetime. One instance lives on `ReminderScheduler` (see that file's
/// `sweepForFullScreenEscalation()`).
@MainActor
final class FullScreenTakeoverWindow {
    /// Auto-close deadline (contract §C, ship-blocking requirement): a takeover nobody touches
    /// must never sit forever holding the screen. 60s and it closes on its own, counted as "still
    /// waiting" — NEVER as an implicit "Done".
    static let autoCloseInterval: TimeInterval = 60

    private var panels: [KeyableScreenPanel] = []
    private var autoCloseTimer: Timer?

    /// `true` while a takeover is currently up — read by `ReminderScheduler` to serialize
    /// escalations one at a time so two full-screen windows never stack.
    var isPresenting: Bool { !panels.isEmpty }

    /// Shows the takeover on every currently-attached screen (`NSScreen.screens` — a display
    /// connected/disconnected between sweeps is picked up fresh on each call; nothing cached).
    /// No-op if a takeover is already up: `ReminderScheduler` already guards this via
    /// `isPresenting` before calling, but guarding here too keeps this class safe to call from
    /// anywhere without depending on caller discipline.
    func present(title: String, deadline: Date?, onDone: @escaping () -> Void, onSnooze: @escaping () -> Void) {
        guard !isPresenting else { return }

        // Both wrapped once here (not passed raw) so EVERY path off this screen — the "Xong"
        // button, the "Tôi thấy rồi" button, Esc, and the 60s auto-close timeout below — all funnel
        // through the same `dismiss()` teardown exactly once, however the takeover ends.
        let wrappedDone: () -> Void = { [weak self] in
            onDone()
            self?.dismiss()
        }
        let wrappedSnooze: () -> Void = { [weak self] in
            onSnooze()
            self?.dismiss()
        }

        let content = AnyView(
            TakeoverContentView(title: title, deadline: deadline, onDone: wrappedDone, onSnooze: wrappedSnooze)
        )

        for screen in NSScreen.screens {
            let hosting = NSHostingView(rootView: content)
            let panel = KeyableScreenPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            // Contract §C, verbatim: `.screenSaver` level + this exact `collectionBehavior` is
            // what lets the takeover surface above a full-screen app and on whatever Space the
            // user is currently on, without appearing in Cmd+Tab / Mission Control as a real
            // document window (`.stationary` keeps it from being reflowed into Mission Control's
            // per-Space layout).
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            // Mirrors `CapturePanelController`'s own reasoning: this class is retained for the
            // app's whole lifetime and only ever hides/tears down its panels, never expects AppKit
            // to deallocate one out from under it.
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.contentView = hosting
            panel.setFrame(screen.frame, display: true)
            panels.append(panel)
        }

        // Same "accessory app can't reliably become key without activating first" trade-off
        // `CapturePanelController.show()` documents — required for Esc/button clicks to land
        // reliably on the primary panel.
        NSApp.activate(ignoringOtherApps: true)
        if let primary = panels.first {
            primary.makeKeyAndOrderFront(nil)
        }
        for panel in panels.dropFirst() {
            panel.orderFrontRegardless()
        }

        autoCloseTimer?.invalidate()
        // Same `Timer(timeInterval:repeats:block:)` + `RunLoop.main.add(_:forMode:.common)`
        // construction `ReminderScheduler.startFullScreenEscalationSweep()` uses (which itself
        // mirrors `AppState.startDelegationTimer()`'s established convention) — the `@Sendable`
        // block hops back onto `@MainActor` before touching `self`.
        let timer = Timer(timeInterval: Self.autoCloseInterval, repeats: false) { @Sendable [weak self] _ in
            _Concurrency.Task { @MainActor [weak self] in
                // Timeout: tear down WITHOUT calling `onDone`/`onSnooze` — contract §C: "coi như
                // vẫn chờ, không tự mark done." The underlying `ReminderRecord` is simply left
                // `.delivered`, exactly as it already was; every other existing behavior for it
                // (system banner already shown, voice already spoken if applicable) is unaffected.
                // `ReminderScheduler.escalatedRecordIds` keeps this same record from being
                // re-offered a full-screen takeover again for the rest of this run — see that
                // property's doc comment for why that's a deliberate one-shot-per-record choice.
                self?.dismiss()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoCloseTimer = timer
    }

    private func dismiss() {
        autoCloseTimer?.invalidate()
        autoCloseTimer = nil
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll()
    }
}

// MARK: - Content

/// Full-screen takeover content — one `NSHostingView` of this per screen, all showing the same
/// task/deadline and wired to the same two already-wrapped closures from
/// `FullScreenTakeoverWindow.present`. Button copy is anh Khôi's own approved literal text — not
/// translated/reworded.
///
/// Tone: calm, no blame (constitution V — the same no-shame voice `Sources/Views/SweepView.swift`
/// already established for the evening batch card: no "overdue"/"missed" wording, no exclamation
/// points, no red). "DEADLINE" as a plain section label states the fact without judging it.
private struct TakeoverContentView: View {
    let title: String
    let deadline: Date?
    let onDone: () -> Void
    let onSnooze: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            // Same heavy dark glass treatment `FocusOverlay.swift` already uses for its own
            // fullscreen one-task surface, so this reads as the same family of "the whole screen
            // is now about one thing" moment rather than a novel visual language. Tint uses the
            // `bg` token (not a hardcoded literal) so it tracks the palette automatically.
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(VolarColor.bg.opacity(0.82))
                .ignoresSafeArea()

            VStack(spacing: 22) {
                Text("DEADLINE")
                    .font(.system(size: 12, weight: .medium))
                    .tracking(2.0)
                    .foregroundStyle(VolarColor.textMut)

                Text(title)
                    .font(.system(size: 30, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(VolarColor.textPri)
                    .frame(maxWidth: 640)

                if let deadlineText {
                    Text(deadlineText)
                        .font(.system(size: 15))
                        .foregroundStyle(VolarColor.textSec)
                }

                HStack(spacing: 14) {
                    Button(action: onDone) {
                        Text("Xong")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 14)
                            // Vùng bấm phủ đúng vùng nhìn thấy (luật 2026-08-09, xem
                            // `Sidebar.swift`'s `SidebarItem`). Ở màn nhắc chiếm TOÀN BỘ màn hình
                            // thì lỗi này nặng nhất trong cả app: 28pt padding ngang + 14pt dọc là
                            // vùng chết, nên nút to đùng mà bấm trượt — người đang bị nhắc mà không
                            // tắt được sẽ đọc thành "app treo", không phải "mình bấm chưa trúng".
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(VolarColor.done)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                    Button(action: onSnooze) {
                        Text("Tôi thấy rồi — 10 phút nữa")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(VolarColor.textPri)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 14)
                            // Cùng lý do với nút "Xong" ngay trên.
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(VolarColor.veil(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(VolarColor.veil(0.14), lineWidth: 0.5))
                    // Esc == snooze 10 (contract §C, explicit — "không có đường nào khiến user
                    // kẹt"). `.keyboardShortcut(.cancelAction)` on the real, visible button —
                    // NOT a separate invisible button/`.onExitCommand` — matching this repo's own
                    // established Esc-in-a-borderless-panel convention: `CapturePanelController`'s
                    // header comment (`Sources/Views/CapturePanel.swift`) documents that
                    // `PopoverView`'s `.keyboardShortcut(.cancelAction)` buttons are what actually
                    // receive Esc in this exact borderless/non-activating-panel setup, which is
                    // also why `KeyableScreenPanel.canBecomeKey` is overridden `true` above.
                    .keyboardShortcut(.cancelAction)
                }
                .padding(.top, 8)
            }
            .padding(48)
        }
        // `@FocusState` + `.onAppear { isFocused = true }` mirrors `FocusOverlay.swift`'s own
        // pattern for getting a borderless-panel-hosted SwiftUI view to actually take focus;
        // `.keyboardShortcut(.cancelAction)` above (not first-responder key-event routing) is
        // what makes Esc itself work, matching this repo's established convention.
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
    }

    private var deadlineText: String? {
        guard let deadline else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: deadline)
    }
}
