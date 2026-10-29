import SwiftUI
import NollieCore

// Fetching, searching and editing chats on the gateway

extension ChatListView {
    /// Fetches the list. A chat that is open in the app but not yet listed by the gateway stays
    /// in the list, taken from its live session. With nothing cached, a cold start retries a few times.
    func load(attempt: Int = 0) async {
        guard let runtime else { return }
        let scope = allBots ? "*" : runtime.selectedProfile
        if sessions.isEmpty { sessions = cachedList(for: runtime, scope: scope) }
        loading = sessions.isEmpty
        defer { loading = false }
        do {
            let listed = allBots ? try await listEveryBot(runtime) : try await listSelectedBot(runtime)
            let known = Set(listed.map(\.id))
            sessions = (listed + openChatsNotListed(by: runtime, listed: known)).sorted(by: Self.pinnedThenRecent)
            remember(sessions, for: runtime, scope: scope)
            errorText = nil
        } catch is CancellationError {
            // A later load (bot or gateway changed) superseded this one.
        } catch {
            let words = error.localizedDescription
            guard !words.localizedCaseInsensitiveContains("cancelled") else { return }
            errorText = words
            // On a cold start the request can go out before the session is renewed or the gateway has
            // replied. When nothing is cached and the page would stay blank, try several more times, then stop.
            guard sessions.isEmpty, attempt < 3, !Task.isCancelled else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { await load(attempt: attempt + 1) }
        }
    }

    /// Saves the list for the next launch, and for the details Siri can name while the app is
    /// closed: the bots and the titles of recent chats.
    private func remember(_ list: [StoredSession], for runtime: GatewayRuntime, scope: String?) {
        SiriCatalog.rememberBots(runtime.profiles)
        SiriCatalog.rememberChats(list)
        SessionCache.save(list, connection: runtime.connection.id, profile: scope)
    }

    private func updateOnGateway(_ id: String, _ fields: [String: JSONValue]) async throws {
        let _: JSONValue? = try await runtime?.api.send("PATCH", "/api/sessions/\(id)", json: .object(fields))
    }

    private func cachedList(for runtime: GatewayRuntime, scope: String?) -> [StoredSession] {
        let exact = SessionCache.load(connection: runtime.connection.id, profile: scope)
        // Cold start, bot not known yet: any list held for this gateway is better than an empty page.
        return exact.isEmpty ? SessionCache.loadAny(connection: runtime.connection.id) : exact
    }

    private static func pinnedThenRecent(_ a: StoredSession, _ b: StoredSession) -> Bool {
        let left = (a.pinned == true ? 1 : 0, a.lastActive ?? 0)
        let right = (b.pinned == true ? 1 : 0, b.lastActive ?? 0)
        return left > right
    }

    /// Every row remembers the bot it was listed under, so opening it later does not hinge on
    /// which bot happens to be selected then.
    nonisolated private static func stamped(_ sessions: [StoredSession], with bot: String?) -> [StoredSession] {
        sessions.map { row in
            guard row.profile?.isEmpty ?? true else { return row }
            var copy = row
            copy.profile = bot
            return copy
        }
    }

    private func recentQuery(limit: Int) -> [URLQueryItem] {
        [URLQueryItem(name: "order", value: "recent"), URLQueryItem(name: "limit", value: String(limit))]
    }

    private func listEveryBot(_ runtime: GatewayRuntime) async throws -> [StoredSession] {
        let query = recentQuery(limit: 50)
        var everything: [StoredSession] = []
        try await withThrowingTaskGroup(of: [StoredSession].self) { group in
            for bot in runtime.profiles.map(\.name) {
                group.addTask {
                    let reply: SessionListResponse = try await runtime.api.get("/api/sessions", query: query, profile: bot)
                    return Self.stamped(reply.sessions, with: bot)
                }
            }
            for try await part in group { everything += part }
        }
        return everything
    }

    private func listSelectedBot(_ runtime: GatewayRuntime) async throws -> [StoredSession] {
        let bot = runtime.selectedProfile
        let reply: SessionListResponse = try await runtime.api.get("/api/sessions", query: recentQuery(limit: 100), profile: bot)
        return Self.stamped(reply.sessions, with: bot)
    }

