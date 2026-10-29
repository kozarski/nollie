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
        if let tint { dressed.modifier(ReadableActionTint(tint: tint)) } else { dressed }
    }
}

/// A tinted action keeps its colour, deepened just enough for its white words to read.
private struct ReadableActionTint: ViewModifier {
    var tint: Color
    @Environment(\.self) private var environment

    func body(content: Content) -> some View {
        content.tint(tint.readable(against: .white, ratio: 4.5, in: environment))
    }
}

extension Color {
    /// This colour, darkened only as much as it takes to stand `ratio` to 1 against a lighter
    /// `other` (WCAG contrast): a title on a white page, a tint under white words. Unchanged when
    /// it already does, or when `other` is the darker one (a dark page).
    func readable(against other: Color, ratio: Double, in environment: EnvironmentValues) -> Color {
        let mine = resolve(in: environment)
        let theirs = other.resolve(in: environment)
        let lit = mine.luminance, back = theirs.luminance
        guard back > lit, (back + 0.05) / (lit + 0.05) < ratio else { return self }
        let wanted = max(0, (back + 0.05) / ratio - 0.05)
        let scale = lit > 0 ? Float(wanted / lit) : 0
        // Colour.Resolved holds linear light, so scaling each channel scales the luminance exactly.
        return Color(Color.Resolved(colorSpace: .sRGBLinear, red: mine.linearRed * scale,
                                    green: mine.linearGreen * scale, blue: mine.linearBlue * scale, opacity: mine.opacity))
    }
}

extension Color.Resolved {
    /// Relative luminance, from 0 (black) to 1 (white).
    var luminance: Double {
        0.2126 * Double(linearRed) + 0.7152 * Double(linearGreen) + 0.0722 * Double(linearBlue)
    }
}
