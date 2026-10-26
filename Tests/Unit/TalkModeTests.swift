import Foundation
import NollieCore
import Testing
@testable import Nollie

/// Talk mode's decisions, without a mic: the conversation loop, and the rule that nothing heard is
/// ever sent while a card waits for the person's tap.
struct TalkLoopTests {
    /// A loop driven through `events`, with every effect it asked for in order.
    private func run(_ events: [TalkLoop.Event], from start: TalkLoop = TalkLoop()) -> (TalkLoop, [TalkLoop.Effect]) {
        var loop = start
        var effects: [TalkLoop.Effect] = []
        for event in events { effects += loop.handle(event) }
        return (loop, effects)
    }

    @Test func listensSendsOnAPauseSpeaksTheReplyAndListensAgain() {
        var loop = TalkLoop()
        #expect(loop.handle(.start) == [.openMic])
        #expect(loop.phase == .listening)
        #expect(loop.handle(.paused) == [.transcribe])
        #expect(loop.handle(.heard("  What's on   today? ")) == [.send("What's on today?")])
        #expect(loop.phase == .waiting)
        #expect(loop.handle(.chat(running: true, cardsUp: false)).isEmpty)
        #expect(loop.handle(.turnEnded(reply: "Two meetings.")) == [.speak("Two meetings.")])
        #expect(loop.phase == .speaking)
        #expect(loop.handle(.doneSpeaking) == [.openMic])
        #expect(loop.phase == .listening)
    }

    @Test func nothingHeardListensAgainAndLongSilenceEnds() {
        let (heardNothing, effects) = run([.start, .paused, .heard("   ")])
        #expect(heardNothing.phase == .listening)
        #expect(effects.last == .openMic)
        #expect(!effects.contains { if case .send = $0 { true } else { false } })

        let (quiet, ended) = run([.start, .gaveUp])
        #expect(quiet.phase == .off)
        #expect(ended.last == .closeMic)
    }

    @Test func aReplyWithNothingToSayListensAgain() {
        let (loop, effects) = run([.start, .paused, .heard("Do it"), .turnEnded(reply: "")])
        #expect(loop.phase == .listening)
        #expect(effects.last == .openMic)
    }

    @Test func endingStopsTheMicAndTheVoice() {
        let (loop, effects) = run([.start, .paused, .heard("Hi"), .turnEnded(reply: "Hello"), .stop])
        #expect(loop.phase == .off)
        #expect(effects.suffix(2) == [.closeMic, .stopSpeaking])
        // Stopping twice does nothing more.
        var again = loop
        #expect(again.handle(.stop).isEmpty)
    }

    @Test func skipStopsReadingAndListens() {
        let (loop, effects) = run([.start, .paused, .heard("Hi"), .turnEnded(reply: "A long answer"), .skip])
        #expect(loop.phase == .listening)
        #expect(effects.suffix(2) == [.stopSpeaking, .openMic])
    }

    @Test func aFailureEndsTalkModeAndSaysWhy() {
        let (loop, effects) = run([.start, .failed("Nollie can't use the microphone.")])
        #expect(loop.phase == .off)
        #expect(effects.contains(.show("Nollie can't use the microphone.")))
    }

    @Test func aTurnBegunElsewhereStopsListening() {
        let (loop, effects) = run([.start, .chat(running: true, cardsUp: false)])
        #expect(loop.phase == .waiting)
        #expect(effects.last == .closeMic)
        // Its reply is read like any other.
        var after = loop
        #expect(after.handle(.turnEnded(reply: "Done.")) == [.speak("Done.")])
    }

    @Test func wordsHeardWhileAnotherTurnStartedAreDropped() {
        let (loop, effects) = run([.start, .paused, .chat(running: true, cardsUp: false), .heard("yes")])
        #expect(loop.phase == .waiting)
        #expect(!effects.contains(.send("yes")))
    }
}

/// The safety rule: approvals are answered with a tap, never by voice.
struct NeverApproveByVoiceTests {
    private func sends(_ effects: [TalkLoop.Effect]) -> [String] {
        effects.compactMap { if case .send(let words) = $0 { words } else { nil } }
    }

    @Test func aCardShutsTheMicAndSaysOnlyThatItNeedsYou() {
        var loop = TalkLoop()
        _ = loop.handle(.start)
        let effects = loop.handle(.chat(running: false, cardsUp: true))
        #expect(effects == [.closeMic, .sayNeedsYou])
        #expect(loop.phase == .needsYou)
        // Speech that still arrives is not acted on: the mic is shut and nothing is sent.
        #expect(loop.handle(.paused).isEmpty)
        #expect(loop.handle(.heard("Yes, approve it")).isEmpty)
        #expect(loop.phase == .needsYou)
    }

