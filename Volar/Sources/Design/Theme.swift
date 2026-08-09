// Sources/Design/Theme.swift — frozen design tokens: palette, accents, density, glass (spec §3)
//
// RETHEME 3 — "Volar Graphite" (2026-08-07, specs/005-cursor-retheme/design-spec.md). Supersedes
// RETHEME 2 "Volar Twilight" (2026-07-26) on ink/hairline/text VALUES only — the mint spotlight
// rule, the anti-red rule, and the mint logo family it all serves are untouched. Token NAMES are
// unchanged yet again, so every call site keeps compiling — only values moved.
//
// What changed vs. Twilight, and why: Twilight's three ink layers (`bg`/`surface`/`surfaceHi`) and
// its hairline/veil base were tinted cool blue (`0x94B2E0`) on the theory that a night-blue room
// makes the mint spotlight read as a light source rather than a green chip on gray. In practice the
// blue ink was the SAME family as the mint accent it was supposed to set off — it competed with the
// spotlight instead of making it pop. This pass (borrowing Cursor's IDE palette, see the spec's §0)
// moves the ink to a near-neutral graphite (R≈G, B nudged +2) and reverts every hairline/veil/card
// token to a plain white base at lower alphas, exactly as it was before Twilight. A neutral ground
// is the best possible backdrop for a single colored light source: nothing on the page competes
// with mint for "warmest/coolest thing in the room" except mint itself.
//
// THE ONE RULE (unchanged, still the whole point): mint (`nowAccent` family) is a spotlight, not a
// brand-everywhere color — reserved for the single active/NOW task (spotlight glow, NOW label, NOW
// focus ring). The app-wide accent (`VolarAccent.indigo`, the default) and every informational
// token resolve to the ICE BLUE instrument family instead. If two things on a screen are mint, one
// of them is wrong.
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
    // --- Ink / depth — Graphite's three near-neutral layers ---
    /// `--ink-0` — base bg, deepest. Graphite page ground.
    static let bg = Color(volar: 0x0F0F11)
    /// `--surface-1` — raised surface, one step up from `bg`. NOTE: name predates the retheme.
    static let surface = Color(volar: 0x16161A)
    /// `--surface-2` — raised surface, higher. Card / input / hover panel.
    static let surfaceHi = Color(volar: 0x1E1E23)
    /// Low-key translucent card fill over whichever surface it sits on. Base reverted to plain
    /// white (was Twilight's cool-blue `0x94B2E0`, see file header): the ink is now a near-neutral
    /// graphite, so a white film no longer greys the surface out the way it did over night-blue ink
    /// — a white veil is what Cursor itself uses over its own neutral ground.
    static let card = Color.white.opacity(0.035)
    static let cardHover = Color.white.opacity(0.06)
    /// `--hairline` — reverted to white (was Twilight's cool-blue `rgba(148,178,224,.10)`); alpha
    /// also dropped 0.10 → 0.07. Cursor separates panels by a fill delta more than a drawn line, so
    /// the hairline can afford to sit lighter than it did on Twilight's blue ink.
    static let border = Color.white.opacity(0.07)
    /// `--hairline-strong` — reverted to white, alpha dropped 0.18 → 0.12 (was Twilight's
    /// `rgba(148,178,224,.18)`).
    static let borderHi = Color.white.opacity(0.12)

    /// One-off translucent film at an arbitrary strength, for the ~40 places across the views that
    /// need a fill/stroke between two named tokens (hover tints, chip backgrounds, progress-track
    /// fills). Reverted to the pre-Twilight formula — plain `Color.white.opacity(x)` — now that the
    /// ink underneath it is graphite instead of night-blue, so every one of those ~40 call sites
    /// needs no edits: the base changed here, not at the call site. Prefer a named token when one
    /// fits — this exists so a view never has to reach back for `Color.white` directly.
    static func veil(_ opacity: Double) -> Color { Color.white.opacity(opacity) }

    // --- Text (foundations.html --tx-1/2/3) ---
    /// `--tx-1` primary. Contrast vs `bg` (#0F0F11) ≈ 15.7:1 — passes WCAG AAA for body text.
    static let textPri = Color(volar: 0xE8E8EA)
    /// `--tx-2` secondary. Contrast vs `bg` ≈ 7.5:1 — passes WCAG AA (and AAA) for body text.
    static let textSec = Color(volar: 0xA1A1A8)
    /// `--tx-3` tertiary / muted. Contrast vs `bg` ≈ 3.6:1 — intentionally BELOW body-text AA per
    /// the source spec (this token is for de-emphasized/tertiary labels, never body copy).
    static let textMut = Color(volar: 0x6B6B74)

    // --- Priority / status dots & badges ---
    // No red, ever (anti-shame rule, foundations.html §01 rule-callout) and no mint (mint is
    // reserved exclusively for `nowAccent`/the NOW spotlight — see file header). Priority hierarchy
    // is expressed as a warm-neutral clay → taupe → cool-gray ramp, which stays clear of the
    // reserved hue by construction: nothing in this ramp is green.
    /// High priority — muted clay/terracotta. Deliberately NOT alarm red. (Pre-Twilight this also
    /// had to dodge the amber NOW spotlight; amber is no longer reserved. Held again through the
    /// Graphite pass, unchanged — on a neutral graphite ground this warm ramp becomes the ONLY warm
    /// hue anywhere on screen, so the priority tier reads even more clearly than it did on Twilight's
    /// blue ink: warm = priority, cool = information, mint = NOW.)
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

