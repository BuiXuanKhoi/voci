// Sources/Design/Theme.swift — frozen design tokens: palette, accents, density, glass (spec §3)
//
// RETHEME — "Studio Dark / One Lit Thing" (2026-07). Values ported 1:1 from the source-of-truth
// prototype tokens (`voci-redesign/foundations.html`, `voci-redesign/menubar-now.html`). Every
// token NAME below already existed before this pass and is unchanged, so every call site
// (`VociColor.*`, `VociAccent.*`, `VociMotion.*`, `Density.*`, `GlassLevel.*`) keeps compiling —
// only the underlying VALUES moved to the new palette. New tokens added for the spotlight/NOW
// system are called out below with `// NEW`.
//
// THE ONE RULE: warm amber (`nowAccent` family) is a spotlight, not a brand color — it is reserved
// for the single active/NOW task (spotlight glow, NOW label, NOW focus ring) and must never be the
// app-wide accent. `VociAccent`'s default (`.indigo`) and every other general-purpose "accent" token
// in this file resolve to the COOL instrument blue family instead. Views adopt `nowAccent`/`nowGlow`
// /`.vociSpotlight()` for the active task in a later pass — this file only prepares the tokens.
import SwiftUI

extension Color {
    /// Constructs a `Color` from a 24-bit RGB literal (e.g. `0xFF6B6B`), always going through
    /// the exact `Color(.sRGB, red:green:blue:opacity:)` initializer the token spec calls for.
    /// Centralizing the hex math here (instead of hand-computing decimals at each call site)
    /// keeps every token numerically exact.
    init(voci hex: UInt32, opacity: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}

/// Base palette — Studio Dark ink + text + priority/status tokens, ported from
/// `voci-redesign/foundations.html`'s `:root` custom properties (`--ink-*`, `--surface-*`,
/// `--tx-*`, `--sage`, etc). Dark-only; this app is dark-first Studio Dark (see §"Support
/// light+dark?" — no light variant exists here, so none needs preserving).
enum VociColor {
    // --- Ink / depth (foundations.html §01 "Color") ---
    /// `--ink-0` — base bg, deepest.
    static let bg = Color(voci: 0x0B0D11)
    /// `--surface-1` — raised surface. NOTE: name predates the retheme; maps to the spec's
    /// "raised surface" layer, one step up from `bg`/`--ink-1`.
    static let surface = Color(voci: 0x15181E)
    /// `--surface-2` — raised surface, higher.
    static let surfaceHi = Color(voci: 0x1B1F26)
    /// Low-key translucent card fill over whichever surface it sits on — tuned down from the old
    /// graphite value so cards read as quiet ink, not gray plastic.
    static let card = Color.white.opacity(0.04)
    static let cardHover = Color.white.opacity(0.07)
    /// `--hairline` (rgba(255,255,255,.07)).
    static let border = Color.white.opacity(0.07)
    /// `--hairline-strong` (rgba(255,255,255,.11)).
    static let borderHi = Color.white.opacity(0.11)

    // --- Text (foundations.html --tx-1/2/3) ---
    /// `--tx-1` primary. Contrast vs `bg` (#0B0D11) ≈ 15.6:1 — passes WCAG AAA for body text.
    static let textPri = Color(voci: 0xEAECEF)
    /// `--tx-2` secondary. Contrast vs `bg` ≈ 7.6:1 — passes WCAG AA (and AAA) for body text.
    static let textSec = Color(voci: 0x9BA3AE)
    /// `--tx-3` tertiary / muted. Contrast vs `bg` ≈ 3.3:1 — intentionally BELOW body-text AA per
    /// the source spec (this token is for de-emphasized/tertiary labels, never body copy).
    static let textMut = Color(voci: 0x5D646E)

