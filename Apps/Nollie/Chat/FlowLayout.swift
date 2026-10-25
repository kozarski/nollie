import SwiftUI

/// Places children from left to right and continues on new lines when full, as with the recipient chips in
/// Messages.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    typealias Cache = Void

    /// A child with the size it was given on its line.
    private struct Slot {
        let index: Int
        let size: CGSize
    }

    private typealias Line = [Slot]

    /// Breaks the children into lines. Each is measured against the space left on its line, so a
    /// text field takes what remains and not its huge ideal width. It drops to the next line only
    /// if even its smallest width won't fit.
    private func breakIntoLines(width: CGFloat, _ subviews: Subviews) -> [Line] {
        var lines: [Line] = [[]]
        var filled: CGFloat = 0
        for (index, child) in subviews.enumerated() {
            let smallest = child.sizeThatFits(.init(width: 0, height: nil)).width
            if filled > 0, smallest > max(0, width - filled) {
                lines.append([])
                filled = 0
            }
            let space = max(0, width - filled)
            let ideal = child.sizeThatFits(.init(width: space, height: nil))
            let size = CGSize(width: min(ideal.width, space), height: ideal.height)
            lines[lines.count - 1].append(Slot(index: index, size: size))
            filled += size.width + spacing
        }
        return lines
    }

    private func tallest(_ line: Line) -> CGFloat { line.map(\.size.height).max() ?? 0 }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width ?? 320.0
        let lines = breakIntoLines(width: width, subviews)
        let between = spacing * CGFloat(max(0, lines.count - 1))
        return CGSize(width: width, height: lines.map(tallest).reduce(0, +) + between)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        var y = bounds.minY
        for line in breakIntoLines(width: bounds.width, subviews) {
            let rowHeight = tallest(line)
            var x = bounds.minX
            for slot in line {
                let offset = (rowHeight - slot.size.height) / 2
                subviews[slot.index].place(at: CGPoint(x: x, y: y + offset),
                                           proposal: .init(width: slot.size.width, height: slot.size.height))
                x += slot.size.width + spacing
            }
            y += rowHeight + spacing
        }
    }
}
