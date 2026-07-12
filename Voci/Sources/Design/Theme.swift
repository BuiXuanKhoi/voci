// Sources/Design/Theme.swift — frozen design tokens: palette, accents, density, glass (spec §3)
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

/// Base palette — dark-only literals ported from `design/tokens.jsx` (`VOCI_BASE`).
enum VociColor {
    static let bg = Color(voci: 0x1C1C1E)
    static let surface = Color(voci: 0x2C2C2E)
    static let surfaceHi = Color(voci: 0x3A3A3C)
    static let card = Color.white.opacity(0.05)
    static let cardHover = Color.white.opacity(0.08)
    static let border = Color.white.opacity(0.08)
    static let borderHi = Color.white.opacity(0.14)
    static let textPri = Color.white.opacity(0.88)
    static let textSec = Color.white.opacity(0.45)
    static let textMut = Color.white.opacity(0.25)
    static let high = Color(voci: 0xFF6B6B)
    static let med = Color(voci: 0xFFB347)
    static let low = Color.white.opacity(0.30)
    static let destruct = Color(voci: 0xFF453A)
    static let done = Color(voci: 0x5BD17A)
}

/// One accent family's four derived roles (`VOCI_ACCENTS.*`).
struct Accent: Sendable {
    let solid: Color
    let hover: Color
    let surface: Color
    let glow: Color
}

/// Selectable accent families (`VOCI_ACCENTS`). Default is `.indigo`.
enum VociAccent: String, CaseIterable, Identifiable, Sendable, Equatable, Hashable {
    case indigo, teal, amber, magenta

    var id: String { rawValue }

    var accent: Accent {
        switch self {
        case .indigo:
            let solid = Color(voci: 0x6B6BFF)
            return Accent(solid: solid, hover: Color(voci: 0x8B8BFF), surface: solid.opacity(0.15), glow: solid.opacity(0.45))
        case .teal:
            let solid = Color(voci: 0x3DD5C7)
            return Accent(solid: solid, hover: Color(voci: 0x6FE3D8), surface: solid.opacity(0.15), glow: solid.opacity(0.45))
        case .amber:
            let solid = Color(voci: 0xFFB547)
            return Accent(solid: solid, hover: Color(voci: 0xFFC76B), surface: solid.opacity(0.15), glow: solid.opacity(0.45))
        case .magenta:
            let solid = Color(voci: 0xFF6BD0)
            return Accent(solid: solid, hover: Color(voci: 0xFF8BD9), surface: solid.opacity(0.15), glow: solid.opacity(0.45))
        }
    }
}

/// Row/section spacing presets (`VOCI_DENSITY`). Default is `.comfy`.
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

/// Glass/material intensity presets (`VOCI_GLASS`). Default is `.standard`.
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
    /// Convenience matching the prototype's default system font stack; SwiftUI's `.system` font
    /// already resolves to SF Pro on macOS, so no custom font registration is needed.
    static func voci(size: CGFloat, weight: Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

extension View {
    /// `fontVariantNumeric: tabular-nums` equivalent (§6 fidelity mapping).
    func vociTabularNumbers() -> some View {
        monospacedDigit()
    }
}
