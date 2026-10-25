import SwiftUI

// Small shapes of styling the chat views share.

extension View {
    /// Padding by axis in one go: `h` on the left and right, `v` above and below.
    func inset(h: CGFloat = 0, v: CGFloat = 0) -> some View {
        padding(EdgeInsets(top: v, leading: h, bottom: v, trailing: h))
    }

    /// A square frame.
    func frame(square side: CGFloat) -> some View {
        frame(width: side, height: side)
    }

    /// Smaller type in a quieter colour, for the facts under a title.
    func quiet(_ size: Font = .caption, _ tone: some ShapeStyle = .secondary) -> some View {
        foregroundStyle(tone).font(size)
    }

    /// Fills the width the parent offers, text and all pinned to one side.
    func spread(_ side: Alignment = .leading) -> some View {
        frame(maxWidth: .infinity, alignment: side)
    }

    /// Sits on a capsule of `fill`, with room at the sides.
    func capsuled(_ fill: some ShapeStyle, h: CGFloat = 8, v: CGFloat = 4) -> some View {
        inset(h: h, v: v).background(fill, in: Capsule())
    }

    /// Tells the bots' ambient look which way a list is scrolling.
    func feedsBotAmbient() -> some View {
        onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }, action: { was, now in
            BotAmbient.shared.scrolled(dy: now - was)
        })
    }
}

/// A button that draws only what it is given: no chrome, no highlight of its own.
struct PlainButton<Label: View>: View {
    var role: ButtonRole? = nil
    var action: () -> Void
    @ViewBuilder var label: Label

    var body: some View {
        Button(role: role, action: action) { label }.buttonStyle(.plain)
    }
}

/// One symbol with its type and, when given, its tone set in one place.
struct Glyph: View {
    var name: String
    var font: Font
    var tone: AnyShapeStyle?

    init(_ name: String, _ font: Font = .body) {
        self.name = name
        self.font = font
    }

    init(_ name: String, _ font: Font = .body, _ tone: some ShapeStyle) {
        self.name = name
        self.font = font
        self.tone = AnyShapeStyle(tone)
    }

    var body: some View {
        if let tone {
            Image(systemName: name).font(font).foregroundStyle(tone)
        } else {
            Image(systemName: name).font(font)
        }
    }
}

/// A round glass button with one symbol on it, as the chat's headers and sheets use.
struct GlassCircleButton: View {
    var symbol: String
    var diameter: CGFloat
    var weight: Font.Weight = .semibold
    var font: Font = .body
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(font.weight(weight))
                .frame(square: diameter)
                .nollieGlass(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
    }
}
