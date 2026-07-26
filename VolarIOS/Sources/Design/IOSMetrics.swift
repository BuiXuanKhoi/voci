// Sources/Design/IOSMetrics.swift — iOS-only type scale & layout metrics (plan §4.1).
//
// WHY THIS FILE EXISTS INSTEAD OF EDITING `Shared/Design/Theme.swift`: `Theme.swift` is a FROZEN,
// platform-neutral contract (plan §3 table: "không có gì macOS-only... không sửa 1 chữ nào" — the
// macOS app and this iOS app both compile it verbatim). Its type sizes (11–13pt) were tuned for a
// desktop window viewed at arm's length; ported verbatim to an iPhone held at reading distance they
// are too small to read comfortably — a 10.5pt eyebrow or an 11pt section header is fine on a 27"
// display, illegible on a 6.1" phone screen. Rather than fork `Theme.swift` per platform (which
// would force every shared view to branch on `#if os(iOS)` at each `.font(...)` call site, or worse,
// tempt someone into just editing the numbers in place and silently breaking macOS), this file is a
// SEPARATE, additive, iOS-only scale that only the iOS views import. Colors, accents, motion, and
// glass levels are NOT re-derived here — those tokens are resolution-independent (a color is a
// color at any screen size) and continue to come from `VolarColor` / `VolarAccent` / `VolarMotion` /
// `GlassLevel` unchanged. Only type size/tracking and iOS-specific layout constants live here.
//
// FROZEN API (Opus, 2026-07-27): agents A3 (Today), A4 (Capture), A5 (Focus), A6 (Settings) are
// writing SwiftUI code against these exact names/values concurrently with this file being authored.
// Do not rename, retype, or omit any member below — a mismatch breaks four other files that can't
// be compiled here to catch the break (no Swift toolchain on this machine, see plan header).
//
// SOURCE OF TRUTH for every value: plan §4.1's macOS→iOS conversion table, cross-checked against
// `design/volar-mobile.jsx` (the iOS companion prototype, `VolarMobileApp` and its subcomponents) —
// that file's inline literal pixel values are cited per-constant below.
import SwiftUI

enum IOSMetrics {
    // MARK: - Type scale (plan §4.1 table; `Font.volar` so every size still resolves through the
    // app's one font-stack helper in Theme.swift rather than reaching for `.system` directly here)

    /// Greeting / screen title. Plan §4.1: macOS 22pt → iOS **34** semibold.
    /// `volar-mobile.jsx` `VolarMobileApp` header: `fontSize: 34, fontWeight: 500` for
    /// "Good morning, Alex." (the prototype's CSS `500` reads as SwiftUI `.semibold` per this
    /// codebase's existing `Font.volar` convention — see `rowTitle`/`nowTitle` below, which map the
    /// jsx's own `fontWeight: 500`/`600` the same way elsewhere in this file).
    static let screenTitle: Font = .volar(size: 34, weight: .semibold)

    /// Eyebrow / date line (uppercase). Plan §4.1: macOS 10.5pt → iOS **13** medium.
    /// `volar-mobile.jsx` header eyebrow ("Wed, May 21"): `fontSize: 13, fontWeight: 500`.
    static let eyebrow: Font = .volar(size: 13, weight: .medium)

    /// NOW / hero card title. Plan §4.1: macOS 15pt → iOS **17** semibold.
    /// `volar-mobile.jsx` `MobileTaskCard` (`big` variant) title: `fontSize: big ? 17 : 15,
    /// fontWeight: big ? 600 : 500`.
    static let nowTitle: Font = .volar(size: 17, weight: .semibold)

    /// Ordinary task row title. Plan §4.1: macOS 13pt → iOS **15** medium.
    /// `volar-mobile.jsx` `MobileTaskCard` (non-`big`) title: `fontSize: 15, fontWeight: 500`.
    static let rowTitle: Font = .volar(size: 15, weight: .medium)

    /// Meta / badge text (time chip, priority label, duration). Plan §4.1: macOS 11pt → iOS
    /// **12.5** regular. `volar-mobile.jsx` `MobileTaskCard` meta row: `fontSize: 12.5`.
    static let meta: Font = .volar(size: 12.5, weight: .regular)

