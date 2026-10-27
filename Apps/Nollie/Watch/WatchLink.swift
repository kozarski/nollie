import Foundation
import NollieCore
#if os(iOS)
import UIKit
import WatchConnectivity
#endif

/// The iPhone's side of Nollie on Apple Watch. The phone holds the link to the Mac, so the Watch
/// asks it for what is waiting and who is working, and hands it an answer or a Stop to carry out.
/// While the app is in front the phone also keeps the Watch's picture current on its own.
@MainActor
final class WatchLink: NSObject {
    static let shared = WatchLink()

    /// Called once at launch (AppModel). Does nothing where there is no Watch.
    static func start() {
        #if os(iOS)
        shared.begin()
        #endif
    }

    #if os(iOS)
    private var started = false
    private var loop: Task<Void, Never>?
    private var lastSent: WatchWire.Snapshot?
    private static let checkEvery: Duration = .seconds(3)
    /// Sent again this often even when nothing changed, so the Watch knows the picture is current.
    private static let refreshEvery: TimeInterval = HelperAtWorkTiming.refreshEvery
    /// The last Night shift card read for the Watch, the gateway it came from and when.
    private var night: (gateway: UUID, read: Date, card: ConversationPost.NightShift?)?
    private var readingNight = false
    /// The card comes once a morning, so it is read again only this often.
    private static let nightEvery: TimeInterval = 15 * 60

