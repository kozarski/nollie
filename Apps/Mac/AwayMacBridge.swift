#if os(macOS)
import AppKit
import Foundation
import NollieCore
import Observation

/// Away from home through iCloud, on the Mac: answers what linked phones write in the person's own
/// iCloud, on this Mac's own Hermes, as if it had been typed here. See Docs/specs/away-icloud.md.
/// Only the Direct edition links phones, so only it answers.
@MainActor
@Observable
final class AwayMacBridge {
    static let shared = AwayMacBridge()
    /// Nil until the person chooses: then on whenever it is safe.
    static let enabledKey = "away.icloud.mac.v1"
    static let keyAccount = "away.mac.key.v1"
    static let seenKey = "away.icloud.seen.v1"

    private(set) var state: AwayICloudState = .checking
    /// Linked phones that swapped away keys.
    private(set) var phones = 0
    /// Moves when the switch changes, so the page draws the demo copy's choice too.
    private(set) var demoChanged = 0
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var wake: CheckedContinuation<Void, Never>?
    #if NOLLIE_DIRECT
    @ObservationIgnored private let cloud = CloudKitAwayCloud()
    @ObservationIgnored private var desk: AwayDesk?
    @ObservationIgnored private var keyGiven = false
    @ObservationIgnored private var subscribedTag: String?
    /// Turns phones started, by chat: who asked, and where the reply begins.
    @ObservationIgnored private var carried: [String: Carried] = [:]
    /// Each card sent to a phone: its chat, and Hermes's own id for the question.
    @ObservationIgnored private var relayed: [String: (chat: String, question: String)] = [:]

    private struct Carried {
        var request: String
        var phone: String
        var bot: String
        var from: Int
        var since: Date
    }
    #endif

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var isAvailable: Bool {
        #if NOLLIE_DIRECT
        !DemoMode.isOn
        #else
        false
        #endif
    }

    /// The demo copy keeps the choice for this launch only, so each picture starts from its flag.
    @ObservationIgnored private var demoChoice: Bool?
    private var chosen: Bool? { DemoMode.isOn ? demoChoice : defaults.object(forKey: Self.enabledKey) as? Bool }

    /// What the page shows. In the demo copy, a launch flag chooses.
    var shownState: AwayICloudState {
        _ = demoChanged
        #if DEBUG
        if DemoMode.isOn {
            let flagged = DemoMode.iCloud ?? .needsLink
            return flagged.canTurnOn ? (chosen.map { $0 ? .ready : .off } ?? flagged) : flagged
        }
        #endif
        return isAvailable ? state : .unavailable
    }

