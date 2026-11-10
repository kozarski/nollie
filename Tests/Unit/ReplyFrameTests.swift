import Foundation
import Testing
@testable import NollieCore

// Hermes 0.23 can send a turn's reply frames twice (a replay, a retried attempt, a second socket). Each carries
// turn_id, and a delta its segment and UTF-16 offset; a copy must never paint beside the original.

@Suite struct ReplyFrameLedgerTests {
    @Test func aCopiedDeltaIsDroppedAndAnOverlapKeepsOnlyItsNewTail() {
        var ledger = ReplyFrameLedger()
        let r1 = ledger.start(turn: "t1")
        #expect(r1)
        let r2 = ledger.delta("Hello ", turn: "t1", segment: 0, offset: 0)
        #expect(r2 == "Hello ")
        let r3 = ledger.delta("world", turn: "t1", segment: 0, offset: 6)
        #expect(r3 == "world")
        let r4 = ledger.delta("Hello ", turn: "t1", segment: 0, offset: 0)
        #expect(r4 == nil)
        let r5 = ledger.delta("world", turn: "t1", segment: 0, offset: 6)
        #expect(r5 == nil)
        // A retried attempt re-sends the segment from the start in bigger pieces, then goes further.
        let r6 = ledger.delta("Hello world, ", turn: "t1", segment: 0, offset: 0)
        #expect(r6 == ", ")
        let r7 = ledger.delta("friend", turn: "t1", segment: 0, offset: 13)
        #expect(r7 == "friend")
        let r8 = ledger.start(turn: "t1")
        #expect(r8 == false)
    }

    @Test func offsetsCountUTF16SoEmojiNeverSplit() {
        var ledger = ReplyFrameLedger()
        let r9 = ledger.delta("Sun 🌻", turn: "t1", segment: 0, offset: 0)
        #expect(r9 == "Sun 🌻")
        // "Sun 🌻" is six UTF-16 units: 🌻 counts two.
        let r10 = ledger.delta("Sun 🌻 and 🐝", turn: "t1", segment: 0, offset: 0)
        #expect(r10 == " and 🐝")
        let r11 = ledger.delta(" and 🐝", turn: "t1", segment: 0, offset: 6)
        #expect(r11 == nil)
    }

    @Test func segmentsAreSeparateAndASealIsCountedOnce() {
        var ledger = ReplyFrameLedger()
        let r12 = ledger.delta("First.", turn: "t1", segment: 0, offset: 0)
        #expect(r12 == "First.")
        let r13 = ledger.interim(turn: "t1", segment: 0)
        #expect(r13)
        let r14 = ledger.interim(turn: "t1", segment: 0)
        #expect(r14 == false)
        let r15 = ledger.delta("First.", turn: "t1", segment: 0, offset: 0)
        #expect(r15 == nil)
        let r16 = ledger.delta("Second.", turn: "t1", segment: 1, offset: 0)
        #expect(r16 == "Second.")
    }

    @Test func aFinishedTurnTakesNoLateCopiesButTheNextTurnStreams() {
        var ledger = ReplyFrameLedger()
        _ = ledger.start(turn: "t1")
        _ = ledger.delta("Done.", turn: "t1", segment: 0, offset: 0)
        ledger.finish()
        let r17 = ledger.start(turn: "t1")
        #expect(r17 == false)
        let r18 = ledger.delta("Done.", turn: "t1", segment: 0, offset: 0)
        #expect(r18 == nil)
        let r19 = ledger.start(turn: "t2")
        #expect(r19)
        let r20 = ledger.delta("Next.", turn: "t2", segment: 0, offset: 0)
        #expect(r20 == "Next.")
    }

    @Test func unstampedFramesFromOlderHermesPassAsBefore() {
        var ledger = ReplyFrameLedger()
        let r21 = ledger.start(turn: nil)
        #expect(r21)
        let r22 = ledger.start(turn: nil)
        #expect(r22)
        let r23 = ledger.delta("a", turn: nil, segment: nil, offset: nil)
        #expect(r23 == "a")
        let r24 = ledger.delta("a", turn: nil, segment: nil, offset: nil)
        #expect(r24 == "a")
        let r25 = ledger.interim(turn: nil, segment: nil)
        #expect(r25)
    }

    @Test func aGapStillShowsWhatCame() {
        var ledger = ReplyFrameLedger()
        let r26 = ledger.delta("later part", turn: "t1", segment: 0, offset: 40)
        #expect(r26 == "later part")
        let r27 = ledger.delta("later part", turn: "t1", segment: 0, offset: 40)
        #expect(r27 == nil)
    }
}

@Suite struct ReplyFrameCoalescingTests {
    private func delta(_ text: String, offset: Int, turn: String = "t1") -> GatewayEvent {
        GatewayEvent(type: "message.delta", sessionID: "rt", payload: ["text": .string(text), "turn_id": .string(turn),
                                                                        "segment": 0, "offset": .number(Double(offset))])
    }

