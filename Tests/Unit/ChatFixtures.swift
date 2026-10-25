import Foundation
@testable import Nollie
@testable import NollieCore

/// A chat that talks to nothing, for tests that feed it events by hand.
@MainActor enum ChatFixtures {
    static func runtime(named name: String = "unit") throws -> GatewayRuntime {
        let address = try GatewayURL.normalize("https://127.0.0.1:1")
        let link = GatewayConnection(name: name, gateway: address, authMode: .sessionToken)
        return GatewayRuntime(connection: link, store: ConnectionStore())
    }

    static func chat(stored: String? = nil, named name: String = "unit") throws -> ChatSession {
        ChatSession(runtime: try runtime(named: name), storedID: stored, title: nil)
    }

    /// An event for a chat's own session.
    static func event(for chat: ChatSession, _ type: String, _ fields: [String: JSONValue] = [:]) -> GatewayEvent {
        GatewayEvent(type: type, sessionID: chat.runtimeID, payload: .object(fields))
    }
}

/// Short ways to build the rows of a transcript.
enum TestRows {
    static let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    static func user(_ id: String, _ words: String, at offset: TimeInterval = 0) -> TranscriptItem {
        TranscriptItem(id: id, kind: .user(text: words, attachments: []), timestamp: epoch.addingTimeInterval(offset))
    }

    static func reply(_ id: String, _ words: String, streaming: Bool = false, at offset: TimeInterval = 0) -> TranscriptItem {
        TranscriptItem(id: id, kind: .assistant(text: words, reasoning: nil, streaming: streaming), timestamp: epoch.addingTimeInterval(offset))
    }

    static func tool(_ id: String, status: ToolActivity.Status = .running, at offset: TimeInterval = 0) -> TranscriptItem {
        TranscriptItem(id: id, kind: .tool(ToolActivity(id: id, name: "terminal", status: status)), timestamp: epoch.addingTimeInterval(offset))
    }
}
