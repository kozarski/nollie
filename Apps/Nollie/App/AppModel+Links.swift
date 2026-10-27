import Foundation
import NollieCore

/// Opening chats from outside the usual screens: links, Siri, the main chat, Ask Nollie, the Board.
extension AppModel {
    // MARK: Siri and shortcuts

    /// Siri and Shortcuts entry point for a new chat. Falls back to the default bot if none is given.
    func requestNewChat(profile: String?) {
        (sideChatRequestedAt, composeProfile, selectedTab) = (.now, profile, .chats)
        // The Chats screen needs a moment to appear and start listening for the request.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.5))
            newChatRequest = UUID()
        }
    }

    /// Jumps into an existing chat when Siri, Shortcuts or Spotlight ask for it.
    func openStoredChat(id: String, profile: String?) {
        show(chat: id, of: profile)
    }

    /// Goes to a stored chat. An empty bot name counts as none: the gateway is then asked who
    /// owns the chat when it opens, instead of assuming whichever bot happens to be selected.
    private func show(chat id: String, of profile: String?) {
        selectedTab = .chats
        let bot = (profile?.isEmpty ?? true) ? nil : profile
        pendingRoute = PendingRoute(connectionID: runtime?.connection.id, storedSessionID: id, profile: bot)
    }

    // MARK: Links

    /// URL entry point. Understands the chat deep link (id plus optional bot), the chat list link, pairing
    /// links, and Nollie Link codes.
    func open(_ url: URL) {
        if NollieLinkOffer.isOffer(url.absoluteString) {
            acceptLinkOffer(url)
            return
        }
        guard AppIdentity.acceptsURLScheme(url.scheme) else { return }

        #if DEBUG
        if DemoMode.isOn, url.host == "demo-notification", openDemoNotification(url) { return }
        #endif

        if url.host == "pair" {
            acceptPairing(url)
            return
        }

        selectedTab = .chats
        guard url.host == "chat", let id = url.pathComponents.dropFirst().first else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        show(chat: id, of: items?.first { $0.name == "profile" }?.value)
    }

    private func acceptLinkOffer(_ url: URL) {
        #if os(iOS)
        guard !devicePairingFlowActive, pendingDevicePairing == nil, pendingLinkOffer == nil,
              let offer = try? NollieLinkOffer.parse(url.absoluteString)
        else { return }
        pendingLinkOffer = offer
        #endif
    }

    private func acceptPairing(_ url: URL) {
        #if os(iOS)
        guard !devicePairingFlowActive, pendingDevicePairing == nil, pendingLinkOffer == nil,
              let invitation = try? DevicePairingInvitation.parse(url.absoluteString)
        else { return }
        pendingDevicePairing = invitation
        #endif
    }

    #if DEBUG
    /// A fake notification for demos: `nollie://demo-notification?session=...&profile=...&row=...`.
    private func openDemoNotification(_ url: URL) -> Bool {
        guard let runtime, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        var query: [String: String] = [:]
        for item in parts.queryItems ?? [] where query[item.name] == nil { query[item.name] = item.value ?? "" }
        var payload: [String: Any] = [
            "session_id": query["session"] ?? "",
            "profile": query["profile"] ?? "default",
            "connection_id": runtime.connection.id.uuidString,
            "gateway": runtime.connection.gateway.description,
            "kind": "turn",
        ]
        if let row = query["row"].flatMap(Int.init) { payload["message_row_id"] = row }
        route(from: ["hermes": payload], action: nil)
        return true
    }
    #endif

    // MARK: A bot's Bot Chat

    /// Tapping a "Messaged X" notice lands here and opens X's own read-only Bot Chat. X is a routing
    /// alias that can match a profile's name or display name. Gives back a reason on failure, else nil.
    func openBotChat(_ handle: String) async -> String? {
        guard let runtime else { return String(localized: "Not connected.") }
        let wanted = BotDelivery.key(handle)
        let match = runtime.profiles.first { BotDelivery.key($0.name) == wanted || BotDelivery.key($0.label) == wanted }
        guard let profile = match else { return String(localized: "This gateway has no bot named \(handle).") }

        let session: String?
        do {
            session = try await findBotChat(of: profile, on: runtime)
        } catch {
            return String(localized: "Could not list \(profile.shownName)'s chats: \(error.localizedDescription)")
        }
        guard let session else {
            return String(localized: "\(profile.shownName) has no Bot Chat yet. One starts when it first messages another bot.")
        }
        var route = PendingRoute(connectionID: runtime.connection.id, storedSessionID: session, profile: profile.name)
        route.kind = "readonly"
        (selectedTab, pendingRoute) = (.chats, route)
        return nil
    }

    /// Looks for a bot's Bot Chat in three steps. The gateway names it itself (the profile
    /// list's canonical session, the live end of the chat's lineage), which is also how the
    /// companion finds it. Failing that, the recent list, then a title search.
    private func findBotChat(of profile: ProfileInfo, on runtime: GatewayRuntime) async throws -> String? {
        if let canonical = await canonicalSession(of: profile, on: runtime) { return canonical }

        let recent: SessionListResponse = try await runtime.api.get(
            "/api/sessions", query: Self.sessionQuery(["order": "recent", "limit": "100"]), profile: profile.name)
        let mine = recent.sessions.filter { ($0.profile ?? profile.name) == profile.name }
        let exact = mine.filter { $0.title == "Bot Chat" }
        let loose = mine.filter { ($0.title ?? "").localizedCaseInsensitiveContains("bot chat") }
        if let hit = (exact + loose).first { return hit.id }

        let hits: SessionListResponse? = try? await runtime.api.get(
            "/api/sessions/search", query: Self.sessionQuery(["q": "Bot Chat"]), profile: profile.name)
        return hits?.sessions.first { $0.title == "Bot Chat" }?.id
    }

    /// The session the gateway itself lists as this bot's Bot Chat, when it lists one.
    private func canonicalSession(of profile: ProfileInfo, on runtime: GatewayRuntime) async -> String? {
        guard let listing = try? await runtime.rpc("profiles.list"), let rows = listing["profiles"]?.arrayValue else {
            return nil
        }
        let own = rows.filter { $0["name"]?.stringValue == profile.name }
        for row in own {
            guard let canonical = row["canonical_session"], !canonical.isNull else { continue }
            if let id = canonical["resolved_id"]?.stringValue ?? canonical["id"]?.stringValue { return id }
        }
        return nil
    }

    /// Query items in a fixed order, so a request reads the same each time.
    private static func sessionQuery(_ pairs: KeyValuePairs<String, String>) -> [URLQueryItem] {
        pairs.map { URLQueryItem(name: $0.key, value: $0.value) }
    }

    // MARK: The main chat

    /// Opens a bot's one continuous chat, its Bot Chat, which the gateway keeps as the bot's
    /// forever-chat and follows through compression. It opens writable (another bot's, from a
    /// "Messaged X" notice, opens read-only). If the gateway says the bot has none, one titled
    /// "Bot Chat" is started. Returns why it could not open, or nil.
    @discardableResult
    func openMainChat(_ profileName: String? = nil) async -> String? {
        guard !Task.isCancelled else { return nil }
        guard !lock.isLocked else { return String(localized: "Unlock Nollie to open your conversation.") }
        guard let runtime else { return String(localized: "Not connected.") }
        guard let name = profileName ?? runtime.selectedProfile ?? runtime.profiles.first?.name, !name.isEmpty else {
            return String(localized: "No bot on this gateway.")
        }
        let label = runtime.profiles.first(where: { $0.name == name })?.shownName ?? name

        func stale() -> Bool { Task.isCancelled || self.runtime !== runtime || lock.isLocked }

        let lookup = await runtime.mainChat(profile: name)
        if stale() { return nil }

        let session: String
        switch lookup {
        case .found(let id):
            session = id
        case .missing:
            guard let started = try? await runtime.newChat(profile: name) else {
                return String(localized: "Could not start \(label)'s main chat.")
            }
            if stale() { return nil }
            await started.rename("Bot Chat") // A title the gateway matches on, so it stays in English.
            guard !started.storedID.isEmpty else { return String(localized: "Could not start \(label)'s main chat.") }
            session = started.storedID
        case .unknown:
            return String(localized: "Could not reach \(label)'s main chat. Check the connection, then try again.")
        }
        if stale() { return nil }

        #if os(macOS)
        CloudAlertHelperController.shared.updateCanonicalSession(connectionID: runtime.connection.id, profile: name, sessionID: session)
        #endif
        var route = PendingRoute(connectionID: runtime.connection.id, storedSessionID: session, profile: name)
        route.kind = "main"
        route.token = UUID()
        selectedTab = .chats
        pendingRoute = route
        return nil
    }

    // MARK: Ask Nollie

    /// The Ask Nollie control: open the main chat with the keyboard up. Behind the app lock it
    /// waits for the unlock; with no gateway running, the saved one comes up first.
    func askNollie() {
        selectedTab = .chats
        askNollieWaiting = true
        guard !lock.isLocked, askNollieTask == nil else { return }

        askNollieTask = Task { @MainActor in
            defer { askNollieTask = nil }
            if runtime == nil { await activateSavedConnection() }
            guard !lock.isLocked else { return }

            let problem = await openMainChat()
            // If the lock came up part way, nothing opened; it runs again after the unlock.
            guard !lock.isLocked else { return }
            if problem == nil {
                composerFocusSession = pendingRoute?.storedSessionID
                composerFocusRequestedAt = Date()
            }
            askNollieWaiting = false
            // With nothing set up yet, setup is the answer, so no alert on top of it.
            askNollieError = hasConnections ? problem : nil
        }
    }

    // MARK: The Board

    func openBoardChat(_ task: KanbanTask, board: String?, boardName: String?) {
        guard let runtime,
              let context = BoardChatContext(task: task, connectionID: runtime.connection.id, board: board, boardName: boardName)
        else { return }
        boardChatContext = context
        selectedTab = .chats
        pendingRoute = context.route
    }

    func returnToBoardTask(_ context: BoardChatContext) {
        guard let runtime, runtime.connection.id == context.connectionID else { return }
        if let board = context.board { runtime.kanban.select(board: board) }
        boardTaskToReveal = context
        selectedTab = .kanban
    }
}
