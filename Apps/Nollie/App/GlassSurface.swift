import SwiftUI

private struct NollieGlassSurface<Surface: Shape>: ViewModifier {
    var glass: Glass
    var shape: Surface
    var solid: Color
    @AppStorage(GlassAppearance.enabledKey) private var enabled = GlassAppearance.defaultEnabled
    @AppStorage(GlassAppearance.strengthKey) private var strength = GlassAppearance.defaultStrength
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let policy = GlassAppearance.resolve(enabled: enabled, strength: strength,
                                             reduceTransparency: reduceTransparency,
                                             increaseContrast: contrast == .increased)
        if policy.usesGlass {
            content
                .background(solid.opacity(policy.backingOpacity), in: shape)
                .glassEffect(glass, in: shape)
        } else {
            content
                .background(solid, in: shape)
                .overlay {
                    shape.stroke(Color.primary.opacity(contrast == .increased ? 0.35 : 0.12), lineWidth: 1)
                        .allowsHitTesting(false)
                }
        }
    }
}

extension View {
    /// Custom Nollie surfaces follow Appearance. System-owned window chrome
    /// retains the platform's own material and accessibility behavior.
    func nollieGlass(_ glass: Glass = .regular, in shape: some Shape,
                    solid: Color = Color(.secondarySystemGroupedBackground)) -> some View {
        modifier(NollieGlassSurface(glass: glass, shape: shape, solid: solid))
    }
}

struct NollieGlassButtonStyle: PrimitiveButtonStyle {
    var prominent = false
    @AppStorage(GlassAppearance.enabledKey) private var enabled = GlassAppearance.defaultEnabled
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        let usesGlass = GlassAppearance.resolve(enabled: enabled, strength: GlassAppearance.defaultStrength,
                                                reduceTransparency: reduceTransparency,
                                                increaseContrast: contrast == .increased).usesGlass
        if usesGlass {
            if prominent {
                Button(configuration).buttonStyle(.glassProminent)
            } else {
                Button(configuration).buttonStyle(.glass)
            }
        } else if prominent {
            Button(configuration).buttonStyle(.borderedProminent)
        } else {
            Button(configuration).buttonStyle(.bordered)
        }
    }
}

extension PrimitiveButtonStyle where Self == NollieGlassButtonStyle {
    static var nollieGlass: NollieGlassButtonStyle { .init() }
    static var nollieGlassProminent: NollieGlassButtonStyle { .init(prominent: true) }
}
