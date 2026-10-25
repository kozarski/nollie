import SwiftUI

/// The page's name at the top of a Settings sub-page, large and quiet. Scrolls with the list.
struct SettingsHeaderSection: View {
    var title: String

    var body: some View {
        Section {
            Text(title)
                .font(.largeTitle.weight(.bold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(BareRow(top: 8, side: 4))
        }
    }
}

/// A list row with no card behind it and tight edges: the text sits straight on the page.
private struct BareRow: ViewModifier {
    var top: CGFloat
    var side: CGFloat

    func body(content: Content) -> some View {
        content
            .listRowInsets(.init(top: top, leading: side, bottom: 0, trailing: side))
            .listRowBackground(Color.clear)
    }
}
