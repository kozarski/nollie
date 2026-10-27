import Foundation
import Observation

// The mailbox in the person's own iCloud: the Mac's desk that answers, and the phone's courier
// that asks. Storage is behind `AwayCloud`, CloudKit in the app and a fake in tests. Nothing here
// talks to Hermes: the desk hands work to the app through `AwayDeskHandler`.

/// One record as storage keeps it: the header in the clear (bound into the seal) and the box.
public struct AwayRecord: Equatable, Sendable {
    public var header: AwayHeader
    public var box: Data

    public init(header: AwayHeader, box: Data) {
        self.header = header
        self.box = box
    }
}

/// The person's private iCloud database, as the mailbox uses it.
@MainActor
public protocol AwayCloud: AnyObject {
    func post(_ record: AwayRecord) async throws
    /// Records addressed to this tag, oldest first, at most a hundred.
    func fetch(to tag: String) async throws -> [AwayRecord]
    func delete(_ ids: [String]) async throws
    /// This device's own records that ran out.
    func deleteExpired(from tag: String, before: Date) async throws
    func setPresence(tag: String, at: Date) async throws
    func presence(tag: String) async throws -> Date?
}

/// Note ids already acted on, each kept until it would have expired anyway. A record put back
/// into iCloud a second time is then ignored.
public struct AwaySeenList: Codable, Equatable, Sendable {
    public private(set) var ids: [String: Date] = [:]
    public static let maximum = 4_096

    public init() {}

    /// True the first time an id is seen.
    public mutating func insert(_ id: String, until: Date, now: Date) -> Bool {
        prune(now: now)
        guard ids[id] == nil else { return false }
        if ids.count >= Self.maximum, let oldest = ids.min(by: { $0.value < $1.value })?.key { ids[oldest] = nil }
        ids[id] = until.addingTimeInterval(AwayRules.skew)
        return true
    }

    public func contains(_ id: String) -> Bool { ids[id] != nil }

    public mutating func prune(now: Date) { ids = ids.filter { $0.value > now } }
}

/// Opens one record for a channel, or says why it can't be used. Shared by both ends.
enum AwayLetterbox {
    enum Verdict: Equatable { case letter(AwayLetter), drop }

    static func open(_ record: AwayRecord, with channel: AwayChannel, now: Date) -> Verdict {
        guard record.header.to == channel.ownTag, record.header.from == channel.otherTag,
              let plain = try? channel.open(record.box, header: record.header),
              let letter = AwayLetter.decode(plain), letter.id == record.header.id,
              letter.note.sentBy == channel.side.other,
              AwayRules.isFresh(letter, expiresAt: record.header.expiresAt, now: now) else { return .drop }
        return .letter(letter)
    }
}

// MARK: The Mac's desk

/// A card the Mac sent a phone: good once, for ten minutes, from that phone only.
public struct AwayIssuedCard: Equatable, Sendable {
    public var id: String
    public var phone: String
    public var request: String
    public var bot: String
    public var chat: String
    /// Hermes's own name for the question, so the bridge answers the right card.
    public var question: String
    public var expiresAt: Date
    public var used = false
}

/// What the Mac app does for the desk, on its own Hermes.
@MainActor
public protocol AwayDeskHandler: AnyObject {
    /// Sends the words into the chat (a new one for that bot when `chat` is nil). The chat it went
    /// to, or why not. Later notes for this request come back through `AwayDesk.reply` and `card`.
    func send(bot: String, chat: String?, text: String, request: String, phone: String) async -> Result<String, AwayRefusal>
    /// Answers the card's question with `once` or `deny`, after the phone's own owner check.
    func answer(_ card: AwayIssuedCard, choice: String) async -> AwayCardOutcome
    /// The Lock Screen Stop. Returns how many schedules were paused.
    func stop(device: String) async -> Int
    func helpers() async -> [AwayHelper]
    /// The Mac's Private list, read fresh.
    func isPrivate(_ bot: String) -> Bool
}

