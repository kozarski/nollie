import CloudKit
import Foundation
import NollieCore
import Observation

/// Away through iCloud as the screens show it, on the phone and on the Mac.
enum AwayICloudState: Equatable, Sendable {
    /// Looking at iCloud and the keys.
    case checking
    /// On, and both ends have keys: works away from home.
    case ready
    /// The person turned it off.
    case off
    /// No away keys with a Mac yet: link at home (or open Nollie at home once).
    case needsLink
    /// iCloud isn't signed in on this device, or is off for Nollie.
    case needsICloud
    /// iCloud refused the records: the schema isn't in this environment yet.
    case notAvailableYet
    /// Not on this device or edition (Mac App Store, the demo).
    case unavailable

    var canTurnOn: Bool { self == .ready || self == .off }
}

/// The phone's words for the mailbox's answers.
enum AwayWords {
    static let sent = "Sent through iCloud"
    static let received = "Your Mac has it"
    static let notDelivered = "Didn't reach your Mac. It may be asleep."
    static let asleep = "Your Mac seems to be asleep. It gets this when it wakes."

    static func refusal(_ reason: AwayRefusal) -> String {
        switch reason {
        case .slashCommand: "Slash commands work at home."
        case .privateBot: "Private helpers stay on your Mac."
        case .tooLong: "That's too long to send away from home."
        case .empty: "There was nothing to send."
        case .unknownBot, .unknownChat: "Your Mac couldn't find this chat."
        case .expired: "That ran out. Answer on your Mac."
        case .unknownCard: "Answer this on your Mac."
        case .busy, .notReady: "Your Mac isn't ready. Try again soon."
        case .notAllowed: "That works at home."
        }
    }

    static func state(_ state: AwayICloudState) -> String? {
        switch state {
        case .needsLink: "Link at home once."
        case .needsICloud: "Sign in to iCloud on both."
        case .notAvailableYet: "Not available yet."
        default: nil
        }
    }
}

#if os(iOS)
import UIKit

/// Away from home through iCloud on the phone: carries messages, approvals and Stop to the linked
/// Mac while it is out of reach, and puts what comes back into the chats. See Docs/specs/away-icloud.md.
@MainActor
@Observable
final class AwayPhone {
    static let shared = AwayPhone()
    /// Nil until the person chooses: then it follows whether it is safe (keys and iCloud).
    static let enabledKey = "away.icloud.v1"

    private(set) var state: AwayICloudState = .checking
    private(set) var courier: AwayCourier?
    @ObservationIgnored private let cloud = CloudKitAwayCloud()
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var subscribedTag: String?
    @ObservationIgnored private var polling: Task<Void, Never>?
    /// Each request's progress row in its chat, and replies for chats that aren't open yet.
    @ObservationIgnored private var noteRows: [String: (chat: String, row: String)] = [:]
    @ObservationIgnored private var waitingReplies: [String: [AwayLetter]] = [:]
    @ObservationIgnored private var lastCleanup: Date?

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// The demo copy keeps the choice for this launch only, so each picture starts from its flag.
    @ObservationIgnored private var demoChoice: Bool?
    private var chosen: Bool? { DemoMode.isOn ? demoChoice : defaults.object(forKey: Self.enabledKey) as? Bool }

    /// The switch on the page: what the person chose, or on when it is safe.
    var isOn: Bool { state == .ready }

    /// True when the phone should carry things through iCloud now: the Mac is out of reach.
    func carries(_ model: AppModel) -> Bool {
        state == .ready && courier != nil && model.linkReach == .away
    }

    // MARK: Setting up

