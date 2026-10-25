import AppKit
import QuickLookThumbnailing
import SwiftUI

// The phone's picture types, spelled in AppKit so shared code reads the same on both platforms.
// What has no AppKit twin (scroll probes, the keyboard, gestures) is guarded where it is used.

typealias UIImage = NSImage

// MARK: Screen

/// The main display, asked for each time because it can change under a window.
struct UIScreen {
    static let main = UIScreen()

    private var display: NSScreen? { NSScreen.main }

    var scale: CGFloat { display?.backingScaleFactor ?? 2 }

    var bounds: CGRect {
        guard let display else { return CGRect(origin: .zero, size: CGSize(width: 1440, height: 900)) }
        return display.frame
    }
}

// MARK: Drawing into a picture

/// Accepted and ignored: the picture is redrawn at whatever scale it ends up shown at.
final class UIGraphicsImageRendererFormat {
    var scale: CGFloat = 0
}

/// Draws with a closure, in points with the origin at the top left, as UIKit does.
final class UIGraphicsImageRenderer {
    let size: CGSize

    struct Context {
        var cgContext: CGContext
    }

    convenience init(size: CGSize, format: UIGraphicsImageRendererFormat) {
        self.init(size: size)
    }

    init(size: CGSize) {
        self.size = size
    }

    func image(actions draw: @escaping (Context) -> Void) -> NSImage {
        let canvas = NSImage(size: size, flipped: true) { _ in
            let current = NSGraphicsContext.current
            guard let cg = current?.cgContext else { return false }
            draw(Context(cgContext: cg))
            return true
        }
        return canvas
    }
}

// MARK: NSImage

extension NSImage {
    enum RenderingMode { case automatic, alwaysOriginal, alwaysTemplate }

    convenience init(cgImage: CGImage) {
        let pixels = NSSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        self.init(cgImage: cgImage, size: pixels)
    }

    var cgImage: CGImage? {
        var whole = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &whole, context: nil, hints: nil)
    }

    /// Template drawing is chosen on the SwiftUI `Image` here, so the picture comes back unchanged.
    func withRenderingMode(_ mode: RenderingMode) -> NSImage { self }

    func pngData() -> Data? { bitmapData(.png, [:]) }

    func jpegData(compressionQuality: CGFloat) -> Data? {
        bitmapData(.jpeg, [.compressionFactor: compressionQuality])
    }

    /// Fits inside a square or box given in pixels. Never enlarges, keeps the proportions.
    func preparingThumbnail(of target: CGSize) -> NSImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let density = UIScreen.main.scale
        let across = target.width / density / size.width
        let down = target.height / density / size.height
        let ratio = Swift.min(across, down, 1)
        let smaller = CGSize(width: size.width * ratio, height: size.height * ratio)
        return NSImage(size: smaller, flipped: false) { area in
            self.draw(in: area, from: .zero, operation: .copy, fraction: 1)
            return true
        }
    }

    private func bitmapData(_ kind: NSBitmapImageRep.FileType, _ options: [NSBitmapImageRep.PropertyKey: Any]) -> Data? {
        cgImage.flatMap { NSBitmapImageRep(cgImage: $0).representation(using: kind, properties: options) }
    }
}

// MARK: SwiftUI and Quick Look bridges

extension Image {
    init(uiImage picture: NSImage) {
        self = Image(nsImage: picture)
    }
}

extension ImageRenderer {
    @MainActor var uiImage: NSImage? { self.nsImage }
}

extension QLThumbnailRepresentation {
    var uiImage: NSImage { self.nsImage }
}
