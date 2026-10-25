import Foundation

/// Small pieces the chat session leans on.

extension JSONValue {
    /// The string under `key`, when this is an object that has one.
    func text(_ key: String) -> String? { self[key]?.stringValue }

    /// True only when `key` is present and true.
    func flag(_ key: String) -> Bool { self[key]?.boolValue == true }
}

/// The events a chat reacts to. Anything else is logged and dropped.
enum ChatEventKind: String {
    case messageStart = "message.start"
    case messageDelta = "message.delta"
    case messageInterim = "message.interim"
    case messageComplete = "message.complete"
    case reasoningDelta = "reasoning.delta"
    case reasoningAvailable = "reasoning.available"
    case thinkingDelta = "thinking.delta"
    case toolStart = "tool.start"
    case toolGenerating = "tool.generating"
    case toolComplete = "tool.complete"
    case toolOutputRisk = "tool.output_risk"
    case sessionUsage = "session.usage"
    case sessionInfo = "session.info"
    case sessionTitle = "session.title"
    case sessionReclaimed = "session.reclaimed"
    case sessionResumeProgress = "session.resume_progress"
    case statusUpdate = "status.update"
    case error
    case notice
    case notificationShow = "notification.show"
    case notificationClear = "notification.clear"
    case requestCancel = "request.cancel"
    // Known, and of no interest to the thread.
    case reviewSummary = "review.summary"
    case todoUpdated = "todo.updated"
    case voiceStatus = "voice.status"
    case voiceTranscript = "voice.transcript"
    case reaction
    case messageReaction = "message.reaction"
    case skinChanged = "skin.changed"

    /// Events that begin a turn. Seeing one while the chat is idle means another device with this
    /// chat open sent the prompt.
    var opensTurn: Bool {
        switch self {
        case .messageStart, .reasoningDelta, .thinkingDelta, .toolStart: return true
        default: return false
        }
    }

    /// Events that show the bot doing something again.
    var movesTurn: Bool {
        switch self {
        case .messageDelta, .reasoningDelta, .thinkingDelta, .toolStart, .toolComplete: return true
        default: return false
        }
    }
}

/// The turn's clock and counters, for the speed footer under the last bubble.
struct TurnClock {
    private(set) var began: Date?
    private var tokensAtStart: Int?
    var characters = 0

    /// Starts the clock unless it already runs.
    mutating func begin(outputTokens: Int?) {
        guard began == nil else { return }
        began = Date()
        tokensAtStart = outputTokens
        characters = 0
    }

    mutating func stop() { began = nil }

    /// Stats for the turn so far; nil when it never began. With no `outputTokens` the figure
    /// is an estimate from the characters streamed (plus `extra`).
    func stats(outputTokens: Int?, extra: Int = 0) -> TurnStats? {
        guard let began else { return nil }
        return TurnStats.make(outputBefore: tokensAtStart, outputAfter: outputTokens,
                              streamedCharacters: characters + extra, seconds: Date().timeIntervalSince(began))
    }

    /// A running estimate with no usage figures.
    func estimate() -> TurnStats? {
        guard let began else { return nil }
        return TurnStats.make(outputBefore: nil, outputAfter: nil, streamedCharacters: characters,
                              seconds: Date().timeIntervalSince(began))
    }
}

/// A reply while it is still being put together and drawn.
struct LiveReply {
    var assembler = StreamAssembler()
    var rowID: String?
    /// Text already closed off into earlier bubbles this turn, since tool calls cut the stream into
    /// pieces. `message.complete` holds the full turn, so it is compared against this.
    var sealed = ""
    var flush: Task<Void, Never>?
}

/// The bookkeeping around snapshots of the session.
struct SnapshotBook {
    /// Count of snapshots whose rows are being built away from the main actor.
    var building = 0
    /// Events that came in during that time, each stamped with when it arrived.
    var held: [HeldEvent] = []
    /// How many held events predate the reply in the most recently applied snapshot. The snapshot
    /// already shows them; replaying them would repeat a tool call and double the reply.
    var heldShown = 0
    /// Cards the applied snapshot left up without listing them (see `applyCards`).
    var leftUp: Set<String> = []
    /// Ticket counter for replies, plus the newest ticket applied. One chat can have two reads in
    /// flight (a reconnect and a return to the app); if the older finishes last, it must not roll
    /// the thread back.
    var answered = 0
    var newestApplied = 0
    /// Rows that the latest snapshot, REST page or cache supplied. A row that shows up while a
    /// snapshot is being built and is not in this set was added locally.
    var fetched: Set<String> = []
}

/// Deferred work on the main actor that can be cancelled.
enum Delay {
    @MainActor
    static func run(after wait: Duration, _ work: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            try? await Task.sleep(for: wait)
            if !Task.isCancelled { work() }
        }
    }

    /// Calls `work` every `interval` for as long as `isActive` holds and the task lives.
    @MainActor
    static func repeating(every interval: Duration, while isActive: @escaping @MainActor () -> Bool,
                          _ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled || !isActive() { return }
                await work()
            }
        }
    }
}
