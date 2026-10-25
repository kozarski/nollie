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

    var body: some View {
        VStack(alignment: .leading, spacing: .zero) {
            ForEach(items, content: row)
        }
        .inset(v: 10)
        .frame(width: 272)
        // The panel hangs off a 36 pt button as an overlay, so it is only offered that much height and
        // its glass came out shorter than the rows. Fixing the size lets it take the room it needs.
        .fixedSize()
        .nollieGlass(.regular, in: .rect(cornerRadius: 30))
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
