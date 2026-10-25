import NollieCore
import SwiftUI

/// Draws a markdown table as a compact card inside a bubble. Each column follows its widest cell,
/// held to about 64...220 pt, and anything longer wraps over up to three lines. If everything fits
/// the card fills the bubble; if not, the table slides sideways within the card and fades at any
/// edge that hides more (the thread's time reveal stays out of that drag). A corner button opens
/// the entire table in a sheet. At the largest accessibility text sizes each row turns into its
/// own card of "Header: value" lines, so there is nothing to scroll.
struct MarkdownTableView: View {
    var table: MarkdownTable

    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var more = MarkdownTableMetrics.Overflow()
    @State private var showingFull = false

    @ViewBuilder private var shown: some View {
        if !typeSize.isAccessibilitySize {
            card
        } else {
            MarkdownTableStack(table: table)
        }
    }

    var body: some View {
        shown
        // No menu here: pressing and holding still opens the reply's own (Reply, Copy, Share). The
        // sheet is owned by this view, as with the HTML card, since the lazy thread keeps the row
        // alive beneath a presented sheet.
        .sheet(isPresented: $showingFull) { fullSheet.withAppModel() }
    }

    private var fullSheet: some View {
        let sheet = MarkdownTableSheet(table: table)
        return sheet.sheetFrame(.wide)
    }

    private var grid: MarkdownTableGrid { .bubble(table) }

    private var card: some View {
        // Plain grid when the columns fit, so it stretches to the bubble. Otherwise the same grid
        // in a horizontal scroll view. A narrow table never gets a scroll view that would take
        // the thread's drags.
        ViewThatFits(in: .horizontal) {
            grid
            sideways
        }
            .background(Color(.systemBackground).opacity(0.5))
            .clipShape(.rect(cornerRadius: 16, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color(.separator), lineWidth: 0.5) }
            .overlay(alignment: .topTrailing) { fullButton }
            .accessibilityElement(children: .contain)
            // No selecting inside the bubble. On the Mac a selectable cell is its own AppKit text
            // view with accessibility of its own, and VoiceOver walking a pile of those within the
            // horizontal scroller recursed until the app crashed. Selection lives in the sheet.
            .textSelection(.disabled)
    }

    private var sideways: some View {
        ScrollView(.horizontal, showsIndicators: false) { grid }
            .onScrollGeometryChange(for: MarkdownTableMetrics.Overflow.self) { geometry in
                MarkdownTableMetrics.overflow(contentWidth: geometry.contentSize.width,
                                              visibleMinX: geometry.visibleRect.minX, visibleMaxX: geometry.visibleRect.maxX)
            } action: { _, latest in more = latest }
            .mask { edgeMask.animation(.easeOut(duration: 0.15), value: more) }
    }

    private var fullButton: some View {
        PlainButton { showingFull = true } label: {
            Glyph("arrow.up.left.and.arrow.down.right", .caption2.weight(.semibold), .secondary)
                .padding(5)
                .background(.thinMaterial, in: .circle)
        }
        .padding(4)
        .accessibilityLabel("Open the table full screen")
        .help("Open Table")
    }

    /// Solid across the middle; a side with more table past it fades out.
    private var edgeMask: some View {
        let band = { (left: Double, right: Double) in
            LinearGradient(colors: [.black.opacity(left), .black.opacity(right)], startPoint: .leading, endPoint: .trailing)
                .frame(width: 24)
        }
        return HStack(spacing: 0) {
            band(more.leading ? 0 : 1, 1)
            Color.black
            band(1, more.trailing ? 0 : 1)
        }
    }
}