    /// Open chats that the gateway's list leaves out. A freshly started chat is stored only after its
    /// first prompt, and the row is completed while the turn is saved. Left as is, a chat begun
    /// seconds ago (or one still running) would vanish from the list as soon as you backed out.
    /// So we hold on to those, assembled out of the running session, until the gateway shows them
    /// itself. Pinned rows the gateway omitted are handled the other way and dropped: it returns
    /// every pinned chat, so an extra one is a leftover (id changed by compression, or deleted
    /// elsewhere) that could never be unpinned.
    private func openChatsNotListed(by runtime: GatewayRuntime, listed: Set<String>) -> [StoredSession] {
        let now = Date().timeIntervalSince1970
        let wanted = runtime.selectedProfile
        return runtime.chats.compactMap { chat in
            guard !chat.storedID.isEmpty, !listed.contains(chat.storedID) else { return nil }
            guard chat.isRunning || !chat.items.isEmpty else { return nil }
            guard allBots || chat.profileName == (wanted ?? chat.profileName) else { return nil }
            let first = chat.items.first
            var opening: String?
            if case .user(let text, _)? = first?.kind { opening = text }
            let lastSeen = chat.items.last?.timestamp.timeIntervalSince1970 ?? now
            var stand = StoredSession(id: chat.storedID, title: chat.title == ChatSession.newChatTitle ? nil : chat.title, preview: opening)
            stand.source = "ios"
            stand.model = chat.modelName.isEmpty ? nil : chat.modelName
            stand.startedAt = first?.timestamp.timeIntervalSince1970 ?? now
            stand.lastActive = max(lastSeen, now - 1)
            stand.messageCount = chat.items.count
            stand.isActive = chat.isRunning
            stand.archived = false
            stand.pinned = false
            stand.profile = chat.profileName
            return stand
        }
    }

    func search(_ words: String) async {
        guard let runtime, !words.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchResults = []
            return
        }
        let bot = runtime.selectedProfile
        do {
            let reply: JSONValue = try await runtime.api.get("/api/sessions/search", query: [URLQueryItem(name: "q", value: words)], profile: bot)
            let found = reply["sessions"]?.arrayValue ?? reply["results"]?.arrayValue ?? reply.arrayValue ?? []
            searchResults = Self.stamped(found.compactMap { try? $0.decode(StoredSession.self) }, with: bot)
        } catch {
            errorText = error.localizedDescription
        }
    }

    // MARK: Changing chats

    /// Use the chat's owning bot rather than the selected bot, since all-bots mode mixes rows from every profile.
    private func botName(of session: StoredSession, _ runtime: GatewayRuntime) -> String? {
        session.profile ?? runtime.selectedProfile
    }

    func archive(_ list: [StoredSession]) async {
        guard let runtime else { return }
        for session in list where session.archived != true {
            var fields: [String: JSONValue] = ["archived": .bool(true)]
            if session.pinned == true { fields["pinned"] = .bool(false) }
            if let bot = botName(of: session, runtime), !bot.isEmpty { fields["profile"] = .string(bot) }
            do {
                try await updateOnGateway(session.id, fields)
            } catch {
                errorText = String(localized: "\u{201C}\(session.displayTitle)\u{201D} did not archive: \(error.localizedDescription)",
                                   comment: "A chat's title in quotes, then the reason")
            }
        }
        await load()
    }

    func delete(_ list: [StoredSession]) async {
        for session in list { await remove(session, reload: false) }
        sessions.removeAll { row in list.contains { $0.id == row.id } }
        await load()
    }

    func delete(_ session: StoredSession) async {
        await remove(session, reload: true)
    }

    private func remove(_ session: StoredSession, reload: Bool) async {
        droppedIDs.insert(session.id)
        guard let runtime else { return }
        if let open = runtime.chatForStored(session.id) { runtime.closeChat(open) }
        if reload { sessions.removeAll { $0.id == session.id } }
        let _: JSONValue? = try? await runtime.api.send("DELETE", "/api/sessions/\(session.id)",
                                                        profile: botName(of: session, runtime), body: EmptyBody())
        if reload { await load() }
    }

    func patch(_ session: StoredSession, _ fields: [String: JSONValue]) async {
        guard let runtime else { return }
        var body = fields
        if let bot = botName(of: session, runtime), !bot.isEmpty { body["profile"] = .string(bot) }
        // An archive also removes the pin. The gateway returns all pinned chats archived or not, which means
        // a pinned archived chat would stay on top and the action would seem to have done nothing.
        if case .bool(true)? = body["archived"], session.pinned == true { body["pinned"] = .bool(false) }
        // Applied to the screen immediately; the gateway's reply confirms or reverts it.
        let before = sessions
        if let at = sessions.firstIndex(where: { $0.id == session.id }) {
            if case .bool(let on)? = body["pinned"] { sessions[at].pinned = on }
            if case .bool(let on)? = body["archived"] { sessions[at].archived = on }
        }
        do {
            try await updateOnGateway(session.id, body)
        } catch HermesAPIError.http(404, _) {
            // The gateway has no such id any more (compression moved it, or another device deleted it).
            // The row was out of date, and the gateway's list is what counts.
            sessions.removeAll { $0.id == session.id }
            droppedIDs.insert(session.id)
        } catch {
            sessions = before
            errorText = String(localized: "Could not update the chat: \(error.localizedDescription)")
            return
        }
        await load()
    }
}