    /// Looks at the keys, iCloud and the person's choice, and makes sure this phone hears its Mac.
    func refresh(_ runtime: GatewayRuntime?) async {
        if DemoMode.isOn {
            // The demo copy's flag, which the switch can then turn off and on.
            let flagged = DemoMode.iCloud ?? .needsLink
            state = flagged.canTurnOn ? (chosen.map { $0 ? .ready : .off } ?? flagged) : flagged
            return
        }
        guard let runtime, let channel = runtime.awayChannel else {
            courier = nil
            state = .needsLink
            return
        }
        guard chosen != false else { courier = nil; state = .off; return }
        guard await cloud.accountAvailable() else { state = .needsICloud; return }
        if courier?.channel.phoneTag != channel.phoneTag {
            let made = AwayCourier(channel: channel, cloud: cloud)
            made.onLetter = { [weak self] letter in self?.apply(letter) }
            courier = made
        }
        if subscribedTag != channel.phoneTag {
            do {
                try await cloud.subscribe(tag: channel.phoneTag, side: .phone)
                subscribedTag = channel.phoneTag
                // CloudKit's pushes need this registration; the alert one also needs notifications allowed.
                UIApplication.shared.registerForRemoteNotifications()
            } catch {
                state = AwayICloudState.from(error)
                return
            }
        }
        state = .ready
    }

    func setOn(_ on: Bool, runtime: GatewayRuntime?) async {
        if DemoMode.isOn { demoChoice = on } else { defaults.set(on, forKey: Self.enabledKey) }
        if !on, let courier {
            await cloud.forget(tag: courier.channel.phoneTag, side: .phone)
            subscribedTag = nil
            self.courier = nil
            polling?.cancel()
        }
        await refresh(runtime)
    }

    // MARK: Carrying

