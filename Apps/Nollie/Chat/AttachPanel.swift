import SwiftUI

/// A row in the + panel.
struct AttachItem: Identifiable {
    var title: String
    var id: String { title }
    var symbol: String

    /// Identifier UI tests use, such as "attach.message-history".
    var testID: String {
        let slug = title.lowercased().split(separator: " ").joined(separator: "-")
        return "attach.\(slug)"
    }

    var color: Color
    var disabled = false
    var action: () -> Void
}

/// The + panel, a tall glass card of round icons with names, much like Messages has. It opens out
/// of the + button and closes back into it. The chat composer and New Message both use it.
struct AttachPanel: View {
    let items: [AttachItem]
    /// Closes the panel. Called right before a row's own action.
    let close: () -> Void

    /// Room above the composer, from the chat's own measurements. With large text or a short window
    /// the rows scroll inside the panel instead of running off the top.
    @Environment(\.attachPanelRoom) private var room
    /// The rows' own height, measured, so the panel is never taller than they need.
    @State private var natural: CGFloat = 0

    static let width: CGFloat = 272

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: .zero) {
                ForEach(items, content: row)
            }
            .inset(v: 10)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { natural = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
        .frame(width: Self.width, height: Self.height(natural: natural, estimate: estimate, room: room))
        // The panel hangs off a 36 pt button as an overlay, so it is only offered that much height.
        // Fixing the size lets it take the room it needs, within the room there is.
        .fixedSize()
        .nollieGlass(.regular, in: .rect(cornerRadius: 30))
    }

    /// A first guess at the rows' height, until they have been measured.
    private var estimate: CGFloat { CGFloat(items.count) * 56 + 20 }

    /// As tall as the rows, but no taller than the room (and never shorter than two rows).
    static func height(natural: CGFloat, estimate: CGFloat, room: CGFloat) -> CGFloat {
        let wanted = natural > 0 ? natural : estimate
        guard room.isFinite else { return wanted }
        return min(wanted, max(room, 132))
    }

    private func row(_ item: AttachItem) -> some View {
        PlainButton {
            close()
            item.action()
        } label: {
            HStack(spacing: 16) {
                Glyph(item.symbol, .system(size: 18, weight: .semibold), .white)
                    .frame(square: 40)
                    .background { Circle().fill(item.color) }
                Text(item.title).font(Font.title3)
                Spacer(minLength: 0)
            }
            .inset(h: 18, v: 8)
            .contentShape(.rect)
        }
        .disabled(item.disabled)
        .opacity(item.disabled ? 0.4 : 1)
        .accessibilityIdentifier(item.testID)
    }
}