    @Test func wordsBeingReadWhenACardArrivesAreDropped() {
        var loop = TalkLoop()
        _ = loop.handle(.start)
        _ = loop.handle(.paused)
        _ = loop.handle(.chat(running: true, cardsUp: true))
        let effects = loop.handle(.heard("Yes, go ahead"))
        #expect(sends(effects).isEmpty)
        #expect(loop.phase == .needsYou)
    }

    @Test func aCardDuringTheReplyStopsTheVoice() {
        var loop = TalkLoop()
        _ = loop.handle(.start)
        _ = loop.handle(.paused)
        _ = loop.handle(.heard("Send it"))
        _ = loop.handle(.chat(running: true, cardsUp: false))
        _ = loop.handle(.turnEnded(reply: "Sending now"))
        #expect(loop.handle(.chat(running: false, cardsUp: true)) == [.stopSpeaking, .sayNeedsYou])
    }

    @Test func startingWithACardUpNeverOpensTheMic() {
        var loop = TalkLoop()
        _ = loop.handle(.chat(running: true, cardsUp: true))
        let effects = loop.handle(.start)
        #expect(!effects.contains(.openMic))
        #expect(loop.phase == .needsYou)
    }

    @Test func listeningResumesOnlyAfterTheTapAndTheTurn() {
        var loop = TalkLoop()
        _ = loop.handle(.start)
        _ = loop.handle(.paused)
        _ = loop.handle(.heard("Book the table"))
        _ = loop.handle(.chat(running: true, cardsUp: false))
        _ = loop.handle(.chat(running: true, cardsUp: true))
        // The person taps the card; the turn carries on, so Nollie waits, still not listening.
        #expect(loop.handle(.chat(running: true, cardsUp: false)).isEmpty)
        #expect(loop.phase == .waiting)
        #expect(loop.handle(.turnEnded(reply: "Booked.")) == [.speak("Booked.")])
    }

    @Test func aReplyThatFinishesUnderACardWaitsForTheCard() {
        var loop = TalkLoop()
        _ = loop.handle(.start)
        _ = loop.handle(.paused)
        _ = loop.handle(.heard("Tidy my desktop"))
        _ = loop.handle(.chat(running: true, cardsUp: true))
        #expect(loop.handle(.turnEnded(reply: "Done.")).isEmpty)
        #expect(loop.handle(.chat(running: false, cardsUp: false)) == [.speak("Done.")])
    }

    @Test func spokenWordsCanNeverBeACommand() {
        #expect(TalkRules.deliverable("/approve", cardsUp: false, running: false) == "approve")
        #expect(TalkRules.deliverable(" //deny all ", cardsUp: false, running: false) == "deny all")
        #expect(TalkRules.deliverable("/", cardsUp: false, running: false) == nil)
        #expect(TalkRules.deliverable("   \n ", cardsUp: false, running: false) == nil)
    }

    @Test func nothingIsDeliverableWhileACardIsUpOrATurnRuns() {
        for words in ["yes", "approve", "Yes, do it", "always"] {
            #expect(TalkRules.deliverable(words, cardsUp: true, running: false) == nil)
            #expect(TalkRules.deliverable(words, cardsUp: false, running: true) == nil)
        }
        #expect(TalkRules.deliverable("yes", cardsUp: false, running: false) == "yes")
    }

    /// Thousands of random event orders: whenever a card is up after an event, that event neither
    /// opened the mic nor sent anything.
    @Test func noOrderOfEventsSendsOrListensWhileACardIsUp() {
        var random = SeededRandom(seed: 0x5EED)
        let words = ["yes", "approve", "/approve", "do it", "", "always allow"]
        for _ in 0..<4000 {
            var loop = TalkLoop()
            for _ in 0..<12 {
                let event: TalkLoop.Event
                switch random.next() % 10 {
                case 0: event = .start
                case 1: event = .paused
                case 2: event = .heard(words[Int(random.next() % UInt64(words.count))])
                case 3: event = .gaveUp
                case 4: event = .chat(running: random.next() % 2 == 0, cardsUp: random.next() % 2 == 0)
                case 5: event = .turnEnded(reply: random.next() % 2 == 0 ? "" : "Reply")
                case 6: event = .doneSpeaking
                case 7: event = .skip
                case 8: event = .stop
                default: event = .chat(running: false, cardsUp: random.next() % 3 == 0)
                }
                let effects = loop.handle(event)
                if loop.cardsUp {
                    #expect(!effects.contains(.openMic), "opened the mic with a card up after \(event)")
                    #expect(sends(effects).isEmpty, "sent words with a card up after \(event)")
                }
                if loop.phase == .needsYou { #expect(loop.cardsUp) }
            }
        }
    }
}

/// A small repeatable random source, so a failure can be replayed.
private struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state >> 33
    }
}

