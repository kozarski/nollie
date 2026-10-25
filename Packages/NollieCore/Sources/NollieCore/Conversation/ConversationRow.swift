import Foundation

/// One row of a conversation as a screen draws it.
public struct ConversationRow: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: Kind
    /// The turn it belongs to in the live tail (0 for rows from stored history).
    public var turn: Int
    /// Where Hermes stored it, once known.
    public var address: ConversationRowAddress?

    public init(id: String, kind: Kind, turn: Int = 0, address: ConversationRowAddress? = nil) {
        self.id = id
        self.kind = kind
        self.turn = turn
        self.address = address
    }

    public enum Kind: Codable, Hashable, Sendable {
        case user(text: String, delivery: ConversationDelivery)
        case assistant(ConversationReply)
        case tool(ConversationToolStep)
        case note(ConversationNote)
        case error(String)
        /// A card the workflow add-on posted (`Docs/specs/night-shift.md`). Never stored by Hermes or the cache.
        case post(ConversationPost)
    }

    public var reply: ConversationReply? {
        if case .assistant(let reply) = kind { return reply }
        return nil
    }

    public var userText: String? {
        if case .user(let text, _) = kind { return text }
        return nil
    }

    public var note: ConversationNote? {
        if case .note(let note) = kind { return note }
        return nil
    }

    public var post: ConversationPost? {
        if case .post(let post) = kind { return post }
        return nil
    }
}

/// What happened to a message the person sent.
public enum ConversationDelivery: Codable, Hashable, Sendable {
    case sending
    case sent
    /// The answer to the send was lost: Hermes may or may not have it. Never sent again on its own.
    case uncertain
    /// Hermes refused it.
    case notSent(String)
}

public struct ConversationReply: Codable, Hashable, Sendable {
    public var text: String
    public var reasoning: String
    public var streaming: Bool
    public var ending: Ending?

    public enum Ending: String, Codable, Hashable, Sendable {
        case complete, interrupted, error
    }

    public init(text: String = "", reasoning: String = "", streaming: Bool = false, ending: Ending? = nil) {
        self.text = text
        self.reasoning = reasoning
        self.streaming = streaming
        self.ending = ending
    }

    var isEmpty: Bool { text.isEmpty && reasoning.isEmpty }
}

public struct ConversationToolStep: Codable, Hashable, Sendable {
    public var toolId: String
    public var name: String
    public var context: String?
    public var argumentsText: String?
    public var done: Bool
    public var summary: String?
    public var resultText: String?
    public var seconds: Double?
    public var risk: String?

    public init(toolId: String, name: String, context: String? = nil, argumentsText: String? = nil, done: Bool = false,
                summary: String? = nil, resultText: String? = nil, seconds: Double? = nil, risk: String? = nil) {
        self.toolId = toolId
        self.name = name
        self.context = context
        self.argumentsText = argumentsText
        self.done = done
        self.summary = summary
        self.resultText = resultText
        self.seconds = seconds
        self.risk = risk
    }
}

/// Quiet rows: things that happened in the conversation that nobody typed.
public enum ConversationNote: Codable, Hashable, Sendable {
    /// Hermes summarized earlier messages to keep going. `into` is the new tip, once known.
    case summarized(into: String?)
    case interrupted
    /// The person answered a question here.
    case answered(choice: String?)
    /// A question was settled somewhere else (another device, or the turn ended).
    case answeredElsewhere
    /// Hermes stopped waiting for an answer.
    case withdrawn
    case notice(String)
}

/// A question the bot is waiting on.
public struct ConversationCard: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var method: String
    public var kind: Kind
    /// The reducer's clock when it was shown; a snapshot asked for earlier cannot take it down.
    public var shownAt: Int
    /// True for an approval known only from the snapshot's approval queue: answered with `approval.respond`.
    public var viaApprovalQueue: Bool

    public init(id: String, method: String, kind: Kind, shownAt: Int, viaApprovalQueue: Bool = false) {
        self.id = id
        self.method = method
        self.kind = kind
        self.shownAt = shownAt
        self.viaApprovalQueue = viaApprovalQueue
    }

    public enum Kind: Codable, Hashable, Sendable {
        case approval(requestId: String?, command: String?, description: String?, choices: [String])
        case clarify(questions: [Question])
        /// A typed value (a password, a code, a key).
        case value(prompt: String, secret: Bool)
    }

    public struct Question: Codable, Hashable, Sendable {
        public var id: String
        public var text: String
        public var choices: [String]
        public var multipleChoice: Bool

        public init(id: String, text: String, choices: [String] = [], multipleChoice: Bool = false) {
            self.id = id
            self.text = text
            self.choices = choices
            self.multipleChoice = multipleChoice
        }
    }

    public var approvalRequestId: String? {
        if case .approval(let requestId, _, _, _) = kind { return requestId }
        return nil
    }
}

/// The short line under the chat that says what the bot is doing. Never a row.
public enum ConversationActivity: Codable, Hashable, Sendable {
    case idle
    case sending
    case thinking
    case writing
    case runningTool(String)
    case preparingTool(String)
    case summarizing
    /// Hermes's own words.
    case status(String)
}
