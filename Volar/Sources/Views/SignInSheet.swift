// Sources/Views/SignInSheet.swift — sign-in sheet reachable from the MAIN WINDOW, not just
// Settings ▸ Account.
//
// Before this file, the ONLY way to sign in was Settings ▸ Account — a brand-new user opening the
// main window for the first time had no visible path to ever turn on cloud speech/parsing or buy
// Pro (both gated behind having an account). This sheet is that missing entry point: opened from a
// new "Sign in" toolbar pill in `TodayView` (shown only while signed out), and also from
// `PaywallView`'s "Sign in to subscribe" CTA (via `SettingsView.accountTab`'s `onNeedSignIn`).
//
// UI ONLY, same as `PaywallView`: it owns no session state of its own, just presents
// `EmailSignInForm` (the ONE email-OTP form in the codebase — see that file's header) inside a
// small modal shell styled to match `PaywallView`'s sheet chrome (`VolarColor.bg`, 16pt corner
// radius, `volarHairline`).
//
// Sign in with Apple was removed from Volar entirely on 2026-07-27 — nothing here (or anywhere
// this form is used) should reintroduce an Apple/ASAuthorization sign-in path.
import SwiftUI

struct SignInSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    private var accentColors: Accent { appState.accent.accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            closeButton
            header
            EmailSignInForm(onSignedIn: { dismiss() })
        }
        .padding(20)
        .frame(width: 380)
        .background(VolarColor.bg)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .volarHairline(cornerRadius: 16)
        // Belt-and-suspenders with `EmailSignInForm`'s own `onSignedIn` callback above: that
        // callback already calls `dismiss()` the instant `appState.accountEmail` flips non-nil, but
        // this sheet also watches the same signal directly — exactly the technique `PaywallView`
        // already uses (`.onChange(of: appState.accountTier)` closing itself on a successful
        // purchase) — so this sheet closes correctly even if some future caller embeds
        // `EmailSignInForm` here without wiring `onSignedIn`.
        .onChange(of: appState.accountEmail) { oldEmail, newEmail in
            if oldEmail == nil, newEmail != nil {
                dismiss()
            }
        }
    }

    // MARK: - Close

    /// Identical recipe to `PaywallView.closeButton` (same icon, size, padding, circular veil
    /// background) — not shared code, since that one is `private` to `PaywallView`, but the two
    /// sheets should look like one family of modal, not two independently-styled close affordances.
    private var closeButton: some View {
        HStack {
            Spacer()
            Button {
                dismiss()
            } label: {
                VolarIcon(.x, size: 11, color: VolarColor.textMut, weight: .medium)
                    .padding(6)
                    .background(VolarColor.veil(0.06))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Header

    /// Copy here must stay exactly as true as `SettingsView.accountCard`'s equivalent signed-out
    /// line: signing in unlocks cloud speech + cloud parsing (both tiers use them — Pro just raises
    /// the daily ceiling, see `PaywallView`'s own "no unlimited" rule), and the app's core
    /// (capture/tasks/reminders/focus) already works with no account at all. No mention of Apple
    /// sign-in — email OTP is the only method, and the copy doesn't need to say so explicitly since
    /// the form below only offers that one path anyway.
    private var header: some View {
        VStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [accentColors.solid, accentColors.hover], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 48, height: 48)
                .overlay {
                    VolarIcon(.mic, size: 24, color: .white, weight: .regular)
                }
                .shadow(color: accentColors.glow, radius: 16, y: 6)

            Text("Sign in to Volar AI")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(VolarColor.textPri)

            Text("Sign in to unlock Cloud parsing and Groq speech transcription. Volar's core (capture, tasks, reminders, focus) never requires an account.")
                .font(.system(size: 12.5))
                .foregroundStyle(VolarColor.textSec)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    SignInSheet()
        .environment(AppState())
}
