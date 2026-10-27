import FoundationModels
import SwiftUI
import NollieCore

/// Progress through a burst of summary jobs. Jobs line up while the model is busy; once it
/// goes quiet, the next job starts the count over.
struct SummaryProgress: Equatable {
    private(set) var done = 0
    private(set) var total = 0

    var isWorking: Bool { total > done }
    var fraction: Double { Double(done) / Double(max(total, 1)) }
    /// Which job is under way, counting from 1 ("3 of 12").
    var current: Int { min(done + 1, total) }

    mutating func queued() {
        if !isWorking { self = SummaryProgress() }
        total += 1
    }

    mutating func finished() {
        done = min(done + 1, total)
    }
}

/// Where finished summaries are stored across launches. Only the 300 newest are kept.
enum SummaryCache {
    private static let key = "chats.aiSummaries.cache"
    private static let limit = 300

    static func load() -> [String: ChatSummarizer.Summary] {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([String: ChatSummarizer.Summary].self, from: $0) } ?? [:]
    }

    /// Writes the newest summaries to disk and hands back the ones that survived the cut.
    @discardableResult
    static func save(_ all: [String: ChatSummarizer.Summary]) -> [String: ChatSummarizer.Summary] {
        var kept = all
        if all.count > limit {
            let newest = all.sorted { $0.value.stamp > $1.value.stamp }.prefix(limit)
            kept = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
        if let blob = try? JSONEncoder().encode(kept) { UserDefaults.standard.set(blob, forKey: key) }
        return kept
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// Has the on-device model write a short title and blurb from the tail of a chat.
enum SummaryWriter {
    @Generable
    struct Draft {
        @Guide(description: "Up to six words naming the chat. No quotation marks and no full stop at the end.")
        var title: String
        @Guide(description: "One or two brief sentences on the topic and how far it got. Keep it under 140 characters.")
        var summary: String
    }

    // Goes to the model, so it stays in English.
    private static let brief = """
        Write the preview text for one row of a chat list, based on an exchange between a person and an assistant. \
        Stay specific and matter-of-fact, and never say the words conversation or summary.
        """

    /// The tidied draft. Nil if the model declines or fails, and the row then keeps its own text.
    static func draft(from messages: [TranscriptMessage]) async -> (title: String, summary: String)? {
        let lines = messages.map { "\($0.role == "user" ? "User" : "Assistant"): \(($0.text ?? "").prefix(600))" }
        let reply = try? await LanguageModelSession(instructions: brief)
            .respond(to: "Conversation:\n" + lines.joined(separator: "\n"), generating: Draft.self)
        guard let made = reply?.content else { return nil }
        let title = made.title.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ".\"'"))
        let summary = made.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty && summary.isEmpty ? nil : (title, summary)
    }

    /// Up to ten latest user and assistant lines, preferring what is already saved on this device.
    @MainActor static func recentMessages(of session: StoredSession, runtime: GatewayRuntime, profile: String?) async -> [TranscriptMessage] {
        func spoken(_ all: [TranscriptMessage]) -> [TranscriptMessage] {
            let said = all.filter { ["user", "assistant"].contains($0.role) && !($0.text ?? "").isEmpty }
            return Array(said.suffix(10))
        }
        if let local = TranscriptCache.load(connection: runtime.connection.id, storedID: session.id), !local.isEmpty {
            return spoken(local)
        }
        let latest = [URLQueryItem(name: "order", value: "latest"), URLQueryItem(name: "limit", value: "14")]
        let bot = profile ?? session.profile ?? runtime.selectedProfile
        let reply: JSONValue? = try? await runtime.api.get("/api/sessions/\(session.id)/messages", query: latest, profile: bot)
        let decoded = (reply?["messages"]?.arrayValue ?? []).compactMap { try? $0.decode(TranscriptMessage.self) }
        return spoken(TranscriptItem.withPromotedAnswers(decoded))
    }
}