    // --- Priority / status dots & badges ---
    // No red, ever (anti-shame rule, foundations.html §01 rule-callout) and no amber (amber is
    // reserved exclusively for `nowAccent`/the NOW spotlight — see file header). Priority hierarchy
    // is instead expressed as a warm-neutral clay → taupe → cool-gray ramp so "High" still reads as
    // warmer than "Low" without touching either reserved hue.
    /// High priority — muted clay/terracotta. Deliberately NOT the signature amber (more
    /// red-brown, less gold) and NOT alarm red.
    static let high = Color(voci: 0xB9705A)
    /// Medium priority — muted warm taupe, between `high` and `low`.
    static let med = Color(voci: 0x9C8C6B)
    /// Low priority — neutral gray, unchanged formula (already palette-safe).
    static let low = Color.white.opacity(0.30)
    /// Destructive action (e.g. Delete). This is the standard macOS destructive-affordance red,
    /// distinct from the "never red for overdue/badges" anti-shame rule — that rule governs
    /// task-status badges, not an irreversible system action button. Toned down from a neon red to
    /// a muted brick to stay in the Studio Dark register.
    static let destruct = Color(voci: 0xC85C4C)
    /// `--sage` — success. Muted, not neon.
    static let done = Color(voci: 0x7FA88C)

    // MARK: - NEW: NOW / spotlight tokens (foundations.html §01, §03; menubar-now.html)

    /// `--amber` — THE key light. Warm. Used ONLY on the one NOW task (spotlight glow, NOW label,
    /// NOW focus ring, NOW primary action). Never the general/app-wide accent.
    static let nowAccent = Color(voci: 0xE8B25A)
    /// `--amber-soft` — lighter warm, used for NOW title text / primary-button gradient top.
    static let nowAccentSoft = Color(voci: 0xF0C67E)
    /// `--amber-deep` — darker warm, gradient bottom / pressed states.
    static let nowAccentDeep = Color(voci: 0xB9832F)
    /// `--amber-glow` — the spotlight pool's inner glow.
    static let nowGlow = Color(voci: 0xE8B25A, opacity: 0.20)
    /// `--amber-glow-soft` — the spotlight pool's outer falloff.
    static let nowGlowSoft = Color(voci: 0xE8B25A, opacity: 0.10)
    /// `--amber-ring` — NOW-specific focus ring / hairline accent (e.g. `m-chip.warm` border).
    static let nowRing = Color(voci: 0xE8B25A, opacity: 0.55)

    // MARK: - NEW: instrument tokens (foundations.html §05 "Instrument readouts")

    /// `--cool` — cool instrument accent. Informational only, sparing: WIP counter, timers,
    /// links, dependency dots. Never used for the NOW spotlight.
    static let instrument = Color(voci: 0x5B8DEF)
    /// `--cool-dim` — dimmed cool, for dashed dependency chips / secondary instrument marks.
    static let instrumentDim = Color(voci: 0x40557F)

    /// `--reschedule` — calm neutral "needs rescheduling" tone. This is what overdue uses INSTEAD
    /// of red (anti-shame rule) — provided here so a later per-view pass has a token ready rather
    /// than reaching for `destruct` or inventing a one-off color.
    static let reschedule = Color(voci: 0x8A8FA0)
}

/// One accent family's four derived roles (`VOCI_ACCENTS.*`).
struct Accent: Sendable {
    let solid: Color
    let hover: Color
    let surface: Color
    let glow: Color
}

/// Selectable accent families (`VOCI_ACCENTS`). Default is `.indigo`, which now resolves to the
/// same cool instrument blue as `VociColor.instrument` (`--cool`) — the general-purpose/app-wide
/// accent (active states, capture button, selection) is COOL, never the reserved warm `nowAccent`.
/// `.amber` is a legacy user-selectable option (was already selectable pre-retheme); its hex was
/// shifted off the exact NOW hue (copper/burnt-orange vs. NOW's honey-gold) so a user who opts
/// into it doesn't produce a second "amber thing" that visually competes with the NOW spotlight.
enum VociAccent: String, CaseIterable, Identifiable, Sendable, Equatable, Hashable {
    case indigo, teal, amber, magenta

