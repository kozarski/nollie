import SwiftUI
import NollieCore

/// What a long press on a chat row shows: the last few messages as little bubbles, the way
/// Messages lets you peek at a thread. Opening the chat stays in the menu, because a SwiftUI
/// preview cannot be tapped.
struct SessionPreview: View {
    var session: StoredSession
    var runtime: GatewayRuntime?
    var profile: String?

    @State private var tail = [TranscriptMessage]()
    @State private var settled = false

    private var botName: String { session.profile ?? profile ?? runtime?.selectedProfile ?? "?" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            titleBar
            if tail.isEmpty { placeholder } else { bubbles }
            facts
        }
        .padding(16)
        // Its own width when there is room for it, and whatever the preview is offered when there is not.
        .frame(minWidth: 0, idealWidth: 340, maxWidth: 340, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            tail = await recentSpoken()
            settled = true
        }
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            BotAvatar(profile: botName, size: 24)
            Text(session.displayTitle)
                .font(.headline)
                .lineLimit(1)
                .spread()
        }
    }

    /// Shown until there is something to peek at: the saved preview line, or a spinner.
    @ViewBuilder private var placeholder: some View {
        if let line = session.preview, !line.isEmpty {
            Text(line).quiet(.subheadline).lineLimit(6)
        }
        if !settled { ProgressView().controlSize(.small).spread(.center) }
    }

    private var bubbles: some View {
        VStack(spacing: 6) {
            ForEach(Array(tail.enumerated()), id: \.offset) { _, message in
                bubble(message)
            }
        }
    }

    private func bubble(_ message: TranscriptMessage) -> some View {
        let fromMe = message.role == "user"
        return Text(message.text ?? "")
            .font(.footnote)
            .lineLimit(4)
            .foregroundStyle(fromMe ? .white : .primary)
            .inset(h: 10, v: 6)
            .background(fromMe ? Color.nollie : Color(.systemGray5), in: .rect(cornerRadius: 12))
            .spread(fromMe ? .trailing : .leading)
            .padding(fromMe ? .leading : .trailing, 40)
    }

    private var facts: some View {
        HStack(spacing: 10) {
            if let count = session.messageCount { Label("\(count) messages", systemImage: "text.bubble") }
            if let name = session.model, !name.isEmpty {
                Label(ModelNames.tail(name), systemImage: "cpu").lineLimit(1)
            }
            if let when = session.lastDate { Text(when, format: .relative(presentation: .named)) }
        }
        .quiet(.caption, .tertiary)
    }

    private static let spokenRoles: Set<String> = ["user", "assistant"]

    /// Up to six recent messages that someone actually said. Uses the saved copy of the chat when
    /// there is one, and asks the gateway otherwise.
    private func recentSpoken() async -> [TranscriptMessage] {
        guard let runtime else { return [] }
        if let saved = TranscriptCache.load(connection: runtime.connection.id, storedID: session.id),
           !saved.isEmpty {
            return saved.filter { Self.spokenRoles.contains($0.role) }.suffix(6).map { $0 }
        }
        let bot = profile ?? session.profile ?? runtime.selectedProfile
        let newestTwelve = ["limit": "12", "order": "latest"]
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        let reply: JSONValue? = try? await runtime.api.get("/api/sessions/\(session.id)/messages",
                                                           query: newestTwelve, profile: bot)
        var messages = [TranscriptMessage]()
        for raw in reply?["messages"]?.arrayValue ?? [] {
            if let message = try? raw.decode(TranscriptMessage.self) { messages.append(message) }
        }
        let said = TranscriptItem.withPromotedAnswers(messages).filter { message in
            Self.spokenRoles.contains(message.role) && !(message.text ?? "").isEmpty
        }
        return Array(said.suffix(6))
    }
}
