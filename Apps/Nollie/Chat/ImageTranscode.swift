import ImageIO
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import UniformTypeIdentifiers
import NollieCore

/// Re-saves photos as JPEG when the gateway would turn them down. The photo library hands out
/// HEIC, while image attach takes JPEG, PNG, GIF and WebP.
enum ImageTranscode {
    static func install() {
        let transcode: @Sendable (Data, String) -> (Data, String)? = { convert($0, named: $1) }
        ChatSession.imageTranscoder = transcode
    }

    static let accepted = Set(["png", "jpeg", "jpg", "webp", "gif"])

    /// The JPEG bytes with their new file name, or nil if the file can go as it is (or won't decode).
    private static func convert(_ data: Data, named name: String) -> (Data, String)? {
        let original = URL(fileURLWithPath: name)
        if accepted.contains(original.pathExtension.lowercased()) { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let picture = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
              let jpeg = jpegBytes(of: picture, turn: embeddedOrientation(source)) else { return nil }
        let base = original.deletingPathExtension().lastPathComponent
        return (jpeg, "\(base.isEmpty ? "photo" : base).jpg")
    }

    /// The photo's orientation lives in its metadata. Passing it on keeps the result upright.
    private static func embeddedOrientation(_ source: CGImageSource) -> Any? {
        let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return metadata?[kCGImagePropertyOrientation]
    }

    private static func jpegBytes(of picture: CGImage, turn orientation: Any?) -> Data? {
        let buffer = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(buffer, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.88]
        properties[kCGImagePropertyOrientation] = orientation
        CGImageDestinationAddImage(writer, picture, properties as CFDictionary)
        return CGImageDestinationFinalize(writer) ? buffer as Data : nil
    }
}

/// A faint tap for each burst of reply text, like typing on a typewriter. It lives in Settings,
/// Notifications, Typing haptics (beta). Ticks are spaced out so a fast stream hums instead of
/// rattling, and they happen only for the open chat while the app is up front.
@MainActor
final class TypingHaptics {
    static let key = "chat.typingHaptics"
    static let shared = TypingHaptics()

    static var isOn: Bool {
        let store = UserDefaults.standard
        let hapticsAllowed = store.object(forKey: "hapticsEnabled") as? Bool ?? true
        return store.bool(forKey: key) && hapticsAllowed
    }

    #if os(iOS)
    private let generator = UIImpactFeedbackGenerator(style: .soft)
    #endif
    private var pending = 0
    private var lastTick = Date.distantPast

    func start() {
        let center = NotificationCenter.default
        _ = center.addObserver(forName: .hermesStreamDelta, object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo
            let amount = info?["count"] as? Int ?? 1
            let chat = info?["storedID"] as? String
            Task { @MainActor in self?.tick(storedID: chat, count: amount) }
        }
    }

    private func tick(storedID: String?, count: Int) {
        guard Self.isOn && LocalNotifier.isForeground else { return }
        guard let storedID, storedID == AppModel.shared.visibleChatID else { return }
        pending += count
        let now = Date()
        // At most about eight a second. A larger burst gets a slightly firmer tap.
        if now.timeIntervalSince(lastTick) <= 0.12 { return }
        lastTick = now
        let firmness = min(CGFloat(1), CGFloat(pending) / 60 + 0.35)
        pending = 0
        #if os(iOS)
        generator.impactOccurred(intensity: firmness)
        generator.prepare()
        #endif
    }
}
