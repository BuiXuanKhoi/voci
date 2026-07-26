// Sources/Design/Glass.swift — GlassBackground + material/tint/hairline helpers (spec §6)
//
// RETHEME (Studio Dark) — no structural change here. This panel's tint/border default straight
// through to `VolarColor.bg` / `VolarColor.borderHi` (Theme.swift), so retheming those tokens to the
// deep-ink Studio Dark palette already tunes every `volarGlass`/`volarHairline` call site to be
// deep, cool, and low-key — no numeric change was needed in this file.
import SwiftUI

/// Backing view for "Liquid Glass" panels: a system `Material` (native blur, no custom
/// Metal/Canvas blur) tinted with a base color at the level's opacity, plus a 0.5px hairline
/// border — the SwiftUI equivalent of the prototype's `backdrop-filter: blur()` + a
/// `border: 0.5px solid …` (§6 fidelity mapping).
struct GlassBackground: View {
    var level: GlassLevel
    var tint: Color
    var cornerRadius: CGFloat
    var borderColor: Color

    init(
        level: GlassLevel = .standard,
        tint: Color = VolarColor.bg,
        cornerRadius: CGFloat = 12,
        borderColor: Color = VolarColor.borderHi
    ) {
        self.level = level
        self.tint = tint
        self.cornerRadius = cornerRadius
        self.borderColor = borderColor
    }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(level.material)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(tint.opacity(level.bgOpacity))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(borderColor, lineWidth: 0.5)
            )
    }
}

extension View {
    /// Applies `GlassBackground` behind this view, clipped to the same rounded rect.
    func volarGlass(level: GlassLevel = .standard, tint: Color = VolarColor.bg, cornerRadius: CGFloat = 12) -> some View {
        background(GlassBackground(level: level, tint: tint, cornerRadius: cornerRadius))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// A bare 0.5px hairline border for elements that already have their own fill/material (e.g.
    /// task rows) — the `border: 0.5px solid …` fidelity mapping (§6) without a full glass panel.
    func volarHairline(_ color: Color = VolarColor.border, cornerRadius: CGFloat = 9, lineWidth: CGFloat = 0.5) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(color, lineWidth: lineWidth)
        )
    }
}
