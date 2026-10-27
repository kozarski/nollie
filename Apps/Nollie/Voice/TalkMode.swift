import AVFoundation
import Foundation
import NollieCore

/// Talk mode for one chat at a time: Nollie listens, sends when you pause, reads the reply and
/// listens again, until you end it. `TalkLoop` decides each step; this does them, on this device:
/// the recording is read by on-device speech recognition and deleted straight after.
@MainActor
@Observable
final class TalkMode {
    static let shared = TalkMode()

    /// The chat talk mode is on in.
    private(set) var chatID: String?
    private(set) var loop = TalkLoop()
    /// The mic's latest loudness readings, newest last, for the bar's level.
    private(set) var levels: [Float] = []

    @ObservationIgnored private weak var chat: ChatSession?
    @ObservationIgnored private var capture: MicCapture?
    @ObservationIgnored private var detector: PauseDetector?
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var seen: (running: Bool, cardsUp: Bool) = (false, false)
    /// True from handing the words to the chat until the gateway has taken them.
    @ObservationIgnored private var sending = false

    static let levelSamples = 24

    var phase: TalkLoop.Phase { loop.phase }

    func isOn(in chat: ChatSession) -> Bool { loop.isOn && chatID == chat.storedID }

    /// How the bot's character looks while talk mode or a reply being read is in this chat. Nil
    /// leaves it to the chat (thinking while a turn runs, needs-you with a card up). Words just sent
    /// look like thinking before the turn shows as running.
    func mood(for storedID: String, profile: String, running: Bool) -> CharacterState? {
        if loop.isOn, chatID == storedID {
            switch loop.phase {
            case .listening: return .listening
            case .transcribing: return .thinking
            case .waiting: return running ? nil : .thinking
            case .speaking: return .speaking
            case .off, .needsYou: return nil
            }
        }
        let speaking = ReplyVoice.shared.speakingFor
        return speaking == storedID || speaking == profile ? .speaking : nil
    }

    // MARK: Starting and ending

    /// Turns talk mode on in `chat`, ending it anywhere else first. The mic must already be allowed:
    /// `TalkModeButton` asks, with a line on why, before this is reached.
    func start(in chat: ChatSession) {
        if loop.isOn { stop() }
        ReplyVoice.shared.stop()
        self.chat = chat
        chatID = chat.storedID
        seen = (chat.isRunning, !chat.cards.isEmpty)
        _ = loop.handle(.chat(running: seen.running, cardsUp: seen.cardsUp))
        apply(.start)
        watch(chat)
    }

    func stop() {
        apply(.stop)
    }

    /// Ends talk mode if it is on in `chat` (the chat closed, or went to the background).
    func stop(in chat: ChatSession) {
        if chatID == chat.storedID { stop() }
    }

    /// While the reply is read: stop reading and listen.
    func skip() {
        apply(.skip)
    }

    // MARK: Doing what the loop decides

    private func apply(_ event: TalkLoop.Event) {
        for effect in loop.handle(event) { perform(effect) }
        if !loop.isOn { wrapUp() }
    }

    private func perform(_ effect: TalkLoop.Effect) {
        switch effect {
        case .openMic: openMic()
        case .closeMic: closeMic(keep: false)
        case .transcribe: transcribe()
        case .send(let words): send(words)
        case .speak(let reply): speak(reply)
        case .stopSpeaking: ReplyVoice.shared.stop()
        case .sayNeedsYou: sayNeedsYou()
        case .show(let message): chat?.banner = message
        }
    }

    private func wrapUp() {
        sending = false
        watcher?.cancel()
        watcher = nil
        closeMic(keep: false)
        levels = []
        chat = nil
        chatID = nil
    }

    // MARK: The mic

    private func openMic() {
        levels = []
        Task {
            do {
                let mic = try await MicCapture.start(stem: "talk-\(UUID().uuidString)", dictation: true, sampleRate: 24000)
                // Talk mode may have moved on while the mic was starting.
                guard loop.phase == .listening, capture == nil else {
                    mic.stop()
                    try? FileManager.default.removeItem(at: mic.file)
                    return
                }
                capture = mic
                detector = PauseDetector(startedAt: Date())
                mic.watch(every: 0.05) { mic in self.heard(level: mic.loudness) }
            } catch {
                apply(.failed(error.localizedDescription))
            }
        }
    }

    private func heard(level: Float) {
        guard loop.phase == .listening, var detector else { return }
        levels = Array((levels + [level]).suffix(Self.levelSamples))
        let verdict = detector.feed(level, at: Date())
        self.detector = detector
        switch verdict {
        case .paused: apply(.paused)
        case .gaveUp: apply(.gaveUp)
        case .waiting, .hearing: break
        }
    }

