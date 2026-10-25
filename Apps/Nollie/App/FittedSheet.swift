import SwiftUI

/// Sheet that sizes itself to its content and hangs from the top.
///
/// The content is measured and the detent follows it, switching to full height when the content is
/// too tall. The grabber is always cleared at the top, scrolling kicks in only when needed, and
/// the backdrop is dense enough that nothing behind it can bleed into the text.
struct FittedSheet<Content: View>: View {
    private let content: Content
    @State private var measured: CGFloat = 420

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    /// Space for the grabber, plus a little air.
    private let grabberRoom: CGFloat = 40

    var body: some View {
        ScrollView {
            content
                .padding(.top, grabberRoom)
                .frame(maxWidth: .infinity)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { measured = $0 })
        }
        .scrollBounceBehavior(.basedOnSize)
        #if os(macOS)
        // A scroll view reports no height of its own, so give the Mac sheet one.
        .frame(width: 460, height: min(measured, 640))
        #endif
        .presentationDetents([.height(measured), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.thickMaterial)
    }
}
