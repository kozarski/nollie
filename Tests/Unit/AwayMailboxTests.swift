import Foundation
import Testing
@testable import NollieCore

/// The person's private iCloud database, in memory. It also lets a test do what someone with the
/// account could: put a record back, change one, or lose one.
@MainActor
final class FakeAwayCloud: AwayCloud {
    var records: [String: AwayRecord] = [:]
    var order: [String] = []
    var presences: [String: Date] = [:]
    var failPosts = false
    var posted = 0
    var deleted: [String] = []

    func post(_ record: AwayRecord) async throws {
        if failPosts { throw URLError(.notConnectedToInternet) }
        posted += 1
        records[record.header.id] = record
        order.append(record.header.id)
    }

    func fetch(to tag: String) async throws -> [AwayRecord] {
        order.compactMap { records[$0] }.filter { $0.header.to == tag }.prefix(100).map { $0 }
    }

    func delete(_ ids: [String]) async throws {
        deleted += ids
        for id in ids { records[id] = nil }
    }

    func deleteExpired(from tag: String, before: Date) async throws {
        for (id, record) in records where record.header.from == tag && record.header.expiresAt < before { records[id] = nil }
    }

    func setPresence(tag: String, at: Date) async throws { presences[tag] = at }
    func presence(tag: String) async throws -> Date? { presences[tag] }

    /// Puts a record back exactly as it was: a replay.
    func replay(_ record: AwayRecord) {
        records[record.header.id] = record
        order.append(record.header.id)
    }

    func waiting(to tag: String) -> [AwayRecord] { order.compactMap { records[$0] }.filter { $0.header.to == tag } }
}

/// The Mac app, pretending: records what it was asked to do.
@MainActor
final class FakeDeskHandler: AwayDeskHandler {
    var sends: [(bot: String, chat: String?, text: String)] = []
    var answers: [(card: String, choice: String)] = []
    var stops: [String] = []
    var sendResult: Result<String, AwayRefusal> = .success("20261026_120000_abcdef")
    var answerOutcome: AwayCardOutcome = .answered
    var privateBots: Set<String> = ["private"]

    func send(bot: String, chat: String?, text: String, request: String, phone: String) async -> Result<String, AwayRefusal> {
        sends.append((bot, chat, text))
        return sendResult
    }
    func answer(_ card: AwayIssuedCard, choice: String) async -> AwayCardOutcome {
        answers.append((card.id, choice))
        return answerOutcome
    }
    func stop(device: String) async -> Int { stops.append(device); return 2 }
    func helpers() async -> [AwayHelper] { [AwayHelper(bot: "career", name: "Scout", working: true, waiting: 0)] }
    func isPrivate(_ bot: String) -> Bool { privateBots.contains(bot.lowercased()) }
}

@MainActor
final class AwayTestClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

@MainActor
struct AwayMailboxTests {
    let cloud = FakeAwayCloud()
    let handler = FakeDeskHandler()
    let clock = AwayTestClock()
    let macKey = AwayKey()
    let phoneKey = AwayKey()
    let desk: AwayDesk
    let courier: AwayCourier

    init() throws {
        let clock = clock
        desk = AwayDesk(macKey: macKey, cloud: cloud, handler: handler, clock: { clock.now })
        desk.setPhones([(name: "Corey's iPhone", key: phoneKey.publicKey)])
        let channel = try AwayChannel(own: phoneKey, side: .phone, otherPublic: macKey.publicKey)
        courier = AwayCourier(channel: channel, cloud: cloud, clock: { clock.now })
    }