struct PauseDetectorTests {
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    private func feed(_ detector: inout PauseDetector, _ level: Float, for seconds: Double, from t: inout Double) -> PauseDetector.Verdict {
        var verdict = PauseDetector.Verdict.waiting
        let end = t + seconds
        while t < end {
            verdict = detector.feed(level, at: start.addingTimeInterval(t))
            t += 0.05
        }
        return verdict
    }

    @Test func speechThenAPauseEndsWhatWasSaid() {
        var detector = PauseDetector(startedAt: start)
        var t = 0.0
        #expect(feed(&detector, 0.1, for: 1, from: &t) == .waiting)
        #expect(feed(&detector, 0.7, for: 2, from: &t) == .hearing)
        #expect(feed(&detector, 0.1, for: 0.8, from: &t) == .hearing)
        #expect(feed(&detector, 0.1, for: 0.6, from: &t) == .paused)
    }

    @Test func aClickIsNotSpeech() {
        var detector = PauseDetector(startedAt: start)
        var t = 0.0
        _ = feed(&detector, 0.1, for: 1, from: &t)
        _ = feed(&detector, 0.9, for: 0.06, from: &t)
        #expect(feed(&detector, 0.1, for: 3, from: &t) == .waiting)
        #expect(!detector.heardSpeech)
    }

    @Test func nothingSaidForLongEnoughGivesUp() {
        var detector = PauseDetector(startedAt: start)
        var t = 0.0
        #expect(feed(&detector, 0.2, for: 19, from: &t) == .waiting)
        #expect(feed(&detector, 0.2, for: 1.2, from: &t) == .gaveUp)
    }

    @Test func aNoisyRoomNeedsLouderSpeech() {
        var detector = PauseDetector(startedAt: start)
        var t = 0.0
        // A steady hum just under the usual bar raises it.
        _ = feed(&detector, 0.4, for: 3, from: &t)
        #expect(feed(&detector, 0.5, for: 1, from: &t) == .waiting)
        #expect(feed(&detector, 0.75, for: 1, from: &t) == .hearing)
    }
}

struct SpokenReplyTests {
    @Test func markdownReadsAsPlainWords() {
        let reply = """
        ## Your day
        - **Dentist** at 9
        - Lunch with [Sam](https://example.com/sam)
        > Bring the *forms*.
        ---
        More at https://www.bbc.co.uk/news 🎉
        """
        let spoken = SpokenReply.plain(reply)
        #expect(spoken == """
        Your day
        Dentist at 9
        Lunch with Sam
        Bring the forms.

        More at bbc.co.uk
        """)
    }

    @Test func codeAndTablesStayOnScreen() {
        let reply = """
        Here it is:
        ```swift
        let x = 1
        ```
        | Day | Time |
        | --- | --- |
        | Mon | 9 |
        That's all.
        """
        #expect(SpokenReply.plain(reply) == """
        Here it is:
        \(SpokenReply.codeOnScreen)
        \(SpokenReply.tableOnScreen)
        That's all.
        """)
    }

    @Test func theLatestTurnIsTheBotsWordsAfterYourLastMessage() {
        let items = [
            TranscriptItem(id: "1", kind: .user(text: "Hi", attachments: [])),
            TranscriptItem(id: "2", kind: .assistant(text: "Old reply", reasoning: nil, streaming: false)),
            TranscriptItem(id: "3", kind: .user(text: "Weather?", attachments: [])),
            TranscriptItem(id: "4", kind: .tool(ToolActivity(id: "t", name: "web_search", status: .done))),
            TranscriptItem(id: "5", kind: .assistant(text: "Sunny, **22°C**.", reasoning: nil, streaming: false)),
        ]
        #expect(SpokenReply.latestTurn(in: items) == "Sunny, 22°C.")
    }

    @Test func aCutShortTurnHasNothingToRead() {
        let items = [
            TranscriptItem(id: "1", kind: .user(text: "Go", attachments: [])),
            TranscriptItem(id: "2", kind: .assistant(text: "Operation interrupted.", reasoning: nil, streaming: false)),
        ]
        #expect(SpokenReply.latestTurn(in: items).isEmpty)
    }
}
