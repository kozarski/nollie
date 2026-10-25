import Foundation

/// The saved preference is independent of accessibility overrides and material rendering.
enum GlassAppearance {
    static let enabledKey = "nollie.appearance.glass.enabled"
    static let strengthKey = "nollie.appearance.glass.strength"
    static let defaultEnabled = true
    #if os(macOS)
    static let defaultStrength = 0.35
    #else
    static let defaultStrength = 0.60
    #endif

    struct Policy: Equatable, Sendable {
        let usesGlass: Bool
        let strength: Double
        let backingOpacity: Double
    }

    static func normalizedStrength(_ value: Double) -> Double {
        guard value.isFinite else { return defaultStrength }
        return min(1, max(0, value))
    }

    static func resolve(enabled: Bool, strength: Double,
                        reduceTransparency: Bool, increaseContrast: Bool) -> Policy {
        let strength = normalizedStrength(strength)
        let usesGlass = enabled && !reduceTransparency && !increaseContrast
        // The slider adjusts the backing under native glass, not an undocumented
        // system material parameter. Even its clearest setting retains contrast.
        return Policy(usesGlass: usesGlass, strength: strength,
                      backingOpacity: usesGlass ? 0.94 - strength * 0.50 : 1)
    }
}