    @Test func aMessageReachesTheMacOnceAndItsReplyComesBack() async throws {
        let request = try await courier.send(bot: "career", chat: "c_1", text: "Find two flights to Lisbon")
        #expect(courier.deliveries[request] == .sent)
        #expect(try await desk.collect() == 1)
        #expect(handler.sends.count == 1)
        #expect(handler.sends.first?.text == "Find two flights to Lisbon")
        // Read records leave iCloud at once.
        #expect(cloud.waiting(to: desk.macTag).isEmpty)

        let letters = try await courier.collect()
        #expect(letters.map(\.note.kind) == ["received"])
        #expect(courier.deliveries[request] == .received)
        #expect(courier.requests[request]?.chat == "20261026_120000_abcdef")

        await desk.reply(request: request, bot: "career", chat: "c_1", text: "Two found.", to: courier.channel.phoneTag, alert: true)
        let reply = try await courier.collect()
        #expect(reply.first?.note == .reply(request: request, bot: "career", chat: "c_1", text: "Two found."))
        #expect(courier.deliveries[request] == .replied)
        #expect(cloud.waiting(to: courier.channel.phoneTag).isEmpty)
        // Collecting again finds nothing new and does nothing twice.
        #expect(try await courier.collect().isEmpty)
        #expect(try await desk.collect() == 0)
        #expect(handler.sends.count == 1)
    }

    @Test func aRecordPutBackIsIgnored() async throws {
        _ = try await courier.stop()
        let record = try #require(cloud.waiting(to: desk.macTag).first)
        #expect(try await desk.collect() == 1)
        cloud.replay(record)
        #expect(try await desk.collect() == 0)
        #expect(handler.stops == ["Corey's iPhone"])
        // And it is deleted again.
        #expect(cloud.waiting(to: desk.macTag).isEmpty)
    }

    @Test func aChangedOrForgedRecordIsDroppedUnread() async throws {
        _ = try await courier.send(bot: "default", chat: nil, text: "hi")
        var record = try #require(cloud.waiting(to: desk.macTag).first)
        record.header.expiresAt = record.header.expiresAt.addingTimeInterval(3600)
        cloud.records[record.header.id] = record
        // Someone with the account writes their own record in the Mac's mailbox.
        let stranger = try AwayChannel(own: AwayKey(), side: .phone, otherPublic: macKey.publicKey)
        let header = stranger.header(expiresAt: clock.now.addingTimeInterval(60))
        let letter = AwayLetter(id: header.id, at: clock.now, note: .stop)
        try await cloud.post(AwayRecord(header: header, box: try stranger.seal(try letter.encoded(), header: header)))
        #expect(try await desk.collect() == 0)
        #expect(handler.sends.isEmpty && handler.stops.isEmpty)
        #expect(cloud.waiting(to: desk.macTag).isEmpty)
    }

    @Test func aRemovedPhoneIsNoLongerHeard() async throws {
        _ = try await courier.stop()
        desk.setPhones([])
        #expect(try await desk.collect() == 0)
        desk.setPhones([(name: "iPad", key: AwayKey().publicKey)])
        #expect(try await desk.collect() == 0)
        #expect(handler.stops.isEmpty)
    }

    @Test func anExpiredMessageIsNeverActedOnAndThePhoneSaysSo() async throws {
        let request = try await courier.send(bot: "default", chat: nil, text: "Book it")
        // The Mac was asleep for longer than a message lives.
        clock.advance(AwayRules.sendLife + 1)
        #expect(try await desk.collect() == 0)
        #expect(handler.sends.isEmpty)
        #expect(cloud.waiting(to: desk.macTag).isEmpty)
        courier.expire()
        #expect(courier.deliveries[request] == .notDelivered)
    }

