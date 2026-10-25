import Foundation

/// One row Hermes stored, kept raw enough that offsets count the same rows Hermes counts (also ones a screen hides).
public struct ConversationHistoryRow: Codable, Hashable, Sendable {
    public var address: ConversationRowAddress
    public var role: String
    public var text: String
    public var reasoning: String?
    /// For a tool row: the tool's name and the call it answers.
    public var toolName: String?
    public var toolCallId: String?
    /// For an assistant row that called tools: their names.
    public var calledTools: [String]
    public var displayKind: String?
    public var timestamp: Double?

    public init(address: ConversationRowAddress, role: String, text: String, reasoning: String? = nil, toolName: String? = nil,
                toolCallId: String? = nil, calledTools: [String] = [], displayKind: String? = nil, timestamp: Double? = nil) {
        self.address = address
        self.role = role
        self.text = text
        self.reasoning = reasoning
        self.toolName = toolName
        self.toolCallId = toolCallId
        self.calledTools = calledTools
        self.displayKind = displayKind
        self.timestamp = timestamp
    }

    /// A row of `GET /api/sessions/{id}/messages`: the stored row as Hermes keeps it (`id`, `content` as text or
    /// parts, `tool_calls`, `tool_name`, a Unix or ISO timestamp). Nil without an id.
    public init?(stored json: GatewayJSON, segment: String) {
        guard let rowId = json["id"]?.intValue ?? json["row_id"]?.intValue else { return nil }
        let names = (json["tool_calls"]?.arrayValue ?? []).compactMap { call in
            call["function"]?["name"]?.stringValue ?? call["name"]?.stringValue
        }
        let reasoning = json["reasoning"]?.stringValue ?? json["reasoning_content"]?.stringValue
        self.init(address: ConversationRowAddress(segment: segment, rowId: rowId),
                  role: json["role"]?.stringValue ?? "assistant",
                  text: ConversationText.plain(json["display_content"]) ?? ConversationText.plain(json["content"])
                      ?? json["text"]?.stringValue ?? "",
                  reasoning: reasoning.flatMap { $0.isEmpty ? nil : $0 },
                  toolName: json["tool_name"]?.stringValue ?? json["name"]?.stringValue,
                  toolCallId: json["tool_call_id"]?.stringValue,
                  calledTools: names,
                  displayKind: json["display_kind"]?.stringValue,
                  timestamp: Self.seconds(json["timestamp"]))
    }

    private static func seconds(_ value: GatewayJSON?) -> Double? {
        if let number = value?.doubleValue { return number }
        guard let text = value?.stringValue else { return nil }
        if let date = try? Date(text, strategy: .iso8601) { return date.timeIntervalSince1970 }
        // Hermes also writes ISO times without a zone; they are UTC.
        if let date = try? Date(text + "Z", strategy: .iso8601) { return date.timeIntervalSince1970 }
        return nil
    }

    /// Whether a screen shows it. System rows, assistant rows that only called tools, and what reads as a stored
    /// summary of an earlier segment stay hidden (see the open questions in the spec).
    public var isShown: Bool {
        if let kind = displayKind?.lowercased(), kind.contains("compact") || kind.contains("summary") { return false }
        switch role {
        case "user", "tool": return true
        case "assistant": return !text.isEmpty || !(reasoning ?? "").isEmpty
        default: return false
        }
    }

    /// The row as a screen draws it, under `id` (a live row's id it replaces, or one made from its address).
    public func row(id: String? = nil) -> ConversationRow {
        let kind: ConversationRow.Kind
        switch role {
        case "user":
            kind = .user(text: text, delivery: .sent)
        case "tool":
            kind = .tool(ConversationToolStep(toolId: toolCallId ?? "", name: toolName ?? "tool", done: true, resultText: text))
        default:
            kind = .assistant(ConversationReply(text: text, reasoning: reasoning ?? "", ending: .complete))
        }
        return ConversationRow(id: id ?? "stored:\(address)", kind: kind, address: address)
    }
}

/// Some stored rows of one segment, oldest first.
public struct ConversationHistoryPage: Hashable, Sendable {
    public var rows: [ConversationHistoryRow]
    /// No rows older than these exist in the segment.
    public var reachedStart: Bool

    public init(rows: [ConversationHistoryRow], reachedStart: Bool) {
        self.rows = rows
        self.reachedStart = reachedStart
    }
}

/// Where stored rows come from when the cache does not have them.
public protocol ConversationHistorySource: Sendable {
    /// The `limit` rows of `segment` after skipping the `offset` newest, oldest first.
    func page(segment: String, offset: Int, limit: Int) async throws -> ConversationHistoryPage
}

/// Where the segment before a segment comes from.
public protocol ConversationLineageSource: Sendable {
    /// The stored session this one was compressed from; nil for the root.
    func parent(of segment: String) async throws -> String?
}

/// Chat history from Hermes's REST sessions endpoints: the `/api/sessions/{id}` record and its
/// `/messages` list. The app passes in the fetch closure, which adds base path, credentials and profile.
public struct HermesConversationHistory: ConversationHistorySource, ConversationLineageSource {
    /// Fetches a gateway path with query items and returns the body.
    public typealias Fetch = @Sendable (_ path: String, _ query: [URLQueryItem]) async throws -> Data

    private let fetch: Fetch
    private let profile: String?

    public init(profile: String?, fetch: @escaping Fetch) {
        self.profile = profile
        self.fetch = fetch
    }

    public func page(segment: String, offset: Int, limit: Int) async throws -> ConversationHistoryPage {
        var query = [URLQueryItem(name: "order", value: "latest"), URLQueryItem(name: "offset", value: String(offset)),
                     URLQueryItem(name: "limit", value: String(limit))]
        if let profile { query.append(URLQueryItem(name: "profile", value: profile)) }
        let body = try GatewayJSON.parse(try await fetch("/api/sessions/\(Self.escaped(segment))/messages", query))
        let rows = (body["messages"]?.arrayValue ?? []).compactMap { ConversationHistoryRow(stored: $0, segment: segment) }
        let sorted = Dictionary(rows.map { ($0.address.rowId, $0) }, uniquingKeysWith: { first, _ in first })
            .values.sorted { $0.address.rowId < $1.address.rowId }
        return ConversationHistoryPage(rows: sorted, reachedStart: rows.count < limit)
    }

    public func parent(of segment: String) async throws -> String? {
        let query = profile.map { [URLQueryItem(name: "profile", value: $0)] } ?? []
        let body = try GatewayJSON.parse(try await fetch("/api/sessions/\(Self.escaped(segment))", query))
        return body["parent_session_id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func escaped(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? id
    }
}
