import SwiftUI
import NollieCore

/// Opening the chat a conversation screen shows: finds or makes the session, says why it could
/// not, and sends the first message when the compose sheet brought one.
@MainActor @Observable
final class ConversationLoader {
    var chat: ChatSession?
    var failure: String?
    /// The exact address used to open this chat, before resume follows a compression continuation.
    var requestedID: String?
    var focus: NotificationMessageFocus?
    private var sentFirst = false

    /// Opens the chat `route` names, or a new one. Returns the session when it opened.
    func open(_ route: ChatRoute, model: AppModel) async -> ChatSession? {
        guard let runtime = model.runtime, route.connectionID.map({ $0 == runtime.connection.id }) ?? true else {
            failure = "The connection for this conversation is no longer open."
            return nil
        }
        // Viewing another bot's chat read-only passes that bot with each call and does not touch the
        // selected bot. Our own chats switch to their bot first.
        if !route.readOnly, let bot = route.profile, !bot.isEmpty, runtime.selectedProfile != bot {
            runtime.selectedProfile = bot
        }
        // An existing chat comes back immediately from the cached transcript and syncs in the background.
        // Its bot stays attached for as long as the chat is open.
        if let stored = route.storedID, let bot = route.profile,
           let known = runtime.chatForStored(stored), known.profileName != bot {
            failure = "This conversation belongs to a different bot. Open it from Chats."
            return nil
        }
        do {
            let session: ChatSession
            if let stored = route.storedID {
                session = try await runtime.openChat(storedID: stored, title: route.title, profile: route.profile)
            } else {
                session = try await runtime.newChat(cwd: route.cwd)
            }
            guard !Task.isCancelled, model.runtime === runtime else { return nil }
            requestedID = route.storedID
            chat = session
            return session
        } catch {
            failure = error.localizedDescription
            return nil
        }
    }

    /// A fresh chat in place of the one showing.
    func startFresh(model: AppModel) async {
        guard let runtime = model.runtime else { return }
        do {
            let fresh = try await runtime.newChat()
            guard !Task.isCancelled, model.runtime === runtime else { return }
            requestedID = nil
            focus = nil
            chat = fresh
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Once the chat exists, the compose sheet's first message goes out.
    func sendFirstMessage(of route: ChatRoute, in session: ChatSession) async {
        guard !sentFirst, let words = route.initialText, !words.isEmpty || !route.initialAttachments.isEmpty else { return }
        sentFirst = true
        for item in route.initialAttachments {
            guard let file = item.localURL, let data = try? Data(contentsOf: file) else { continue }
            session.stageAttachment(data: data, name: item.name, kind: item.kind)
            try? FileManager.default.removeItem(at: file)
        }
        _ = await session.send(words)
        NotificationCenter.default.post(name: .hermesSessionsChanged, object: nil)
    }
}