/// The Mac's end: reads what linked phones wrote, checks it, and hands allowed work to the app.
@MainActor
public final class AwayDesk {
    public let macTag: String
    /// The linked phones that swapped keys, by tag, with their names for Stop.
    public private(set) var phones: [String: (channel: AwayChannel, name: String)] = [:]
    public private(set) var seen: AwaySeenList
    public private(set) var cards: [String: AwayIssuedCard] = [:]
    public private(set) var lastNote: Date?
    private let cloud: any AwayCloud
    private weak var handler: (any AwayDeskHandler)?
    private let clock: () -> Date
    private let saveSeen: (AwaySeenList) -> Void
    private var lastPresence: Date?
    private var lastCleanup: Date?
    private var collecting = false

    public static let presenceEvery: TimeInterval = 5 * 60

    public init(macKey: AwayKey, cloud: any AwayCloud, handler: any AwayDeskHandler, seen: AwaySeenList = .init(),
                clock: @escaping () -> Date = Date.init, saveSeen: @escaping (AwaySeenList) -> Void = { _ in }) {
        macTag = AwayTag.of(macKey.publicKey, side: .mac)
        self.cloud = cloud
        self.handler = handler
        self.seen = seen
        self.clock = clock
        self.saveSeen = saveSeen
        self.macKey = macKey
    }

    private let macKey: AwayKey

    /// The phones the Link door knows, with the away keys they swapped. A phone not in this list
    /// is ignored from now on, and so is everything it wrote.
    public func setPhones(_ list: [(name: String, key: Data)]) {
        var next: [String: (channel: AwayChannel, name: String)] = [:]
        for entry in list {
            guard let channel = try? AwayChannel(own: macKey, side: .mac, otherPublic: entry.key) else { continue }
            next[channel.phoneTag] = (channel, entry.name)
        }
        phones = next
        cards = cards.filter { next[$0.value.phone] != nil }
    }

    /// Reads and acts on everything waiting. Returns how many notes were acted on.
    @discardableResult
    public func collect() async throws -> Int {
        guard !collecting, !phones.isEmpty else { return 0 }
        collecting = true
        defer { collecting = false }
        let records = try await cloud.fetch(to: macTag)
        var acted = 0
        var gone: [String] = []
        var work: [(AwayLetter, String)] = []
        let now = clock()
        for record in records {
            gone.append(record.header.id)
            guard let phone = phones[record.header.from],
                  case .letter(let letter) = AwayLetterbox.open(record, with: phone.channel, now: now),
                  seen.insert(letter.id, until: record.header.expiresAt, now: now) else { continue }
            work.append((letter, record.header.from))
        }
        if !work.isEmpty { saveSeen(seen) }
        // Read records go before any work, so a slow turn never leaves them to be read again.
        if !gone.isEmpty { try? await cloud.delete(gone) }
        // A Stop goes first, whatever order the records came in.
        work.sort { lhs, rhs in lhs.0.note == .stop && rhs.0.note != .stop }
        for (letter, phone) in work {
            await act(letter, from: phone)
            acted += 1
        }
        if acted > 0 { lastNote = clock() }
        await housekeeping()
        return acted
    }

    private func act(_ letter: AwayLetter, from phone: String) async {
        guard let handler else { return }
        // A refused answer (a choice the phone may not give) leaves the card up on the Mac.
        if let refusal = AwayRules.refusal(for: letter.note, isPrivate: handler.isPrivate) {
            await post(.refused(request: letter.id, reason: refusal), to: phone)
            return
        }
        switch letter.note {
        case .send(let bot, let chat, let text):
            switch await handler.send(bot: bot, chat: chat, text: text, request: letter.id, phone: phone) {
            case .success(let opened): await post(.received(request: letter.id, chat: opened), to: phone)
            case .failure(let reason): await post(.refused(request: letter.id, reason: reason), to: phone)
            }
        case .answer(let id, let choice):
            guard var card = cards[id], card.phone == phone, !card.used else {
                await post(.refused(request: letter.id, reason: .unknownCard), to: phone)
                return
            }
            guard card.expiresAt > clock() else {
                cards[id] = nil
                await post(.closed(card: id, outcome: .expired), to: phone)
                return
            }
            card.used = true
            cards[id] = card
            let outcome = await handler.answer(card, choice: choice)
            cards[id] = nil
            await post(.closed(card: id, outcome: outcome), to: phone)
        case .stop:
            let paused = await handler.stop(device: phones[phone]?.name ?? String(localized: "your iPhone", table: "Core", comment: "As in: You said yes at 14:02 on your iPhone"))
            await post(.stopped(request: letter.id, paused: paused), to: phone)
        case .status:
            await post(.helpers(request: letter.id, helpers: await handler.helpers()), to: phone)
        default:
            break
        }
    }