    @Test func runsJoinOnlyWhereOffsetsFollowOn() {
        let batch = [delta("Hel", offset: 0), delta("lo", offset: 3), delta("Hel", offset: 0), delta("lo", offset: 3), delta("!", offset: 5)]
        let joined = GatewayEvent.coalescingText(batch)
        #expect(joined.map { $0.payload["text"]?.stringValue } == ["Hello", "Hello!"])
        #expect(joined.map { $0.payload["offset"]?.intValue } == [0, 0])

        var ledger = ReplyFrameLedger()
        let shown = joined.compactMap { ledger.delta($0.payload) }.joined()
        #expect(shown == "Hello!")
    }
}

@MainActor @Suite struct ReplyFrameChatTests {
    private func feed(_ chat: ChatSession, _ type: String, _ fields: [String: JSONValue] = [:]) {
        chat.handle(event: ChatFixtures.event(for: chat, type, fields))
    }

    private func piece(_ text: String, _ offset: Int, segment: Int = 0, turn: String = "turn-a") -> [String: JSONValue] {
        ["text": .string(text), "turn_id": .string(turn), "segment": .number(Double(segment)), "offset": .number(Double(offset))]
    }

    private func replies(_ chat: ChatSession) -> [String] {
        chat.items.compactMap { if case .assistant(let text, _, _) = $0.kind { text } else { nil } }
    }

    @Test func duplicatedAndOverlappingDeltasPaintOnce() throws {
        let chat = try ChatFixtures.chat()
        feed(chat, "message.start", ["turn_id": "turn-a"])
        feed(chat, "message.delta", piece("The disk ", 0))
        feed(chat, "message.delta", piece("is 94% ", 9))
        // The same frames again (a replay), then a retry that resends the segment and finishes it.
        feed(chat, "message.start", ["turn_id": "turn-a"])
        feed(chat, "message.delta", piece("The disk ", 0))
        feed(chat, "message.delta", piece("is 94% ", 9))
        feed(chat, "message.delta", piece("The disk is 94% full.", 0))
        feed(chat, "message.complete", ["status": "complete"])
        #expect(replies(chat) == ["The disk is 94% full."])
    }

    @Test func aRepeatedInterimSealAddsNoSecondBubble() throws {
        let chat = try ChatFixtures.chat()
        feed(chat, "message.start", ["turn_id": "turn-b"])
        feed(chat, "message.interim", ["text": "Looking now.", "turn_id": "turn-b", "segment": 0])
        feed(chat, "message.interim", ["text": "Looking now.", "turn_id": "turn-b", "segment": 0])
        feed(chat, "message.delta", piece("Found it.", 0, segment: 1, turn: "turn-b"))
        feed(chat, "message.delta", piece("Found it.", 0, segment: 1, turn: "turn-b"))
        feed(chat, "message.complete", ["status": "complete"])
        #expect(replies(chat) == ["Looking now.", "Found it."])
    }

    @Test func unstampedDeltasStillAppendAsBefore() throws {
        let chat = try ChatFixtures.chat()
        feed(chat, "message.start")
        feed(chat, "message.delta", ["text": "ab"])
        feed(chat, "message.delta", ["text": "ab"])
        feed(chat, "message.complete", ["status": "complete"])
        #expect(replies(chat) == ["abab"])
    }
}

@Suite struct ReplyFrameReducerTests {
    private func event(_ type: String, seq: Int, _ payload: GatewayJSON) -> ConversationInput {
        .event(GatewayEventEnvelope(type: type, sessionId: "rt-1", seq: seq, payload: payload))
    }

    @Test func replayedFramesWithNewSeqsPaintOnce() throws {
        var state = ConversationReducer.reduce(ConversationState(lineage: ConversationLineage(tip: "s0")),
                                               .attached(ConversationSnapshot(runtimeSession: "rt-1", storedSession: "s0"),
                                                         held: [], requestedAt: 0, full: false))
        state = ConversationReducer.reduce(state, [
            event("message.start", seq: 1, ["turn_id": "t9"]),
            event("message.delta", seq: 2, ["text": "Twelve ", "turn_id": "t9", "segment": 0, "offset": 0]),
            event("message.delta", seq: 3, ["text": "rows.", "turn_id": "t9", "segment": 0, "offset": 7]),
            // A reconnect replay stamps new seqs on the same frames.
            event("message.start", seq: 4, ["turn_id": "t9"]),
            event("message.delta", seq: 5, ["text": "Twelve ", "turn_id": "t9", "segment": 0, "offset": 0]),
            event("message.delta", seq: 6, ["text": "Twelve rows. Done.", "turn_id": "t9", "segment": 0, "offset": 0]),
        ])
        let texts = state.rows.compactMap(\.reply).map(\.text)
        #expect(texts == ["Twelve rows. Done."])
    }
}
