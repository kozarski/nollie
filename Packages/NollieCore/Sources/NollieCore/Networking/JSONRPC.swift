import Foundation

/// A JSON-RPC error answer.
public struct RPCError: Error, Hashable, Sendable {
    public init(code: Int, message: String, data: JSONValue? = nil) {
        (self.code, self.message, self.data) = (code, message, data)
    }

    public var code: Int
    public var message: String
    public var data: JSONValue?
}

extension RPCError: LocalizedError {
    public var errorDescription: String? { message }
}

public extension RPCError {
    static let methodNotFound = -32601
}

/// Something the gateway asks of the app (an approval, a question, a vault lookup). The app
/// answers with a response carrying the same id.
public struct ServerRequest: Hashable, Sendable, Identifiable {
    public init(id: String, method: String, params: JSONValue) {
        (self.id, self.method, self.params) = (id, method, params)
    }

    public var id: String
    public var method: String
    public var params: JSONValue
}

public extension ServerRequest {
    /// The chat it is about, or empty when it is about the app as a whole.
    var sessionID: String { params["session_id"]?.stringValue ?? "" }
}

/// One `event` notification from the gateway.
public struct GatewayEvent: Hashable, Sendable {
    public init(type: String, sessionID: String, payload: JSONValue, seq: Int? = nil) {
        (self.type, self.sessionID, self.payload, self.seq) = (type, sessionID, payload, seq)
    }

    public var type: String
    public var sessionID: String
    public var payload: JSONValue
    public var seq: Int?
}

/// What one line from the gateway turns out to be.
public enum InboundFrame: Sendable {
    case unknown
    case serverRequest(ServerRequest)
    case event(GatewayEvent)
    case response(id: JSONValue, result: JSONValue?, error: RPCError?)
}

extension InboundFrame {
    public static func parse(_ text: String) -> InboundFrame {
        let decoded = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        return decoded.map { parse($0) } ?? .unknown
    }

    public static func parse(_ value: JSONValue) -> InboundFrame {
        let method = value["method"]?.stringValue
        let id = value["id"]

        if method == nil {
            guard let id, !id.isNull else { return .unknown }
            return .response(id: id, result: value["result"], error: value["error"].map(failure(from:)))
        }
        if method == "event" {
            return .event(event(from: value["params"] ?? .null))
        }
        guard let requestID = id?.stringValue else { return .unknown }
        return .serverRequest(ServerRequest(id: requestID, method: method!, params: value["params"] ?? .object([:])))
    }

    private static func failure(from body: JSONValue) -> RPCError {
        RPCError(code: body["code"]?.intValue ?? -32000,
                 message: body["message"]?.stringValue ?? "Unknown error",
                 data: body["data"])
    }

    private static func event(from params: JSONValue) -> GatewayEvent {
        let text = { (key: String) in params[key]?.stringValue ?? "" }
        return GatewayEvent(type: text("type"), sessionID: text("session_id"),
                            payload: params["payload"] ?? .null, seq: params["seq"]?.intValue)
    }
}

/// Outgoing frames, each as one line of text.
public enum RPCFrames {
    public static func request(id: Int, method: String, params: JSONValue = [:]) -> String {
        wrap(("id", .number(Double(id))), ("method", .string(method)), ("params", params))
    }

    public static func response(id: String, result: JSONValue) -> String {
        wrap(("id", .string(id)), ("result", result))
    }

    public static func errorResponse(id: String, code: Int, message: String) -> String {
        let reason: JSONValue = ["code": .number(Double(code)), "message": .string(message)]
        return wrap(("id", .string(id)), ("error", reason))
    }

    public static func encode(_ value: JSONValue) -> String {
        let writer = JSONEncoder()
        writer.outputFormatting = .withoutEscapingSlashes
        return (try? writer.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    private static func wrap(_ members: (String, JSONValue)...) -> String {
        var body: [String: JSONValue] = ["jsonrpc": "2.0"]
        for (name, member) in members { body[name] = member }
        return encode(.object(body))
    }
}
