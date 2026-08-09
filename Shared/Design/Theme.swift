// Sources/Design/Theme.swift — frozen design tokens: palette, accents, density, glass (spec §3)
//
// RETHEME 2 — "Volar Twilight" (2026-07-26). Values taken from the design board of that name
// (claude.ai/design, project "Voci voice command app design", `Volar Twilight.dc.html`), which is
// now the source of truth for palette and tone; it supersedes the earlier "Studio Dark / One Lit
// Thing" pass whose prototype files (`volar-redesign/foundations.html`, `menubar-now.html`) the
// comments below still cite for PROVENANCE of each token's role. Token NAMES are unchanged again,
// so every call site keeps compiling — only values moved.
//
// What changed vs. Studio Dark, and why: the key light is now MINT, matching the logo mark
// (assets/…design.zip -> export-logo/README.txt: "nón sáng rọi xuống đúng một chấm"; the lit dot is
// mint and is the brand's whole identity). Warm amber was the key light when the palette had no
// logo to answer to; keeping it would have left the app's single brightest element a different hue
// from the mark on its own icon. The neutral graphite ink also moves to the board's three night-blue
// layers so the mint reads as a light source in a blue room rather than a green chip on gray.
//
// THE ONE RULE (unchanged in spirit, new hue): mint (`nowAccent` family) is a spotlight, not a
// brand-everywhere color — reserved for the single active/NOW task (spotlight glow, NOW label, NOW
// focus ring). The board states it as "bạc hà = NOW duy nhất · xanh băng = thông tin". So the
// app-wide accent (`VolarAccent.indigo`, the default) and every informational token resolve to the
// ICE BLUE instrument family instead. If two things on a screen are mint, one of them is wrong.
import SwiftUI

extension Color {
    /// Constructs a `Color` from a 24-bit RGB literal (e.g. `0xFF6B6B`), always going through
    /// the exact `Color(.sRGB, red:green:blue:opacity:)` initializer the token spec calls for.
    /// Centralizing the hex math here (instead of hand-computing decimals at each call site)
    /// keeps every token numerically exact.
    init(volar hex: UInt32, opacity: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}

/// Base palette — Studio Dark ink + text + priority/status tokens, ported from
/// `volar-redesign/foundations.html`'s `:root` custom properties (`--ink-*`, `--surface-*`,
/// `--tx-*`, `--sage`, etc). Dark-only; this app is dark-first Studio Dark (see §"Support
/// light+dark?" — no light variant exists here, so none needs preserving).
enum VolarColor {
    // --- Ink / depth — Twilight's "3 tầng xanh đêm" (three night-blue layers) ---
    /// `--ink-0` — base bg, deepest. Twilight page ground.
    static let bg = Color(volar: 0x07090E)
    /// `--surface-1` — raised surface, one step up from `bg`. NOTE: name predates the retheme.
    static let surface = Color(volar: 0x0A101C)
    /// `--surface-2` — raised surface, higher. Top of the Mac window's own gradient on the board.
    static let surfaceHi = Color(volar: 0x101827)
    /// Low-key translucent card fill over whichever surface it sits on. Tinted with the same cool
    /// blue as the hairlines rather than pure white: over night-blue ink a white veil greys the
    /// surface out, which is what made the old chrome read as gray plastic.
    static let card = Color(volar: 0x94B2E0, opacity: 0.05)
    static let cardHover = Color(volar: 0x94B2E0, opacity: 0.08)
    /// `--hairline` — Twilight draws every divider/edge as `rgba(148,178,224,.10)`, a cool blue
    /// hairline, NOT white. This is what keeps window edges from reading as a bright white line.
    static let border = Color(volar: 0x94B2E0, opacity: 0.10)
    /// `--hairline-strong` — the board's stronger edge, `rgba(148,178,224,.18)`.
    static let borderHi = Color(volar: 0x94B2E0, opacity: 0.18)

    /// One-off translucent film at an arbitrary strength, for the ~40 places across the views that
    /// need a fill/stroke between two named tokens (hover tints, chip backgrounds, progress-track
    /// fills). Those all used `Color.white.opacity(x)` before Twilight; over night-blue ink a white
    /// film desaturates the surface to grey, so they take the SAME cool base as `border`/`card` and
    /// keep their original alpha. Prefer a named token when one fits — this exists so a view never
    /// has to reach back for `Color.white` and reintroduce the grey.
    static func veil(_ opacity: Double) -> Color { Color(volar: 0x94B2E0, opacity: opacity) }

