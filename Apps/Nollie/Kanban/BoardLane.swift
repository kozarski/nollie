import SwiftUI

/// One lane of the board: a heading with its count, then the cards, scrolling on their own.
/// Cards can be dropped onto it; it lights up softly while one is over it.
struct BoardLane<Content: View>: View {
    let group: KanbanPresentationGroup
    let count: Int
    /// Receives dragged items; returns whether the drop was taken.
    let onDrop: ([String]) -> Bool
    /// A task id to scroll into view.
    var selection: String? = nil
    @ViewBuilder var content: () -> Content

    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LaneHeading(group: group, count: count)
            scrollingCards
        }
        .inset(h: 6, v: 10)
        .frame(maxHeight: .infinity, alignment: .top)
        // No box around a lane, only the column.
        .background(Color.primary.opacity(hovered ? 0.06 : 0), in: .rect(cornerRadius: Ink.cardRadius, style: .continuous))
        .dropDestination(for: String.self, action: { dropped, _ in onDrop(dropped) }, isTargeted: { hovered = $0 })
    }

    private var scrollingCards: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(spacing: 12) {
                    content()
                    if count == 0 { emptyNote }
                }
                .padding(2)
            }
            .scrollIndicators(.hidden)
            .onChange(of: selection) { _, id in
                if let id { reader.scrollTo(id, anchor: .center) }
            }
        }
    }

    private var emptyNote: some View {
        Text(group == .blocked ? "Nothing needs your help" : "No tasks here")
            .small(.subheadline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
    }
}

/// The lane's name, a symbol, and how many cards it holds. Blue when something waits on the person.
private struct LaneHeading: View {
    var group: KanbanPresentationGroup
    var count: Int

    var body: some View {
        HStack(spacing: 7) {
            Label(group.title, systemImage: group.symbol).font(.headline)
            Text(count, format: .number).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
        }
        .foregroundStyle(group == .blocked && count > 0 ? Color.blue : Color.primary)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .testID("board.group.\(group.rawValue)")
    }
}
