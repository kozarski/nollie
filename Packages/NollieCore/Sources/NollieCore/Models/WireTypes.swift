import Foundation

// How the gateway's answers look to the app, for the parts about a conversation: what a model
// used, what a chat is, and what was said in it. Fields the gateway may leave out are optional.
// The requests it makes of us live in WireRequests.swift, accounts and models in WireAccount.swift
// and settings and tooling in WireSettings.swift.

// MARK: Usage

/// Token counts, context fill and cost for a chat.
public struct Usage: Codable, Hashable, Sendable {
    public var contextEstimated: Bool? = nil
    public var input: Int? = nil
    public var output: Int? = nil
    public var reasoning: Int? = nil
    public var total: Int? = nil
    public var calls: Int? = nil
    public var compressions: Int? = nil
    public var contextUsed: Int? = nil
    public var contextMax: Int? = nil
    public var contextPercent: Int? = nil
    public var cacheHitPct: Int? = nil
    public var activeSubagents: Int? = nil
    public var avgTps: Double? = nil
    public var costUsd: Double? = nil
    public var model: String? = nil
    public var costStatus: String? = nil
}

public extension Usage {
    /// How full the context is, in whole percent: the gateway's number when it sent one,
    /// otherwise what is used over the window. Nil when the window isn't known.
    var computedContextPercent: Int? {
        guard let window = contextMax, window > 0 else { return nil }
        if let stated = contextPercent { return stated }
        let used = contextUsed ?? total ?? 0
        return Int(Double(used) / Double(window) * 100)
    }
}

/// What the gateway knows about a live chat right now.
public struct SessionLiveInfo: Codable, Hashable, Sendable {
    public var fast: Bool? = nil
    public var yolo: Bool? = nil
    public var running: Bool? = nil
    public var lazy: Bool? = nil
    public var model: String? = nil
    public var provider: String? = nil
    public var reasoningEffort: String? = nil
    public var serviceTier: String? = nil
    public var approvalMode: String? = nil
    public var cwd: String? = nil
    public var branch: String? = nil
    public var title: String? = nil
    public var storedSessionId: String? = nil
    public var version: String? = nil
    public var profileName: String? = nil
    public var credentialWarning: String? = nil
    public var usage: Usage? = nil
}

// MARK: Messages

/// One message in a chat's history.
///
/// Two wire shapes reach this type. The socket call `session.resume` delivers flattened rows with a
/// `text` field. The REST page `/api/sessions/{id}/messages` hands back the stored row unchanged:
/// `content` may hold plain text or parts, the identifier is called `id` instead of `row_id`, the
/// timestamp is ISO, and the tool name is tucked into `tool_calls`. Quick open reads that page.
public struct TranscriptMessage: Codable, Hashable, Sendable {
    /// The row asked for tools, so any reasoning on it is thinking before the call, not an answer.
    public var hasToolCalls: Bool
    public var rowId: Int? = nil
    public var timestamp: Double? = nil
    public var role: String
    public var text: String? = nil
    public var displayKind: String? = nil
    public var controlMarker: String? = nil
    public var notificationCategory: String? = nil
    public var name: String? = nil
    public var context: String? = nil
    /// The whole arguments of a tool call; `context` is only the short preview.
    public var argsText: String? = nil
    public var reasoning: String? = nil
    /// What the gateway passed back from the model's API, kept for rows whose stored content is blank.
    /// A model that wrote its entire answer as reasoning gets that text promoted to the reply.
    public var apiContent: String? = nil
    /// "stop", "length", "tool_calls" and so on. Nil when the page doesn't carry it, as with
    /// `session.resume`.
    public var finishReason: String? = nil

    public init(role: String, text: String? = nil, timestamp: Double? = nil, rowId: Int? = nil, displayKind: String? = nil,
                name: String? = nil, context: String? = nil, reasoning: String? = nil, apiContent: String? = nil,
                finishReason: String? = nil, hasToolCalls: Bool = false, argsText: String? = nil,
                controlMarker: String? = nil, notificationCategory: String? = nil) {
        self.hasToolCalls = hasToolCalls
        self.rowId = rowId
        self.timestamp = timestamp
        self.role = role
        self.text = text
        self.displayKind = displayKind
        self.controlMarker = controlMarker
        self.notificationCategory = notificationCategory
        self.name = name
        self.context = context
        self.argsText = argsText
        self.reasoning = reasoning
        self.apiContent = apiContent
        self.finishReason = finishReason
    }