    @Test func theMacRefusesWhatThePhoneMayNotAsk() async throws {
        // Written straight into iCloud, past the phone's own checks.
        let channel = courier.channel
        func write(_ note: AwayNote) async throws -> String {
            let header = channel.header(expiresAt: clock.now.addingTimeInterval(60))
            let letter = AwayLetter(id: header.id, at: clock.now, note: note)
            try await cloud.post(AwayRecord(header: header, box: try channel.seal(try letter.encoded(), header: header)))
            return header.id
        }
        let slash = try await write(.send(bot: "default", chat: nil, text: "/yolo"))
        let secret = try await write(.send(bot: "private", chat: nil, text: "hello"))
        let reply = try await write(.reply(request: slash, bot: "default", chat: "c", text: "spoofed"))
        // The Mac's own kind of note, written by a phone, is dropped unread: it is no request at all.
        #expect(try await desk.collect() == 2)
        #expect(handler.sends.isEmpty)
        #expect(cloud.waiting(to: desk.macTag).isEmpty)
        let back = try await courier.collect()
        #expect(back.contains { $0.note == .refused(request: slash, reason: .slashCommand) })
        #expect(back.contains { $0.note == .refused(request: secret, reason: .privateBot) })
        #expect(!back.contains { if case .refused(let request, _) = $0.note { request == reply } else { false } })
        // The phone's own checks catch the same before anything is written.
        let before = cloud.posted
        await #expect(throws: AwayCourier.Failure.refused(.slashCommand)) {
            try await courier.send(bot: "default", chat: nil, text: "/reset")
        }
        #expect(cloud.posted == before)
    }

    private func issueCard() async throws -> (request: String, card: String) {
        let request = try await courier.send(bot: "career", chat: "c_1", text: "Email Sam the plan")
        try await desk.collect()
        let card = try #require(await desk.card(request: request, bot: "career", chat: "c_1", question: "q-1",
                                                approval: AwayApproval(description: "Send an email to Sam", choices: []),
                                                offered: ["once", "session", "always", "deny"], to: courier.channel.phoneTag))
        try await courier.collect()
        return (request, card)
    }

    @Test func aCardIsAnsweredOnceWithAllowOnce() async throws {
        let (_, card) = try await issueCard()
        let shown = try #require(courier.cards[card])
        #expect(shown.approval.choices == ["once", "deny"])
        #expect(shown.expiresAt == clock.now.addingTimeInterval(AwayRules.cardLife))
        // The card asks for a visible notification; the received note did not.
        try await courier.answer(card: card, choice: "once")
        await #expect(throws: AwayCourier.Failure.refused(.unknownCard)) { try await courier.answer(card: card, choice: "deny") }
        try await desk.collect()
        #expect(handler.answers.map(\.choice) == ["once"])
        try await courier.collect()
        #expect(courier.cards[card] == nil)
        // The same answer put back into iCloud does nothing.
        #expect(handler.answers.count == 1)
    }

    @Test func aCardRunsOutAfterTenMinutes() async throws {
        let (_, card) = try await issueCard()
        clock.advance(AwayRules.cardLife + 1)
        await #expect(throws: AwayCourier.Failure.refused(.expired)) { try await courier.answer(card: card, choice: "once") }

        // Even an answer written in time, read late, is refused by the Mac.
        let (_, second) = try await issueCard()
        try await courier.answer(card: second, choice: "once")
        clock.advance(AwayRules.cardLife - 1)
        // The answer's own life ends with the card's, so the Mac never acts on it.
        clock.advance(2)
        try await desk.collect()
        #expect(handler.answers.isEmpty)
    }

    @Test func onlyThePhoneTheCardWentToMayAnswerIt() async throws {
        let otherKey = AwayKey()
        desk.setPhones([(name: "iPhone", key: phoneKey.publicKey), (name: "iPad", key: otherKey.publicKey)])
        let (_, card) = try await issueCard()
        let iPad = AwayCourier(channel: try AwayChannel(own: otherKey, side: .phone, otherPublic: macKey.publicKey), cloud: cloud, clock: { [clock] in clock.now })
        // The iPad never got the card, so it can't answer through its courier...
        await #expect(throws: AwayCourier.Failure.refused(.unknownCard)) { try await iPad.answer(card: card, choice: "once") }
        // ...and a record it writes anyway is refused by the Mac.
        let channel = iPad.channel
        let header = channel.header(expiresAt: clock.now.addingTimeInterval(60))
        let letter = AwayLetter(id: header.id, at: clock.now, note: .answer(card: card, choice: "once"))
        try await cloud.post(AwayRecord(header: header, box: try channel.seal(try letter.encoded(), header: header)))
        try await desk.collect()
        #expect(handler.answers.isEmpty)
        #expect(try await iPad.collect().first?.note == .refused(request: header.id, reason: .unknownCard))
    }

    @Test func sessionAndAlwaysAreRefusedEvenWrittenByHand() async throws {
        let (_, card) = try await issueCard()
        let channel = courier.channel
        for choice in ["session", "always"] {
            let header = channel.header(expiresAt: clock.now.addingTimeInterval(60))
            let letter = AwayLetter(id: header.id, at: clock.now, note: .answer(card: card, choice: choice))
            try await cloud.post(AwayRecord(header: header, box: try channel.seal(try letter.encoded(), header: header)))
        }
        try await desk.collect()
        #expect(handler.answers.isEmpty)
        // The card is still up on the Mac for the person there.
        #expect(desk.openCards.map(\.id) == [card])
    }

    @Test func aCardThatCantBeAnsweredAwayStaysOnTheMac() async throws {
        let request = try await courier.send(bot: "career", chat: "c_1", text: "x")
        try await desk.collect()
        let card = await desk.card(request: request, bot: "career", chat: "c_1", question: "q", approval: AwayApproval(choices: []),
                                   offered: ["once", "session"], to: courier.channel.phoneTag)
        #expect(card == nil)
        try await courier.collect()
        #expect(courier.cards.isEmpty)
    }

    @Test func answeredOnTheMacClosesThePhonesCard() async throws {
        let (_, card) = try await issueCard()
        await desk.closeCards(question: "q-1", outcome: .answeredOnMac)
        let letters = try await courier.collect()
        #expect(letters.first?.note == .closed(card: card, outcome: .answeredOnMac))
        #expect(courier.cards.isEmpty)
        await #expect(throws: AwayCourier.Failure.refused(.unknownCard)) { try await courier.answer(card: card, choice: "once") }
    }

    @Test func stopIsActedOnFirstAndOnce() async throws {
        _ = try await courier.send(bot: "default", chat: nil, text: "Long task")
        let stop = try await courier.stop()
        #expect(courier.waiting)
        try await desk.collect()
        #expect(handler.stops.count == 1)
        try await courier.collect()
        #expect(courier.lastStop?.request == stop)
        #expect(courier.lastStop?.paused == 2)
        // While a helper works the Mac looks every three seconds, so Stop lands fast.
        #expect(desk.nextLook(working: true) == 3)
        clock.advance(600)
        #expect(desk.nextLook(working: false) == 30)
    }

    @Test func statusComesBack() async throws {
        try await courier.askStatus()
        try await desk.collect()
        try await courier.collect()
        #expect(courier.helpers == [AwayHelper(bot: "career", name: "Scout", working: true, waiting: 0)])
    }

    @Test func aSendIsNeverRepeatedByItself() async throws {
        cloud.failPosts = true
        await #expect(throws: AwayCourier.Failure.notSent) { try await courier.send(bot: "default", chat: nil, text: "Pay the bill") }
        cloud.failPosts = false
        #expect(courier.deliveries.isEmpty)
        try await courier.collect()
        try await desk.collect()
        #expect(handler.sends.isEmpty)
    }

    @Test func theMacSaysWhenItWasLastUp() async throws {
        try await courier.askStatus()
        try await desk.collect()
        await courier.checkMac()
        #expect(!courier.macAsleep)
        clock.advance(AwayCourier.asleepAfter + 1)
        #expect(courier.macAsleep)
    }

    @Test func eachSideCleansUpItsOwnOldRecords() async throws {
        _ = try await courier.send(bot: "default", chat: nil, text: "x")
        clock.advance(AwayRules.sendLife + 1)
        await courier.cleanUp()
        #expect(cloud.records.isEmpty)
    }
}
