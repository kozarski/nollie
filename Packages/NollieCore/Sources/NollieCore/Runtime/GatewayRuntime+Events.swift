import Foundation
import OSLog

// What comes in from the socket: events for chats, list changes, and requests from the server.

extension GatewayRuntime {
    /// Signposts so Instruments (Points of Interest) can time event batches and snapshots.
    nonisolated static let signposter = OSSignposter(subsystem: "Nollie", category: .pointsOfInterest)

    /// Processes the events the socket collected since the main actor last checked. Consecutive reply
    /// text is merged into one piece and repeated list refreshes collapse to one apiece, because
    /// after a long absence there can be thousands of frames to chew through at once.
    func handle(batch: [GatewayEvent]) {
        if batch.isEmpty { return }
        let settled = GatewayEvent.droppingRepeatedRefreshes(GatewayEvent.coalescingText(batch))
        Self.signposter.withIntervalSignpost("events", "\(batch.count) events") {
            settled.forEach(route)
        }
    }

    /// Sends an event to the chat it belongs to. Events for no open chat are mostly about the
    /// gateway's lists, which are refreshed instead.
    private func route(_ event: GatewayEvent) {
        switch (registry.byRuntime(event.sessionID), event.type) {
        case (let chat?, _):
            chat.handle(event: event)
        case (nil, "session.reclaimed"):
            guard let id = event.payload["session_id"]?.stringValue else { return }
            registry.byRuntime(id)?.handle(event: event)
        case (nil, "sessions.changed"):
            announce(.hermesSessionsChanged)
            Task { await projects.refreshTree() }
        case (nil, "projects.changed"):
            Task { await projects.refresh() }
        case (nil, "cron.changed"):
            announce(.hermesCronChanged)
        default:
            break
        }
    }

    private func announce(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }

    // MARK: Requests from the server

    /// Answers a request the gateway made of us (an approval, a question). Called by the socket.
    func answer(serverRequest request: ServerRequest) async -> JSONValue? {
        serverRequestsReceived += 1
        lastServerRequest = "\(request.method) · \(Date().formatted(date: .omitted, time: .shortened))"

        let chat = registry.byRuntime(request.sessionID) ?? registry.byStored(request.sessionID)
        if let choice = autoChoice(for: request, chat: chat) { return ["choice": .string(choice)] }
        if let chat { return await chat.answer(serverRequest: request) }

        // The approval may be for a session this app never opened, such as a cron run or a chat that
        // started on another device. Turning it down would take the prompt away, so open that session
        // and present its card.
        let stored = request.params["stored_session_id"]?.stringValue ?? request.sessionID
        log.warning("opening session \(stored, privacy: .public) which was not open, to answer the \(request.method, privacy: .public) request")
        let bot = request.params["profile"]?.stringValue
        guard let opened = try? await openChat(storedID: stored, title: nil, profile: bot, waitForResume: true) else { return nil }
        return await opened.answer(serverRequest: request)
    }

    /// The app's own answer to an approval, when it has a rule for it (System control on), so
    /// no card is shown. Only for a bot known for certain: the open chat's, or the one the
    /// request names.
    private func autoChoice(for request: ServerRequest, chat: ChatSession?) -> String? {
        guard request.method == "approval", let decide = approvalAutoAnswer else { return nil }
        guard let approval = try? request.params.decode(ApprovalRequest.self),
              let bot = chat?.profileName ?? request.params["profile"]?.stringValue,
              let choice = decide(approval, bot) else { return nil }
        log.info("approval \(approval.patternKey ?? "", privacy: .public) for \(bot, privacy: .public) answered \(choice, privacy: .public) by the app")
        return choice
    }
}
