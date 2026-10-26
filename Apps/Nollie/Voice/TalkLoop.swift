import Foundation

/// Talk mode as a plain state machine: listen, send on a pause, wait, speak the reply, listen
/// again. It decides; `TalkMode` does (opens the mic, sends, speaks). Kept free of audio so the
/// rules can be tested, the safety rule above all: while a card is up the mic is shut and nothing
/// heard is ever sent. Approvals are answered with a tap, never by voice.
struct TalkLoop: Equatable {
    enum Phase: Equatable {
        case off
        /// The mic is open, waiting for the person to speak and then pause.
        case listening
        /// The mic is shut and the recording is being turned into words.
        case transcribing
        /// The words went; the bot is working on its reply.
        case waiting
        /// Reading the reply aloud.
        case speaking
        /// A card waits for a tap. The mic stays shut until it has gone.
        case needsYou
    }

    enum Event: Equatable {
        case start
        /// The person spoke and then paused.
        case paused
        /// What the recording said, possibly nothing.
        case heard(String)
        /// A long time with nothing said.
        case gaveUp
        /// The chat's state as read now: is a turn running, is a card up.
        case chat(running: Bool, cardsUp: Bool)
        /// The turn ended. `reply` is what to read aloud, empty for nothing.
        case turnEnded(reply: String)
        case doneSpeaking
        /// The person tapped while the reply was being read: stop and listen.
        case skip
        case failed(String)
        case stop
    }

    enum Effect: Equatable {
        case openMic
        /// Shut the mic and throw the recording away.
        case closeMic
        /// Shut the mic and turn the recording into words.
        case transcribe
        case send(String)
        case speak(String)
        case stopSpeaking
        /// Say that something on screen needs a tap. Never what the card asks, never an answer.
        case sayNeedsYou
        case show(String)
    }

    private(set) var phase: Phase = .off
    private(set) var cardsUp = false
    private(set) var running = false
    /// A reply that finished while a card was up, read once the card has gone.
    private(set) var heldReply: String?

    var isOn: Bool { phase != .off }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .start: return start()
        case .paused: return phase == .listening ? move(.transcribing, [.transcribe]) : []
        case .heard(let words): return heard(words)
        case .gaveUp: return phase == .listening ? move(.off, [.closeMic]) : []
        case .chat(let nowRunning, let nowCards): return chatChanged(running: nowRunning, cardsUp: nowCards)
        case .turnEnded(let reply): return turnEnded(reply)
        case .doneSpeaking: return phase == .speaking ? afterSpeaking() : []
        case .skip: return phase == .speaking ? [.stopSpeaking] + afterSpeaking() : []
        case .failed(let message):
            guard isOn else { return [] }
            heldReply = nil
            return move(.off, [.closeMic, .stopSpeaking, .show(message)])
        case .stop:
            guard isOn else { return [] }
            heldReply = nil
            return move(.off, [.closeMic, .stopSpeaking])
        }
    }

    private mutating func start() -> [Effect] {
        guard phase == .off else { return [] }
        if cardsUp { return move(.needsYou, [.sayNeedsYou]) }
        if running { return move(.waiting, []) }
        return move(.listening, [.openMic])
    }

    private mutating func heard(_ words: String) -> [Effect] {
        guard phase == .transcribing else { return [] }
        // A card that came up while the words were being read: they are dropped, not sent.
        if cardsUp { return move(.needsYou, []) }
        // A turn begun elsewhere meanwhile: the bot is busy, so the words are dropped too.
        if running { return move(.waiting, []) }
        guard let message = TalkRules.deliverable(words, cardsUp: cardsUp, running: running) else {
            return move(.listening, [.openMic])
        }
        // The turn is assumed to be running from here, so nothing else is heard or sent until it ends.
        running = true
        return move(.waiting, [.send(message)])
    }

    private mutating func chatChanged(running nowRunning: Bool, cardsUp nowCards: Bool) -> [Effect] {
        let cardCame = nowCards && !cardsUp
        let cardWent = !nowCards && cardsUp
        let turnCame = nowRunning && !running
        cardsUp = nowCards
        running = nowRunning
        if cardCame { return cardAppeared() }
        if cardWent, phase == .needsYou {
            if running { return move(.waiting, []) }
            return speakOrListen(heldReply)
        }
        // A turn begun somewhere else (another device, a queued message) while listening: stop
        // listening and wait for it like any other.
        if turnCame, phase == .listening { return move(.waiting, [.closeMic]) }
        return []
    }

    private mutating func cardAppeared() -> [Effect] {
        switch phase {
        case .off, .needsYou: return []
        case .listening: return move(.needsYou, [.closeMic, .sayNeedsYou])
        case .speaking: return move(.needsYou, [.stopSpeaking, .sayNeedsYou])
        case .transcribing, .waiting: return move(.needsYou, [.sayNeedsYou])
        }
    }

    private mutating func turnEnded(_ reply: String) -> [Effect] {
        running = false
        switch phase {
        case .waiting: return speakOrListen(reply)
        case .needsYou:
            // Read once the card has gone, never over it.
            heldReply = reply
            return []
        default: return []
        }
    }

    private mutating func speakOrListen(_ reply: String?) -> [Effect] {
        heldReply = nil
        let spoken = (reply ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if spoken.isEmpty { return move(.listening, [.openMic]) }
        return move(.speaking, [.speak(spoken)])
    }

    private mutating func afterSpeaking() -> [Effect] {
        if cardsUp { return move(.needsYou, [.sayNeedsYou]) }
        if running { return move(.waiting, []) }
        return move(.listening, [.openMic])
    }

    private mutating func move(_ next: Phase, _ effects: [Effect]) -> [Effect] {
        phase = next
        return effects
    }
}

