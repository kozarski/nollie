import SwiftUI
import NollieCore

/// One entry of the list: a row, a post, a card, or the activity line.
struct ConversationItemView: View {
    let item: ConversationListItem
    let bubbleWidth: CGFloat
    let answer: (ConversationCard, ConversationCardAction) -> Void
    /// A tap on a post: Turn on, Keep off, Share, Show all.
    let post: (ConversationPost, ConversationPostTap) -> Void

    var body: some View {
        switch item {
        case .row(let row, let startsTurn):
            ConversationRowView(row: row, startsTurn: startsTurn, bubbleWidth: bubbleWidth).equatable()
        case .post(let row, let expanded):
            if let shown = row.post {
                ConversationPostView(post: shown, expanded: expanded) { post(shown, $0) }
                    .padding(.bottom, ConversationMetrics.rowGap)
                    .frame(maxWidth: ConversationMetrics.column)
                    .frame(maxWidth: .infinity)
            }
        case .card(let card):
            ConversationCardView(card: card) { answer(card, $0) }
                .frame(maxWidth: ConversationMetrics.column)
                .frame(maxWidth: .infinity)
        case .activity(let words):
            Text(words)
                .font(Ink.working)
                .foregroundStyle(Ink.text3)
                .padding(.bottom, ConversationMetrics.rowGap)
                .frame(maxWidth: ConversationMetrics.column, alignment: .leading)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("conversation.activity")
        }
    }
}

/// One row of the conversation, by kind. Equatable on the row alone, so a reply streaming at the bottom redraws
/// only itself.
struct ConversationRowView: View, Equatable {
    let row: ConversationRow
    /// Rows above it in the same direction: a new turn gets more room above.
    let startsTurn: Bool
    /// The widest a bubble may be, worked out once from the list's width.
    let bubbleWidth: CGFloat

    var body: some View {
        content
            .padding(.top, startsTurn ? ConversationMetrics.turnGap : 0)
            .padding(.bottom, ConversationMetrics.rowGap)
            .frame(maxWidth: .infinity, alignment: alignment)
            .frame(maxWidth: ConversationMetrics.column)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("row.\(row.id)")
    }

    private var alignment: Alignment {
        switch row.kind {
        case .user: .trailing
        case .note: .center
        default: .leading
        }
    }

    @ViewBuilder private var content: some View {
        switch row.kind {
        case .user(let text, let delivery):
            YourMessage(text: text, delivery: delivery, width: bubbleWidth)
        case .assistant(let reply):
            BotReply(reply: reply, width: bubbleWidth)
        case .tool(let step):
            ToolStepLine(step: step)
        case .note(let note):
            QuietNote(words: note.shownWords)
        case .error(let text):
            Label(text.isEmpty ? "Something went wrong" : text, systemImage: "exclamationmark.circle")
                .font(Ink.cardBody)
                .foregroundStyle(.red)
        case .post:
            // The list draws posts itself (`ConversationItemView`), with their taps.
            EmptyView()
        }
    }
}

/// The spacing of the conversation, in one place.
enum ConversationMetrics {
    static let side: CGFloat = 20
    static let rowGap: CGFloat = 14
    /// Extra room above each of your messages, so a turn reads as one block.
    static let turnGap: CGFloat = 12
    /// The widest a bubble may be, as a share of the reading column.
    static let bubbleShare: CGFloat = 0.86

    /// The widest a bubble may be in a list `width` points wide: a share of the column, never the screen.
    static func bubbleWidth(listWidth width: CGFloat) -> CGFloat {
        let column = min(width, ConversationMetrics.column) - 2 * side
        return max(column * bubbleShare, 120)
    }
    /// The reading column: the Mac's own, and at most this on a wide iPad.
    #if os(macOS)
    static let column: CGFloat = Ink.column
    #else
    static let column: CGFloat = 720
    #endif
}

