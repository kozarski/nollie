import Foundation

public extension Notification.Name {
    /// The gateway's list of chats changed.
    static let hermesSessionsChanged = Notification.Name("hermesSessionsChanged")
    /// Posted by `/new` in a chat; asks for another chat to be started with this bot (userInfo "profile").
    static let hermesNewChatRequested = Notification.Name("hermesNewChatRequested")
    /// Reply text came in for a chat (userInfo `storedID`, and `count` characters).
    static let hermesStreamDelta = Notification.Name("hermesStreamDelta")
    /// A reply finished (userInfo `storedID`, and `text`, the whole turn), for the bot's row.
    static let hermesReplyCompleted = Notification.Name("hermesReplyCompleted")
    static let hermesCronChanged = Notification.Name("hermesCronChanged")
    static let hermesOpenSession = Notification.Name("hermesOpenSession")
}