/// The fixed rules for what talk mode may send. Not model judgement: plain checks.
enum TalkRules {
    /// The words to send for what was heard, or nil to send nothing. Nothing goes while a card is
    /// up or a turn is running (a "yes" then could be read as an answer to the card). Leading
    /// slashes are dropped, so speech can never become a command such as /approve.
    static func deliverable(_ heard: String, cardsUp: Bool, running: Bool) -> String? {
        guard !cardsUp, !running else { return nil }
        let words = heard
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .drop(while: { $0 == "/" || $0.isWhitespace })
        return words.isEmpty ? nil : String(words)
    }
}

/// Hears when the person has finished speaking, from the mic's loudness alone. Loudness runs
/// from 0 (quiet) to 1, read twenty times a second. The bar for speech rises with a noisy room.
struct PauseDetector {
    enum Verdict: Equatable {
        /// Nothing said yet.
        case waiting
        /// Speech has started and is still going, or the pause is not long enough yet.
        case hearing
        /// Speech, then a long enough quiet.
        case paused
        /// Nothing said for a long time.
        case gaveUp
    }

    /// The least loudness counted as speech, about -29 dB.
    var speechLevel: Float = 0.42
    /// How far over the room's own noise speech must be.
    var overNoise: Float = 0.18
    /// How long a quiet ends what was said.
    var pause: TimeInterval = 1.3
    /// How long to wait for anything at all.
    var patience: TimeInterval = 20
    /// Readings in a row that make speech, so a click or a cough on its own is not.
    var loudInARow = 3

    private let started: Date
    private var noise: Float?
    private var run = 0
    private(set) var heardSpeech = false
    private var lastLoud: Date?

    init(startedAt: Date) { started = startedAt }

    mutating func feed(_ level: Float, at now: Date) -> Verdict {
        let bar = max(speechLevel, (noise ?? 0) + overNoise)
        if level >= bar {
            run += 1
            if run >= loudInARow { heardSpeech = true }
            if heardSpeech { lastLoud = now }
        } else {
            run = 0
            // The room's level drifts slowly towards the quiet readings.
            noise = noise.map { $0 * 0.95 + level * 0.05 } ?? level
        }
        if heardSpeech {
            let quietFor = now.timeIntervalSince(lastLoud ?? now)
            return quietFor >= pause ? .paused : .hearing
        }
        return now.timeIntervalSince(started) >= patience ? .gaveUp : .waiting
    }
}

#if DEBUG
extension TalkLoop {
    /// Pictures only: a loop already in `phase`, with no mic behind it.
    init(showing phase: Phase) {
        self.phase = phase
    }
}
#endif