private struct YourMessage: View {
    let text: String
    let delivery: ConversationDelivery
    let width: CGFloat

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text(text)
                .font(Ink.message)
                .lineSpacing(Ink.lineSpacing)
                .foregroundStyle(Ink.onInk)
                .padding(.horizontal, Ink.bubblePadH).padding(.vertical, Ink.bubblePadV)
                .background(Ink.ink, in: .rect(cornerRadius: Ink.bubbleRadius, style: .continuous))
                .opacity(delivery == .sending ? 0.6 : 1)
                .textSelection(.enabled)
            if let words = delivery.shownWords {
                Text(words).font(Ink.stamp).foregroundStyle(Ink.text3)
            }
        }
        .frame(maxWidth: min(width, Ink.myBubble), alignment: .trailing)
    }
}

private struct BotReply: View {
    let reply: ConversationReply
    let width: CGFloat

    var body: some View {
        let blocks = ConversationReplyBlocks.blocks(reply.text)
        VStack(alignment: .leading, spacing: 10) {
            if blocks.isEmpty {
                // Thinking before the first word: three quiet dots hold the place.
                Text("…").font(Ink.message).foregroundStyle(Ink.text3)
            }
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let words):
                    Text(ConversationReplyBlocks.inline(words))
                        .font(Ink.message)
                        .lineSpacing(Ink.lineSpacing)
                        .foregroundStyle(Ink.text)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(_, let code):
                    ReplyCode(code: code)
                }
            }
            if reply.ending == .interrupted {
                Text("Stopped").font(Ink.stamp).foregroundStyle(Ink.text3)
            }
        }
        .textSelection(.enabled)
        .padding(.horizontal, Ink.bubblePadH).padding(.vertical, Ink.bubblePadV)
        .background(Ink.bubble, in: .rect(cornerRadius: Ink.bubbleRadius, style: .continuous))
        .frame(maxWidth: min(width, Ink.botBubble), alignment: .leading)
    }
}

private struct ReplyCode: View {
    let code: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(Ink.codeBlock)
                .foregroundStyle(Ink.codeText)
                .fixedSize()
                .padding(14)
        }
        // As tall as the code: measured on its own, a sideways scroll view offered any height reports too little.
        .fixedSize(horizontal: false, vertical: true)
        .background(Ink.code, in: .rect(cornerRadius: 14, style: .continuous))
    }
}

private struct ToolStepLine: View {
    let step: ConversationToolStep

    var body: some View {
        Label(step.shownWords, systemImage: step.symbol)
            .font(Ink.steps)
            .foregroundStyle(Ink.text2)
            .lineLimit(1)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .overlay(Capsule().strokeBorder(Ink.line, lineWidth: 1))
            .opacity(step.done ? 1 : 0.7)
    }
}

private struct QuietNote: View {
    let words: String

    var body: some View {
        Text(words)
            .font(Ink.stamp)
            .foregroundStyle(Ink.text3)
            .padding(.vertical, 6)
    }
}

extension ConversationNote {
    /// The few words a quiet row says.
    var shownWords: String {
        switch self {
        case .summarized: "Earlier messages summarized"
        case .interrupted: "Stopped"
        case .answered(let choice): choice == "deny" ? "Denied" : "Allowed"
        case .answeredElsewhere: "Answered elsewhere"
        case .withdrawn: "No longer needed"
        case .notice(let text): text
        }
    }
}

extension ConversationDelivery {
    var shownWords: String? {
        switch self {
        case .sending, .sent: nil
        case .uncertain: "May not have sent"
        case .notSent: "Not sent"
        }
    }
}

extension ConversationToolStep {
    var shownWords: String {
        switch name {
        case "terminal", "shell", "bash": "Ran a command"
        case "read_file": "Read a file"
        case "write_file", "patch": "Changed a file"
        case "web_search", "search": "Searched the web"
        case "web_extract", "browser": "Read a page"
        default: name.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    var symbol: String {
        switch name {
        case "terminal", "shell", "bash": "terminal"
        case "read_file": "doc.text"
        case "write_file", "patch": "pencil"
        case "web_search", "search": "magnifyingglass"
        case "web_extract", "browser": "globe"
        default: "wrench.and.screwdriver"
        }
    }
}
