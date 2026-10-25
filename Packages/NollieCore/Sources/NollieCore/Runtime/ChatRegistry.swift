import Foundation

/// How a live chat is named. People navigate by the stored id; the gateway stamps each event and
/// request for the chat with the runtime id.
@MainActor
public protocol ChatIdentity: AnyObject {
    /// Stored ids this conversation had before Hermes compressed it.
    var formerStoredIDs: [String] { get }
    var storedID: String { get }
    var runtimeID: String { get }
}

extension ChatIdentity {
    public var formerStoredIDs: [String] { [] }

    fileprivate func answers(toStored id: String) -> Bool { storedID == id }
    fileprivate func answers(toFormerly id: String) -> Bool { formerStoredIDs.contains(id) }
}

/// The chats that are open, found by either id.
///
/// Deliberately not a dictionary. After a reconnect, `session.resume` may assign a chat a fresh
/// runtime id; a table indexed by the old one lost every reply without a sound, so prompts went
/// out and nothing came back to the screen. A handful of chats is cheap to scan.
@MainActor
public struct ChatRegistry<Chat: ChatIdentity> {
    private var open: [Chat] = []

    public init() {}

    public var all: [Chat] { open }

    public func byRuntime(_ id: String) -> Chat? {
        guard let at = open.firstIndex(where: { $0.runtimeID == id }) else { return nil }
        return open[at]
    }

    /// A chat whose current stored id is `id` wins; failing that, one that used to have it.
    public func byStored(_ id: String) -> Chat? {
        let current = open.firstIndex { $0.answers(toStored: id) }
        let former = open.firstIndex { $0.answers(toFormerly: id) }
        return (current ?? former).map { open[$0] }
    }

    /// Adds a chat; an earlier one with the same stored id is dropped.
    public mutating func add(_ chat: Chat) {
        open = open.filter { !$0.answers(toStored: chat.storedID) } + [chat]
    }

    public mutating func remove(_ chat: Chat) {
        open.removeAll { $0 === chat }
    }
}
