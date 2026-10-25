import SwiftUI
import NollieCore

/// A chat in the list. Shows what it is called, a taste of what was said, the model, and a badge
/// while the chat is busy or waiting on the person.
struct SessionRow: View {
    let session: StoredSession
    let needsYou: Bool
    let live: Bool
    let showBot: Bool
    let botProfile: String?
    let thinking: Bool
    let step: String?
    let summary: ChatSummarizer.Summary?

    init(session: StoredSession, needsYou: Bool, live: Bool, showBot: Bool = false,
         botProfile: String? = nil, thinking: Bool = false, step: String? = nil,
         summary: ChatSummarizer.Summary? = nil) {
        self.session = session
        self.needsYou = needsYou
        self.live = live
        self.showBot = showBot
        self.botProfile = botProfile
        self.thinking = thinking
        self.step = step
        self.summary = summary
    }

    /// What the row says about the chat, using the device summary where there is one.
    private var title: String { summary?.title ?? session.displayTitle }
    private var excerpt: String { summary?.summary ?? session.preview ?? "" }
    private var excerptLines: Int {
        let lines = ChatRowStyle.previewLines
        return live ? max(1, lines - 1) : lines
    }

    var body: some View {
        HStack(spacing: 12) {
            if showBot { avatar }
            textColumn
            Spacer(minLength: 0)
            badge
        }
        .inset(v: 2)
    }

    // MARK: Parts

    private var avatar: some View {
        // Only a chat that is busy or waiting moves; the others stay still.
        BotAvatar(profile: session.profile ?? botProfile ?? "?", size: 34, state: avatarState,
                  animated: live || needsYou)
    }

    private var avatarState: CharacterState {
        if needsYou { return .needsYou }
        if !live { return .idle }
        return thinking ? .thinking : .speaking
    }

    private var textColumn: some View {
        VStack(alignment: .leading, spacing: 3) {
            titleLine
            goalLine
            Text(excerpt).quiet(.subheadline).lineLimit(excerptLines)
            detailLine
        }
    }

    /// A busy chat shows its goal or step above a shorter preview, so rows keep one height.
    @ViewBuilder private var goalLine: some View {
        if live {
            ChatGoalLine(storedID: session.id, step: step)
        }
    }

    private var titleLine: some View {
        HStack(spacing: 6) {
            if session.pinned == true { Glyph("pin.fill", .caption2, .secondary) }
            if session.archived == true {
                Glyph("archivebox", .caption2, .secondary)
                    .accessibilityLabel("Archived")
            }
            Text(title).font(.body.weight(.medium)).lineLimit(1)
            SummarySparkle(key: session.id, done: summary != nil)
        }
    }

    private var detailLine: some View {
        HStack(spacing: 8) {
            if let name = session.model, !name.isEmpty {
                Text(name).quiet(.caption2, .tertiary).lineLimit(1)
            }
            if let when = session.lastDate {
                Text(when, format: .relative(presentation: .named)).quiet(.caption2, .tertiary)
            }
        }
    }

    @ViewBuilder private var badge: some View {
        if needsYou {
            Text("Needs you")
                .quiet(.caption2.weight(.semibold), .red)
                .capsuled(.red.opacity(0.15))
        } else if live {
            ProgressView().controlSize(.small)
        }
    }
}

/// Spacing variants for the chat list, picked in debug builds with the `-nollie-row-style` launch
/// flag followed by a, b or c. A is roomy, b is the tight layout we ship, c is tight with a longer preview.
enum ChatRowStyle {
    private struct Metrics { let card: CGFloat, row: CGFloat, lines: Int }

    private static let metrics: Metrics = {
        var choice = "b"
        #if DEBUG
        let words = ProcessInfo.processInfo.arguments
        if let at = words.firstIndex(of: "-nollie-row-style"), words.indices.contains(at + 1) {
            choice = words[at + 1]
        }
        #endif
        switch choice {
        case "a": return Metrics(card: 16, row: 16, lines: 2)
        case "c": return Metrics(card: 8, row: 12, lines: 3)
        default: return Metrics(card: 8, row: 12, lines: 2)
        }
    }()

    static var cardInset: CGFloat { metrics.card }
    static var rowInset: CGFloat { metrics.row }
    static var previewLines: Int { metrics.lines }
}
