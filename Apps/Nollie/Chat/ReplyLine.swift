import SwiftUI
import NollieCore

/// A bot's reply laid out as a row: a column for its face, then the bubble. While words are still
/// arriving the bubble is the typing bubble.
struct ReplyLine: View {
    var item: TranscriptItem
    var text: String
    var reasoning: String?
    var streaming: Bool
    var look: BubbleLook
    var scheme: ColorScheme
    var profile: String?
    var bot: String?
    var botShown: Bool
    var typingTool: String?
    var showReasoning: Bool
    var showStats: Bool
    var reasoningOpen: Binding<Bool>
    var wide: Bool
    var onSelect: (String) -> Void
    var onReply: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var thoughts: String? {
        guard showReasoning, let reasoning, !reasoning.isEmpty else { return nil }
        return reasoning
    }

    private var hasStats: Bool { showStats && item.stats != nil }
    private var fill: Color { look.plain ? .clear : look.replyFill }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            face
            if streaming {
                waiting
                Spacer(minLength: wide ? 0 : 40)
            } else {
                finished
                if botShown, let bot { ReplyListenButton(text: text, key: item.id, owner: bot) }
                Spacer(minLength: wide ? 0 : 24)
            }
        }
    }

    /// The bot's face in the margin next to a reply. The one live bot is pinned below the thread, so a
    /// reply that is still streaming keeps the column free and shows nothing. Once finished, the reply
    /// carries a painted picture instead, because a live bot per row made scrolling choppy.
    @ViewBuilder private var face: some View {
        if let profile {
            if botShown && !streaming {
                Image(uiImage: BotAvatarImage.cached(profile: profile, size: 28, scheme: scheme))
                    .resizable()
                    .frame(square: 28)
            } else {
                Color.clear.frame(width: 28, height: 1)
            }
        }
    }

    private var statsLine: some View {
        let label = item.stats?.label ?? ""
        return Text(label)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
            .accessibilityLabel("Turn statistics: \(label)")
    }

    /// Until the reply is complete it stays hidden. Reasoning and live steps can still be opened
    /// under the typing bubble for as long as it takes.
    private var waiting: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let thoughts {
                let shape = MessageBubbleShape(side: .leading, tailed: false, radius: Ink.bubbleRadius)
                ReasoningDisclosure(text: thoughts, open: reasoningOpen, itemID: item.id)
                    .inset(h: Ink.bubblePadH, v: Ink.bubblePadV)
                    .background(fill, in: shape)
            }
            TypingBubble(tool: typingTool).accessibilityIdentifier("thread.typing")
            if hasStats { statsLine.padding(.leading, 6).contentTransition(.numericText()) }
        }
    }

    /// Pictures the bot sends (MEDIA: lines, markdown images, plain paths) appear below the text as
    /// thumbnails loaded via the gateway. Other files turn into cards, and videos such as a screen
    /// recording play in place.
    private var finished: some View {
        let pictures = TranscriptMedia.images(in: text)
        let files = TranscriptMedia.files(in: text)
        let videos = files.filter { MediaRef.isVideo($0.name) }
        let others = files.filter { !MediaRef.isVideo($0.name) }
        let words = TranscriptMedia.words(of: text, naming: pictures.count + files.count)
        let pad = look.plain ? (h: CGFloat(4), v: CGFloat(4)) : (h: Ink.bubblePadH, v: Ink.bubblePadV)
        let shape = MessageBubbleShape(side: .leading, tailed: botShown && look.tailed, radius: Ink.bubbleRadius)
        return VStack(alignment: .leading, spacing: 6) {
            if let thoughts { ReasoningDisclosure(text: thoughts, open: reasoningOpen, itemID: item.id) }
            MarkdownView(text: words, inlineSelection: false).equatable()
            if !pictures.isEmpty { MediaThumbStrip(refs: pictures, profile: bot) }
            if !videos.isEmpty { VideoCardStrip(refs: videos, profile: bot) }
            if !others.isEmpty { FileCardStrip(refs: others, profile: bot) }
            if hasStats { statsLine }
        }
        .font(Ink.message)
        .lineSpacing(Ink.lineSpacing)
        .foregroundStyle(Ink.text)
        .inset(h: pad.h, v: pad.v)
        .background(fill, in: shape)
        #if os(macOS)
        // Let the whole bubble, padding and gaps included, take the right-click. Over the words,
        // selectable text on the Mac pops up its own menu, which cannot copy the reply.
        .contentShape(.rect)
        #endif
        .contextMenu {
            BubbleMenu(text: text, steps: [
                (.reply, { onReply(text) }),
                (.copy, copy),
                (.select, { onSelect(text) }),
            ], sharing: true)
        }
        #if os(macOS)
        // A copy button on hover, beyond the bubble's trailing edge.
        .modifier(ReplyCopyHover(text: text, enabled: true))
        #endif
        .transition(ReplyArrival.transition(reduceMotion: reduceMotion))
    }

    private func copy() {
        #if os(macOS)
        UIPasteboard.general.string = TranscriptMedia.copyText(text)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}
