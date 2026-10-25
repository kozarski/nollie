import AppKit
import Observation

/// Picks up Board keys (arrows, return, delete, escape) at window level while that page is
/// showing. A key meant for any editable text is left alone, and chords using command, option
/// or control go to the menus.
@MainActor
final class BoardKeys {
    enum Key {
        case left, right, up, down
        case `return`, delete, escape

        init?(code: UInt16) {
            switch code {
            case 123: self = .left
            case 124: self = .right
            case 126: self = .up
            case 125: self = .down
            case 36, 76: self = .return
            case 51, 117: self = .delete
            case 53: self = .escape
            default: return nil
            }
        }
    }

    private var monitor: Any? = nil

    init(handler: @escaping (Key) -> Bool) {
        let pressed: NSEvent.EventTypeMask = .keyDown
        monitor = NSEvent.addLocalMonitorForEvents(matching: pressed) { event in
            guard let key = Self.boardKey(in: event) else { return event }
            let taken = MainActor.assumeIsolated { handler(key) }
            return taken ? nil : event
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// The key, if this event is one the Board may use right now.
    private static func boardKey(in event: NSEvent) -> Key? {
        let reserved: NSEvent.ModifierFlags = [.command, .option, .control]
        guard event.modifierFlags.isDisjoint(with: reserved),
              let window = event.window, window.isKeyWindow else { return nil }
        let responder = window.firstResponder
        if responder is NSTextView || responder is NSTextField { return nil }
        return Key(code: event.keyCode)
    }
}

/// How the Board menu talks to the Board page. Each request is a fresh id the page notices.
@MainActor @Observable
final class BoardCommands {
    static let shared = BoardCommands()
    var selectedID: String?
    var newTaskRequest: UUID?
    var openRequest: UUID?
}
