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

#if os(iOS)
/// The setup pages' backdrop, edge to edge: grouped grey with a breath of blue from the top corner.
/// The launch screen's colour (LaunchBackground) is the same grey, so opening the app shows no flash.
struct OnboardingBackdrop: View {
    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
            LinearGradient(colors: [Color.blue.opacity(0.08), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .ignoresSafeArea()
    }
}
#endif
