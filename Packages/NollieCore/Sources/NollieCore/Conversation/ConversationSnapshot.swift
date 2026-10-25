import Foundation

/// What a `session.resume` answer says about the conversation, read leniently so an older or newer Hermes still
/// gives what it can.
public struct ConversationSnapshot: Hashable, Sendable {
    public var runtimeSession: String
    public var storedSession: String?
    public var title: String?
    public var running: Bool
    /// The prompt of the turn that runs now, and its reply so far.
    public var inflightUser: String?
    public var inflightReply: String?
    /// A prompt Hermes queued behind the running turn.
    public var queuedUser: String?
    public var openRequests: [GatewayIncomingQuestion]
    public var pendingApproval: PendingApproval?
    /// The text of the last stored user message, when the answer carried messages.
    public var lastUserText: String?

    public struct PendingApproval: Hashable, Sendable {
        public var requestId: String
        public var command: String?
        public var description: String?
        public var choices: [String]
    }

    public init(runtimeSession: String, storedSession: String? = nil, title: String? = nil, running: Bool = false,
                inflightUser: String? = nil, inflightReply: String? = nil, queuedUser: String? = nil,
                openRequests: [GatewayIncomingQuestion] = [], pendingApproval: PendingApproval? = nil,
                lastUserText: String? = nil) {
        self.runtimeSession = runtimeSession
        self.storedSession = storedSession
        self.title = title
        self.running = running
        self.inflightUser = inflightUser
        self.inflightReply = inflightReply
        self.queuedUser = queuedUser
        self.openRequests = openRequests
        self.pendingApproval = pendingApproval
        self.lastUserText = lastUserText
    }

    /// Reads a `session.resume` (or `session.create`) answer. Nil without a runtime session id.
    public init?(resume answer: GatewayJSON) {
        guard let runtime = answer["session_id"]?.stringValue, !runtime.isEmpty else { return nil }
        let info = answer["info"]
        let stored = answer["stored_session_id"]?.stringValue ?? info?["stored_session_id"]?.stringValue
        let inflight = answer["inflight"]
        var requests: [GatewayIncomingQuestion] = []
        for entry in answer["open_requests"]?.arrayValue ?? [] {
            guard let id = entry["id"]?.stringValue, let method = entry["method"]?.stringValue else { continue }
            requests.append(GatewayIncomingQuestion(id: id, method: method, params: entry["params"] ?? [:], replayed: true))
        }
        var approval: PendingApproval?
        if let pending = answer["pending_approval"], let requestId = pending["request_id"]?.stringValue, !requestId.isEmpty {
            approval = PendingApproval(requestId: requestId, command: pending["command"]?.stringValue,
                                       description: pending["description"]?.stringValue,
                                       choices: pending["choices"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        }
        let lastUser = (answer["messages"]?.arrayValue ?? []).last { $0["role"]?.stringValue == "user" }
        self.init(runtimeSession: runtime,
                  storedSession: stored.flatMap { $0.isEmpty ? nil : $0 },
                  title: info?["title"]?.stringValue,
                  running: answer["running"]?.boolValue ?? info?["running"]?.boolValue ?? false,
                  inflightUser: inflight?["user"]?.stringValue,
                  inflightReply: inflight?["assistant"]?.stringValue,
                  queuedUser: answer["queued"]?["user"]?.stringValue,
                  openRequests: requests,
                  pendingApproval: approval,
                  lastUserText: lastUser.flatMap { ConversationText.plain($0["text"] ?? $0["content"]) })
    }
}

/// Extracts text from the content shapes Hermes sends: a bare string, or an array of parts with a `text` field.
enum ConversationText {
    static func plain(_ value: GatewayJSON?) -> String? {
        switch value {
        case .string(let text): return text
        case .array(let parts):
            let pieces = parts.compactMap { part -> String? in
                if case .string(let text) = part { return text }
                guard part["type"]?.stringValue ?? "text" == "text" else { return nil }
                return part["text"]?.stringValue
            }
            return pieces.isEmpty ? nil : pieces.joined()
        default: return nil
        }
    }
}
