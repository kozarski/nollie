import Foundation
import Testing
@testable import NollieCore

/// What a phone may ask its Mac for through iCloud, how long each note is good for, and the strict
/// reading of every note.
struct AwayRulesTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let privateBots: Set<String> = ["private"]
    private func refusal(_ note: AwayNote) -> AwayRefusal? { AwayRules.refusal(for: note, isPrivate: privateBots.contains) }

    @Test func theFourThingsAPhoneMayAskFor() {
        #expect(refusal(.send(bot: "career", chat: "20261026_101500_ab12cd", text: "Find me two flights to Lisbon")) == nil)
        #expect(refusal(.send(bot: "default", chat: nil, text: "Hello 👋🏽 and thanks\n\tline two")) == nil)
        #expect(refusal(.answer(card: AwayRules.newCardID(), choice: "once")) == nil)
        #expect(refusal(.answer(card: AwayRules.newCardID(), choice: "deny")) == nil)
        #expect(refusal(.stop) == nil)
        #expect(refusal(.status) == nil)
    }

    @Test func slashCommandsAndOddTextStayOnTheMac() {
        for text in ["/model gpt", "  /reset", "\n/yolo on", "/"] {
            #expect(refusal(.send(bot: "default", chat: nil, text: text)) == .slashCommand)
        }
        #expect(refusal(.send(bot: "default", chat: nil, text: "   \n ")) == .empty)
        #expect(refusal(.send(bot: "default", chat: nil, text: String(repeating: "a", count: AwayRules.maximumText + 1))) == .tooLong)
        #expect(refusal(.send(bot: "default", chat: nil, text: String(repeating: "a", count: AwayRules.maximumText))) == nil)
        // Control characters and direction overrides could make the Mac read something else.
        for text in ["bell\u{07}", "esc\u{1B}[31m", "abc\u{202E}gnp.exe", "x\u{2066}y", "nul\u{0}"] {
            #expect(refusal(.send(bot: "default", chat: nil, text: text)) == .notAllowed)
        }
        // Emoji joiners are fine.
        #expect(refusal(.send(bot: "default", chat: nil, text: "👩‍💻")) == nil)
    }

    @Test func privateAndOddBotsAndChatsAreRefused() {
        #expect(refusal(.send(bot: "private", chat: nil, text: "hi")) == .privateBot)
        #expect(refusal(.send(bot: "Private", chat: nil, text: "hi")) == .privateBot)
        for bot in ["", "all", "ALL", "../default", "de fault", "bot/1", String(repeating: "b", count: 65), "café"] {
            #expect(refusal(.send(bot: bot, chat: nil, text: "hi")) == .unknownBot, "\(bot)")
        }
        for chat in ["", "../x", "a b", "a/b", "x%2F", String(repeating: "c", count: 256)] {
            #expect(refusal(.send(bot: "default", chat: chat, text: "hi")) == .unknownChat, "\(chat)")
        }
    }

    @Test func onlyAllowOnceAndDenyAreAnswersAway() {
        for choice in ["session", "always", "Once", "yes", ""] {
            #expect(refusal(.answer(card: AwayRules.newCardID(), choice: choice)) == .notAllowed)
        }
        #expect(refusal(.answer(card: "ac_123", choice: "once")) == .unknownCard)
        #expect(AwayRules.choices(offered: ["once", "session", "always", "deny"]) == ["once", "deny"])
        #expect(AwayRules.choices(offered: ["deny", "once"]) == ["once", "deny"])
        // Without both, the card is answered on the Mac.
        #expect(AwayRules.choices(offered: ["once", "session"]) == nil)
        #expect(AwayRules.choices(offered: ["deny"]) == nil)
    }

    @Test func aMacsNoteNeverComesFromAPhoneAndTheOtherWayRound() {
        let request = AwayHeader.newID()
        for note: AwayNote in [.received(request: request, chat: nil), .reply(request: request, bot: "default", chat: "c1", text: "x"),
                               .stopped(request: request, paused: 0), .helpers(request: nil, helpers: []),
                               .refused(request: request, reason: .busy), .closed(card: AwayRules.newCardID(), outcome: .expired)] {
            #expect(refusal(note) == .notAllowed)
            #expect(AwayRules.acceptsFromMac(note))
        }
        for note: AwayNote in [.send(bot: "default", chat: nil, text: "x"), .stop, .status, .answer(card: AwayRules.newCardID(), choice: "once")] {
            #expect(!AwayRules.acceptsFromMac(note))
        }
        // A card offering more than once and deny is never shown.
        let wide = AwayApproval(description: "Send the email", choices: ["once", "always", "deny"])
        #expect(!AwayRules.acceptsFromMac(.card(card: AwayRules.newCardID(), request: request, bot: "default", chat: "c1",
                                                 approval: wide, expiresAt: now)))
        let fair = AwayApproval(description: "Send the email", choices: ["once", "deny"])
        #expect(AwayRules.acceptsFromMac(.card(card: AwayRules.newCardID(), request: request, bot: "default", chat: "c1",
                                                approval: fair, expiresAt: now)))
    }

    @Test func eachNoteIsGoodForItsOwnTimeOnly() {
        let id = AwayHeader.newID()
        let send = AwayLetter(id: id, at: now, note: .send(bot: "default", chat: nil, text: "x"))
        #expect(AwayRules.isFresh(send, expiresAt: now.addingTimeInterval(AwayRules.sendLife), now: now.addingTimeInterval(60)))
        // Run out.
        #expect(!AwayRules.isFresh(send, expiresAt: now.addingTimeInterval(AwayRules.sendLife), now: now.addingTimeInterval(AwayRules.sendLife)))
        // A header that claims a longer life than the kind allows.
        #expect(!AwayRules.isFresh(send, expiresAt: now.addingTimeInterval(AwayRules.sendLife + 60), now: now))
        // Written in the future, past the allowed clock difference.
        let ahead = AwayLetter(id: id, at: now.addingTimeInterval(AwayRules.skew + 1), note: .stop)
        #expect(!AwayRules.isFresh(ahead, expiresAt: ahead.at.addingTimeInterval(60), now: now))
        let slightlyAhead = AwayLetter(id: id, at: now.addingTimeInterval(60), note: .stop)
        #expect(AwayRules.isFresh(slightlyAhead, expiresAt: slightlyAhead.at.addingTimeInterval(60), now: now))
        // Expiring before it was written.
        #expect(!AwayRules.isFresh(send, expiresAt: now.addingTimeInterval(-1), now: now.addingTimeInterval(-10)))
        #expect(AwayRules.life(of: .stop) == 600)
        #expect(AwayRules.life(of: .status) == 120)
        #expect(AwayRules.cardLife == 600)
    }

    @Test func lettersRoundTripAndAreReadStrictly() throws {
        let request = AwayHeader.newID()
        let card = AwayRules.newCardID()
        let notes: [AwayNote] = [
            .send(bot: "default", chat: nil, text: "Hi"), .send(bot: "career", chat: "c_1", text: "Line\nTwo"),
            .answer(card: card, choice: "once"), .stop, .status,
            .received(request: request, chat: "c_1"), .received(request: request, chat: nil),
            .reply(request: request, bot: "career", chat: "c_1", text: "Here you go"),
            .card(card: card, request: request, bot: "career", chat: "c_1",
                  approval: AwayApproval(command: "send_email", description: "Email Sam", toolName: "send", patternKey: "k", choices: ["once", "deny"]),
                  expiresAt: now.addingTimeInterval(600)),
            .card(card: card, request: request, bot: "career", chat: "c_1", approval: AwayApproval(choices: ["once", "deny"]), expiresAt: now),
            .closed(card: card, outcome: .answeredOnMac), .stopped(request: request, paused: 3),
            .helpers(request: request, helpers: [AwayHelper(bot: "career", name: "Scout", working: true, waiting: 1)]),
            .helpers(request: nil, helpers: []), .refused(request: request, reason: .privateBot),
        ]
        for note in notes {
            let letter = AwayLetter(id: AwayHeader.newID(), at: now, note: note)
            #expect(AwayLetter.decode(try letter.encoded()) == letter, "\(note.kind)")
        }
    }

    @Test func extraMissingOrWrongFieldsAreNoNoteAtAll() throws {
        let id = AwayHeader.newID()
        func read(_ object: [String: Any]) -> AwayLetter? {
            var full: [String: Any] = ["v": 1, "id": id, "at": 1_800_000_000]
            full.merge(object) { $1 }
            return AwayLetter.decode(try! JSONSerialization.data(withJSONObject: full))
        }
        #expect(read(["kind": "stop"]) != nil)
        let bad: [[String: Any]] = [
            ["kind": "stop", "extra": 1],
            ["kind": "shell", "command": "ls"],
            ["kind": "config", "key": "yolo"],
            ["kind": "send", "bot": "default"],
            ["kind": "send", "bot": "default", "text": "x", "files": ["a.pdf"]],
            ["kind": "send", "bot": "default", "text": "x", "chat": 5],
            ["kind": "send", "bot": 1, "text": "x"],
            ["kind": "answer", "card": "ac_x", "choice": "once", "always": true],
            ["kind": "stop", "v": 2],
            ["kind": "stop", "at": "yesterday"],
            ["kind": "stop", "at": 1.5],
            ["kind": "stop", "id": "aw1_short"],
            ["kind": "stopped", "request": id, "paused": true],
            ["kind": "stopped", "request": id, "paused": -1],
            ["kind": "helpers", "helpers": [["bot": "a", "name": "A", "working": 1, "waiting": 0]]],
            ["kind": "card", "card": "ac_1", "request": id, "bot": "b", "chat": "c", "until": 1, "approval": ["choices": ["once"], "run": "x"]],
            ["kind": "closed", "card": "ac_1", "outcome": "approvedForever"],
        ]
        for object in bad { #expect(read(object) == nil, "\(object)") }
        #expect(AwayLetter.decode(Data("not json".utf8)) == nil)
        #expect(AwayLetter.decode(Data(count: AwayLetter.maximumSize + 1)) == nil)
    }
}
