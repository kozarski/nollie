import AppKit
import UniformTypeIdentifiers

// `UIPasteboard.general` answered from `NSPasteboard`.
struct UIPasteboard {
    static var general: UIPasteboard { UIPasteboard() }

    private var board: NSPasteboard { .general }

    var string: String? {
        get { board.string(forType: .string) }
        nonmutating set {
            board.clearContents()
            guard let newValue else { return }
            board.setString(newValue, forType: .string)
        }
    }

    var image: NSImage? { NSImage(pasteboard: board) }

    var hasStrings: Bool { string != nil }
    var hasImages: Bool { board.canReadObject(forClasses: [NSImage.self], options: nil) }
    var hasURLs: Bool { board.canReadObject(forClasses: [NSURL.self], options: nil) }
    var numberOfItems: Int { board.pasteboardItems?.count ?? 0 }

    /// One dictionary per item: type identifier to its data.
    var items: [[String: Any]] {
        (board.pasteboardItems ?? []).map { item in
            var byType: [String: Any] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { byType[type.rawValue] = data }
            }
            return byType
        }
    }

    /// Each item offered as an `NSItemProvider`, limited to types the system knows by identifier.
    var itemProviders: [NSItemProvider] {
        (board.pasteboardItems ?? []).map { item in
            let provider = NSItemProvider()
            for type in item.types {
                guard let known = UTType(type.rawValue) else { continue }
                provider.registerDataRepresentation(forTypeIdentifier: known.identifier, visibility: .all) { finish in
                    finish(item.data(forType: type), nil)
                    return nil
                }
            }
            return provider
        }
    }
}
