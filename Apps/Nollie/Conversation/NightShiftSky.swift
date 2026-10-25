import SwiftUI

/// The card stays night in either appearance, including the picture made to share.
enum NightShiftInk {
    static let top = color(0x171630)
    static let middle = color(0x302653)
    static let bottom = color(0x584079)
    static let horizon = color(0x9B72BC)
    static let solid = color(0x241D3F)
    static let text = color(0xF7F3FF)
    static let detail = color(0xDDD5F0)
    static let warning = color(0xFFDCA8)
    static let moon = color(0xFFF0CF)
    static let control = color(0x3B3158)

    private static func color(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255,
              green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

/// Still stars keep recycled cells and shared pictures alike, with no offscreen animation work.
struct NightShiftSky: View {
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.nightSkySolid) private var solid
    private var reduceTransparency: Bool { systemReduceTransparency || solid }

    struct Star: Equatable {
        let x: Double
        let y: Double
        let size: Double
        let opacity: Double
    }

    static let horizonOpacity = 0.2
    static let stars = makeStars()

    static func makeStars(seed: UInt64 = 0x4E49474854) -> [Star] {
        var state = seed
        func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / 9_007_199_254_740_992
        }
        return (0..<30).map { index in
            let x = (Double(index % 6) + 0.2 + next() * 0.6) / 6
            let y = (Double(index / 6) + 0.2 + next() * 0.6) / 5
            let size = [0.9, 1.5, 2.2][Int(next() * 3)]
            // Fade towards the brighter horizon so even words over a star keep their contrast.
            let opacity = [0.12, 0.18, 0.24][Int(next() * 3)] * (1 - 0.85 * y)
            return Star(x: x, y: y, size: size, opacity: opacity)
        }
    }

    var body: some View {
        Group {
            if reduceTransparency {
                NightShiftInk.solid
            } else {
                Canvas(opaque: true, colorMode: .nonLinear) { context, size in
                    let bounds = Path(CGRect(origin: .zero, size: size))
                    context.fill(bounds, with: .linearGradient(
                        Gradient(colors: [NightShiftInk.top, NightShiftInk.middle, NightShiftInk.bottom]),
                        startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                    context.fill(bounds, with: .radialGradient(
                        Gradient(colors: [NightShiftInk.horizon.opacity(Self.horizonOpacity), .clear]),
                        center: CGPoint(x: size.width * 0.55, y: size.height * 1.08),
                        startRadius: 0, endRadius: max(size.width, size.height) * 0.65))
                    for star in Self.stars {
                        let rect = CGRect(x: star.x * size.width - star.size / 2,
                                          y: star.y * size.height - star.size / 2,
                                          width: star.size, height: star.size)
                        context.fill(Path(ellipseIn: rect), with: .color(NightShiftInk.detail.opacity(star.opacity)))
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct NightShiftHeading: View {
    let window: String?
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.nightSkySolid) private var solid
    private var reduceTransparency: Bool { systemReduceTransparency || solid }
    @ScaledMetric(relativeTo: .body) private var moonSize = 30.0

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Night shift").font(Ink.cardTitle).foregroundStyle(NightShiftInk.text)
            if let window {
                Text(window).font(Ink.stamp).foregroundStyle(NightShiftInk.detail)
            }
        }
        .padding(.leading, moonSize + 12)
        .overlay(alignment: .leading) {
            Image(systemName: "moon.stars.fill")
                .symbolRenderingMode(.monochrome)
                .font(.system(size: moonSize, weight: .regular))
                .foregroundStyle(NightShiftInk.moon)
                .shadow(color: NightShiftInk.moon.opacity(reduceTransparency ? 0 : 0.3), radius: 8)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

extension EnvironmentValues {
    /// Draws the solid sky even when Reduce Transparency is off: the shared picture and its snapshots.
    @Entry var nightSkySolid = false
}