    private func begin() {
        guard !started, WCSession.isSupported() else { return }
        started = true
        WCSession.default.delegate = self
        WCSession.default.activate()
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in WatchLink.shared.foreground() }
        }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in WatchLink.shared.background() }
        }
    }

    // MARK: Keeping the Watch current

    private func foreground() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.push()
                try? await Task.sleep(for: Self.checkEvery)
            }
        }
    }

    private func background() {
        loop?.cancel()
        loop = nil
        push(force: true)
    }

    /// Sends the picture when it changed, or when the last one is getting old.
    private func push(force: Bool = false) {
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        let now = Date()
        readNightIfDue(force: force)
        let snapshot = Self.snapshot(runtime: AppModel.shared.runtime, now: now, night: nightCard)
        let old = lastSent.map { now.timeIntervalSince($0.made) >= Self.refreshEvery } ?? true
        guard force || old || !snapshot.sameAs(lastSent) else { return }
        let countChanged = snapshot.helpers.count != lastSent?.helpers.count
        lastSent = snapshot
        try? session.updateApplicationContext(WatchWire.message(snapshot))
        // A complication showing the count gets its own, faster delivery when the count moves.
        if countChanged, session.isComplicationEnabled, session.remainingComplicationUserInfoTransfers > 0 {
            session.transferCurrentComplicationUserInfo(WatchWire.message(snapshot))
        }
    }

    /// The card read for the gateway the phone is on now.
    private var nightCard: ConversationPost.NightShift? {
        guard let night, night.gateway == AppModel.shared.runtime?.connection.id else { return nil }
        return night.card
    }

    /// Reads the newest Night shift card in the background when the last read is old or was for another
    /// gateway, then sends the picture again.
    private func readNightIfDue(force: Bool = false) {
        guard !readingNight, let runtime = AppModel.shared.runtime else { return }
        let gateway = runtime.connection.id
        if let night, night.gateway == gateway, Date().timeIntervalSince(night.read) < (force ? 60 : Self.nightEvery) { return }
        readingNight = true
        Task { [weak self] in
            await self?.readNight(runtime)
            self?.push()
        }
    }

    private func readNight(_ runtime: GatewayRuntime) async {
        readingNight = true
        defer { readingNight = false }
        let card = await CrewSummaryModel.latestNight(runtime)
        guard runtime.connection.id == AppModel.shared.runtime?.connection.id else { return }
        night = (runtime.connection.id, Date(), card)
    }

    // MARK: Answering the Watch

    func handle(_ request: WatchWire.Request?) async -> WatchWire.Reply {
        let extraTime = BackgroundTime("nollie.watch")
        defer { extraTime.end() }
        guard let request else { return WatchWire.Reply(done: false, line: WatchWords.openPhone) }
        switch request {
        case .refresh:
            let runtime = try? await SiriAsk.readyRuntime()
            if let runtime, night?.gateway != runtime.connection.id || night.map({ Date().timeIntervalSince($0.read) >= Self.nightEvery }) == true {
                await readNight(runtime)
            }
            return reply(done: runtime != nil, line: runtime == nil ? WatchWords.openPhone : nil)
        case .answer(let answer):
            let line = await self.answer(answer)
            return reply(done: line == WatchWords.allowed || line == WatchWords.denied, line: line)
        case .notificationDeny(let details):
            if let answer = await denial(from: details) {
                let line = await self.answer(answer)
                return reply(done: line == WatchWords.denied, line: line)
            }
            // From another gateway: the phone's own notification path checks and switches.
            AppModel.shared.route(from: ["hermes": details], action: LocalNotifier.denyAction)
            return reply(done: true, line: nil)
        case .stop:
            let line = await MacStop.press()
            return reply(done: line == MacStopWords.stopped, line: line)
        }
    }

    private func reply(done: Bool, line: String?) -> WatchWire.Reply {
        let snapshot = Self.snapshot(runtime: AppModel.shared.runtime, now: Date(), night: nightCard)
        lastSent = snapshot
        return WatchWire.Reply(done: done, line: line, snapshot: snapshot)
    }

    /// A notification's Deny as an answer, when it came from the gateway the phone is on now.
    private func denial(from details: [String: String]) async -> WatchWire.Answer? {
        guard let chatID = details["session_id"], let runtime = try? await SiriAsk.readyRuntime() else { return nil }
        let connection = runtime.connection
        let sameGateway = details["connection_id"] == connection.id.uuidString
            || (details["connection_id"] == nil && details["gateway"].flatMap({ try? GatewayURL.normalize($0) }) == connection.gateway)
        guard sameGateway else { return nil }
        return WatchWire.Answer(cardID: details["card_id"] ?? "", requestID: details["request_id"] ?? "", chatID: chatID,
                                profile: details["profile"] ?? "default", connectionID: connection.id.uuidString, choice: .deny)
    }

    /// Carries out one answer on exactly the card it names, after checking the phone's own rules.
    private func answer(_ answer: WatchWire.Answer) async -> String {
        guard let runtime = try? await SiriAsk.readyRuntime() else { return WatchWords.openPhone }
        guard runtime.connection.id.uuidString == answer.connectionID else { return WatchWords.gone }
        let chat: ChatSession
        if let open = runtime.chatForStored(answer.chatID) {
            chat = open
        } else if let opened = try? await runtime.openChat(storedID: answer.chatID, profile: answer.profile) {
            chat = opened
        } else {
            return WatchWords.gone
        }
        // A yes always names its card. A no without one (an older push) answers the chat's only approval.
        let names = [answer.cardID, answer.requestID].filter { !$0.isEmpty }
        guard chat.profileName == answer.profile, !names.isEmpty || answer.choice == .deny,
              let card = await chat.approvalToAnswer(named: names, waitingUpTo: 6),
              let request = card.approval
        else { return WatchWords.gone }
        let privateBot = Self.isPrivate(answer.profile, on: runtime)
        switch WatchCards.verdict(answer.choice, request: request, privateBot: privateBot) {
        case .refuse(let line):
            return line
        case .answer(let choice):
            if SignInAsk(request) != nil {
                // Only ever a no from here (the yes is refused above); answered as the card does.
                _ = await SignInAnswer.answer(false, card: card, chat: chat)
            } else {
                await chat.respond(card: card, result: ["choice": .string(choice)])
            }
            return choice == "once" ? WatchWords.allowed : WatchWords.denied
        }
    }
    #endif

    // MARK: The picture

    static func isPrivate(_ profile: String, on runtime: GatewayRuntime) -> Bool {
        if let bot = runtime.profiles.first(where: { $0.name == profile }) { return bot.isPrivateBot(on: runtime.connection.id) }
        return PrivateBots.isPrivate(profile, connection: runtime.connection.id)
    }

    #if os(iOS)
    /// What the Watch shows: every approval waiting in the open chats, the helpers at work, and the
    /// last Night shift card as a note. Private bots' work stays off the wrist; their approvals show
    /// only that something waits, and the add-on never puts them on the card.
    static func snapshot(runtime: GatewayRuntime?, now: Date, night: ConversationPost.NightShift? = nil) -> WatchWire.Snapshot {
        guard let runtime else { return .empty(at: now) }
        let connection = runtime.connection
        var approvals: [WatchWire.Approval] = []
        var seenCards: Set<String> = []
        for chat in runtime.chats {
            let profile = chat.profileName
            let bot = runtime.profiles.first { $0.name == profile }
            let privateBot = isPrivate(profile, on: runtime)
            let name = bot?.shownName ?? profile.capitalized
            let avatar = CharacterDrawing.avatarName(BotAvatarStore.look(for: profile))
            for card in chat.cards {
                guard let request = card.approval, seenCards.insert(card.id).inserted else { continue }
                approvals.append(WatchCards.approval(
                    card: card, request: request, chatID: chat.storedID, profile: profile, connectionID: connection.id,
                    botName: name, avatar: avatar, privateBot: privateBot, asksAgain: ApprovalConfirm.shouldAsk(for: request)))
            }
        }
        return WatchWire.Snapshot(made: now, approvals: approvals,
                                  helpers: CrewAtWork.members(in: runtime, now: now).map(\.helper),
                                  canStop: connection.linkedMac != nil, connected: runtime.socketState.isOpen,
                                  night: WatchNight.note(night, now: now))
    }
    #endif
}


#if os(iOS)
// MARK: - WatchConnectivity

/// Hands a reply back to the Watch from the main actor.
private struct ReplyHandler: @unchecked Sendable {
    let send: ([String: Any]) -> Void
}

extension WatchLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: (any Error)?) {
        guard state == .activated else { return }
        Task { @MainActor in WatchLink.shared.push(force: true) }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// Switching to another Watch: start again with the new one.
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in WatchLink.shared.push(force: true) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        let request = try? WatchWire.request(from: message)
        let handler = ReplyHandler(send: replyHandler)
        Task { @MainActor in
            let reply = await WatchLink.shared.handle(request)
            handler.send(WatchWire.message(reply))
        }
    }

    /// A Deny the Watch could not deliver at once (from a notification, with the phone out of
    /// reach) arrives later this way. Only a Deny is ever carried out late: a late yes or Stop could
    /// act on something nobody is looking at any more.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let late: WatchWire.Request
        switch try? WatchWire.request(from: userInfo) {
        case .answer(let answer)? where answer.choice == .deny: late = .answer(answer)
        case .notificationDeny(let details)?: late = .notificationDeny(details)
        default: return
        }
        Task { @MainActor in _ = await WatchLink.shared.handle(late) }
    }
}
#endif
