import SwiftUI

/// A settings page's one big action: its words and symbol, as wide as the column.
struct PageActionLabel: View {
    var title: String
    var symbol: String

    init(_ title: LocalizedStringResource, symbol: String) {
        self.init(verbatim: String(localized: title), symbol: symbol)
    }

    fileprivate init(verbatim title: String, symbol: String) {
        self.title = title
        self.symbol = symbol
    }

    var body: some View {
        Label(title, systemImage: symbol).fullWidthLabel()
    }
}

extension View {
    /// Dresses a button as a page's one big action: a capsule of glass, in `tint` when given.
    @ViewBuilder func pageAction(tint: Color? = nil) -> some View {
        let dressed = buttonStyle(.nollieGlassProminent).buttonBorderShape(.capsule).controlSize(.large)
        if let tint { dressed.tint(tint) } else { dressed }
    }
}
