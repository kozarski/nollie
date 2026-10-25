import Foundation

/// One tool call in the thread: what the bot ran, how it went, what came back.
public struct ToolActivity: Hashable, Sendable, Identifiable {
    public enum Status: Hashable, Sendable {
        case running
        case done
        case failed
    }

    public var name: String
    public var id: String
    public var status: Status = .running

    public init(id: String, name: String, context: String? = .none, argsText: String? = .none, status: Status = Status.running,
                summary: String? = .none, resultText: String? = .none, durationSeconds: Double? = .none, risk: String? = .none) {
        let carried = BotDelivery.parse(name: name, context: context, argsText: argsText)
        self.delivery = carried
        self.id = id
        self.name = name
        self.status = status
        self.context = context
        self.argsText = argsText
        self.risk = risk
        self.summary = summary
        self.resultText = resultText
        self.durationSeconds = durationSeconds
    }

    public var summary: String?
    public var durationSeconds: Double?
    public var risk: String?
    public var resultText: String?
    /// The preview of what was run, as the gateway cut it.
    public var context: String?
    public var argsText: String?
    /// Present when the call was a message to another bot, letting the row say "Messaged X" rather
    /// than print a terminal transcript.
    public var delivery: BotDelivery?

    public var displayName: String { name.split(separator: "_", omittingEmptySubsequences: false).joined(separator: " ") }

    /// What the other bot answered, if a quiet run brought something back. The terminal may have
    /// wrapped the answer as `{"output": ...}`, added session bookkeeping lines, or let the other
    /// bot echo a "Message from X:" lead-in; none of that is the answer.
    public var deliveryReply: String? {
        guard delivery != nil, let result = resultText?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty else { return nil }
        let unwrapped = Self.unwrapOutput(result)
        let lines = unwrapped.components(separatedBy: "\n").filter { !$0.drop(while: \.isWhitespace).hasPrefix("session_id:") }
        let answer = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if answer.isEmpty { return nil }
        return AgentMessage.parse(answer)?.body ?? answer
    }

    /// The terminal may wrap a result as `{"output": "..."}`.
    private static func unwrapOutput(_ text: String) -> String {
        guard text.hasPrefix("{"), let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return text }
        return (object["output"] as? String) ?? text
    }
}

/// A file or picture attached to a message, on this device and/or on the gateway.
public struct AttachmentPreview: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable { case image, pdf, audio, video, file }

    public var kind: Kind
    public var id: String
    public var byteCount: Int?
    public var localURL: URL?

    public init(id: String, name: String, serverPath: String? = .none, kind: Kind, localURL: URL? = .none, byteCount: Int? = .none) {
        self.kind = kind
        self.name = name
        self.id = id
        self.serverPath = serverPath
        self.localURL = localURL
        self.byteCount = byteCount
    }

    public var name: String
    public var serverPath: String?
}

/// One row of a conversation.
public struct TranscriptItem: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        case assistant(text: String, reasoning: String?, streaming: Bool)
        case user(text: String, attachments: [AttachmentPreview])
        case system(text: String, symbol: String)
        case tool(ToolActivity)
        case subagent(SubagentActivity)
        case error(text: String)
        /// A nudge sent into a turn that is running: the person's own words, shown greyed.
        case steer(text: String, status: String)
    }

    public var kind: Kind
    public var id: String
    /// Added when a turn completes, on its last assistant bubble.
    public var stats: TurnStats?
    public var rowID: Int?

    public init(id: String, kind: Kind, timestamp: Date = .now, rowID: Int? = .none, stats: TurnStats? = .none,
                finishReason: String? = .none, displayKind: String? = .none, controlMarker: String? = .none,
                notificationCategory: String? = .none) {
        self.kind = kind
        self.id = id
        self.stats = stats
        self.rowID = rowID
        self.timestamp = timestamp
        self.finishReason = finishReason
        self.displayKind = displayKind
        self.controlMarker = controlMarker
        self.notificationCategory = notificationCategory
    }

    public var timestamp: Date = .now
    public var controlMarker: String?
    public var displayKind: String?
    public var notificationCategory: String?
    /// An interrupted or failed reply is never taken for a silence marker, so this is kept.
    public var finishReason: String?
}

// MARK: Building rows from stored messages

extension TranscriptItem {
    /// Turns a full stored history into rows.
    ///
    /// Looking at the history as one list instead of message by message lets an empty assistant row be
    /// judged with its neighbours. If a model put its entire answer into its reasoning, that text is
    /// shown as the reply; thinking ahead of a tool call, or in a turn that is still going, stays hidden.
    /// `running` means the chat's turn is still in progress. `settled` holds (normalised) replies this
    /// device has already displayed as finished, so a turn begun elsewhere a moment later cannot drag
    /// the earlier answer back out.
    public static func fromHistory(_ messages: [TranscriptMessage], running: Bool = false, settled: Set<String> = .init()) -> [TranscriptItem] {
        let lastPosition = messages.count - 1
        return messages.enumerated().compactMap { position, message in
            if let own = fromHistory(message, index: position) { return own }
            guard isEmptyAssistant(message) else { return nil }
            let after = messages.dropFirst(position + 1).first { $0.displayKind != "hidden" }
            guard let answer = promotedAnswer(message, next: after, isLast: position == lastPosition,
                                              running: running, settled: settled) else { return nil }
            return TranscriptItem(id: historyID(message, position),
                                  kind: .assistant(text: answer, reasoning: distinctThinking(message, from: answer), streaming: false),
                                  timestamp: stamp(of: message), rowID: message.rowId)
        }
    }

