import NollieCore
import SwiftUI

/// The arithmetic for table columns and for the scroll edges. Free of views so tests reach it.
enum MarkdownTableMetrics {
    /// The sheet has room, so long cells get wider columns and fewer lines.
    static let sheetMaxColumn: CGFloat = 320
    /// Column cap for table cards in the thread: a long cell wraps onto three lines before it may widen.
    static let bubbleMaxColumn: CGFloat = 220
    /// Room for a short word with its padding, but small enough for a rank number or an emoji.
    static let minColumn: CGFloat = 64

    /// Whether more table lies past the left or right edge of a sideways scroll view.
    struct Overflow: Equatable {
        /// A table scrolls only if it is wider than the card, starting from the first column, so
        /// before any measurement the safe guess is that part of it hides on the right.
        var trailing: Bool
        var leading: Bool

        init(leading: Bool = false, trailing: Bool = true) {
            self.trailing = trailing
            self.leading = leading
        }
    }

    static func overflow(contentWidth: CGFloat, visibleMinX: CGFloat, visibleMaxX: CGFloat) -> Overflow {
        let moreOnLeft = visibleMinX > 1
        let moreOnRight = visibleMaxX + 1 < contentWidth
        return Overflow(leading: moreOnLeft, trailing: moreOnRight)
    }

    /// One width per column. `natural` is each column's width on a single line, clamped to
    /// `lo...hi`. If `fill` leaves room over, wrapped columns first get back toward their
    /// one-line width (all of them share the room when it is short), then every column grows
    /// by the same ratio. With no room the clamped widths stay and the table scrolls.
    static func columnWidths(natural: [CGFloat], fill: CGFloat?, min lo: CGFloat, max hi: CGFloat) -> [CGFloat] {
        let clamped = natural.map { Swift.max(lo, Swift.min(hi, $0)) }
        // An unbounded proposal is not a width to stretch to.
        if clamped.isEmpty { return clamped }
        guard let fill, fill.isFinite else { return clamped }
        let room = fill - clamped.reduce(0, +)
        if room <= 0.5 { return clamped }

        let shortfall = zip(natural, clamped).map { Swift.max(0, $0 - $1) }
        let shortfallSum = shortfall.reduce(0, +)
        let refund = shortfallSum > 0 ? Swift.min(1, room / shortfallSum) : 0
        let restored = zip(clamped, shortfall).map { $0 + $1 * refund }
        let remaining = room - shortfallSum * refund
        if remaining <= 0.5 { return restored }
        let ratio = 1 + remaining / restored.reduce(0, +)
        return restored.map { $0 * ratio }
    }

}

/// Puts table cells into rows of `columns` (the header comes first). Row height follows the tallest
/// cell in it. SwiftUI's own Grid split the width evenly, which squeezed a wide table to a few
/// letters per column.
struct MarkdownTableLayout: Layout {
    var minColumn: CGFloat = MarkdownTableMetrics.minColumn
    var columns: Int
    var maxColumn: CGFloat = MarkdownTableMetrics.bubbleMaxColumn
    /// Width to grow to if the columns add up to less. With nil the proposal is used instead; a
    /// horizontal scroll view proposes none, which leaves the table at its natural width.
    var fillWidth: CGFloat? = nil

    /// Measurements kept until the cells change.
    struct Cache {
        var oneLine: [CGFloat]?
        var wrapped: (widths: [CGFloat], heights: [CGFloat])?
    }

    /// Column widths and row heights, plus the edges they imply.
    private struct Measure {
        var widths: [CGFloat]
        var heights: [CGFloat]

        var size: CGSize { .init(width: widths.reduce(0, +), height: heights.reduce(0, +)) }
        var lefts: [CGFloat] { Self.runningTotals(widths) }
        var tops: [CGFloat] { Self.runningTotals(heights) }

        private static func runningTotals(_ steps: [CGFloat]) -> [CGFloat] {
            var edges: [CGFloat] = [0]
            for step in steps { edges.append(edges[edges.count - 1] + step) }
            return edges
        }
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = Cache(oneLine: nil, wrapped: nil)
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(oneLine: nil, wrapped: nil)
    }

    private func oneLineWidths(_ subviews: Subviews) -> [CGFloat] {
        var widest = [CGFloat](repeating: 0, count: columns)
        for (position, cell) in subviews.enumerated() {
            let column = position % columns
            widest[column] = max(widest[column], cell.sizeThatFits(.unspecified).width)
        }
        return widest
    }

    private func rowHeights(_ subviews: Subviews, widths: [CGFloat]) -> [CGFloat] {
        let rowCount = Int((Double(subviews.count) / Double(columns)).rounded(.up))
        var heights = [CGFloat](repeating: 0, count: rowCount)
        for (position, cell) in subviews.enumerated() {
            let height = cell.sizeThatFits(.init(width: widths[position % columns], height: nil)).height
            heights[position / columns] = max(heights[position / columns], height)
        }
        return heights
    }

    private func measure(_ proposal: ProposedViewSize, _ subviews: Subviews, _ cache: inout Cache) -> Measure {
        let natural = cache.oneLine ?? oneLineWidths(subviews)
        cache.oneLine = natural
        let widths = MarkdownTableMetrics.columnWidths(natural: natural, fill: fillWidth ?? proposal.width,
                                                       min: minColumn, max: maxColumn)
        if let kept = cache.wrapped, kept.widths == widths { return Measure(widths: widths, heights: kept.heights) }
        let heights = rowHeights(subviews, widths: widths)
        cache.wrapped = (widths, heights)
        return Measure(widths: widths, heights: heights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        if columns <= 0 || subviews.isEmpty { return .zero }
        return measure(proposal, subviews, &cache).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        if columns <= 0 || subviews.isEmpty { return }
        let found = measure(proposal, subviews, &cache)
        let (lefts, tops) = (found.lefts, found.tops)
        for (position, cell) in subviews.enumerated() {
            let (row, column) = position.quotientAndRemainder(dividingBy: columns)
            let origin = CGPoint(x: bounds.minX + lefts[column], y: bounds.minY + tops[row])
            cell.place(at: origin, anchor: .topLeading, proposal: .init(width: found.widths[column], height: found.heights[row]))
        }
    }
}
