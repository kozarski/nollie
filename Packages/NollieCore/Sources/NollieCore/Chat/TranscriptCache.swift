import Foundation

/// What this device last saw of a chat, kept on disk so reopening it draws at once while the live
/// resume is still under way. One JSON file per session, in a folder per gateway connection, in
/// the caches area (the system may clear it). Only the newest rows are kept.
public enum TranscriptCache {
    /// How many of the newest rows a session keeps.
    static let cap = 200

    /// Saves run one at a time, in the order asked, away from the main thread: every finished
    /// reply asks for one, and a long chat's rows are not cheap to encode.
    private static let saves: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "dev.nollie.transcript-cache"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()

    /// Where one session's rows live; nil for a session with no stored id yet.
    static func url(connection: UUID, storedID: String) -> URL? {
        if storedID.isEmpty { return nil }
        let leaf = storedID.replacing("/", with: "_") + ".json"
        let folder = NolliePaths.current.transcripts.appending(component: connection.uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(component: leaf, directoryHint: .notDirectory)
    }

    public static func load(connection: UUID, storedID: String) -> [TranscriptMessage]? {
        guard let file = url(connection: connection, storedID: storedID) else { return nil }
        do {
            return try JSONDecoder().decode([TranscriptMessage].self, from: Data(contentsOf: file))
        } catch {
            return nil
        }
    }

    public static func save(_ items: [TranscriptItem], connection: UUID, storedID: String) {
        guard let file = url(connection: connection, storedID: storedID) else { return }
        let rows = items.suffix(cap).compactMap(stored(_:))
        saves.addOperation {
            if let bytes = try? JSONEncoder().encode(rows) { try? bytes.write(to: file, options: .atomic) }
        }
    }

    /// Blocks until the saves already queued have landed.
    public static func flush() { saves.waitUntilAllOperationsAreFinished() }

    /// Forgets what was kept for one gateway connection (a demo's, when it ends).
    public static func clear(connection: UUID) {
        let folder = NolliePaths.current.transcripts.appending(component: connection.uuidString, directoryHint: .isDirectory)
        let wipe = BlockOperation { try? FileManager.default.removeItem(at: folder) }
        saves.addOperations([wipe], waitUntilFinished: true)
    }

    public static func clearAll() {
        // Queued behind any save already asked for, which would otherwise bring a file back.
        let wipe = BlockOperation { try? FileManager.default.removeItem(at: NolliePaths.current.transcripts) }
        saves.addOperations([wipe], waitUntilFinished: true)
    }

    /// One row in the shape it is stored in. Rows with nothing worth keeping give nil.
    private static func stored(_ item: TranscriptItem) -> TranscriptMessage? {
        let time = item.timestamp.timeIntervalSince1970

        func spoken(by role: String, _ text: String) -> TranscriptMessage {
            TranscriptMessage(role: role, text: text, timestamp: time, rowId: item.rowID,
                              displayKind: item.displayKind, controlMarker: item.controlMarker,
                              notificationCategory: item.notificationCategory)
        }
        func plain(_ role: String, _ text: String) -> TranscriptMessage {
            TranscriptMessage(role: role, text: text, timestamp: time, rowId: item.rowID)
        }

        switch item.kind {
        case .user(let text, _), .steer(let text, _):
            return spoken(by: "user", text)
        case .assistant(let text, let reasoning, _):
            if text.isEmpty { return nil }
            var row = spoken(by: "assistant", text)
            row.reasoning = reasoning
            row.finishReason = item.finishReason
            return row
        case .tool(let call):
            return TranscriptMessage(role: "tool", text: call.resultText, timestamp: time, rowId: item.rowID,
                                     name: call.name, context: call.context,
                                     finishReason: call.status == .failed ? "error" : nil, argsText: call.argsText)
        case .system(let text, _):
            return plain("system", text)
        case .error(let text):
            return plain("error", text)
        case .subagent:
            return nil
        }
    }
}
