import NollieCore
import SwiftUI

/// The full table in a sheet. Cells show all their lines, columns reach about 320 pt, and the
/// grid scrolls both ways with the header held at the top. A roomy sheet (landscape iPad, Mac
/// window) lets the table spread out instead of keeping a narrow phone layout.
struct MarkdownTableSheet: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    var table: MarkdownTable
    @Environment(\.dismiss) private var dismiss
    /// How much width is showing, which lets a small table grow to fill the sheet.
    @State private var visibleWidth: CGFloat = 0
    /// True when rows have scrolled up beneath the header.
    @State private var pinned = false

    private static let margin: CGFloat = 16

    /// Changes only when the device turns or the header begins or stops sticking. Plain scrolling
    /// leaves it equal, which spares the table a rebuild.
    private struct Reading: Equatable {
        var width: CGFloat
        var pinned: Bool

        init(_ geometry: ScrollGeometry) {
            let insets = geometry.contentInsets
            width = geometry.containerSize.width - (insets.leading + insets.trailing)
            pinned = geometry.contentOffset.y + insets.top > MarkdownTableSheet.margin
        }
    }

    var body: some View {
        NavigationStack {
            page
                .navigationTitle("Table")
                .textSelection(.enabled)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) { copyButton }
                    ToolbarItem(placement: .cancellationAction) { Button("Done", action: { dismiss() }) }
                }
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
        }
        #if os(iOS)
        .presentationSizing(.page)
        #endif
    }

    private var copyButton: some View {
        Button("Copy as Markdown", systemImage: "doc.on.doc") {
            UIPasteboard.general.string = table.markdown
        }
    }

    @ViewBuilder private var page: some View {
        if !typeSize.isAccessibilitySize {
            ScrollView([.vertical, .horizontal]) { grid.padding(Self.margin) }
                .onScrollGeometryChange(for: Reading.self, of: Reading.init) { _, now in
                    if visibleWidth != now.width { visibleWidth = now.width }
                    if pinned != now.pinned { pinned = now.pinned }
                }
        } else {
            ScrollView {
                MarkdownTableStack(table: table, font: .body)
                    .padding(Self.margin)
            }
        }
    }

    private var grid: some View {
        MarkdownTableGrid.expanded(table, room: max(0, visibleWidth - Self.margin * 2), pinned: pinned)
    }
}
