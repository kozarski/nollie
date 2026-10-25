import SwiftUI

/// The shades small text is set in.
enum TextTone {
    case secondary, tertiary, red, orange

    var style: AnyShapeStyle {
        switch self {
        case .secondary: AnyShapeStyle(.secondary)
        case .tertiary: AnyShapeStyle(.tertiary)
        case .red: AnyShapeStyle(Color.red)
        case .orange: AnyShapeStyle(Color.orange)
        }
    }
}

extension View {
    /// Small supporting text: a font size and a shade together, since they nearly always go together.
    func small(_ size: Font = .caption, _ tone: TextTone = .secondary) -> some View {
        font(size).foregroundStyle(tone.style)
    }
}

extension View {
    /// A label that fills the width of a button, as the large glass buttons use.
    func fullWidthLabel(_ padding: CGFloat = 6) -> some View {
        font(.headline).frame(maxWidth: .infinity).padding(.vertical, padding)
    }
}