    var id: String { rawValue }

    var accent: Accent {
        switch self {
        case .indigo:
            // Cool instrument blue (`--cool`) — the app-wide default. NOT warm.
            let solid = Color(voci: 0x5B8DEF)
            return Accent(solid: solid, hover: Color(voci: 0x7FA5F5), surface: solid.opacity(0.15), glow: solid.opacity(0.45))
        case .teal:
            let solid = Color(voci: 0x3DBFAF)
            return Accent(solid: solid, hover: Color(voci: 0x63D6C7), surface: solid.opacity(0.15), glow: solid.opacity(0.45))
        case .amber:
            // Deliberately NOT `VociColor.nowAccent` — copper/burnt-orange, not honey-gold, so it
            // never gets mistaken for the reserved NOW spotlight color.
            let solid = Color(voci: 0xD9853D)
            return Accent(solid: solid, hover: Color(voci: 0xE9A165), surface: solid.opacity(0.15), glow: solid.opacity(0.45))
        case .magenta:
            let solid = Color(voci: 0xD16BC0)
            return Accent(solid: solid, hover: Color(voci: 0xE38BD4), surface: solid.opacity(0.15), glow: solid.opacity(0.45))
        }
    }
}

/// Row/section spacing presets (`VOCI_DENSITY`). Default is `.comfy`. Unchanged by the retheme —
/// spacing is not a color/token-value concern.
enum Density: Sendable, Equatable, Hashable {
    case cozy, comfy, roomy

    var rowPadY: CGFloat {
        switch self {
        case .cozy: return 7
        case .comfy: return 10
        case .roomy: return 14
        }
    }

    var rowGap: CGFloat {
        switch self {
        case .cozy: return 3
        case .comfy: return 4
        case .roomy: return 6
        }
    }

    var sectionGap: CGFloat {
        switch self {
        case .cozy: return 18
        case .comfy: return 22
        case .roomy: return 30
        }
    }
}

/// Glass/material intensity presets (`VOCI_GLASS`). Default is `.standard`. Blur/opacity numbers
/// unchanged — they already read as "deep, cool, low-key" once layered over the new ink `bg`/
/// `borderHi` tokens above (see `Glass.swift`'s default `tint`/`borderColor`), so no numeric
/// retune was needed here.
enum GlassLevel: Sendable, Equatable, Hashable {
    case subtle, standard, heavy

    /// CSS `backdrop-filter: blur()` radius from the prototype — kept for documentation/fidelity
    /// even though SwiftUI's system `Material`s don't take an explicit blur radius parameter.
    var blur: CGFloat {
        switch self {
        case .subtle: return 14
        case .standard: return 24
        case .heavy: return 36
        }
    }

    /// Opacity of the `VociColor.bg` tint layered over the system material.
    var bgOpacity: Double {
        switch self {
        case .subtle: return 0.92
        case .standard: return 0.78
        case .heavy: return 0.55
        }
    }

