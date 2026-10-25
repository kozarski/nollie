import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import NollieCore

/// A bot's avatar rendered as a plain image, for spots where a SwiftUI view cannot go, such as menu icons and
/// the small still beside replies in a long thread.
enum BotAvatarImage {
    private static let menuSide: CGFloat = 28
    @MainActor private static let remembered: NSCache<NSString, UIImage> = .init()

    /// Like `make`, but reuses a picture already drawn for the same bot, size, scheme and look.
    /// Threads show one next to each reply, and a live view per reply made scrolling choppy.
    @MainActor static func cached(profile: String, size: CGFloat = menuSide,
                                  scheme: ColorScheme = .light) -> UIImage {
        let parts = [profile, "\(size)", scheme == .dark ? "d" : "l", BotAvatarStore.choice(for: profile).raw]
        let key = parts.joined(separator: "|") as NSString
        if let hit = remembered.object(forKey: key) { return hit }
        // Only a real drawing is remembered. A stand-in is retried on the next row.
        guard let fresh = drawn(profile: profile, size: size, scheme: scheme) else {
            return standIn(profile: profile, size: size)
        }
        defer { remembered.setObject(fresh, forKey: key) }
        return fresh
    }

    @MainActor static func make(profile: String, size: CGFloat = menuSide,
                                scheme: ColorScheme = .light) -> UIImage {
        if let image = drawn(profile: profile, size: size, scheme: scheme) { return image }
        return standIn(profile: profile, size: size)
    }

    /// The bot's photo or its drawn character. Nil when a busy GPU hands back an empty picture twice.
    @MainActor private static func drawn(profile: String, size: CGFloat, scheme: ColorScheme) -> UIImage? {
        if BotAvatarStore.showsPhoto(profile), let photo = BotAvatarStore.photo(for: profile) {
            return circled(photo, side: size)
        }
        let character = CharacterView(look: BotAvatarStore.look(for: profile), size: size, animated: false)
            .environment(\.colorScheme, scheme)
        for _ in 0..<2 {
            let renderer = ImageRenderer(content: character)
            renderer.scale = 3
            renderer.isOpaque = false
            if let result = renderer.uiImage, hasInk(result) { return result.withRenderingMode(.alwaysOriginal) }
        }
        return nil
    }

    /// The character's notification still in a circle, like a photo. Drawn without the GPU.
    @MainActor static func standIn(profile: String, size: CGFloat) -> UIImage {
        if let still = UIImage(named: CharacterDrawing.avatarName(BotAvatarStore.look(for: profile))) {
            return circled(still, side: size)
        }
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { _ in }
    }

    private static func circled(_ picture: UIImage, side: CGFloat) -> UIImage {
        let frame = CGRect(x: 0, y: 0, width: side, height: side)
        return UIGraphicsImageRenderer(size: frame.size).image { context in
            context.cgContext.addEllipse(in: frame)
            context.cgContext.clip()
            picture.draw(in: frame)
        }.withRenderingMode(.alwaysOriginal)
    }

    /// Whether a character came out: it covers well over a sixteenth of its square.
    static func hasInk(_ image: UIImage) -> Bool {
        #if os(macOS)
        guard let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        #else
        guard let bitmap = image.cgImage else { return false }
        #endif
        let (width, height) = (bitmap.width, bitmap.height)
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let painted = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(bitmap, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard painted else { return false }
        let covered = stride(from: 3, to: rgba.count, by: 4).filter { rgba[$0] > 0 }.count
        return covered > width * height / 16
    }
}