    /// A message's reasoning, unless it only repeats the words shown as the reply.
    private static func distinctThinking(_ message: TranscriptMessage, from reply: String) -> String? {
        guard let thoughts = message.reasoning else { return nil }
        return StreamAssembler.normalized(thoughts) == StreamAssembler.normalized(reply) ? nil : thoughts
    }

    /// The same messages with each promoted answer written into its message's text, for readers
    /// of messages (summaries, previews) that would otherwise skip such a reply as empty.
    public static func withPromotedAnswers(_ messages: [TranscriptMessage], running: Bool = false) -> [TranscriptMessage] {
        var result = messages
        let lastPosition = messages.count - 1
        for position in messages.indices where isEmptyAssistant(messages[position]) {
            let after = messages.dropFirst(position + 1).first { $0.displayKind != "hidden" }
            let found = promotedAnswer(messages[position], next: after, isLast: position == lastPosition, running: running)
            if let found { result[position].text = found }
        }
        return result
    }

    /// Assistant row that is visible yet carries no text of its own, the place a promoted answer can be hiding.
    static func isEmptyAssistant(_ m: TranscriptMessage) -> Bool {
        guard m.role == "assistant", m.displayKind != "hidden" else { return false }
        return (m.text ?? "").allSatisfy(\.isWhitespace)
    }

    /// Decides what an empty assistant row means: the gateway's `api_content` when present, else the
    /// reasoning, provided nothing hints it was only thinking. That needs no tool calls and a clean
    /// stop, then either the person replying or a finished chat ending there.
    static func promotedAnswer(_ m: TranscriptMessage, next: TranscriptMessage? = nil, isLast: Bool, running: Bool = false, settled: Set<String> = .init()) -> String? {
        // Only a clean stop counts as an answer. When the gateway nudged a stalled reply along, the
        // partial text sits in api_content and does not qualify.
        if let reason = m.finishReason, reason != "stop" { return nil }
        if let content = m.apiContent, !content.allSatisfy(\.isWhitespace) { return content }
        guard !m.hasToolCalls, let thoughts = m.reasoning, thoughts.contains(where: { !$0.isWhitespace }) else { return nil }
        if let next { return next.role == "user" ? thoughts : nil }
        if !isLast { return nil }
        let alreadyShown = settled.contains(StreamAssembler.normalized(thoughts))
        return (running && !alreadyShown) ? nil : thoughts
    }

    /// One stored message as a row; nil for the ones that show nothing.
    public static func fromHistory(_ m: TranscriptMessage, index: Int) -> TranscriptItem? {
        let id = historyID(m, index)
        let time = stamp(of: m)
        let text = m.text ?? ""

        if m.displayKind == "hidden" {
            // Hidden rows stay hidden unless they are the bot's own silence marker.
            let isMarker = m.role == "assistant" && (AutomatedReply.isControlMarker(m.text) || m.controlMarker == "intentional_silence")
            if !isMarker { return nil }
        }

        switch m.role {
        case "user":
            return TranscriptItem(id: id, kind: .user(text: text, attachments: []), timestamp: time, rowID: m.rowId,
                                  displayKind: m.displayKind, controlMarker: m.controlMarker, notificationCategory: m.notificationCategory)
        case "assistant":
            if text.isEmpty { return nil }
            return TranscriptItem(id: id, kind: .assistant(text: text, reasoning: distinctThinking(m, from: text), streaming: false),
                                  timestamp: time, rowID: m.rowId,
                                  finishReason: m.finishReason, displayKind: m.displayKind, controlMarker: m.controlMarker,
                                  notificationCategory: m.notificationCategory)
        case "tool", "tool_call":
            var call = ToolActivity(id: id, name: m.name ?? "tool", context: m.context, argsText: m.argsText,
                                    status: m.finishReason == "error" ? .failed : .done)
            call.resultText = m.text
            return TranscriptItem(id: id, kind: .tool(call), timestamp: time, rowID: m.rowId)
        case "system":
            return text.isEmpty ? nil : TranscriptItem(id: id, kind: .system(text: text, symbol: "info.circle"), timestamp: time, rowID: m.rowId)
        case "error":
            return text.isEmpty ? nil : TranscriptItem(id: id, kind: .error(text: text), timestamp: time, rowID: m.rowId)
        default:
            return text.isEmpty ? nil : TranscriptItem(id: id, kind: .assistant(text: text, reasoning: nil, streaming: false), timestamp: time, rowID: m.rowId)
        }
    }

    private static func historyID(_ m: TranscriptMessage, _ position: Int) -> String {
        "h-\(m.rowId ?? position)-\(position)"
    }

    private static func stamp(of m: TranscriptMessage) -> Date {
        guard let seconds = m.timestamp else { return .now }
        return Date(timeIntervalSince1970: seconds)
    }
}
