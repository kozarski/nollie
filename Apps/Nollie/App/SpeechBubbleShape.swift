import SwiftUI

/// A speech bubble drawn as one outline, so tail and body share a stroke with no seam. The tail
/// occupies 8 points at the bottom of the frame, or at the top when `tailOnTop` is set.
struct SpeechBubbleShape: Shape {
    var tailOnTop = false

    private enum Metric {
        static let tailDepth: CGFloat = 8
        static let tailSpan: CGFloat = 16
        static let corner: CGFloat = 16
    }

    func path(in rect: CGRect) -> Path {
        // Draw the tail-down version, then turn it over for a tail on top.
        let outline = Self.tailDown(in: rect)
        guard tailOnTop else { return outline }
        let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: rect.minY + rect.maxY)
        return outline.applying(flip)
    }

    private static func tailDown(in rect: CGRect) -> Path {
        let depth = Metric.tailDepth, half = Metric.tailSpan / 2
        let body = CGRect(origin: rect.origin, size: CGSize(width: rect.width, height: rect.height - depth))
        let r = min(Metric.corner, body.height / 2)
        let mid = rect.midX
        let lean = Metric.tailSpan * 0.22, bulge = depth * 0.55

        var path = Path()
        path.move(to: CGPoint(x: body.minX + r, y: body.minY))
        path.addLine(to: CGPoint(x: body.maxX - r, y: body.minY))
        path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY), tangent2End: CGPoint(x: body.maxX, y: body.minY + r), radius: r)
        path.addLine(to: CGPoint(x: body.maxX, y: body.maxY - r))
        path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY), tangent2End: CGPoint(x: body.maxX - r, y: body.maxY), radius: r)
        path.addLine(to: CGPoint(x: mid + half, y: body.maxY))
        path.addQuadCurve(to: CGPoint(x: mid, y: rect.maxY), control: CGPoint(x: mid + lean, y: body.maxY + bulge))
        path.addQuadCurve(to: CGPoint(x: mid - half, y: body.maxY), control: CGPoint(x: mid - lean, y: body.maxY + bulge))
        path.addLine(to: CGPoint(x: body.minX + r, y: body.maxY))
        path.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY), tangent2End: CGPoint(x: body.minX, y: body.maxY - r), radius: r)
        path.addLine(to: CGPoint(x: body.minX, y: body.minY + r))
        path.addArc(tangent1End: CGPoint(x: body.minX, y: body.minY), tangent2End: CGPoint(x: body.minX + r, y: body.minY), radius: r)
        path.closeSubpath()
        return path
    }
}
