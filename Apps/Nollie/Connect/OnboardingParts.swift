import SwiftUI

/// A heading with one plain line under it, as the setup steps open their cards.
struct StepHeading: View {
    var title: String
    var note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title3).fontWeight(.semibold).accessibilityAddTraits(.isHeader)
            Text(note).small(.body).fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension View {
    /// Pads a step's content and sets it on a glass card, left-aligned to the full width.
    func glassCard(inset: CGFloat, corner: CGFloat, continuous: Bool = true) -> some View {
        padding(inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .nollieGlass(.regular, in: .rect(cornerRadius: corner, style: continuous ? .continuous : .circular))
    }
}
