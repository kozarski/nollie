import NollieCore
import SwiftUI

/// The cells of a table. The header row is semibold on a tertiary fill, rows are divided by
/// thin lines, with inline markdown inside every cell. A body cell is read aloud by VoiceOver as
/// "header: value".
struct MarkdownTableGrid: View {
    var table: MarkdownTable
    private var columnIDs: [Int] { Array(table.header.indices) }
    var font: Font = .footnote
    private var rowIDs: [Int] { Array(table.rows.indices) }
    /// How many lines a cell shows before it is cut off. Nil shows all of them.
    var lineLimit: Int? = 3
    var maxColumn: CGFloat = MarkdownTableMetrics.bubbleMaxColumn
    var fillWidth: CGFloat? = nil
    private var cellInsets: (h: CGFloat, v: CGFloat) { (10, 7) }
    /// Extra room at the right end of the header, so a corner button never covers its text.
    var headerInset: CGFloat = 0
    /// True once rows have scrolled up beneath the header, which then draws a hairline.
    var pinned = false
    /// Whether the header stays in view over scrolling rows, on a solid fill (the sheet).
    var opaqueHeader = false

    /// The compact form used inside a chat bubble, with room kept for the corner button.
    static func bubble(_ table: MarkdownTable) -> MarkdownTableGrid {
        MarkdownTableGrid(table: table, lineLimit: 3, maxColumn: MarkdownTableMetrics.bubbleMaxColumn, headerInset: 22)
    }

    /// The roomy form used on the table's own sheet.
    static func expanded(_ table: MarkdownTable, room: CGFloat, pinned: Bool) -> MarkdownTableGrid {
        MarkdownTableGrid(table: table, font: .subheadline, lineLimit: nil,
                          maxColumn: MarkdownTableMetrics.sheetMaxColumn, fillWidth: room,
                          pinned: pinned, opaqueHeader: true)
    }

    var body: some View {
        MarkdownTableLayout(columns: columnIDs.count, maxColumn: maxColumn, fillWidth: fillWidth) {
            ForEach(columnIDs, id: \.self) { header($0) }
            ForEach(rowIDs, id: \.self) { row in
                ForEach(columnIDs, id: \.self) { bodyCell(row: row, column: $0) }
            }
        }
    }

    // MARK: Cells

    private func header(_ column: Int) -> some View {
        let isLast = column == table.header.count - 1
        let source = table.header[column]
        return text(source, column: column, weight: .semibold)
            .accessibilityLabel(MarkdownTable.plain(source))
            .accessibilityAddTraits(.isHeader)
            .padding(EdgeInsets(top: cellInsets.v, leading: cellInsets.h, bottom: cellInsets.v,
                                trailing: cellInsets.h + (isLast ? headerInset : 0)))
            .fillCell(anchor: CellSide(table.alignment(of: column)).anchor)
            .background(headerFill)
            .overlay(alignment: .bottom) { if opaqueHeader && pinned { divider } }
            // The render pass keeps the header at the top, reading the cell's place in the scroll
            // view. Holding the offset in state would lay out every cell on every frame.
            .visualEffect { [sticks = opaqueHeader] content, proxy in
                let scrolledAway = -proxy.frame(in: .scrollView).minY
                return content.offset(y: sticks && scrolledAway > 0 ? scrolledAway : 0)
            }
            .zIndex(1)
    }

    private func bodyCell(row: Int, column: Int) -> some View {
        text(table.cell(row: row, column: column), column: column)
            .accessibilityLabel(table.spokenCell(row: row, column: column))
            .inset(h: cellInsets.h, v: cellInsets.v)
            .fillCell(anchor: CellSide(table.alignment(of: column)).anchor)
            .overlay(alignment: .top) { divider }
    }

    private var headerFill: some View {
        ZStack {
            if opaqueHeader { Color(.systemBackground) }
            Color(.tertiarySystemFill)
        }
    }

    private func text(_ markdown: String, column: Int, weight: Font.Weight? = nil) -> some View {
        Text(MarkdownView.inline(markdown))
            .font(weight.map(font.weight) ?? font)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .truncationMode(.tail)
            .multilineTextAlignment(CellSide(table.alignment(of: column)).text)
    }

    private var divider: some View {
        Color(.separator).frame(height: 0.5)
    }
}

/// A column's alignment as the two forms SwiftUI wants: where a cell tucks its content, and how
/// its lines align.
private struct CellSide {
    let anchor: Alignment
    let text: TextAlignment

    init(_ alignment: MarkdownColumnAlignment) {
        switch alignment {
        case .center: (anchor, text) = (.top, .center)
        case .trailing: (anchor, text) = (.topTrailing, .trailing)
        case .leading: (anchor, text) = (.topLeading, .leading)
        }
    }
}

private extension View {
    /// Takes the whole cell and tucks the content against `anchor`.
    func fillCell(anchor: Alignment) -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: anchor)
    }
}

/// What a table turns into at accessibility text sizes: a card for each row holding one
/// "Header: value" line per column. Everything wraps, and nothing scrolls sideways.
struct MarkdownTableStack: View {
    var table: MarkdownTable
    private let gap: CGFloat = 8
    var font: Font = .footnote

    var body: some View {
        VStack(alignment: .leading, spacing: gap) {
            // With only a header there are no rows, so the names are listed on one card.
            if table.rows.isEmpty {
                RowCard {
                    ForEach(Array(table.header.indices), id: \.self) { column in
                        Text(MarkdownView.inline(table.header[column]))
                            .fixedSize(horizontal: false, vertical: true)
                            .font(font.weight(.semibold))
                    }
                }
            }
            ForEach(Array(table.rows.indices), id: \.self) { row in
                RowCard {
                    ForEach(Array(table.header.indices), id: \.self) { line(row: row, column: $0) }
                }
            }
        }
    }

    private func line(row: Int, column: Int) -> some View {
        let value = Text(MarkdownView.inline(table.cell(row: row, column: column)))
        let name = table.header[column]
        let combined = name.isEmpty ? value : Text("\(Text(MarkdownView.inline(name)).fontWeight(.semibold)): \(value)")
        let spoken = table.spokenCell(row: row, column: column)
        return combined
            .accessibilityLabel(spoken)
            .fixedSize(horizontal: false, vertical: true)
            .font(font)
    }
}

/// One row of a table, drawn as a small outlined card.
private struct RowCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        let corners = RoundedRectangle(cornerRadius: 10)
        VStack(alignment: .leading, spacing: 4) { content }
            .accessibilityElement(children: .contain)
            .inset(h: 10, v: 8)
            .spread()
            .background(corners.fill(Color(.systemBackground).opacity(0.5)))
            .overlay(corners.strokeBorder(Color(.separator), lineWidth: 0.5))
    }
}
