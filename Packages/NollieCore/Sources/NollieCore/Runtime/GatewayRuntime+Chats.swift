import Foundation

// Opening, starting and closing chats.

extension GatewayRuntime {
    public func chat(runtimeID: String) -> ChatSession? {
        chats.first { $0.runtimeID == runtimeID }
    }

    public func chatForStored(_ storedID: String) -> ChatSession? {
        let found = registry.byStored(storedID)
        return found
    }

    /// Marks a chat as having something waiting for the person, or clears the mark.
    public func setAttention(storedID: String, needed: Bool = true) {
        if needed {
            needsAttention.insert(storedID)
        } else {
            needsAttention.remove(storedID)
        }
    }

    /// Hands over the open chat that matches a stored id, creating one when needed. The cached transcript is
    /// available at once while the live attach finishes in the background (see
    /// `ChatSession.isResuming` and `resumeError`); `waitForResume` blocks until the attach is done.
    ///
    /// `profile` is the bot that owns the stored chat. If the caller lacks it, the gateway is queried
    /// first, because `session.resume` against the wrong bot succeeds anyway and quietly files the
    /// chat under that bot.
    @discardableResult
    public func openChat(storedID: String, title: String? = nil, profile: String? = nil, waitForResume: Bool = false) async throws -> ChatSession {
        try refuseIfDisposed()
        let already = chatForStored(storedID)
        if let already { return await revive(already, waiting: waitForResume) }

        let owner = try await botHolding(storedID, hint: profile)
        try refuseIfDisposed()
        // Someone else may have opened the same chat while the gateway was being asked.
        if let raced = chatForStored(storedID) { return await revive(raced, waiting: waitForResume) }

        let fresh = ChatSession(runtime: self, storedID: storedID, title: title, profile: owner)
        registry.add(fresh)
        fresh.beginResume()
        if waitForResume { try await settle(fresh) }
        return fresh
    }

    /// The bot the caller named, or else the one the gateway says has the chat.
    private func botHolding(_ storedID: String, hint: String?) async throws -> String? {
        if let hint, !hint.isEmpty { return hint }
        return try await ownerProfile(ofStored: storedID)
    }

    /// Waits for a chat's attach; if it failed the chat is dropped and the failure thrown.
    private func settle(_ chat: ChatSession) async throws {
        await chat.awaitResume()
        guard let failure = chat.resumeError else { return }
        registry.remove(chat)
        throw HermesAPIError.transport(failure)
    }

    /// Returns a chat that has been requested again. If its earlier attach failed (for instance it
    /// opened during a socket outage that the first connect never repairs), attach anew. Handing over a
    /// broken chat would make every send fail until the person left.
    private func revive(_ chat: ChatSession, waiting: Bool) async -> ChatSession {
        if chat.resumeError != nil, !chat.isResuming { chat.beginResume() }
        if waiting { await chat.awaitResume() }
        return chat
    }

    /// Begins a new chat. `cwd` is a gateway folder; the chat runs in it and lands under that project.
    /// `profile` names the bot when it differs from the selected one, so the list on screen stays put.
    @discardableResult
    public func newChat(cwd: String? = .none, profile: String? = .none) async throws -> ChatSession {
        try refuseIfDisposed()
        let started = ChatSession(runtime: self, storedID: nil, title: nil, profile: profile)
        try await started.create(cwd: cwd)
        try refuseIfDisposed()
        registry.add(started)
        return started
    }

    /// A disposed runtime keeps no chats. One added after disposal would never be released.
    private func refuseIfDisposed() throws {
        if isDisposed { throw HermesAPIError.transport("This gateway is closed.") }
    }

    public func closeChat(_ chat: ChatSession) {
        registry.remove(chat)
        let farewell = Self.params(["session_id": .string(chat.runtimeID)], owner: chat.profile)
        Task { [socket] in _ = try? await socket?.call("session.close", params: farewell) }
    }
}