    // --- Text (foundations.html --tx-1/2/3) ---
    /// `--tx-1` primary. Contrast vs `bg` (#07090E) ≈ 16.9:1 — passes WCAG AAA for body text.
    static let textPri = Color(volar: 0xEDF2F9)
    /// `--tx-2` secondary. Contrast vs `bg` ≈ 7.9:1 — passes WCAG AA (and AAA) for body text.
    static let textSec = Color(volar: 0x9AA7BC)
    /// `--tx-3` tertiary / muted. Contrast vs `bg` ≈ 3.3:1 — intentionally BELOW body-text AA per
    /// the source spec (this token is for de-emphasized/tertiary labels, never body copy).
    static let textMut = Color(volar: 0x57637C)

    // --- Priority / status dots & badges ---
    // No red, ever (anti-shame rule, foundations.html §01 rule-callout) and no mint (mint is
    // reserved exclusively for `nowAccent`/the NOW spotlight — see file header). Priority hierarchy
    // is expressed as a warm-neutral clay → taupe → cool-gray ramp, which stays clear of the
    // reserved hue by construction: nothing in this ramp is green.
    /// High priority — muted clay/terracotta. Deliberately NOT alarm red. (Pre-Twilight this also
    /// had to dodge the amber NOW spotlight; amber is no longer reserved, but the ramp is unchanged
    /// — it reads correctly against night-blue ink and re-tuning it is not this pass's business.)
    static let high = Color(volar: 0xB9705A)
    /// Medium priority — muted warm taupe, between `high` and `low`.
    static let med = Color(volar: 0x9C8C6B)
    /// Low priority — neutral gray, unchanged formula (already palette-safe).
    static let low = Color.white.opacity(0.30)
    /// Destructive action (e.g. Delete). This is the standard macOS destructive-affordance red,
    /// distinct from the "never red for overdue/badges" anti-shame rule — that rule governs
    /// task-status badges, not an irreversible system action button. Toned down from a neon red to
    /// a muted brick to stay in the Studio Dark register.
    static let destruct = Color(volar: 0xC85C4C)
    /// `--sage` — success. Muted, not neon.
    static let done = Color(volar: 0x7FA88C)

    // MARK: - NOW / spotlight tokens (foundations.html §01, §03; hues from the Twilight board)

    /// `--mint` — THE key light, and the same mint as the lit dot in the logo mark. Used ONLY on
    /// the one NOW task (spotlight glow, NOW label, NOW focus ring, NOW primary action). Never the
    /// general/app-wide accent.
    static let nowAccent = Color(volar: 0x8FEDCB)
    /// `--mint-soft` — lighter mint, NOW title text / primary-button gradient top. Top stop of the
    /// logo mark's own gradient.
    static let nowAccentSoft = Color(volar: 0xA9F5DA)
    /// `--mint-deep` — deeper mint, gradient bottom / pressed states. Bottom stop of that same
    /// logo gradient, so a NOW button and the app icon are cut from one ramp.
    static let nowAccentDeep = Color(volar: 0x74DDB6)
    /// `--mint-glow` — the spotlight pool's inner glow.
    static let nowGlow = Color(volar: 0x8FEDCB, opacity: 0.20)
    /// `--mint-glow-soft` — the spotlight pool's outer falloff.
    static let nowGlowSoft = Color(volar: 0x8FEDCB, opacity: 0.10)
    /// `--mint-ring` — NOW-specific focus ring / hairline accent (e.g. `m-chip` border).
    static let nowRing = Color(volar: 0x8FEDCB, opacity: 0.55)

    // MARK: - Instrument tokens (foundations.html §05 "Instrument readouts")

    /// `--cool` — ice-blue instrument accent ("xanh băng = thông tin"). Informational only,
    /// sparing: WIP counter, timers, links, dependency dots. Never used for the NOW spotlight.
    static let instrument = Color(volar: 0x86B9FF)
    /// `--cool-dim` — dimmed ice blue, for dashed dependency chips / secondary instrument marks.
    static let instrumentDim = Color(volar: 0x3A4E75)