/// Row/section spacing presets (`VOLAR_DENSITY`). Default is `.comfy`. Tightened in the Graphite
/// pass (§1.7): Cursor's list density reads chattier/denser than Twilight's, so every tier's
/// padding/gap moved down a notch. See per-case comments below for the old (Twilight) numbers.
enum Density: Sendable, Equatable, Hashable {
    case cozy, comfy, roomy

    var rowPadY: CGFloat {
        switch self {
        case .cozy: return 5
        case .comfy: return 8   // was 10 (Twilight)
        case .roomy: return 12  // was 14 (Twilight)
        }
    }

    var rowGap: CGFloat {
        switch self {
        case .cozy: return 2
        case .comfy: return 3   // was 4 (Twilight)
        case .roomy: return 5   // was 6 (Twilight)
        }
    }

    var sectionGap: CGFloat {
        switch self {
        case .cozy: return 14
        case .comfy: return 18  // was 22 (Twilight)
        case .roomy: return 26  // was 30 (Twilight)
        }
    }
}

/// Glass/material intensity presets (`VOLAR_GLASS`). Default is `.standard`. `blur` and `material`
/// are unchanged by the Graphite pass; `bgOpacity` moved up sharply (§1.5, "flatten by default" —
/// design-spec.md §0 rule 5) because blur is now reserved for surfaces that truly float over the
/// desktop (menubar popover, `FocusOverlay`) — every panel inside the main window should read flat
/// and opaque instead of glassy. See per-case comments below for the old (Twilight) numbers.
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
        case .subtle: return 1.00    // was 0.92 (Twilight) — fully flat, no material shows through
        case .standard: return 0.97  // was 0.78 (Twilight) — material still present, nearly invisible
        case .heavy: return 0.80     // was 0.55 (Twilight) — still glass; for surfaces floating over the desktop
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

/// The reusable mint radial pool + vignette-into-shadow that sits behind exactly ONE (the
/// active/NOW) task. Theme-level only — no view currently adopts this; it's prepared here so a
/// later per-view pass can drop `.volarSpotlight()` onto the NOW task's container without
/// reinventing the gradient math. Two layers, matching the prototype 1:1:
///   1. `.pool` — a soft mint radial glow (`nowGlow` → `nowGlowSoft` → clear), blurred.
///   2. `.vignette` — a dark radial overlay that settles the pool's edges into `bg` shadow (graphite
///      as of the RETHEME 3 pass, was night-blue under Twilight — the overlay itself is unchanged,
///      it just reads `VolarColor.bg` live).
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
