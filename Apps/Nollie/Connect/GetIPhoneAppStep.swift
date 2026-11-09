import CoreImage.CIFilterBuiltins
import SwiftUI

/// Nollie for iPhone, iPad and Apple Watch on the App Store.
enum AppStoreLink {
    static let iPhone = URL(string: "https://apps.apple.com/app/nollie-app/id6825756639")!
}

#if os(macOS)
/// The step before a pairing code: a code the iPhone's Camera opens straight to Nollie on the App Store,
/// for an iPhone that doesn't have Nollie yet. "I have the app" goes on to the pairing code.
struct GetIPhoneAppStep: View {
    var haveApp: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            RoundedCodeImage(value: AppStoreLink.iPhone.absoluteString)
                .accessibilityLabel(String(localized: "Code for Nollie on the App Store. Scan it with your iPhone's camera.",
                                           comment: "Accessibility: the code that opens the App Store on an iPhone"))
                .accessibilityIdentifier("pairing.appStore")
            Text("Scan with your iPhone's camera to get Nollie from the App Store",
                 comment: "Under the code that opens Nollie on the App Store on an iPhone")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Ink.text)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                // Narrow enough that the two lines come out about even.
                .frame(maxWidth: 330)
            Button(action: haveApp) {
                Text("I have the app", comment: "Goes on from the App Store code to the pairing code").fullWidthLabel()
            }
            .buttonStyle(.nollieGlassProminent)
            .testID("pairing.haveApp")
        }
    }
}

/// A QR code drawn soft, as on nollie.app: dots for modules, rounded corner eyes and the app's icon in the
/// middle. The highest error correction keeps it readable with the icon over the centre.
struct RoundedCodeImage: View {
    var value: String
    var side: CGFloat = 244

    /// Which modules are dark, row by row, without the margin.
    static func modules(_ value: String) -> [[Bool]]? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "H"
        guard let output = filter.outputImage else { return nil }
        let width = Int(output.extent.width)
        var pixels = [UInt8](repeating: 0, count: width * width * 4)
        CIContext().render(output, toBitmap: &pixels, rowBytes: width * 4, bounds: output.extent,
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        // CoreImage adds a module of margin all round.
        return (1..<(width - 1)).map { y in (1..<(width - 1)).map { x in pixels[(y * width + x) * 4] < 128 } }
    }

    /// The middle square cleared for the icon: odd, about a fifth of the code, with a module of air.
    static func hole(_ count: Int) -> ClosedRange<Int> {
        var size = Int((Double(count) * 0.22).rounded())
        if size % 2 == 0 { size += 1 }
        let start = (count - size) / 2
        return (start - 1)...(start + size)
    }

    var body: some View {
        if let grid = Self.modules(value) {
            let count = grid.count
            let cell = side / CGFloat(count)
            let hole = Self.hole(count)
            let iconSide = CGFloat(hole.count - 2) * cell
            Canvas { context, _ in
                let ink = GraphicsContext.Shading.color(Color(red: 0x1d / 255, green: 0x1d / 255, blue: 0x1f / 255))
                func eye(_ x: Int, _ y: Int) -> Bool {
                    (x < 7 && y < 7) || (x >= count - 7 && y < 7) || (x < 7 && y >= count - 7)
                }
                var dots = Path()
                for (y, row) in grid.enumerated() {
                    for (x, dark) in row.enumerated() where dark && !eye(x, y) && !(hole.contains(x) && hole.contains(y)) {
                        dots.addEllipse(in: CGRect(x: (CGFloat(x) + 0.07) * cell, y: (CGFloat(y) + 0.07) * cell,
                                                   width: cell * 0.86, height: cell * 0.86))
                    }
                }
                context.fill(dots, with: ink)
                for (x, y) in [(0, 0), (count - 7, 0), (0, count - 7)] {
                    let outer = CGRect(x: (CGFloat(x) + 0.5) * cell, y: (CGFloat(y) + 0.5) * cell, width: 6 * cell, height: 6 * cell)
                    context.stroke(Path(roundedRect: outer, cornerRadius: 2.1 * cell), with: ink, lineWidth: cell)
                    let inner = CGRect(x: (CGFloat(x) + 2) * cell, y: (CGFloat(y) + 2) * cell, width: 3 * cell, height: 3 * cell)
                    context.fill(Path(roundedRect: inner, cornerRadius: cell), with: ink)
                }
            }
            .frame(width: side, height: side)
            .overlay {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().interpolation(.high)
                    .frame(width: iconSide, height: iconSide)
            }
            .padding(18)
            .background(.white, in: .rect(cornerRadius: 28))
        }
    }
}
#endif
