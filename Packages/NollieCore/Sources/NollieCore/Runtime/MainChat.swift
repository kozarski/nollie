import Foundation

/// The answer to "where is this bot's Bot Chat?", the one long conversation the gateway keeps
/// for each bot, followed through compression to its newest stored id.
public enum MainChatLookup: Sendable {
    case found(String)
    /// The gateway said outright that there isn't one yet.
    case missing
    /// It couldn't be asked, or didn't say.
    case unknown
}

private let botChatTitle = "Bot Chat"

@MainActor
extension GatewayRuntime {
    /// Looks for a bot's main chat in three places, in order: the canonical session in
    /// `profiles.list` (what the companion goes by), the chat titled "Bot Chat" among the bot's
    /// recent chats, and a title search, the way a "Messaged X" notice finds another bot's.
    public func mainChat(profile name: String) async -> MainChatLookup {
        var gatewayDeniesIt = false

        if let listing = try? await rpc("profiles.list"),
           let entry = listing["profiles"]?.arrayValue?.first(where: { $0["name"]?.stringValue == name }),
           let canonical = entry["canonical_session"] {
            if canonical.isNull {
                gatewayDeniesIt = true
            } else if let id = canonical["resolved_id"]?.stringValue ?? canonical["id"]?.stringValue, !id.isEmpty {
                return .found(id)
            }
        }

        if let id = await botChatID(path: "/api/sessions", profile: name, ownedBy: name, query: [
            URLQueryItem(name: "order", value: "recent"),
            URLQueryItem(name: "limit", value: "100"),
        ]) {
            return .found(id)
        }
        if let id = await botChatID(path: "/api/sessions/search", profile: name, ownedBy: nil, query: [
            URLQueryItem(name: "q", value: botChatTitle),
        ]) {
            return .found(id)
        }
        return gatewayDeniesIt ? .missing : .unknown
    }

    /// The stored id of a bot's main chat, or nil when it has none yet or the gateway can't say.
    public func mainChatID(profile name: String) async -> String? {
        guard case .found(let id) = await mainChat(profile: name) else { return nil }
        return id
    }

    private func botChatID(path: String, profile: String, ownedBy owner: String?, query: [URLQueryItem]) async -> String? {
        guard let page: SessionListResponse = try? await api.get(path, query: query, profile: profile) else { return nil }
        let match = page.sessions.first { row in
            guard row.title == botChatTitle else { return false }
            guard let owner else { return true }
            return (row.profile ?? owner) == owner
        }
        return match?.id
    }
}