    func start() {
        guard isAvailable, loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let wait = await self.tick()
                await self.sleep(wait)
            }
        }
    }

    /// A push from the away subscription: look now.
    func lookNow() {
        wake?.resume()
        wake = nil
    }

    private func sleep(_ seconds: TimeInterval) async {
        await withCheckedContinuation { continuation in
            wake = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                self?.lookNow()
            }
        }
    }

    func setOn(_ on: Bool) async {
        if DemoMode.isOn { demoChoice = on } else { defaults.set(on, forKey: Self.enabledKey) }
        demoChanged += 1
        #if NOLLIE_DIRECT
        if !on, let desk {
            state = .off
            await cloud.forget(tag: desk.macTag, side: .mac)
            subscribedTag = nil
        }
        #endif
        // The loop looks again now; a second look alongside it could answer a turn twice.
        lookNow()
    }

    /// One look: keys, phones, iCloud, then the mailbox. Returns seconds until the next.
    private func tick() async -> TimeInterval {
        #if NOLLIE_DIRECT
        guard let runtime = AppModel.shared.runtime, NollieLinkMacClient.isAvailable(for: runtime.connection) else {
            state = .unavailable
            return 30
        }
        guard let key = try? AwayKey.loadOrCreate(account: Self.keyAccount) else { state = .unavailable; return 60 }
        if !keyGiven { keyGiven = (try? await NollieLinkMacClient.giveAwayKey(key.publicKey)) != nil }
        guard let status = try? await NollieLinkMacClient.status() else { state = .unavailable; return 30 }
        let list = Self.awayPhones(status.devices)
        phones = list.count
        if desk == nil {
            let saved = defaults.data(forKey: Self.seenKey).flatMap { try? JSONDecoder().decode(AwaySeenList.self, from: $0) } ?? AwaySeenList()
            desk = AwayDesk(macKey: key, cloud: cloud, handler: self, seen: saved, saveSeen: { [defaults] seen in
                if let data = try? JSONEncoder().encode(seen) { defaults.set(data, forKey: Self.seenKey) }
            })
        }
        guard let desk else { return 30 }
        desk.setPhones(list)
        guard !list.isEmpty else { state = .needsLink; return 30 }
        guard chosen != false else { state = .off; return 60 }
        guard await cloud.accountAvailable() else { state = .needsICloud; return 60 }
        if subscribedTag != desk.macTag {
            do {
                try await cloud.subscribe(tag: desk.macTag, side: .mac)
                subscribedTag = desk.macTag
                // Silent pushes need no permission, only this registration.
                NSApplication.shared.registerForRemoteNotifications()
            } catch {
                state = AwayICloudState.from(error)
                return 60
            }
        }
        state = .ready
        do { try await desk.collect() } catch { state = AwayICloudState.from(error) }
        await watchCarried(desk: desk, runtime: runtime)
        let working = runtime.chats.contains(where: \.isRunning) || ComputerCenter.shared.task != nil
        return carried.isEmpty ? desk.nextLook(working: working) : min(desk.nextLook(working: working), 2)
        #else
        state = .unavailable
        return 3600
        #endif
    }

    /// The phones that may use the iCloud away path: an owner's own, with a valid swapped key. A
    /// member (someone a helper is shared with) never does, even if the helper handed on a key.
    nonisolated static func awayPhones(_ devices: [NollieLinkIPCDevice]) -> [(name: String, key: Data)] {
        devices.compactMap { device in
            guard device.person == nil, let text = device.awayKey, let key = AwayBase64URL.decode(text),
                  AwayKey.validPublic(key) else { return nil }
            return (device.name, key)
        }
    }

    #if NOLLIE_DIRECT
    /// Cards and endings in the turns phones started: cards go to the phone that asked, and the
    /// reply goes once the turn is over.
    private func watchCarried(desk: AwayDesk, runtime: GatewayRuntime) async {
        for (chatID, turn) in carried {
            guard let chat = runtime.chatForStored(chatID) else { carried[chatID] = nil; continue }
            for card in chat.cards where card.method == "approval" && !relayed.values.contains(where: { $0.question == card.id }) {
                guard let approval = card.approval else { continue }
                let shown = AwayApproval(command: approval.command, description: approval.description,
                                         toolName: approval.toolName, patternKey: approval.patternKey, choices: [])
                if let id = await desk.card(request: turn.request, bot: turn.bot, chat: chatID, question: card.id, approval: shown,
                                            offered: approval.offeredChoices, to: turn.phone) {
                    relayed[id] = (chatID, card.id)
                    AwayPapertrail.record(bot: turn.bot, kind: "card", runtime: runtime)
                }
            }
            // A card answered or withdrawn on the Mac closes on the phone.
            for (id, sent) in relayed where sent.chat == chatID && !chat.cards.contains(where: { $0.id == sent.question }) {
                if desk.openCards.contains(where: { $0.id == id }) { await desk.closeCards(question: sent.question, outcome: .answeredOnMac) }
                relayed[id] = nil
            }
            let over = !chat.isRunning && chat.queue.isEmpty && chat.cards.isEmpty && Date().timeIntervalSince(turn.since) > 2
            if over {
                let text = Self.replyText(chat.items.dropFirst(turn.from))
                await desk.reply(request: turn.request, bot: turn.bot, chat: chatID, text: text, to: turn.phone,
                                 alert: !CloudAlertTransport.shared.isEnabled)
                AwayPapertrail.record(bot: turn.bot, kind: "reply", runtime: runtime)
                carried[chatID] = nil
            } else if Date().timeIntervalSince(turn.since) > 2 * 3600 {
                carried[chatID] = nil
            }
        }
    }

    /// The bot's words in the turn: its last reply, or a plain line when it ended without one.
    static func replyText<S: Sequence>(_ rows: S) -> String where S.Element == TranscriptItem {
        var last: String?
        var failed: String?
        for row in rows {
            switch row.kind {
            case .assistant(let text, _, _) where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty: last = text
            case .error(let text): failed = text
            default: break
            }
        }
        return last ?? failed.map { String(localized: "It stopped: \($0)", comment: "A turn ended with this error") }
            ?? String(localized: "It finished without a reply.")
    }
    #endif
}

