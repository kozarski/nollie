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
    @Environment(\.threadWaitsOnYou) private var waitsOnYou
    /// The pointer is over this reply (Mac): its play button shows on an older reply too.
    @State private var hovering = false

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
                listen
                Spacer(minLength: wide ? 0 : 24)
            }
        }
        #if os(macOS)
        .onHover { hovering = $0 }
        #endif
    }

    /// The play button. Always beside the last reply of a run; on the Mac also beside an older one while the
    /// pointer is over it or it is being read. Elsewhere an older reply offers Listen in its menu.
    @ViewBuilder private var listen: some View {
        if let bot {
            let speaking = ReplyVoice.shared.isSpeaking(item.id)
            if ReplyListenRule.placed(lastOfRun: botShown, onMac: ReplyListenRule.onMac) {
                let shown = ReplyListenRule.shown(lastOfRun: botShown, hovering: hovering, speaking: speaking)
                ReplyListenButton(text: text, key: item.id, owner: bot)
                    .opacity(shown ? 1 : 0)
                    .allowsHitTesting(shown)
                    .animation(.easeOut(duration: 0.15), value: shown)
            }
        }
    }

    private var listenStep: [(BubbleAction, () -> Void)] {
        guard let bot else { return [] }
        let speaking = ReplyVoice.shared.isSpeaking(item.id)
        return [(speaking ? .stopListening : .listen, { ReplyVoice.shared.toggle(SpokenReply.plain(text), key: item.id, owner: bot) })]
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
            // While an approval waits the bot is not typing, it is waiting on the person.
            if !waitsOnYou { TypingBubble(tool: typingTool).accessibilityIdentifier("thread.typing") }
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
            ] + listenStep, sharing: true)
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

/// Where a reply's play button goes. The last reply of a run always has it; an older one has it on the Mac,
/// shown only while the pointer is over the reply or it is being read, so the thread stays quiet. Every
/// finished reply also offers Listen in its menu.
enum ReplyListenRule {
    #if os(macOS)
    static let onMac = true
    #else
    static let onMac = false
    #endif

    /// Whether the row has a play button at all (taking its room even while hidden, so nothing moves).
    static func placed(lastOfRun: Bool, onMac: Bool) -> Bool { lastOfRun || onMac }

    /// Whether a placed button can be seen and pressed now.
    static func shown(lastOfRun: Bool, hovering: Bool, speaking: Bool) -> Bool { lastOfRun || hovering || speaking }
}

extension EnvironmentValues {
    /// Set on the thread while an approval in it waits for an answer.
    @Entry var threadWaitsOnYou = false
}
