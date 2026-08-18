// Sources/Views/Sidebar.swift — capture button + Focus nav + on-device footer
// Ported from `design/volar-mac.jsx`'s sidebar column.
import SwiftUI

struct Sidebar: View {
    @Environment(AppState.self) private var appState: AppState

    /// Drives the `PaywallView` sheet from the sidebar's own "Pro" CTA (below). Lives here rather
    /// than inside `ProSidebarRow` itself so the sheet is attached once, at the `Sidebar` level —
    /// a `@State` owned by a small subview that gets re-created would lose its presented state.
    @State private var showPaywall = false
    /// The sidebar's own sign-in surface, so the paywall's "Sign in to subscribe" CTA is not a dead
    /// button when the paywall was opened from here (see the `.sheet` pair at the bottom of `body`).
    @State private var showSignInSheet = false
    @State private var pendingSignInAfterPaywall = false

    private var accentColors: Accent { appState.accent.accent }

    var body: some View {
        VStack(spacing: 0) {
            // Grouped in their own `VStack(spacing: 0)` — identical to being direct children of
            // the outer `VStack` above (same individual paddings, same spacing) — purely so a
            // single `.tourAnchor(.capture)` can cover both the "Tap to speak" button AND the
            // ⌃⌥M key badges together (guided tour, stop 1: `Sources/Views/Tour/*`). Regrouping
            // rather than tagging `captureButton` alone, per that feature's own instruction to
            // prefer covering both over a tighter single-button hole, as long as doing so doesn't
            // shift any existing layout — and it doesn't, since nesting a zero-spacing `VStack`
            // changes nothing about how its children are laid out.
            VStack(spacing: 0) {
                captureButton
                    .padding(.horizontal, 10)
                    .padding(.top, 12)
                    .padding(.bottom, 4)

                keyBadgeRow
                    .padding(.bottom, 4)
            }
            .tourAnchor(.capture)

            focusSectionLabel

            // Today/Upcoming/Inbox are LIVE as of 2026-07-27 (port of the Windows reference —
            // SidebarControl.xaml.cs's `ApplyNavRow`/`OnNavRowTapped`). Before that, only Today was
            // real: Upcoming/Inbox rendered hardcoded counts (12/3) and had empty `{}` actions.
            // Membership/counts come from `AppState.upcomingNavCount`/`inboxNavCount`
            // (`Sources/Model/TaskSections.swift`); `active` now reflects `appState.selectedSection`
            // instead of the old `true`/`false` literals.
            VStack(spacing: 1) {
                SidebarItem(
                    icon: .today,
                    label: "Today",
                    count: appState.openTasks.count,
                    active: appState.selectedSection == .today
                ) { appState.selectedSection = .today }
                SidebarItem(
                    icon: .upcoming,
                    label: "Upcoming",
                    count: appState.upcomingNavCount,
                    active: appState.selectedSection == .upcoming
                ) { appState.selectedSection = .upcoming }
                SidebarItem(
                    icon: .inbox,
                    label: "Inbox",
                    count: appState.inboxNavCount,
                    active: appState.selectedSection == .inbox
                ) { appState.selectedSection = .inbox }
            }
            .padding(.horizontal, 8)

            Spacer(minLength: 0)

            // "Pro" sits between the Spacer and the footer, per anh Khôi's ask — its own row, NOT
            // another `SidebarItem` (those are flat nav rows; this one has to visually shout, or
            // stay quiet, depending on `accountTier`). `ProSidebarRow` reads `accountTier` itself and
            // picks between a bright upsell CTA and a silent "already Pro" badge — see its doc
            // comment for why those two states must never blend into one.
            ProSidebarRow(isPro: appState.accountTier == .pro) { showPaywall = true }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)

            onDeviceFooter
                .padding(.horizontal, 10)
        }
        .padding(.bottom, 12)
        .frame(width: 172)
        .frame(maxHeight: .infinity)
        .background(sidebarBackground)
        .overlay(alignment: .trailing) {
            Rectangle().fill(VolarColor.border).frame(width: 0.5)
        }
        // `onNeedSignIn` is NOT left at its default no-op here. Purchasing requires a session
        // (`Entitlements.purchase` throws `.notSignedIn`), so a signed-out visitor who opens this
        // paywall lands on its "Sign in to subscribe" CTA — and with the default closure that button
        // does nothing at all. Since the sidebar is now the most prominent way into the paywall, that
        // dead end would be the common path, not an edge case.
        //
        // The handoff goes through `onDismiss` rather than flipping both flags inside the callback:
        // asking SwiftUI to tear down one sheet and present another in the same update routinely
        // drops the second presentation, leaving the user with a paywall that just closes.
        // `pendingSignInAfterPaywall` separates "closed via the CTA" from "closed with the X button",
        // which must open nothing. Mirrors `SettingsView.accountTab`'s pair exactly.
        .sheet(isPresented: $showPaywall, onDismiss: {
            guard pendingSignInAfterPaywall else { return }
            pendingSignInAfterPaywall = false
            showSignInSheet = true
        }) {
            PaywallView(onNeedSignIn: {
                pendingSignInAfterPaywall = true
                showPaywall = false
            })
        }
        .sheet(isPresented: $showSignInSheet) {
            SignInSheet()
        }
    }

    @ViewBuilder
    private var sidebarBackground: some View {
        if appState.ambient != .none {
            // Was `VolarColor.surface.opacity(0.45)` — a magic number duplicating what
            // `GlassLevel.bgOpacity` already exists to express ("opacity of the ink tint layered
            // over the system material"). Reusing it instead of inventing a second constant.
            Rectangle()
                .fill(appState.glass.material)
                .overlay(VolarColor.surface.opacity(appState.glass.bgOpacity))
        } else {
            VolarColor.surface
        }
    }

    private var captureButton: some View {
        Button {
            // Stays on `toggleCapture()` on purpose. `handleHotkey()` saves a pending confirm card,
            // which is right for a BARE keypress whose meaning has to depend on state — but this
            // button says "Tap to speak", and a button that saves your task when its label offers to
            // listen is a surprise, not a shortcut. Same reasoning keeps the Windows sidebar button
            // on ToggleCaptureAsync (SidebarControl.xaml.cs's OnCaptureButtonClick).
            appState.toggleCapture()
        } label: {
            HStack(spacing: 7) {
                VolarIcon(.mic, size: 13, color: accentColors.solid, weight: .semibold)
                Text(appState.captureState == .recording ? "Tap to stop" : "Tap to speak")
                    .font(.system(size: 12, weight: .medium))
                    .tracking(-0.06)
            }
            .foregroundStyle(accentColors.solid)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
        }
        .buttonStyle(CaptureButtonStyle(accentColor: accentColors.solid))
    }

    private var keyBadgeRow: some View {
        HStack(spacing: 4) {
            KeyBadge("⌃")
            KeyBadge("⌥")
            KeyBadge("M")
        }
        .frame(maxWidth: .infinity)
    }

    // §5.4 (specs/009-light-mode-list-v2/design.md): 11pt/.semibold/uppercase/tracking+0.5/textSec.
    // Was 10.5pt/.medium/textMut (3.4:1, below AA) — textMut is reserved for tertiary labels now,
    // never section headers.
    private var focusSectionLabel: some View {
        Text("Focus")
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.5)
            .textCase(.uppercase)
            .foregroundStyle(VolarColor.textSec)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 6)
    }

    /// Whether speech is ACTUALLY running in the cloud right now — computed the same two-part way
    /// `SettingsView`'s "Groq status" row does (`speechEngineChoice == .groq` + `GroqEngine.isConfigured`,
    /// see `SettingsView.generalTab`), not just the raw picker selection. `AppState.selectedEngine`
    /// silently falls back to on-device whenever Groq is picked but not configured (signed out) — so
    /// checking only `speechEngineChoice == .groq` would have this footer claim "Cloud" for someone
    /// who is, in fact, still running fully on-device. Both conditions must hold.
    ///
    /// This footer used to hardcode "On-device / nothing leaves your Mac" — true when Apple/WhisperKit
    /// is the engine, flatly FALSE since 2026-07-27 now that Groq cloud is the default choice
    /// (`AppState.speechEngineChoice`'s `init` fallback). It sits on every Mac screenshot submitted to
    /// the App Store, so a hardcoded on-device claim while cloud is active would misstate the app's
    /// actual privacy behavior — this computed property is what keeps the label honest.
    private var isCloudSpeechActive: Bool {
        appState.speechEngineChoice == .groq && GroqEngine.isConfigured
    }

    private var onDeviceFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(accentColors.solid).frame(width: 5, height: 5)
                Text(isCloudSpeechActive ? "Cloud" : "On-device")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(VolarColor.textPri)
            }
            // Cloud branch is deliberately NOT "nothing leaves your Mac" — that sentence is only
            // true on-device. It says what actually happens (audio goes to Volar's recognition
            // service) plus how to opt back out, instead of repeating the on-device promise here.
            Text(isCloudSpeechActive
                 ? "Audio is sent to Volar's speech recognition service to turn it into text. Switch to on-device anytime in Settings."
                 : "Audio is parsed locally. Nothing leaves your Mac.")
                .font(.system(size: 11))
                .foregroundStyle(VolarColor.textSec)
                .lineSpacing(2)
        }
        .padding(10)
        // Was `VolarColor.veil(0.03)`, an ad hoc alpha. §3 has no named token for a static
        // (always-on, non-hover) subtle box, so reusing `cardHover` — same "one low-alpha ink
        // surface" the row hover uses (§5.2) — instead of inventing another one-off constant.
        .background(VolarColor.cardHover)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            // `.strokeBorder`, not `.stroke`: after `.clipShape` above, `.stroke` draws centered
            // on the path and the outer half gets clipped away — the known half-width-border bug.
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(VolarColor.border, lineWidth: 0.5)
        )
    }
}