#if NOLLIE_DIRECT
extension AwayMacBridge: AwayDeskHandler {
    func send(bot: String, chat id: String?, text: String, request: String, phone: String) async -> Result<String, AwayRefusal> {
        guard let runtime = AppModel.shared.runtime else { return .failure(.notReady) }
        guard runtime.profiles.isEmpty || runtime.profiles.contains(where: { $0.name == bot }) else { return .failure(.unknownBot) }
        let chat: ChatSession
        do {
            if let id, let open = runtime.chatForStored(id) {
                chat = open
            } else if let id {
                chat = try await runtime.openChat(storedID: id, profile: bot, waitForResume: true)
            } else {
                chat = try await runtime.newChat(profile: bot)
            }
        } catch { return .failure(id == nil ? .notReady : .unknownChat) }
        // A chat id from the phone must belong to the bot it named.
        guard chat.profileName == bot else { return .failure(.unknownChat) }
        let from = chat.items.count
        if let problem = await chat.send(text), !problem.isEmpty { return .failure(.notReady) }
        carried[chat.storedID] = Carried(request: request, phone: phone, bot: bot, from: from, since: Date())
        return .success(chat.storedID)
    }

    func answer(_ card: AwayIssuedCard, choice: String) async -> AwayCardOutcome {
        guard let chat = AppModel.shared.runtime?.chatForStored(card.chat),
              let pending = chat.cards.first(where: { $0.id == card.question }) else { return .answeredOnMac }
        relayed[card.id] = nil
        let sent = await chat.respond(card: pending, result: ["choice": .string(choice)], checkedOnPhone: true)
        return sent ? .answered : .answeredOnMac
    }

    func stop(device: String) async -> Int {
        carried = [:]
        if let runtime = AppModel.shared.runtime { AwayPapertrail.record(bot: "default", kind: "stopped", runtime: runtime) }
        return await LinkStopWatcher.shared.perform(device: device, key: "icloud." + UUID().uuidString)
    }

    func helpers() async -> [AwayHelper] {
        guard let runtime = AppModel.shared.runtime else { return [] }
        AwayPapertrail.record(bot: "default", kind: "helpers", runtime: runtime)
        return runtime.profiles.filter { !isPrivate($0.name) && AwayRules.isBotName($0.name) }.prefix(64).map { profile in
            let chats = runtime.chats.filter { $0.profileName == profile.name }
            return AwayHelper(bot: profile.name, name: String(profile.shownName.prefix(64)),
                              working: chats.contains(where: \.isRunning), waiting: min(999, chats.reduce(0) { $0 + $1.cards.count }))
        }
    }

    func isPrivate(_ bot: String) -> Bool {
        guard let runtime = AppModel.shared.runtime else { return true }
        return PrivateBots.isPrivate(bot, connection: runtime.connection.id, fresh: true)
    }
}

/// Every note the Mac writes for a bot shows in that bot's Papertrail as "Your iCloud": the time
/// and the kind of note, never its words.
@MainActor
enum AwayPapertrail {
    static func record(bot: String, kind: String, runtime: GatewayRuntime) {
        struct Line: Encodable { let bot: String; let kind: String }
        Task {
            _ = try? await runtime.api.raw("POST", "/api/plugins/nollie-workflow/papertrail/icloud",
                                           body: (try JSONEncoder().encode(Line(bot: bot, kind: kind)), "application/json"),
                                           authenticated: true, timeout: 8)
        }
    }
}
#endif
#endif