    // MARK: Notes the app sends

    /// The turn a phone started has ended: its reply goes to that phone.
    public func reply(request: String, bot: String, chat: String, text: String, to phone: String, alert: Bool) async {
        let bounded = text.count > AwayRules.maximumReply ? String(text.prefix(AwayRules.maximumReply - 1)) + "…" : text
        await post(.reply(request: request, bot: bot, chat: chat, text: bounded), to: phone, alert: alert)
    }

    /// An approval the phone's turn needs. Nil when it can't be answered away: the card then stays
    /// on the Mac only.
    @discardableResult
    public func card(request: String, bot: String, chat: String, question: String, approval: AwayApproval, offered: [String],
                     to phone: String) async -> String? {
        guard phones[phone] != nil, let choices = AwayRules.choices(offered: offered) else { return nil }
        let now = clock()
        cards = cards.filter { $0.value.expiresAt > now }
        let id = AwayRules.newCardID()
        let expires = now.addingTimeInterval(AwayRules.cardLife)
        cards[id] = AwayIssuedCard(id: id, phone: phone, request: request, bot: bot, chat: chat, question: question, expiresAt: expires)
        var shown = approval
        shown.choices = choices
        for key in [\AwayApproval.command, \AwayApproval.description] {
            if let words = shown[keyPath: key], words.count > AwayRules.maximumCardText {
                shown[keyPath: key] = String(words.prefix(AwayRules.maximumCardText - 1)) + "…"
            }
        }
        let sent = await post(.card(card: id, request: request, bot: bot, chat: chat, approval: shown, expiresAt: expires),
                              to: phone, alert: true, expiresAt: expires)
        if !sent { cards[id] = nil; return nil }
        return id
    }

    /// The question went on the Mac (answered there, or withdrawn): the phone's card closes.
    public func closeCards(question: String, outcome: AwayCardOutcome) async {
        for card in cards.values where card.question == question && !card.used {
            cards[card.id] = nil
            await post(.closed(card: card.id, outcome: outcome), to: card.phone)
        }
    }

    /// Cards still out, for the bridge to watch.
    public var openCards: [AwayIssuedCard] { cards.values.filter { !$0.used && $0.expiresAt > clock() } }

    @discardableResult
    private func post(_ note: AwayNote, to phone: String, alert: Bool = false, expiresAt: Date? = nil) async -> Bool {
        guard let channel = phones[phone]?.channel else { return false }
        let now = clock()
        let header = channel.header(expiresAt: expiresAt ?? now.addingTimeInterval(AwayRules.life(of: note)), alert: alert)
        let letter = AwayLetter(id: header.id, at: now, note: note)
        guard let plain = try? letter.encoded(), let box = try? channel.seal(plain, header: header) else { return false }
        do { try await cloud.post(AwayRecord(header: header, box: box)); return true } catch { return false }
    }

    /// Last seen, every five minutes; the Mac's own expired records, once an hour.
    private func housekeeping() async {
        let now = clock()
        if lastPresence.map({ now.timeIntervalSince($0) >= Self.presenceEvery }) ?? true {
            if (try? await cloud.setPresence(tag: macTag, at: now)) != nil { lastPresence = now }
        }
        if lastCleanup.map({ now.timeIntervalSince($0) >= 3600 }) ?? true {
            lastCleanup = now
            try? await cloud.deleteExpired(from: macTag, before: now)
        }
    }