    /// `--reschedule` — calm neutral "needs rescheduling" tone. This is what overdue uses INSTEAD
    /// of red (anti-shame rule) — provided here so a later per-view pass has a token ready rather
    /// than reaching for `destruct` or inventing a one-off color.
    static let reschedule = Color(volar: 0x8A8FA0)
}

/// One accent family's four derived roles (`VOLAR_ACCENTS.*`).
struct Accent: Sendable {
    let solid: Color
    let hover: Color
    let surface: Color
    let glow: Color
}

/// Selectable accent families (`VOLAR_ACCENTS`). Default is `.indigo`, whose NAME is now a
/// misnomer kept for wire/settings compatibility (it is persisted by rawValue): it resolves to the
/// same ice blue as `VolarColor.instrument` (`--cool`), because the general-purpose/app-wide accent
/// (active states, capture button, selection) must never be the reserved mint `nowAccent`.
///
/// `.teal` (#3DBFAF) is the one family that now sits uncomfortably close to the reserved mint — a
/// user who selects it gets a second green-ish signal competing with the NOW spotlight, the same
/// problem `.amber` had before Twilight moved the spotlight off amber. Left as-is deliberately:
/// it is opt-in and off by default, and re-picking a user-facing palette entry is a design decision
/// of its own rather than a mechanical consequence of this retheme (tracked in backlog.md).
enum VolarAccent: String, CaseIterable, Identifiable, Sendable, Equatable, Hashable {
    case indigo, teal, amber, magenta

    var id: String { rawValue }

    var accent: Accent {
        switch self {
        case .indigo:
            // Ice blue (`--cool`) — the app-wide default. NOT mint.
            let solid = Color(volar: 0x86B9FF)
            return Accent(solid: solid, hover: Color(volar: 0xB3D2FF), surface: solid.opacity(0.15), glow: solid.opacity(0.45))
        case .teal:
            let solid = Color(volar: 0x3DBFAF)
            return Accent(solid: solid, hover: Color(volar: 0x63D6C7), surface: solid.opacity(0.15), glow: solid.opacity(0.45))
        case .amber:
            // Copper/burnt-orange. Was shaped this way to dodge the old amber NOW spotlight; since
            // Twilight moved the spotlight to mint it no longer has to, but the hex stays put so
            // anyone already using it doesn't wake up to a different accent.
            let solid = Color(volar: 0xD9853D)
            return Accent(solid: solid, hover: Color(volar: 0xE9A165), surface: solid.opacity(0.15), glow: solid.opacity(0.45))
        case .magenta:
            let solid = Color(volar: 0xD16BC0)
            return Accent(solid: solid, hover: Color(volar: 0xE38BD4), surface: solid.opacity(0.15), glow: solid.opacity(0.45))
        }
    }
}

/// Row/section spacing presets (`VOLAR_DENSITY`). Default is `.comfy`. Unchanged by the retheme —
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

/// Glass/material intensity presets (`VOLAR_GLASS`). Default is `.standard`. Blur/opacity numbers
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

    /// Opacity of the `VolarColor.bg` tint layered over the system material.
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
    static func volar(size: CGFloat, weight: Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// NEW — the prototype's `--mono` instrument face (`ui-monospace, SFMono-Regular, Menlo, …`).
    /// Reserved for instrument readouts per foundations.html §02/§05: WIP counter, timers, step
    /// counts, estimates — NOT general UI copy. SwiftUI's `.system(design: .monospaced)` resolves
    /// to SF Mono on macOS, matching the prototype's stack head (`ui-monospace`/`SFMono-Regular`).
    static func volarMono(size: CGFloat, weight: Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension View {
    /// `fontVariantNumeric: tabular-nums` equivalent (§6 fidelity mapping).
    func volarTabularNumbers() -> some View {
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
enum VolarMotion {
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

/// The reusable mint radial pool + vignette-into-night-shadow that sits behind exactly ONE (the
/// active/NOW) task. Theme-level only — no view currently adopts this; it's prepared here so a
/// later per-view pass can drop `.volarSpotlight()` onto the NOW task's container without
/// reinventing the gradient math. Two layers, matching the prototype 1:1:
///   1. `.pool` — a soft mint radial glow (`nowGlow` → `nowGlowSoft` → clear), blurred.
///   2. `.vignette` — a dark radial overlay that settles the pool's edges into night-blue shadow.
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
                            colors: [VolarColor.nowGlow, VolarColor.nowGlowSoft, Color.clear],
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
                            colors: [Color.clear, VolarColor.bg.opacity(0.45)],
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
    /// Applies the mint spotlight pool + vignette behind this view. Intended for exactly one
    /// (the NOW) task container at a time — if two things on a screen are mint, one of them is
    /// wrong (foundations.html §01 rule-callout; Twilight's "bạc hà = NOW duy nhất").
    func volarSpotlight(isActive: Bool = true) -> some View {
        modifier(SpotlightBackground(isActive: isActive))
    }
}
