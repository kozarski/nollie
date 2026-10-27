import AppKit
import NollieCore

/// The picture in the menu bar: Nollie's outline in one colour, with a small mark cut into the
/// bottom corner while something runs, waits for the person or uses this Mac. It is a template
/// image, so the menu bar tints it to match.
enum MenuBarIcon {
    enum Badge: Sendable { case idle, working, needsYou, usingMac }

    @MainActor private static var drawn: [Badge: NSImage] = [:]

    @MainActor static func image(_ badge: Badge) -> NSImage {
        if let ready = drawn[badge] { return ready }
        let picture = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { frame in
            draw(badge, in: frame)
            return true
        }
        picture.isTemplate = true
        picture.accessibilityDescription = description(of: badge)
        drawn[badge] = picture
        return picture
    }

    private static func description(of badge: Badge) -> String {
        switch badge {
        case .idle: "Nollie"
        case .working: String(localized: "Nollie, working", comment: "The menu bar icon, for VoiceOver")
        case .needsYou: String(localized: "Nollie, needs you", comment: "The menu bar icon, for VoiceOver")
        case .usingMac: String(localized: "Nollie, using this Mac", comment: "The menu bar icon, for VoiceOver")
        }
    }

    private static func symbolName(for badge: Badge) -> String? {
        switch badge {
        case .idle: nil
        case .working: "circle.fill"
        case .needsYou: "exclamationmark.circle.fill"
        case .usingMac: "cursorarrow"
        }
    }

    /// Draws `source` centred in `box`, as large as fits without changing its proportions.
    private static func drawCentred(_ source: NSImage, in box: NSRect) {
        guard source.size.width > 0, source.size.height > 0 else { return }
        let fit = min(box.width / source.size.width, box.height / source.size.height)
        let size = NSSize(width: source.size.width * fit, height: source.size.height * fit)
        source.draw(in: NSRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2,
                               width: size.width, height: size.height))
    }

    private static func draw(_ badge: Badge, in frame: NSRect) {
        // Everything goes into one transparency layer, so the clear ring around the mark erases
        // only this outline and not whatever is behind the menu bar item.
        let cg = NSGraphicsContext.current?.cgContext
        cg?.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { cg?.endTransparencyLayer() }

        if let outline = NSImage(named: CharacterDrawing.glyphName(.main)) {
            drawCentred(outline, in: frame)
        }
        guard let name = symbolName(for: badge) else { return }

        let corner = NSRect(x: frame.maxX - 9, y: frame.minY, width: 9, height: 9)
        let context = NSGraphicsContext.current
        context?.compositingOperation = .destinationOut
        NSBezierPath(ovalIn: corner.insetBy(dx: -1.5, dy: -1.5)).fill()
        context?.compositingOperation = .sourceOver

        let weight = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        if let mark = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(weight) {
            drawCentred(mark, in: corner)
        }
    }
}
