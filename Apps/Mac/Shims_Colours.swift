import AppKit
import SwiftUI

// iOS names for system colours, so shared views can say `Color(.systemGray5)` on the Mac too.
// AppKit already has the system fills; the numbered greys and grouped backgrounds are filled in
// here with the values iOS uses.

private struct Shade {
    let light: UInt32
    let dark: UInt32

    var colour: NSColor {
        let pick: (UInt32) -> NSColor = { hex in
            let channel = { (shift: UInt32) in CGFloat((hex >> shift) & 0xFF) / 255 }
            return NSColor(srgbRed: channel(16), green: channel(8), blue: channel(0), alpha: 1)
        }
        let (lightColour, darkColour) = (pick(light), pick(dark))
        return NSColor(name: nil) { look in
            look.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkColour : lightColour
        }
    }
}

extension NSColor {
    static var systemGray2: NSColor { Shade(light: 0xAEAEB2, dark: 0x636366).colour }
    static var systemGray3: NSColor { Shade(light: 0xC7C7CC, dark: 0x48484A).colour }
    static var systemGray4: NSColor { Shade(light: 0xD1D1D6, dark: 0x3A3A3C).colour }
    static var systemGray5: NSColor { Shade(light: 0xE5E5EA, dark: 0x2C2C2E).colour }
    static var systemGray6: NSColor { Shade(light: 0xF2F2F7, dark: 0x1C1C1E).colour }

    static var systemGroupedBackground: NSColor { Shade(light: 0xF2F2F7, dark: 0x1C1C1E).colour }
    static var secondarySystemGroupedBackground: NSColor { Shade(light: 0xFFFFFF, dark: 0x1C1C1E).colour }
    static var tertiarySystemGroupedBackground: NSColor { Shade(light: 0xF2F2F7, dark: 0x2C2C2E).colour }

    static var systemBackground: NSColor { windowBackgroundColor }
    static var secondarySystemBackground: NSColor { controlBackgroundColor }
    static var tertiarySystemBackground: NSColor { underPageBackgroundColor }
    static var label: NSColor { labelColor }
    static var secondaryLabel: NSColor { secondaryLabelColor }
    static var separator: NSColor { separatorColor }
}
