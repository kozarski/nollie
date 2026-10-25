import SwiftUI

/// Bubble outline like the one in Messages. With `tailed` set (the final bubble in a run) the
/// speaker's lower corner stretches into a little curled point; otherwise it is a plain rounded box.
struct MessageBubbleShape: Shape {
    enum Side: Hashable {
        case leading
        case trailing
    }

    let side: Side
    let tailed: Bool
    let radius: CGFloat

    init(side: Side, tailed: Bool = true, radius: CGFloat = 18) {
        self.radius = radius
        self.tailed = tailed
        self.side = side
    }

    /// How far the tail's point reaches past the bubble.
    private let reach: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        let corner = min(radius, rect.height / 2, rect.width / 2)
        if !tailed { return Path(roundedRect: rect, cornerRadius: corner, style: .continuous) }
        let outline = trailingTail(in: rect, corner: corner)
        // The tail is drawn on the right; a flip across the middle moves it to the left.
        guard side == .leading else { return outline }
        return outline.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 2 * rect.midX, ty: 0))
    }

    private func trailingTail(in rect: CGRect, corner r: CGFloat) -> Path {
        func spot(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        let (west, east, north, south) = (rect.minX, rect.maxX, rect.minY, rect.maxY)
        return Path { outline in
            func corner(at center: CGPoint, from start: Double, to end: Double) {
                outline.addArc(center: center, radius: r, startAngle: .degrees(start), endAngle: .degrees(end), clockwise: false)
            }
            outline.move(to: spot(west + r, north))
            outline.addLine(to: spot(east - r, north))
            corner(at: spot(east - r, north + r), from: -90, to: 0)
            outline.addLine(to: spot(east, south - r))
            // Out to the point: the edge keeps falling and flares.
            outline.addCurve(to: spot(east + reach, south),
                             control1: spot(east, south - 0.45 * r),
                             control2: spot(east + 0.9 * reach, south - 0.18 * r))
            // Back under itself, onto the flat bottom.
            outline.addCurve(to: spot(east - 0.6 * r, south),
                             control1: spot(east + 0.25 * reach, south),
                             control2: spot(east - 0.12 * r, south - 0.04 * r))
            outline.addLine(to: spot(west + r, south))
            corner(at: spot(west + r, south - r), from: 90, to: 180)
            outline.addLine(to: spot(west, north + r))
            corner(at: spot(west + r, north + r), from: 180, to: 270)
            outline.closeSubpath()
        }
    }
}
