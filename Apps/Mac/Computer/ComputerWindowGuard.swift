#if os(macOS)
import AppKit
import CoreGraphics
import Foundation
import ImageIO

/// One window on the screen, as the window server lists it (never as a bot or a model says).
struct ComputerScreenWindow: Equatable, Sendable {
    var id: Int
    var pid: Int
    /// 0 for ordinary windows; menus, the Dock and floating panels sit higher.
    var layer: Int
    /// Screen points, top left, like the accessibility frames Nollie reads.
    var bounds: CGRect
    var alpha: Double = 1
}

/// Where an action lands on the screen, checked just before it goes: fixed rules, never a model's
/// judgement. The window must still be the picked app's own, an app the task may use (or Nollie)
/// must be in front, and nothing else may cover the spot a click or scroll lands on.
/// A look gives the model on this Mac a picture of that one window only, never the screen.
enum ComputerWindowGuard {
    // Refusals go back to the bot's model, so they stay in English.
    static func notItsWindow(_ app: String) -> String { "Nollie can't see that window of \(app) on screen, so it didn't do that." }
    static func notInFront(_ app: String) -> String {
        "\(app) isn't in front. Nollie only acts while an app you picked, or Nollie, is in front. Ask the person to bring \(app) forward."
    }
    static func covered(_ app: String) -> String { "Something else is covering \(app) there, so Nollie didn't do that." }
    static let notJustTheWindow = "Nollie couldn't get a picture of just that window, so it didn't look."

    /// Why an action can't go now, or nil. `point` is where a click or scroll lands, in screen points.
    /// `windows` run front to back, as the window server lists them.
    static func refusal(for kind: ComputerAction.Kind, app: String, pid: Int, windowID: Int?, point: CGPoint?,
                        frontmostPID: Int?, taskPIDs: Set<Int>, ownPID: Int, windows: [ComputerScreenWindow]) -> String? {
        // The window the action goes to is the app's own, by the window server's word.
        if let windowID {
            guard let window = windows.first(where: { $0.id == windowID }), window.pid == pid else { return notItsWindow(app) }
        }
        if kind == .look { return nil }
        // Something else in front (a dialog of another app, an app a link opened): wait for the person.
        guard let frontmostPID, frontmostPID == ownPID || taskPIDs.contains(frontmostPID) else { return notInFront(app) }
        guard let point, kind == .click || kind == .scroll else { return nil }
        // The top window under the spot, ignoring see-through overlays, is the app's own (its window,
        // a sheet or a menu of it). Another app's window there, Nollie's own included, is in the way.
        let top = windows.first { $0.alpha > 0.01 && $0.bounds.contains(point) }
        guard let top, top.pid == pid else { return covered(app) }
        return nil
    }

    /// Whether a picture is of one window and nothing more: no bigger than that window at the
    /// display's scale (the driver may shrink it), with a little room for rounding.
    static func pictureFits(width: Int, height: Int, window: CGRect, maxScale: Double = 2) -> Bool {
        guard width > 0, height > 0, window.width > 0, window.height > 0 else { return false }
        let slack = 4.0
        return Double(width) <= window.width * maxScale + slack && Double(height) <= window.height * maxScale + slack
    }

    /// The pixel size of a PNG or JPEG, read from its header only. Nil when it isn't a picture.
    static func pictureSize(base64: String) -> (width: Int, height: Int)? {
        guard let data = Data(base64Encoded: base64), let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else { return nil }
        return (width, height)
    }

    /// Every window on screen now, front to back.
    static func onScreen() -> [ComputerScreenWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.intValue,
                  let raw = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: raw) else { return nil }
            return ComputerScreenWindow(id: id, pid: pid, layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                                        bounds: bounds, alpha: (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1)
        }
    }

    static var frontmostPID: Int? { NSWorkspace.shared.frontmostApplication.map { Int($0.processIdentifier) } }
    static var maxScreenScale: Double { NSScreen.screens.map { Double($0.backingScaleFactor) }.max() ?? 2 }
}
#endif