    /// How long until the next look: often right after a note or while helpers work, so Stop is fast.
    public func nextLook(working: Bool) -> TimeInterval {
        if working { return 3 }
        if let lastNote, clock().timeIntervalSince(lastNote) < 120 { return 3 }
        return 30
    }
}

// MARK: The phone's courier

/// Where a message sent away stands, as the chat shows it.
public enum AwayDelivery: Equatable, Sendable {
    /// Written to iCloud; the Mac hasn't picked it up yet.
    case sent
    /// The Mac picked it up and sent it into the chat.
    case received
    case replied
    /// The Mac said no, for this reason.
    case refused(AwayRefusal)
    /// It ran out before the Mac picked it up: the Mac was asleep, off, or on another account.
    case notDelivered
}

/// A card from the Mac, on the phone.
public struct AwayCard: Equatable, Sendable, Identifiable {
    public var id: String
    public var request: String
    public var bot: String
    public var chat: String
    public var approval: AwayApproval
    public var expiresAt: Date
    /// Answered here; waiting for the Mac to say it was taken.
    public var answered: String?
}

/// The phone's end: writes requests to its Mac and reads what comes back.
@MainActor
@Observable
public final class AwayCourier {
    public let channel: AwayChannel
    public private(set) var deliveries: [String: AwayDelivery] = [:]
    /// What each request was, for the chat to place replies.
    public private(set) var requests: [String: (bot: String, chat: String?, sentAt: Date)] = [:]
    public private(set) var cards: [String: AwayCard] = [:]
    public private(set) var helpers: [AwayHelper]?
    public private(set) var lastStop: (request: String, paused: Int?)?
    /// Answers sent, by request, to the card each answered.
    @ObservationIgnored private var answers: [String: String] = [:]
    /// When the Mac last said it was up. Nil until asked.
    public private(set) var macSeen: Date?
    @ObservationIgnored private let cloud: any AwayCloud
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var seen = AwaySeenList()
    @ObservationIgnored private var collecting = false
    /// Every note from the Mac, once, after it is applied here: the app puts replies and cards in chats.
    @ObservationIgnored public var onLetter: (AwayLetter) -> Void = { _ in }

    /// The Mac's last seen older than this means asleep, off, or Nollie closed there.
    public static let asleepAfter: TimeInterval = 10 * 60

    public init(channel: AwayChannel, cloud: any AwayCloud, clock: @escaping () -> Date = Date.init) {
        precondition(channel.side == .phone)
        self.channel = channel
        self.cloud = cloud
        self.clock = clock
    }

    public enum Failure: Error, Equatable, Sendable {
        case refused(AwayRefusal)
        /// Couldn't write to iCloud. Nothing was sent; it is safe to try again.
        case notSent
    }

    /// Sends a message. It is written once: a lost answer from iCloud is never retried by itself.
    @discardableResult
    public func send(bot: String, chat: String?, text: String) async throws(Failure) -> String {
        let note = AwayNote.send(bot: bot, chat: chat, text: text)
        // The phone checks the same rules first, so the person hears at once and nothing is written.
        if let refusal = AwayRules.refusal(for: note, isPrivate: { _ in false }) { throw .refused(refusal) }
        let id = try await post(note)
        requests[id] = (bot, chat, clock())
        deliveries[id] = .sent
        return id
    }

    /// Answers a card from the Mac, after the app's own owner check said yes.
    public func answer(card id: String, choice: String) async throws(Failure) {
        guard var card = cards[id], card.answered == nil else { throw .refused(.unknownCard) }
        guard card.expiresAt > clock() else {
            cards[id] = nil
            throw .refused(.expired)
        }
        guard card.approval.choices.contains(choice) else { throw .refused(.notAllowed) }
        let request = try await post(.answer(card: id, choice: choice), expiresAt: card.expiresAt)
        answers[request] = id
        card.answered = choice
        cards[id] = card
    }

    /// Stop, written before anything else.
    @discardableResult
    public func stop() async throws(Failure) -> String {
        let id = try await post(.stop)
        lastStop = (id, nil)
        return id
    }