    /// Sends what the person wrote into the chat, through iCloud. Nil when it went; otherwise the
    /// words to put back in the composer.
    func send(_ text: String, in chat: ChatSession) async -> String? {
        guard let courier else { return text }
        let bot = chat.profileName
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let request = try await courier.send(bot: bot, chat: chat.storedID, text: trimmed)
            chat.items.append(TranscriptItem(id: "away-user-" + request, kind: .user(text: trimmed, attachments: [])))
            let row = "away-note-" + request
            chat.items.append(TranscriptItem(id: row, kind: .system(text: courier.macAsleep ? AwayWords.asleep : AwayWords.sent, symbol: "icloud")))
            noteRows[request] = (chat.storedID, row)
            look()
            return nil
        } catch .refused(let reason) {
            chat.banner = AwayWords.refusal(reason)
            return text
        } catch {
            chat.banner = "Couldn't reach iCloud. Nothing was sent."
            return text
        }
    }

    /// Answers a card from the Mac, after the same owner check the Mac would ask for.
    func answer(_ card: PendingCard, choice: String, in chat: ChatSession) async {
        guard let courier, let approval = card.approval else { return }
        if choice != "deny" {
            let bot = chat.runtime.profiles.first { $0.name == chat.profileName }?.shownName ?? chat.profileName
            guard await ApprovalOwnerCheck.check(approval, bot: bot) else { return }
        }
        do {
            try await courier.answer(card: card.id, choice: choice)
            chat.cards.removeAll { $0.id == card.id }
            chat.items.append(TranscriptItem(id: "away-answer-" + card.id, kind: .system(
                text: choice == "deny" ? "You said no" : "You said yes", symbol: "checkmark.shield")))
            look()
        } catch .refused(let reason) {
            chat.cards.removeAll { $0.id == card.id }
            chat.banner = AwayWords.refusal(reason)
        } catch {
            chat.banner = "Couldn't reach iCloud. Nothing was sent."
        }
    }

    /// Stop, through iCloud. True when it was written.
    func stop() async -> Bool {
        guard state == .ready, let courier else { return false }
        do {
            try await courier.stop()
            look()
            return true
        } catch { return false }
    }

    // MARK: Hearing back

    /// Reads what the Mac wrote: on a push, on coming to the front, and every few seconds while
    /// something waits.
    func collect() async {
        guard state == .ready, let courier else { return }
        _ = try? await courier.collect()
        if courier.macSeen == nil { await courier.checkMac() }
        // This phone's own records that ran out, once an hour.
        if lastCleanup.map({ Date().timeIntervalSince($0) > 3600 }) ?? true {
            lastCleanup = Date()
            await courier.cleanUp()
        }
        placeWaitingReplies()
        updateRows()
    }

    /// Looks every three seconds while something waits on the Mac and the app is open.
    private func look() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, let courier = self.courier else { break }
                await self.collect()
                if !courier.waiting { break }
            }
            self?.polling = nil
        }
    }

    private func chat(_ id: String) -> ChatSession? { AppModel.shared.runtime?.chatForStored(id) }

    private func apply(_ letter: AwayLetter) {
        switch letter.note {
        case .reply(_, _, let chatID, _):
            waitingReplies[chatID, default: []].append(letter)
        case .card(let id, _, _, let chatID, let approval, _):
            guard let chat = chat(chatID), !chat.cards.contains(where: { $0.id == id }) else { return }
            let request = ApprovalRequest(requestId: id, sessionId: chatID, command: approval.command, description: approval.description,
                                          choices: approval.choices, toolName: approval.toolName, patternKey: approval.patternKey)
            guard let params = try? JSONValue.encode(request) else { return }
            chat.cards.append(PendingCard(id: id, method: "approval", params: params))
        case .closed(let id, let outcome):
            for chat in AppModel.shared.runtime?.chats ?? [] where chat.cards.contains(where: { $0.id == id }) {
                chat.cards.removeAll { $0.id == id }
                if outcome == .expired { chat.banner = AwayWords.refusal(.expired) }
            }
        case .refused(let request, let reason):
            if let place = noteRows[request], let chat = chat(place.chat) {
                replaceRow(place.row, in: chat, with: .error(text: AwayWords.refusal(reason)))
                noteRows[request] = nil
            }
        default:
            break
        }
    }

    /// Replies go into their chat once it is open on this phone.
    private func placeWaitingReplies() {
        for (chatID, letters) in waitingReplies {
            guard let chat = chat(chatID) else { continue }
            for letter in letters {
                guard case .reply(let request, _, _, let text) = letter.note,
                      !chat.items.contains(where: { $0.id == "away-reply-" + letter.id }) else { continue }
                if let place = noteRows.removeValue(forKey: request) { chat.items.removeAll { $0.id == place.row } }
                chat.items.append(TranscriptItem(id: "away-reply-" + letter.id, kind: .assistant(text: text, reasoning: nil, streaming: false),
                                                 timestamp: letter.at))
            }
            waitingReplies[chatID] = nil
        }
    }

    private func updateRows() {
        guard let courier else { return }
        for (request, place) in noteRows {
            guard let chat = chat(place.chat), let state = courier.deliveries[request] else { continue }
            switch state {
            case .received: replaceRow(place.row, in: chat, with: .system(text: AwayWords.received, symbol: "checkmark.icloud"))
            case .notDelivered:
                replaceRow(place.row, in: chat, with: .error(text: AwayWords.notDelivered))
                noteRows[request] = nil
            default: break
            }
        }
    }

    private func replaceRow(_ id: String, in chat: ChatSession, with kind: TranscriptItem.Kind) {
        guard let index = chat.items.firstIndex(where: { $0.id == id }), chat.items[index].kind != kind else { return }
        chat.items[index] = TranscriptItem(id: id, kind: kind, timestamp: chat.items[index].timestamp)
    }

    /// A card on this phone that came through iCloud.
    static func isAwayCard(_ card: PendingCard) -> Bool { AwayRules.isCardID(card.id) }
}
#endif

extension AwayICloudState {
    /// CloudKit's errors, as the switch shows them. A passing network problem leaves it ready: the
    /// next look tries again.
    static func from(_ error: Error) -> AwayICloudState {
        if let failure = error as? CloudKitAwayCloud.Failure, failure == .accountUnavailable { return .needsICloud }
        guard let cloud = error as? CKError else { return .notAvailableYet }
        switch cloud.code {
        case .notAuthenticated, .accountTemporarilyUnavailable, .permissionFailure: return .needsICloud
        // The record type or its indexes aren't in this environment: deploy the schema.
        case .unknownItem, .invalidArguments, .badContainer, .missingEntitlement: return .notAvailableYet
        default: return .ready
        }
    }
}
