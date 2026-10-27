import SwiftUI

/// The tint behind buttons, the selected tab, your own bubbles and links. The person picks it in
/// Settings, Appearance. Blue is what you get until then.
enum AppTheme {
    static let accentKey = "theme.accent"

    struct Accent: Identifiable, Equatable {
        let id: String
        let name: String
        let color: Color
    }

    /// One row per accent: id, shown name, then red, green and blue as fractions of 1.
    private static let swatches: [(String, String, [Double])] = [
        ("blue", String(localized: "Blue", comment: "An accent colour"), [0, 0.478, 1]),
        ("indigo", String(localized: "Indigo", comment: "An accent colour"), [0.345, 0.337, 0.839]),
        ("teal", String(localized: "Teal", comment: "An accent colour"), [0.188, 0.69, 0.78]),
        ("green", String(localized: "Green", comment: "An accent colour"), [0.204, 0.78, 0.349]),
        ("orange", String(localized: "Orange", comment: "An accent colour"), [1, 0.584, 0]),
        ("pink", String(localized: "Pink", comment: "An accent colour"), [1, 0.176, 0.333]),
        ("purple", String(localized: "Purple", comment: "An accent colour"), [0.686, 0.322, 0.871]),
        ("graphite", String(localized: "Graphite", comment: "An accent colour"), [0.557, 0.557, 0.576]),
    ]

    static let accents: [Accent] = swatches.map { id, name, c in
        Accent(id: id, name: name, color: Color(red: c[0], green: c[1], blue: c[2]))
    }

    /// The accent saved under this id. Blue stands in for a name nobody knows.
    static func accent(_ id: String) -> Accent {
        accents.first(where: { $0.id == id }) ?? accents[0]
    }

    /// The chosen accent, for views that fill with it themselves.
    static var current: Color {
        let saved = UserDefaults.standard.string(forKey: accentKey)
        return accent(saved ?? "").color
    }
}

extension Color {
    /// The accent as a plain colour. `.tint` follows the accent by itself; a fill needs this.
    static var nollie: Color { AppTheme.current }
}
