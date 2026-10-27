import Foundation
import NollieCore

/// Turning a tapped notification (or an action on one) into the right chat on the right gateway.
extension AppModel {
    // MARK: Entry points

    func route(from userInfo: [AnyHashable: Any], action: String?, replyText: String? = nil) {
        let known = [LocalNotifier.replyAction, LocalNotifier.approveOnceAction, LocalNotifier.denyAction]
        if let action, !known.contains(action) { return }
        guard var route = PendingRoute(notification: userInfo) else { return }
        route.action = action
        route.replyText = replyText
        enqueue(.route(route))
    }

    func openCloudAlert(eventID: String) { enqueue(.cloud(eventID)) }

    /// Replaces whatever notification was in progress with this one.
    private func enqueue(_ request: NotificationRequest) {
        notificationTask?.cancel()
        notificationTask = nil
        notificationGeneration = UUID()
        notificationRequest = request
        pendingRoute = nil
        notificationRouteError = nil
        notificationLockChanged()
    }

    /// Called whenever the app lock changes. While locked, any work stops. Once unlocked, a
    /// waiting Ask Nollie runs and a waiting notification is carried out.
    func notificationLockChanged() {
        if lock.isLocked {
            if notificationTask != nil { notificationGeneration = UUID() }
            notificationTask?.cancel()
            notificationTask = nil
            return
        }
        if askNollieWaiting { askNollie() }
        guard notificationTask == nil, let request = notificationRequest else { return }

        let generation = notificationGeneration
        notificationTask = Task { [weak self] in
            guard let self else { return }
            defer { if notificationGeneration == generation { notificationTask = nil } }
            guard var route = await resolve(request, generation: generation) else { return }
            route.token = generation
            await ensureConnection(for: route, generation: generation)
            if isLive(generation) { notificationRequest = nil }
        }
    }

    /// A route for the request, looking up a cloud alert's target if needed. Nil means stop.
    private func resolve(_ request: NotificationRequest, generation: UUID) async -> PendingRoute? {
        switch request {
        case .route(let route):
            return route
        case .cloud(let eventID):
            guard let event = await cloudAlerts.openedEvent(eventID: eventID), let target = event.target else {
                guard isLive(generation) else { return nil }
                notificationRequest = nil
                notificationRouteError = String(localized: "This notification is no longer available. Open your assistant to see its latest updates.")
                return nil
            }
            guard target.isValid, isLive(generation) else { return nil }
            // The weekly note opens over the main chat it is shown at the top of.
            if event.kind == .weeklyNote { weeklyRequest = UUID() }
            return PendingRoute(
                connectionID: target.connectionID,
                gatewayFingerprint: target.gatewayFingerprint,
                gatewayIdentity: target.gatewayIdentity,
                storedSessionID: target.sessionID,
                profile: target.profile,
                token: generation,
                messageRowID: target.messageRowID)
        }
    }

    /// Whether the notification work for this generation should carry on: the app is unlocked
    /// and no newer notification has replaced it.
    func isCurrentNotification(_ generation: UUID) -> Bool {
        !lock.isLocked && notificationGeneration == generation
    }

    private func isLive(_ generation: UUID) -> Bool {
        !Task.isCancelled && isCurrentNotification(generation)
    }

    // MARK: Getting to the chat

    private func ensureConnection(for requested: PendingRoute, generation: UUID) async {
        #if os(iOS)
        let extraTime = BackgroundTime("nollie.notification.route")
        defer { extraTime.end() }
        #endif
        guard isLive(generation) else { return }

        // If the notification names a gateway identity, check it. A cold start first brings up
        // its own saved gateway, which can learn an address alias by signing in; it does not
        // probe every saved gateway.
        var verifiedOn: UUID?
        if let identity = requested.gatewayIdentity {
            if runtime == nil, let saved = store.active {
                await activate(saved, ifCurrent: { self.isLive(generation) })
            }
            guard isLive(generation) else { return }
            if let current = runtime, await current.refreshGatewayIdentity() == identity {
                guard isLive(generation), runtime === current else { return }
                verifiedOn = current.connection.id
            }
            guard isLive(generation) else { return }
        }

        guard let target = NotificationNavigation.connection(for: requested, among: store.connections) else {
            notificationRouteError = String(localized: "The connection for this notification is no longer saved on this device.")
            return
        }
        if runtime?.connection.id != target.id {
            await activate(target, ifCurrent: { self.isLive(generation) })
        }
        guard isLive(generation), let runtime, runtime.connection.id == target.id else { return }

        if let identity = requested.gatewayIdentity, verifiedOn != target.id {
            let actual = await runtime.refreshGatewayIdentity()
            guard isLive(generation), self.runtime === runtime else { return }
            guard actual == identity else {
                notificationRouteError = String(localized: "This connection no longer identifies the assistant that sent the notification.")
                return
            }
        }

        var route = requested
        route.connectionID = target.id
        route.profile = route.profile ?? "default"

        guard await confirmOwner(of: route, on: runtime, generation: generation) else { return }

        runtime.selectedProfile = route.profile
        pendingRoute = route
        selectedTab = .chats
        guard let action = route.action else { return }
        await perform(action, for: route, on: runtime, generation: generation)
    }

