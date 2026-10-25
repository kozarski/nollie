import SwiftUI

/// Puts a Done button in the corner that closes the sheet this view sits in. On the phone the
/// title is inline. Pass `id` to give the button a test identifier.
private struct DoneInCorner: ViewModifier {
    let id: String?
    @Environment(\.dismiss) private var dismiss

    private var done: some View {
        let button = Button("Done") { dismiss() }
        return Group {
            if let id { button.accessibilityIdentifier(id) } else { button }
        }
    }

    func body(content: Content) -> some View {
        content
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { done }
            }
    }
}

extension View {
    func doneToolbar(id: String? = nil) -> some View { modifier(DoneInCorner(id: id)) }
}
