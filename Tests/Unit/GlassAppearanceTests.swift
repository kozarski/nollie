import Testing
@testable import Nollie

@MainActor
struct GlassAppearanceTests {
    @Test func turningGlassOffKeepsTheSavedStrengthAndUsesASolidSurface() {
        let policy = GlassAppearance.resolve(enabled: false, strength: 0.8,
                                             reduceTransparency: false, increaseContrast: false)
        #expect(!policy.usesGlass)
        #expect(policy.backingOpacity == 1)
        #expect(policy.strength == 0.8)
    }

    @Test(arguments: [(true, false), (false, true), (true, true)])
    func accessibilityOverridesGlass(reduceTransparency: Bool, increaseContrast: Bool) {
        let policy = GlassAppearance.resolve(enabled: true, strength: 1,
                                             reduceTransparency: reduceTransparency,
                                             increaseContrast: increaseContrast)
        #expect(!policy.usesGlass)
        #expect(policy.backingOpacity == 1)
        #expect(policy.strength == 1)
    }

    @Test func strongerGlassReducesBackingWithoutMakingItClear() {
        let solid = GlassAppearance.resolve(enabled: true, strength: 0,
                                            reduceTransparency: false, increaseContrast: false)
        let glass = GlassAppearance.resolve(enabled: true, strength: 1,
                                            reduceTransparency: false, increaseContrast: false)
        #expect(solid.usesGlass && glass.usesGlass)
        #expect(solid.backingOpacity > glass.backingOpacity)
        #expect(glass.backingOpacity >= 0.4)
    }

    @Test func invalidPreferencesStayWithinSafeBounds() {
        #expect(GlassAppearance.normalizedStrength(-3) == 0)
        #expect(GlassAppearance.normalizedStrength(4) == 1)
        #expect(GlassAppearance.normalizedStrength(.nan) == GlassAppearance.defaultStrength)
        #expect(GlassAppearance.normalizedStrength(.infinity) == GlassAppearance.defaultStrength)
    }

    @Test func defaultsFavorReadableSurfaces() {
        let policy = GlassAppearance.resolve(enabled: GlassAppearance.defaultEnabled,
                                             strength: GlassAppearance.defaultStrength,
                                             reduceTransparency: false, increaseContrast: false)
        #expect(policy.usesGlass)
        #if os(macOS)
        #expect(policy.backingOpacity > 0.75)
        #else
        #expect(policy.backingOpacity >= 0.6)
        #endif
    }
}
