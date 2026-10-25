import Foundation

/// Presentation rules for successful control replies from gateway-injected turns.
/// The transcript and its cache retain the original rows.
public enum AutomatedReply {
    private static func isMachinePrompt(kind: String?, category: String?) -> Bool {
        ["internal_notification", "async_delegation_complete", "process_complete"].contains(kind ?? "") || category == "diagnostic"
    }
    public static func isControlMarker(_ text: String?) -> Bool {
        guard let text else { return false }
        return ["[SILENT]", "NO_REPLY"].contains(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func isAutomatedPrompt(_ text: String) -> Bool {
        InjectedNote.parse(text) != nil || AgentMessage.parse(text) != nil
    }

    /// Final reply of the newest finished turn in a chat, ignoring silent automation. This is what
    /// the Mac's Copy Last Reply puts on the clipboard.
    public static func lastReply(in items: [TranscriptItem]) -> String? {
        presentationItems(items).reversed().lazy.compactMap { item -> String? in
            guard case .assistant(let text, _, false) = item.kind else { return nil }
            let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return words.isEmpty ? nil : words
        }.first
    }

    private static func isPrompt(_ item: TranscriptItem) -> Bool {
        switch item.kind {
        case .user, .steer: true
        default: false
        }
    }

    private static func isReply(_ item: TranscriptItem) -> Bool {
        if case .assistant = item.kind { true } else { false }
    }

    private static let doneWords: Set<String> = ["done", "complete", "completed", "success"]

    public static func presentationItems(_ items: [TranscriptItem]) -> [TranscriptItem] {
        let hidden = hiddenIndices(items.map(Row.init))
        return items.enumerated().compactMap { hidden.contains($0.offset) || $0.element.displayKind == "hidden" ? nil : $0.element }
    }

    public static func previewMessages(_ messages: [TranscriptMessage]) -> [TranscriptMessage] {
        let hidden = hiddenIndices(messages.map(Row.init))
        return messages.enumerated().compactMap {
            hidden.contains($0.offset) || $0.element.displayKind == "hidden" ? nil : $0.element
        }
    }

    public static func suppressesCompletion(text: String? = nil, status: String? = nil, error: String? = nil, items: [TranscriptItem], intentionalSilence: Bool = false) -> Bool {
        if let error, !error.isEmpty { return false }
        if let status, !doneWords.contains(status) { return false }
        if intentionalSilence { return true }

        // What the turn ended with: the completion's own words, else the last finished reply if
        // nobody has spoken since.
        var ending = text
        if ending == nil || ending == "" {
            ending = nil
            if let last = items.lastIndex(where: isReply), !items[(last + 1)...].contains(where: isPrompt),
               case .assistant(let reply, _, false) = items[last].kind {
                ending = reply
            }
        }
        guard isControlMarker(ending) else { return false }

        let wanted = ending?.trimmingCharacters(in: .whitespacesAndNewlines)
        let replyAt = items.lastIndex { item in
            guard case .assistant(let reply, _, false) = item.kind else { return false }
            return reply.trimmingCharacters(in: .whitespacesAndNewlines) == wanted
        }
        let upToReply = items[..<(replyAt.map { $0 + 1 } ?? items.endIndex)]
        guard let start = upToReply.lastIndex(where: isPrompt) else { return false }
        let end = items[(start + 1)...].firstIndex(where: isPrompt) ?? items.endIndex
        let turn = items[start..<end].map(Row.init)
        if turn.contains(where: \.failed) { return false }
        return turn[0].automated || isAutomatedPrompt(turn[0].text)
    }

    /// A trusted live completion can be quiet before a history snapshot contains its result.
    /// Record only presentation metadata; keep the original prompt and tool output.
    public static func completingSilently(_ items: [TranscriptItem]) -> [TranscriptItem] {
        guard let start = items.lastIndex(where: isPrompt) else { return items }
        let rows = items[start...].map(Row.init)
        guard rows[0].automated || isAutomatedPrompt(rows[0].text) else { return items }
        guard !rows.contains(where: { $0.failed }), rows.dropFirst().allSatisfy({
            $0.kind == .tool || $0.kind == .assistant && ($0.text.isEmpty || $0.control || isControlMarker($0.text))
        }) else { return items }
        var marked = items
        marked[start].displayKind = "internal_notification"
        marked[start].controlMarker = "intentional_silence"
        return marked
    }

    private struct Row {
        enum Kind: Equatable { case prompt, assistant, tool, other }
        var kind: Kind
        var text: String = ""
        var control = false
        var automated = false
        var streaming = false
        var failed = false

        init(_ item: TranscriptItem) {
            control = item.controlMarker == "intentional_silence"
            automated = Self.isMachine(item.displayKind, item.notificationCategory)
            switch item.kind {
            case .user(let text, _), .steer(let text, _):
                kind = .prompt; self.text = text
                failed = InjectedNote.parse(text)?.title.lowercased().contains("failed") == true
            case .assistant(let text, _, let streaming):
                kind = .assistant; self.text = text; self.streaming = streaming
                failed = item.finishReason != nil && item.finishReason != "stop" && item.finishReason != "tool_calls"
            case .tool(let tool): kind = .tool; failed = tool.status == .failed; streaming = tool.status == .running
            case .error: kind = .other; failed = true
            default: kind = .other
            }
        }

        init(_ message: TranscriptMessage) {
            text = message.text ?? ""
            control = message.controlMarker == "intentional_silence"
            automated = Self.isMachine(message.displayKind, message.notificationCategory)
            switch message.role {
            case "user":
                kind = .prompt
                failed = InjectedNote.parse(text)?.title.lowercased().contains("failed") == true
            case "assistant":
                kind = .assistant; streaming = message.hasToolCalls
                failed = message.finishReason != nil && message.finishReason != "stop" && message.finishReason != "tool_calls"
            case "tool", "tool_call": kind = .tool; failed = message.finishReason == "error"
            case "error": kind = .other; failed = true
            default: kind = .other
            }
        }

        private static func isMachine(_ kind: String?, _ category: String?) -> Bool {
            AutomatedReply.isMachinePrompt(kind: kind, category: category)
        }
    }

    private static func hiddenIndices(_ rows: [Row]) -> Set<Int> {
        // Gateway-authored inputs are instructions to the bot, never messages from the
        // person. Keep them in raw history to preserve turn boundaries and diagnostics.
        var hidden = Set(rows.indices.filter { rows[$0].kind == .prompt && rows[$0].automated })
        let starts = rows.indices.filter { rows[$0].kind == .prompt }
        for (offset, start) in starts.enumerated() {
            let end = offset + 1 < starts.count ? starts[offset + 1] : rows.count
            let range = start..<end
            guard rows[start].automated || isAutomatedPrompt(rows[start].text) || range.contains(where: { rows[$0].control }) else { continue }
            guard !range.contains(where: { rows[$0].failed }) else { continue }
            let markers = range.filter { rows[$0].kind == .assistant && (rows[$0].control || isControlMarker(rows[$0].text)) }
            hidden.formUnion(markers)
            // Do not flash a control token while it streams. Any text beyond the token
            // becomes an ordinary visible reply, and incomplete final text stays visible.
            hidden.formUnion(range.filter {
                let row = rows[$0], text = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return row.kind == .assistant && row.streaming && !text.isEmpty
                    && ["[SILENT]", "NO_REPLY"].contains(where: { $0.hasPrefix(text) })
            })
            guard let last = range.last, (markers.contains(last) || rows[start].control), !rows[last].streaming else { continue }
            let silentOnly = range.dropFirst().allSatisfy {
                let row = rows[$0]
                if row.streaming { return false }
                return row.kind == .tool || row.kind == .assistant && (row.text.isEmpty || row.control || isControlMarker(row.text))
            }
            if silentOnly { hidden.formUnion(range) }
        }
        return hidden
    }
}