    // MARK: Decoding

    /// A key made from any string, so a row can be asked for under several spellings.
    private struct Spelling: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init(_ name: String) { stringValue = name }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    /// A row of the answer, read by trying each spelling of a field in turn. The shared decoder
    /// turns snake_case into camelCase, the transcript cache's plain decoder does not, so rows
    /// are asked for both ways.
    private struct Row {
        let box: KeyedDecodingContainer<Spelling>

        func value<T: Decodable>(_ type: T.Type, _ spellings: String...) -> T? {
            for spelling in spellings {
                if let found = try? box.decodeIfPresent(T.self, forKey: Spelling(spelling)) { return found }
            }
            return nil
        }

        /// Text that counts as absent when it is only whitespace: the gateway pads some
        /// reasoning fields with a single space for certain APIs.
        func substantial(_ spellings: String...) -> String? {
            for spelling in spellings {
                if let text = try? box.decodeIfPresent(String.self, forKey: Spelling(spelling)),
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
            }
            return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let row = Row(box: try decoder.container(keyedBy: Spelling.self))

        role = row.value(String.self, "role") ?? "assistant"

        var body = row.value(String.self, "text")
        if body == nil, let shown = row.value(JSONValue.self, "displayContent", "display_content") { body = Self.flatten(shown) }
        if body == nil, let stored = row.value(JSONValue.self, "content") { body = Self.flatten(stored) }

        if let seconds = row.value(Double.self, "timestamp") {
            timestamp = seconds
        } else if let written = row.value(String.self, "timestamp") {
            timestamp = Self.seconds(from: written)
        }
        rowId = row.value(Int.self, "rowId", "row_id", "id")
        displayKind = row.value(String.self, "displayKind", "display_kind")

        let meta = row.value(JSONValue.self, "displayMetadata", "display_metadata")
        controlMarker = row.value(String.self, "controlMarker")
            ?? meta?["control_marker"]?.stringValue ?? meta?["controlMarker"]?.stringValue
        notificationCategory = row.value(String.self, "notificationCategory")
            ?? meta?["notification_category"]?.stringValue ?? meta?["notificationCategory"]?.stringValue

        // A deliberate silence has no display text; its stored content is what to show.
        if controlMarker == "intentional_silence", (body ?? "").isEmpty, let stored = row.value(JSONValue.self, "content") {
            body = Self.flatten(stored)
        }
        text = body

        let calls = row.value(JSONValue.self, "toolCalls", "tool_calls")?.arrayValue ?? []
        name = row.value(String.self, "name") ?? calls.first.flatMap { $0["function"]?["name"]?.stringValue ?? $0["name"]?.stringValue }
        context = row.value(String.self, "context")
        hasToolCalls = row.value(Bool.self, "hasToolCalls") ?? !calls.isEmpty

        for spelling in ["argsText", "args_text", "args", "arguments"] {
            guard let args = row.value(JSONValue.self, spelling) else { continue }
            if case .string(let literal) = args { argsText = literal; break }
            if args.arrayValue != nil || args.objectValue != nil { argsText = args.prettyPrinted; break }
        }

        reasoning = row.substantial("reasoning") ?? row.substantial("reasoningContent", "reasoning_content")
        apiContent = row.substantial("apiContent", "api_content")
        finishReason = row.substantial("finishReason", "finish_reason")
    }

    private enum Field: String, CodingKey {
        case role, text, timestamp, rowId, displayKind, controlMarker, notificationCategory
        case name, context, argsText, reasoning, apiContent, finishReason, hasToolCalls
    }