    /// Resuming a chat under the wrong owner can move it on older gateways, so check the named
    /// bot's store only. Never search other bots or guess from the current selection.
    private func confirmOwner(of route: PendingRoute, on runtime: GatewayRuntime, generation: UUID) async -> Bool {
        if let cached = runtime.chatForStored(route.storedSessionID), cached.profileName != route.profile {
            notificationRouteError = String(localized: "This conversation belongs to a different bot. Open it from Chats.")
            return false
        }
        do {
            let info: JSONValue = try await runtime.api.get("/api/sessions/\(route.storedSessionID)", profile: route.profile)
            guard isLive(generation), self.runtime === runtime else { return false }
            guard NotificationNavigation.sessionMatches(info, route: route) else {
                notificationRouteError = String(localized: "The conversation named by this notification is no longer available for this bot.")
                return false
            }
            return true
        } catch {
            guard isLive(generation), self.runtime === runtime else { return false }
            notificationRouteError = String(localized: "The conversation couldn\u{2019}t be checked. Reconnect, then open the notification again.")
            return false
        }
    }

    /// Carries out a notification button: a typed reply, or Approve or Deny.
    private func perform(_ action: String, for route: PendingRoute, on runtime: GatewayRuntime, generation: UUID) async {
        // Wait up to 12 seconds for the socket to open.
        let giveUp = Date().addingTimeInterval(12)
        while runtime.socketState != .open, Date() < giveUp {
            guard isLive(generation), self.runtime === runtime else { return }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        }
        guard isLive(generation), self.runtime === runtime, runtime.socketState == .open,
              let chat = try? await runtime.openChat(storedID: route.storedSessionID, title: nil, profile: route.profile),
              isLive(generation), self.runtime === runtime
        else { return }

        if action == LocalNotifier.replyAction {
            guard let text = route.replyText, !text.isEmpty else { return }
            notificationRequest = nil
            await chat.send(text)
            return
        }

        guard action == LocalNotifier.approveOnceAction || action == LocalNotifier.denyAction,
              let card = await Self.approvalCard(for: route, in: chat),
              isLive(generation), self.runtime === runtime
        else { return }

        let approving = action == LocalNotifier.approveOnceAction
        let choice = approving ? "once" : "deny"
        notificationRequest = nil
        switch (SignInAsk(card.approval) != nil, ApprovalConfirm.shouldAsk(for: card.approval)) {
        case (true, _):
            // A sign-in is never allowed from a notification alone. It needs Face ID or Touch
            // ID first, as on the card itself.
            _ = await SignInAnswer.answer(approving, card: card, chat: chat)
        case (false, true):
            approvalConfirm = ApprovalConfirm(storedID: chat.storedID, cardID: card.id, choice: choice)
        case (false, false):
            await chat.respond(card: card, result: ["choice": .string(choice)])
        }
    }

    /// Picks the approval that a Deny or Approve tapped outside the chat targets. Usually that is the
    /// card the notification names (`PendingRoute.cardKeys`); when no card is named, it is the sole
    /// approval in the chat, waited for while the chat loads. Nil if the request is already gone, or
    /// there is no name and the chat holds none or several.
    static func approvalCard(for route: PendingRoute, in chat: ChatSession, wait: TimeInterval = 8) async -> PendingCard? {
        await chat.approvalToAnswer(named: route.cardKeys, waitingUpTo: wait)
    }
}
