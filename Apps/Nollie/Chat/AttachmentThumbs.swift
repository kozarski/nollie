import SwiftUI
import ImageIO
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Small pictures for attachment images, decoded once per file and size. Rows therefore never
/// hold a full-size bitmap.
enum AttachmentThumbs {
    @MainActor private static let memory = NSCache<NSString, UIImage>()

    private static func cacheKey(_ url: URL, _ side: CGFloat) -> NSString { "\(url.path)|\(Int(side))" as NSString }

    @MainActor private static func pixels(forPoints side: CGFloat) -> Int { Int(side * UIScreen.main.scale) }

    @MainActor static func image(at url: URL, side: CGFloat) -> UIImage? {
        let key = cacheKey(url, side)
        if let hit = memory.object(forKey: key) { return hit }
        guard let fresh = decode(at: url, pixels: pixels(forPoints: side)) else { return nil }
        memory.setObject(fresh, forKey: key)
        return fresh
    }

    /// Same result, decoded away from the main thread so scrolling is not held up.
    @MainActor static func imageAsync(at url: URL, side: CGFloat) async -> UIImage? {
        let key = cacheKey(url, side)
        if let hit = memory.object(forKey: key) { return hit }
        let target = pixels(forPoints: side)
        let ferried = await Task.detached(priority: .userInitiated) {
            Ferry(image: decode(at: url, pixels: target))
        }.value
        guard let fresh = ferried.image else { return nil }
        memory.setObject(fresh, forKey: key)
        return fresh
    }

    /// A downsampled copy no bigger than `pixels` on a side. The full bitmap is never decoded.
    nonisolated static func decode(at url: URL, pixels: Int) -> UIImage? {
        var options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        options[kCGImageSourceCreateThumbnailWithTransform] = true
        options[kCGImageSourceCreateThumbnailFromImageAlways] = true
        options[kCGImageSourceThumbnailMaxPixelSize] = pixels
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: thumb)
    }

    /// Carries a decoded image out of the detached task.
    private struct Ferry: @unchecked Sendable {
        let image: UIImage?
    }
}