    public func encode(to encoder: Encoder) throws {
        var out = encoder.container(keyedBy: Field.self)
        try out.encode(role, forKey: .role)
        try out.encodeIfPresent(text, forKey: .text)
        try out.encodeIfPresent(timestamp, forKey: .timestamp)
        try out.encodeIfPresent(rowId, forKey: .rowId)
        try out.encodeIfPresent(displayKind, forKey: .displayKind)
        try out.encodeIfPresent(controlMarker, forKey: .controlMarker)
        try out.encodeIfPresent(notificationCategory, forKey: .notificationCategory)
        try out.encodeIfPresent(name, forKey: .name)
        try out.encodeIfPresent(context, forKey: .context)
        try out.encodeIfPresent(argsText, forKey: .argsText)
        try out.encodeIfPresent(reasoning, forKey: .reasoning)
        try out.encodeIfPresent(apiContent, forKey: .apiContent)
        try out.encodeIfPresent(finishReason, forKey: .finishReason)
        if hasToolCalls { try out.encode(true, forKey: .hasToolCalls) }
    }

    // MARK: Helpers

    /// Content in the OpenAI style: plain text, or a list of parts like `{type: "text", text: ...}`.
    static func flatten(_ content: JSONValue) -> String? {
        if let plain = content.stringValue { return plain }
        guard let parts = content.arrayValue else { return nil }
        let pieces: [String] = parts.compactMap { part in
            if let plain = part.stringValue { return plain }
            if let words = part["text"]?.stringValue { return words }
            return part["type"]?.stringValue == "image_url" ? "[image]" : nil
        }
        return pieces.isEmpty ? nil : pieces.joined(separator: "\n")
    }

    /// Seconds since 1970 from whatever the gateway wrote: a number in a string, an ISO date
    /// with or without fractions, or one of the database's plain date formats. Dates with no
    /// zone are taken in this device's zone.
    static func seconds(from written: String) -> Double? {
        if let number = Double(written) { return number }

        let iso = ISO8601DateFormatter()
        for options in [ISO8601DateFormatter.Options([.withInternetDateTime, .withFractionalSeconds]), [.withInternetDateTime]] {
            iso.formatOptions = options
            if let date = iso.date(from: written) { return date.timeIntervalSince1970 }
        }

        let plain = DateFormatter()
        plain.locale = Locale(identifier: "en_US_POSIX")
        let hasZone = written.hasSuffix("Z") || written.contains("+")
        plain.timeZone = hasZone ? TimeZone(identifier: "UTC") : .current
        let layouts = ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss.SSSSSS", "yyyy-MM-dd HH:mm:ss"]
        for layout in layouts {
            plain.dateFormat = layout
            if let date = plain.date(from: written) { return date.timeIntervalSince1970 }
        }
        return nil
    }
}

// MARK: Stored chats

/// A chat as `GET /api/sessions` lists it.
public struct StoredSession: Codable, Hashable, Identifiable, Sendable {
    public var isActive: Bool? = nil
    public var archived: Bool? = nil
    public var pinned: Bool? = nil
    public var messageCount: Int? = nil
    public var startedAt: Double? = nil
    public var endedAt: Double? = nil
    public var lastActive: Double? = nil
    public var id: String
    public var title: String? = nil
    public var preview: String? = nil
    public var source: String? = nil
    public var model: String? = nil
    public var profile: String? = nil
    public var cwd: String? = nil

    public init(id: String, title: String? = nil, preview: String? = nil, source: String? = nil, model: String? = nil,
                startedAt: Double? = nil, lastActive: Double? = nil, messageCount: Int? = nil, isActive: Bool? = nil,
                archived: Bool? = nil, pinned: Bool? = nil, profile: String? = nil) {
        self.id = id
        (self.title, self.preview, self.source, self.model) = (title, preview, source, model)
        (self.startedAt, self.lastActive) = (startedAt, lastActive)
        (self.messageCount, self.isActive, self.archived, self.pinned) = (messageCount, isActive, archived, pinned)
        self.profile = profile
    }

    /// The title, else the start of the preview, else "New chat".
    public var displayTitle: String {
        let named = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !named.isEmpty { return named }
        let opening = (preview ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return opening.isEmpty ? String(localized: "New chat", table: "Core") : String(opening.prefix(80))
    }

    public var lastDate: Date? {
        (lastActive ?? startedAt).map(Date.init(timeIntervalSince1970:))
    }
}

public struct SessionListResponse: Codable, Sendable {
    public var sessions: [StoredSession]
    public var total: Int? = nil
}

public struct SessionMessagesResponse: Codable, Sendable {
    public var sessionId: String
    public var messages: [TranscriptMessage]
}