    /// Section header (uppercase, e.g. "LATER TODAY" / "COMPLETED"). Plan §4.1: macOS 10.5pt → iOS
    /// **11** medium. `volar-mobile.jsx` section labels: `fontSize: 11, fontWeight: 500`.
    static let sectionHeader: Font = .volar(size: 11, weight: .medium)

    /// Footnote / caption. Plan §4.1: macOS 11pt → iOS **13** regular — "iOS tối thiểu 13 cho chữ
    /// đọc được" (13pt is this scale's floor for anything meant to be read, not just glanced at).
    static let caption: Font = .volar(size: 13, weight: .regular)

    // MARK: - Tracking (letter-spacing). CSS `em` values from the jsx converted to absolute points
    // at each role's point size (`em * size`), matching how `Theme.swift`'s own header describes
    // fidelity mapping from the CSS prototypes.

    /// Screen title tracking. `volar-mobile.jsx` header: `letterSpacing: '-0.025em'` at 34pt →
    /// `-0.025 * 34 = -0.85`.
    static let titleTracking: CGFloat = -0.85

    /// Eyebrow tracking. `volar-mobile.jsx` header eyebrow: `letterSpacing: '0.05em'` at 13pt →
    /// `0.05 * 13 = 0.65`.
    static let eyebrowTracking: CGFloat = 0.65

    /// Section header tracking. `volar-mobile.jsx` section labels: `letterSpacing: '0.08em'` at
    /// 11pt → `0.08 * 11 = 0.88`.
    static let sectionTracking: CGFloat = 0.88

    // MARK: - Layout (plan §4.1 "Touch target"/"Bo góc"/"Padding ngang" bullets)

    /// Horizontal screen padding for header/section labels. Plan §4.1: **22pt**.
    /// `volar-mobile.jsx` header: `padding: '4px 22px 6px'`; section rows: `padding: '20px 22px 4px'`.
    static let screenPadH: CGFloat = 22

    /// Horizontal card padding. Plan §4.1: **18pt**.
    /// `volar-mobile.jsx` `MobileTaskCard` non-`big`: `padding: '13px 14px'` and the hero/"Now"
    /// wrapper: `padding: '14px 18px 6px'` — 18 is this scale's chosen horizontal figure.
    static let cardPadH: CGFloat = 18

    /// Standard card corner radius. Plan §4.1: card **14**.
    /// `volar-mobile.jsx` `MobileTaskCard` non-`big`: `borderRadius: 14`.
    static let cardRadius: CGFloat = 14

    /// NOW / hero card corner radius. Plan §4.1: NOW card **18**.
    /// `volar-mobile.jsx` `MobileTaskCard` `big` variant: `borderRadius: 18`.
    static let nowCardRadius: CGFloat = 18

    /// Bottom-sheet top corner radius (capture sheet). Plan §4.1: sheet top **28**.
    /// `volar-mobile.jsx` `MobileVoiceSheet`: `borderTopLeftRadius: 28, borderTopRightRadius: 28`.
    static let sheetRadius: CGFloat = 28

    /// Minimum touch target (Apple HIG + plan §4.1: "Touch target ≥ 44×44pt cho mọi thứ bấm được").
    /// E.g. `TaskRow`'s 20/22pt checkbox circle must still sit inside a `.frame(width: 44,
    /// height: 44)` + `.contentShape(Rectangle())` hit area per that bullet.
    static let minTouch: CGFloat = 44

    /// Mic FAB diameter. Plan §4.1 / §4.2: **72pt**.
    /// `volar-mobile.jsx` `MicButton`: `width: 72, height: 72`.
    static let fabSize: CGFloat = 72

    // MARK: - Density → row padding

    /// iOS row vertical padding for a given `Density` preset. Plan §4.1: "iOS mặc định `.comfy`
    /// nhưng `rowPadY` cộng thêm +4 (iOS cần thở hơn)" — iOS needs more breathing room than the
    /// desktop density presets alone provide, so this ADDS a flat +4pt on top of
    /// `Density.rowPadY` (`Shared/Design/Theme.swift`) rather than redefining density for iOS.
    /// Implemented as a function (not a `Density` extension) so `Theme.swift` — shared,
    /// platform-neutral, frozen — never has to know an iOS-only adjustment exists.
    static func rowPadY(_ density: Density) -> CGFloat {
        density.rowPadY + 4
    }
}