    @discardableResult
    public func askStatus() async throws(Failure) -> String { try await post(.status) }

    private func post(_ note: AwayNote, expiresAt: Date? = nil) async throws(Failure) -> String {
        let now = clock()
        let header = channel.header(expiresAt: expiresAt ?? now.addingTimeInterval(AwayRules.life(of: note)))
        let letter = AwayLetter(id: header.id, at: now, note: note)
        guard let plain = try? letter.encoded(), let box = try? channel.seal(plain, header: header) else { throw .notSent }
        do { try await cloud.post(AwayRecord(header: header, box: box)) } catch { throw .notSent }
        return header.id
    }

    /// Reads what the Mac wrote, applies it once, and deletes it from iCloud.
    @discardableResult
    public func collect() async throws -> [AwayLetter] {
        guard !collecting else { return [] }
        collecting = true
        defer { collecting = false }
        let records = try await cloud.fetch(to: channel.phoneTag)
        let now = clock()
        var letters: [AwayLetter] = []
        for record in records {
            guard case .letter(let letter) = AwayLetterbox.open(record, with: channel, now: now),
                  AwayRules.acceptsFromMac(letter.note),
                  seen.insert(letter.id, until: record.header.expiresAt, now: now) else { continue }
            letters.append(letter)
        }
        if !records.isEmpty { try? await cloud.delete(records.map(\.header.id)) }
        if !letters.isEmpty { macSeen = now }
        for letter in letters.sorted(by: { $0.at < $1.at }) {
            apply(letter)
            onLetter(letter)
        }
        expire()
        return letters
    }

    private func apply(_ letter: AwayLetter) {
        switch letter.note {
        case .received(let request, let chat):
            guard deliveries[request] == .sent else { return }
            deliveries[request] = .received
            if let chat, let asked = requests[request] { requests[request] = (asked.bot, chat, asked.sentAt) }
        case .reply(let request, _, _, _):
            if deliveries[request] != nil { deliveries[request] = .replied }
        case .refused(let request, let reason):
            if deliveries[request] != nil { deliveries[request] = .refused(reason) }
            // An answer the Mac couldn't take: the card is answered on the Mac now.
            if let card = answers.removeValue(forKey: request) { cards[card] = nil }
        case .card(let id, let request, let bot, let chat, let approval, let expiresAt):
            cards[id] = AwayCard(id: id, request: request, bot: bot, chat: chat, approval: approval, expiresAt: expiresAt)
        case .closed(let id, _):
            cards[id] = nil
        case .stopped(let request, let paused):
            if lastStop?.request == request { lastStop = (request, paused) }
        case .helpers(_, let list):
            helpers = list
        default:
            break
        }
    }

    /// Requests the Mac never picked up become "not delivered" once they run out, and cards that
    /// ran out go.
    public func expire() {
        let now = clock()
        for (id, state) in deliveries where state == .sent {
            if let asked = requests[id], now.timeIntervalSince(asked.sentAt) >= AwayRules.sendLife { deliveries[id] = .notDelivered }
        }
        cards = cards.filter { $0.value.expiresAt > now }
    }

    /// Asks iCloud when the Mac was last up.
    public func checkMac() async {
        if let seen = try? await cloud.presence(tag: channel.macTag) { macSeen = max(seen, macSeen ?? .distantPast) }
    }

    /// True when the Mac hasn't been seen for a while: asleep, off, or Nollie closed there.
    public var macAsleep: Bool {
        guard let macSeen else { return false }
        return clock().timeIntervalSince(macSeen) > Self.asleepAfter
    }

    /// This phone's own records that ran out, deleted.
    public func cleanUp() async { try? await cloud.deleteExpired(from: channel.phoneTag, before: clock()) }

    /// While something waits on the Mac, the phone looks every few seconds.
    public var waiting: Bool {
        deliveries.values.contains { $0 == .sent || $0 == .received } || cards.values.contains { $0.answered != nil }
            || (lastStop != nil && lastStop?.paused == nil)
    }
}
