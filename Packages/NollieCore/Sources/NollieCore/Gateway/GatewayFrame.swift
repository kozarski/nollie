import Foundation

/// A JSON-RPC error from Hermes, or one the client sends when it declines a question.
public struct GatewayRPCError: Error, Hashable, Sendable {
    public static let unknownMethod = -32601
    /// "No window here shows this chat": another window that does may still answer.
    public static let notShown = 4404
    public static let sessionNotFound = 4001
    public static let agentStarting = 5032

    public var code: Int
    public var message: String
    public var data: GatewayJSON?

    public init(code: Int, message: String, data: GatewayJSON? = nil) {
        (self.code, self.message, self.data) = (code, message, data)
    }
}

/// One event from Hermes: `params` of a `method: "event"` frame, or one entry of a replay answer.
public struct GatewayEventEnvelope: Sendable, Hashable {
    public var type: String
    /// Empty for events that belong to no session.
    public var sessionId: String
    /// Per-session order within one Hermes process. Present only on session events.
    public var seq: Int?
    public var payload: GatewayJSON?

    public init(type: String, sessionId: String = "", seq: Int? = nil, payload: GatewayJSON? = nil) {
        self.type = type
        self.sessionId = sessionId
        self.seq = seq
        self.payload = payload
    }

    init?(_ json: GatewayJSON) {
        guard let kind = json["type"]?.stringValue else { return nil }
        self.init(type: kind, sessionId: json["session_id"]?.stringValue ?? "", seq: json["seq"]?.intValue, payload: json["payload"])
    }

    /// The payload read as the type the contract gives this event.
    public func payload<Payload>(as kind: GatewayEventKind<Payload>) throws -> Payload {
        try (payload ?? [:]).decode(Payload.self)
    }
}

/// A question from Hermes (a server-to-client request) that waits for the client's answer.
public struct GatewayIncomingQuestion: Hashable, Sendable {
    public var id: String
    public var method: String
    public var params: GatewayJSON
    /// True when it came back in a replay's `open_requests` rather than live.
    public var replayed: Bool

    public init(id: String, method: String, params: GatewayJSON, replayed: Bool = false) {
        (self.id, self.method) = (id, method)
        (self.params, self.replayed) = (params, replayed)
    }

    /// Empty for questions about the app rather than one chat.
    public var sessionId: String { params["session_id"]?.stringValue ?? "" }

    /// The params read as the type the contract gives this question.
    public func params<Params, Answer>(as question: GatewayQuestion<Params, Answer>) throws -> Params {
        try params.decode(Params.self)
    }
}

/// One JSON-RPC message from Hermes, sorted by what the client must do with it.
enum GatewayFrame: Hashable, Sendable {
    /// The result of one of the client's calls.
    case answer(id: Int, result: GatewayJSON)
    /// An error answer. `id` is nil when Hermes could not tell which call it was about.
    case refusal(id: Int?, error: GatewayRPCError)
    case event(GatewayEventEnvelope)
    case question(GatewayIncomingQuestion)
    /// Anything else: not JSON, not JSON-RPC, or a shape this client does not use.
    case unreadable
}

// MARK: Reading

extension GatewayFrame {
    /// The frames in one WebSocket message. Hermes sends one per message, so the whole message is read first.
    /// Only if that fails is it read line by line (on line feeds alone: Hermes leaves other line separators raw
    /// inside JSON strings), skipping blank lines.
    static func read(_ text: String) -> [GatewayFrame] {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return [] }
        let whole = readOne(message)
        guard case .unreadable = whole, message.utf8.contains(0x0A) else { return [whole] }

        var frames: [GatewayFrame] = []
        // Split on the line feed byte itself: "\r\n" is a single Character, so a Character split would miss it.
        for raw in message.utf8.split(separator: 0x0A) {
            let line = String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { frames.append(readOne(line)) }
        }
        return frames
    }

    static func readOne(_ text: String) -> GatewayFrame {
        guard let parsed = try? GatewayJSON.parse(Data(text.utf8)), let members = parsed.objectValue else { return .unreadable }
        let id = members["id"]

        if let method = members["method"]?.stringValue {
            if method == "event" && id == nil {
                return members["params"].flatMap(GatewayEventEnvelope.init).map(GatewayFrame.event) ?? .unreadable
            }
            guard let asked = id?.stringValue else { return .unreadable }
            return .question(GatewayIncomingQuestion(id: asked, method: method, params: members["params"] ?? [:]))
        }

        switch (members["result"], members["error"]) {
        case (nil, let problem?):
            let error = GatewayRPCError(code: problem["code"]?.intValue ?? 0, message: problem["message"]?.stringValue ?? "", data: problem["data"])
            if id == nil || id == .null { return .refusal(id: nil, error: error) }
            return id?.intValue.map { .refusal(id: $0, error: error) } ?? .unreadable
        case (let outcome?, nil):
            guard case .integer(let number)? = id else { return .unreadable }
            return .answer(id: number, result: outcome)
        default:
            return .unreadable
        }
    }
}

// MARK: Writing

extension GatewayFrame {
    static func call(id: Int, method: String, params: GatewayJSON) -> String {
        envelope(["id": .integer(id), "method": .string(method), "params": params])
    }

    static func reply(to id: String, result: GatewayJSON) -> String {
        envelope(["id": .string(id), "result": result])
    }

    static func reply(to id: String, error: GatewayRPCError) -> String {
        var problem: [String: GatewayJSON] = ["code": .integer(error.code), "message": .string(error.message)]
        problem["data"] = error.data
        return envelope(["id": .string(id), "error": .object(problem)])
    }

    private static func envelope(_ fields: [String: GatewayJSON]) -> String {
        let all = fields.merging(["jsonrpc": "2.0"]) { mine, _ in mine }
        // Plain JSON values always encode.
        let bytes = (try? GatewayJSON.object(all).encoded()) ?? Data("{}".utf8)
        return String(decoding: bytes, as: UTF8.self)
    }
}