    /// Nearest system `Material` for each intensity (native-first per §6 — no custom blur
    /// implementation). More blur/opacity in the prototype maps to a heavier material.
    var material: Material {
        switch self {
        case .subtle: return .ultraThinMaterial
        case .standard: return .thinMaterial
        case .heavy: return .thickMaterial
        }
    }
}

// MARK: - Fonts & numeric fidelity helpers

extension Font {
    /// Convenience matching the prototype's default system font stack (`--ui`); SwiftUI's
    /// `.system` font already resolves to SF Pro on macOS, so no custom font registration is
    /// needed.
    static func voci(size: CGFloat, weight: Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// NEW — the prototype's `--mono` instrument face (`ui-monospace, SFMono-Regular, Menlo, …`).
    /// Reserved for instrument readouts per foundations.html §02/§05: WIP counter, timers, step
    /// counts, estimates — NOT general UI copy. SwiftUI's `.system(design: .monospaced)` resolves
    /// to SF Mono on macOS, matching the prototype's stack head (`ui-monospace`/`SFMono-Regular`).
    static func vociMono(size: CGFloat, weight: Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension View {
    /// `fontVariantNumeric: tabular-nums` equivalent (§6 fidelity mapping).
    func vociTabularNumbers() -> some View {
        monospacedDigit()
    }
}

/// Shared motion curves so every interaction feels like one system. Spring-based for a soft,
/// premium feel. NEVER use `.repeatForever` on a MenuBarExtra/NSStatusItem-hosted view. Durations
/// unchanged by the retheme — all four are already state-change-only and ≤380ms, consistent with
/// the Studio Dark motion rule ("minimal, state-change only, ≤300ms-ish, no looping/breathing").
/// `menubar-now.html`'s `.mic.live` breathing `@keyframes` is intentionally NOT ported here — the
/// spec itself only applies it to a live-listening mic affordance, not spotlight/token-level motion,
/// and this file must not introduce any looping animation.
enum VociMotion {
    /// Hover / active / selection feedback — snappy but soft.
    static let hover = Animation.spring(response: 0.26, dampingFraction: 0.82)
    /// Press-down feedback — quick.
    static let press = Animation.spring(response: 0.20, dampingFraction: 0.72)
    /// List insert / remove / reorder.
    static let list = Animation.spring(response: 0.38, dampingFraction: 0.86)
    /// Capture-state cross-fades / banners.
    static let state = Animation.easeInOut(duration: 0.20)
}

// MARK: - NEW: Spotlight primitive (foundations.html §03 "The spotlight — the signature";
// menubar-now.html `.pool` + `.vignette`)

/// The reusable warm radial pool + vignette-into-cool-shadow that sits behind exactly ONE (the
/// active/NOW) task. Theme-level only — no view currently adopts this; it's prepared here so a
/// later per-view pass can drop `.vociSpotlight()` onto the NOW task's container without
/// reinventing the gradient math. Two layers, matching the prototype 1:1:
///   1. `.pool` — a soft warm radial glow (`nowGlow` → `nowGlowSoft` → clear), blurred.
///   2. `.vignette` — a dark radial overlay that settles the pool's edges into cool shadow.
/// UNVERIFIED: not build-checked on this machine (Windows, no Xcode) — `RadialGradient`,
/// `ZStack`, and `.blur(radius:)` are all macOS 10.15+ SwiftUI API, so this should compile
/// cleanly on the macOS 14 floor, but the composited visual result hasn't been rendered/verified.
struct SpotlightBackground: ViewModifier {
    /// When `false`, renders nothing — so a view can conditionally spotlight only the active task
    /// (`isActive: task.id == appState.activeTaskID`, wired up by the view layer later) without an
    /// `if`/`else` at every call site.
    var isActive: Bool = true

    func body(content: Content) -> some View {
        content
            .background(
                Group {
                    if isActive {
                        RadialGradient(
                            colors: [VociColor.nowGlow, VociColor.nowGlowSoft, Color.clear],
                            center: .center,
                            startRadius: 4,
                            endRadius: 260
                        )
                        .blur(radius: 6)
                    }
                }
                .allowsHitTesting(false)
            )
            .overlay(
                Group {
                    if isActive {
                        RadialGradient(
                            colors: [Color.clear, VociColor.bg.opacity(0.45)],
                            center: UnitPoint(x: 0.5, y: 0.32),
                            startRadius: 140,
                            endRadius: 320
                        )
                    }
                }
                .allowsHitTesting(false)
            )
    }
}

extension View {
    /// Applies the warm spotlight pool + vignette behind this view. Intended for exactly one
    /// (the NOW) task container at a time — "if two things on a screen are amber, one of them is
    /// wrong" (foundations.html §01 rule-callout).
    func vociSpotlight(isActive: Bool = true) -> some View {
        modifier(SpotlightBackground(isActive: isActive))
    }
}
