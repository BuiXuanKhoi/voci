// Sources/Views/Waveform.swift — animated capture waveform (TimelineView + Canvas)
import SwiftUI

/// Ported from `design/voci-popover.jsx`'s `Waveform`: a row of vertical bars driven by layered
/// sines for an organic "listening" feel. While `active`, height is redrawn every frame via
/// `TimelineView(.animation)`. When `active == false` it settles to a flat 3px line with no
/// animation — mirroring the JSX effect that sets every bar to `height: 3px` and cancels the RAF
/// loop rather than animating the transition.
struct Waveform: View {
    let active: Bool
    let color: Color
    let glow: Color
    var bars: Int = 32
    var height: CGFloat = 42

    init(active: Bool, color: Color, glow: Color, bars: Int = 32, height: CGFloat = 42) {
        self.active = active
        self.color = color
        self.glow = glow
        self.bars = bars
        self.height = height
    }

    private let barWidth: CGFloat = 3
    private let spacing: CGFloat = 3

    var body: some View {
        Group {
            if active {
                TimelineView(.animation) { context in
                    Canvas { canvasContext, size in
                        let t = context.date.timeIntervalSinceReferenceDate
                        canvasContext.addFilter(.shadow(color: glow, radius: 4))
                        drawBars(in: &canvasContext, size: size) { i in
                            barHeight(at: i, t: t)
                        }
                    }
                }
            } else {
                Canvas { canvasContext, size in
                    drawBars(in: &canvasContext, size: size) { _ in 3 }
                }
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
    }

    /// Layered-sine bar height, ported 1:1 from the JSX `tick()` formula:
    /// `sin(t*6+phase)*0.55 + sin(t*10+phase*1.7)*0.35 + cos(t*3+phase*0.5)*0.2`, normalized to
    /// `[0,1]`, shaped by a soft Gaussian envelope that's lower at the edges, min height 2.
    private func barHeight(at i: Int, t: Double) -> CGFloat {
        let phase = Double(i) * 0.35
        let v = sin(t * 6 + phase) * 0.55
            + sin(t * 10 + phase * 1.7) * 0.35
            + cos(t * 3 + phase * 0.5) * 0.2
        let norm = (v + 1.1) / 2.2
        let half = Double(bars) / 2.0
        let denom = Double(bars) / 2.6
        let env = 0.4 + 0.6 * exp(-pow((Double(i) - half) / denom, 2))
        return max(2, CGFloat(norm * env) * (height - 4))
    }

    /// Shared bar-layout pass: centers `bars` rounded rects of `barWidth`, `spacing` apart,
    /// vertically centered, each with a caller-supplied height.
    private func drawBars(in context: inout GraphicsContext, size: CGSize, heightFor: (Int) -> CGFloat) {
        let totalWidth = CGFloat(bars) * barWidth + CGFloat(max(bars - 1, 0)) * spacing
        let startX = (size.width - totalWidth) / 2
        let midY = size.height / 2

        for i in 0..<bars {
            let h = heightFor(i)
            let x = startX + CGFloat(i) * (barWidth + spacing)
            let rect = CGRect(x: x, y: midY - h / 2, width: barWidth, height: h)
            let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)
            context.fill(path, with: .color(color))
        }
    }
}

#Preview {
    VStack(spacing: 24) {
        Waveform(active: true, color: Color(voci: 0x6B6BFF), glow: Color(voci: 0x6B6BFF, opacity: 0.45))
        Waveform(active: false, color: Color(voci: 0x6B6BFF), glow: Color(voci: 0x6B6BFF, opacity: 0.45))
    }
    .padding(24)
    .background(VociColor.bg)
}