/// Gives the "Tap to speak" capture button a press-down highlight (mirrors the prototype's
/// mousedown/up-driven `holdHint` inset glow) using `ButtonStyle`'s own `isPressed` state, rather
/// than a second overlapping gesture recognizer that could compete with the button's tap.
private struct CaptureButtonStyle: ButtonStyle {
    let accentColor: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(accentColor.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(
                // `.strokeBorder`, not `.stroke` — see `onDeviceFooter` comment above for why.
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(accentColor.opacity(configuration.isPressed ? 0.9 : 0.27), lineWidth: configuration.isPressed ? 1 : 0.5)
            )
            .animation(VolarMotion.press, value: configuration.isPressed)
    }
}

/// Single sidebar nav row (icon + label + trailing count). Ported from `volar-mac.jsx`'s
/// `SidebarItem`. Private to `Sidebar` — not part of the frozen component surface.
private struct SidebarItem: View {
    let icon: VolarIconName
    let label: String
    let count: Int?
    let active: Bool
    let action: () -> Void

    @Environment(AppState.self) private var appState: AppState
    @State private var isHovering = false

    private var accentColors: Accent { appState.accent.accent }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                VolarIcon(icon, size: 14, color: active ? accentColors.solid : VolarColor.textSec)
                Text(label)
                    .font(.system(size: 13, weight: active ? .semibold : .regular))
                    .tracking(-0.065)
                    // §5.3: active label reads `textPri` (not accent-colored — the accent budget
                    // goes to the icon + the left bar below, not the whole row). Inactive is
                    // `textSec`, not `textPri`: it was backwards before this pass (inactive rows
                    // were reading as bright as the header, active rows as dim as body text).
                    .foregroundStyle(active ? VolarColor.textPri : VolarColor.textSec)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let count {
                    Text("\(count)")
                        .font(Font.volarMono(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(active ? accentColors.solid : VolarColor.textMut)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            // BUG FIX 2026-08-09 (anh Khôi báo khi chạy thật: "Upcoming/Inbox bấm hoài mà nó không
            // vào"): với `.buttonStyle(.plain)`, SwiftUI chỉ hit-test phần label THỰC SỰ VẼ RA.
            // `Spacer(minLength: 0)` ở trên và hai `.padding` này không vẽ gì cả, nên vùng bấm thật
            // của hàng không phải cả hàng mà là mấy mảnh rời rạc — icon, chữ, và con số — với lỗ
            // thủng ở giữa. Chuyện này khó phát hiện đúng vì cái nền highlight (`.background` ngay
            // dưới đây) được vẽ ở lớp NGOÀI `Button`, nên hàng TRÔNG như bấm được cả dải trong khi
            // thực tế không. `.contentShape` đặt SAU padding để hình chữ nhật hit-test trùm luôn cả
            // padding, tức đúng bằng vùng nền mà mắt nhìn thấy. Cùng idiom `TodayView.swift:1152`
            // (`.contentShape(Rectangle())` + `.onTapGesture`) và `:616` đã dùng — chỗ này chỉ là
            // sót, không phải một quy ước khác.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // §5.3: active = solid `surfaceHi` fill (was `accentColors.surface`, an accent wash at
        // .15 alpha — anh Khôi's "chìm vào giao diện" report). Inactive hover = `cardHover`, the
        // one hover surface (§5.2), replacing the near-invisible ad hoc `veil(0.04)`.
        .background(active ? VolarColor.surfaceHi : (isHovering ? VolarColor.cardHover : .clear))
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(alignment: .leading) {
            if active {
                // §5.3 left bar, 2px, `accentColors.solid` — this row's only saturated pixels.
                // Bo tròn nhẹ (radius 1) + inset dọc 3pt thay vì cao sát mép trên/dưới: mép trên/
                // dưới của row đã bo góc 5pt bởi `.clipShape` ở trên (mà bar này vẽ SAU, không bị
                // clip theo), một thanh vuông góc cao đúng bằng chiều cao row sẽ tràn nhẹ ra ngoài
                // đường bo đó ở hai đầu. Inset + bo nhẹ tránh phần tràn mà không cần tự vẽ lại toàn
                // bộ shape của row.
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(accentColors.solid)
                    .frame(width: 2)
                    .padding(.vertical, 3)
            }
        }
        .onHover { isHovering = $0 }
        .animation(VolarMotion.hover, value: isHovering)
    }
}

/// The sidebar's "Pro" row — deliberately NOT a `SidebarItem` (those are flat nav rows for
/// switching sections; this doesn't navigate anywhere, it sells or confirms a subscription).
/// Private to `Sidebar`, same convention as `SidebarItem`/`CaptureButtonStyle` above.
///
/// Two states that must never blend into one:
///  - `isPro == false` — a bright accent-filled CTA (gradient fill, accent stroke, hover feedback
///    exactly like `SidebarItem`'s own `@State private var isHovering`) that calls `onTapUpsell`.
///    This is the ONE thing in the sidebar allowed to look like a sales pitch.
///  - `isPro == true` — a quiet, unclickable status row: no accent fill, no hover animation, no
///    action at all. Re-pitching Pro to someone who already paid for it is a product bug, not a
///    style choice (same "don't sell twice" rule `PaywallView.alreadyProBody` already follows for
///    the paywall sheet itself) — so this branch has nothing wired to `onTapUpsell`.
private struct ProSidebarRow: View {
    let isPro: Bool
    let onTapUpsell: () -> Void

    @Environment(AppState.self) private var appState: AppState
    @State private var isHovering = false

    private var accentColors: Accent { appState.accent.accent }

    var body: some View {
        if isPro {
            HStack(spacing: 7) {
                VolarIcon(.check, size: 12, color: VolarColor.done, weight: .semibold)
                Text("Pro")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(VolarColor.textSec)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
        } else {
            Button(action: onTapUpsell) {
                HStack(spacing: 7) {
                    VolarIcon(.sparkle, size: 13, color: accentColors.solid, weight: .semibold)
                    Text("Pro")
                        .font(.system(size: 12.5, weight: .semibold))
                        .tracking(-0.06)
                        .foregroundStyle(accentColors.solid)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .frame(maxWidth: .infinity)
                // Cùng lỗi, cùng cách sửa như `SidebarItem` ở trên (xem comment dài ở đó): hàng này
                // cũng là `Button` + `.buttonStyle(.plain)` với `Spacer` + padding không vẽ gì, và
                // gradient fill của nó cũng nằm NGOÀI `Button` — nên nó cũng trông như bấm được cả
                // dải trong khi chỉ có icon và chữ "Pro" là ăn click. Sửa luôn ở đây thay vì đợi ai
                // đó báo tiếp: đây là nút BÁN HÀNG, một nút upsell khó bấm là mất tiền thật.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Gradient fill (accentColors.solid -> .hover) rather than the flat `.surface` tint
            // `SidebarItem`'s `active` state uses — this row needs to read as visibly brighter than
            // an active nav row, not just "selected".
            .background(
                LinearGradient(
                    colors: [accentColors.solid.opacity(0.24), accentColors.hover.opacity(0.14)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(
                // `.strokeBorder`, not `.stroke` — see `onDeviceFooter` comment above for why.
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(accentColors.solid.opacity(isHovering ? 0.75 : 0.45), lineWidth: isHovering ? 1 : 0.75)
            )
            .onHover { isHovering = $0 }
            .animation(VolarMotion.hover, value: isHovering)
        }
    }
}