    /// Stops recording. Returns the file when it is wanted for reading, otherwise deletes it.
    @discardableResult
    private func closeMic(keep: Bool) -> URL? {
        guard let mic = capture else { return nil }
        capture = nil
        detector = nil
        mic.stop()
        if keep { return mic.file }
        try? FileManager.default.removeItem(at: mic.file)
        return nil
    }

    private func transcribe() {
        guard let file = closeMic(keep: true) else { return apply(.heard("")) }
        levels = []
        Task {
            defer { try? FileManager.default.removeItem(at: file) }
            do {
                apply(.heard(try await DeviceTranscriber.transcribe(file: file)))
            } catch {
                apply(.failed(error.localizedDescription))
            }
        }
    }

    // MARK: The chat

    private func send(_ words: String) {
        guard let chat else { return }
        // Away from home without Tailscale the app explains, and talk mode ends.
        if AppModel.shared.awayBlocks() { return stop() }
        NotificationCenter.default.post(name: .hermesMessageSent, object: chat)
        sending = true
        Task {
            _ = await chat.send(words)
            sending = false
        }
    }

    private func speak(_ reply: String) {
        guard let chatID else { return }
        Task {
            await ReplyVoice.shared.speak(reply, key: "talk", owner: chatID)
            // Stopped by Skip or End has already moved on; this only matters after a full read.
            if loop.phase == .speaking { apply(.doneSpeaking) }
        }
    }

    private func sayNeedsYou() {
        guard let chatID else { return }
        Task { await ReplyVoice.shared.speak(TalkWords.needsYou, key: "talk.card", owner: chatID) }
    }

    /// Reads the chat a few times a second while talk mode is on: a turn starting or ending and a
    /// card coming or going each become an event for the loop.
    private func watch(_ chat: ChatSession) {
        watcher?.cancel()
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, self.loop.isOn else { return }
                self.check(chat)
            }
        }
    }

    private func check(_ chat: ChatSession) {
        // Talk mode belongs to the chat on screen; leaving it ends talk mode.
        guard AppModel.shared.visibleChat === chat else { return stop() }
        let now = (running: chat.isRunning, cardsUp: !chat.cards.isEmpty)
        guard now != seen else {
            // A turn too quick to be seen running still ends: words were sent and nothing runs.
            if loop.phase == .waiting, !now.running, !sending {
                apply(.turnEnded(reply: SpokenReply.latestTurn(in: chat.items)))
            }
            return
        }
        let ended = seen.running && !now.running
        seen = now
        if ended {
            // Ended first, so a reply that finished with a card up is held until the card goes.
            apply(.turnEnded(reply: SpokenReply.latestTurn(in: chat.items)))
        }
        apply(.chat(running: now.running, cardsUp: now.cardsUp))
    }
}

#if DEBUG
extension TalkMode {
    /// `-nollie-demo-talk listening|thinking|speaking|needs` in the demo copy: talk mode drawn in
    /// that state in the chat on screen, with made-up mic levels and no mic.
    static var demoPhase: TalkLoop.Phase? {
        guard DemoMode.isOn, let at = ProcessInfo.processInfo.arguments.firstIndex(of: "-nollie-demo-talk"),
              at + 1 < ProcessInfo.processInfo.arguments.count else { return nil }
        switch ProcessInfo.processInfo.arguments[at + 1] {
        case "listening": return .listening
        case "thinking": return .waiting
        case "speaking": return .speaking
        case "needs": return .needsYou
        default: return nil
        }
    }

    func pretend(_ phase: TalkLoop.Phase, in chat: ChatSession) {
        self.chat = chat
        chatID = chat.storedID
        loop = TalkLoop(showing: phase)
        levels = phase == .listening ? (0..<Self.levelSamples).map { Float(0.25 + 0.6 * abs(sin(Double($0) * 0.7))) } : []
    }
}
#endif

/// What talk mode says and shows.
enum TalkWords {
    /// Spoken when a card comes up. It never reads the card or says what will happen.
    static let needsYou = String(localized: "This needs you. Have a look on screen.",
                                 comment: "Safety: spoken when a card waits; it never says what the card does")

    static func state(_ phase: TalkLoop.Phase) -> String {
        switch phase {
        case .off: String(localized: "Talk", comment: "Talk mode, a spoken conversation")
        case .listening: String(localized: "Listening", comment: "What talk mode is doing now")
        case .transcribing, .waiting: String(localized: "Thinking", comment: "What the bot is doing now")
        case .speaking: String(localized: "Speaking", comment: "What talk mode is doing now")
        case .needsYou: String(localized: "Tap to answer", comment: "Talk mode: a card waits for you")
        }
    }
}
