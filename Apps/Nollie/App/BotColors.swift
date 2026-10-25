import SwiftUI
import NollieCore
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Colours per bot, as "#RRGGBB". Picks live in UserDefaults as a single JSON object (profile to
/// hex) under `botColors`. A bot with no pick derives one from its name out of the shared palette,
/// so two bots rarely end up alike. Used by the title pill in chat, the Bots page and the
/// notification tints.
enum BotColors {
    static let storageKey = "botColors"
    /// The same palette everywhere, so each bot has one colour across devices.
    static let palette: [String] = BotPalette.hexes

    private static let table = DefaultsTable(key: storageKey)

    static func color(for profile: String) -> Color {
        Color(hex: hex(for: profile)) ?? .accentColor
    }

    /// A name always maps to the same colour, on every device.
    static func defaultHex(for profile: String) -> String {
        BotPalette.defaultHex(for: profile)
    }

    @MainActor static func set(_ color: Color, for profile: String) {
        var picks = stored()
        picks[profile] = color.hexString
        save(picks)
    }

    static func stored() -> [String: String] { table.read() }

    @MainActor static func save(_ colors: [String: String]) {
        table.write(colors)
        BotLooksMirror.mirror()
    }

    /// The picked colour of a bot, else its default.
    static func hex(for profile: String) -> String {
        let picked = stored()[profile] ?? ""
        return picked.isEmpty ? defaultHex(for: profile) : picked
    }
}

extension Color {
    /// Reads "#RRGGBB" or "RRGGBB". Anything else gives nil.
    init?(hex text: String) {
        let body = text.trimmingCharacters(in: .whitespaces).drop { $0 == "#" }
        guard body.count == 6, let value = UInt32(body, radix: 16) else { return nil }
        let level = { (bits: UInt32) -> Double in Double((value >> bits) & 0xFF) / 255 }
        self.init(red: level(16), green: level(8), blue: level(0))
    }

    /// "#RRGGBB" in sRGB.
    var hexString: String {
        var (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        #if canImport(UIKit)
        let native = UIColor(self)
        #else
        let plain = NSColor(self)
        let native = plain.usingColorSpace(.sRGB) ?? plain
        #endif
        native.getRed(&r, green: &g, blue: &b, alpha: &a)
        return [r, g, b].reduce("#") { $0 + String(format: "%02X", Int(($1 * 255).rounded())) }
    }
}
