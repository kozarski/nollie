import SwiftUI
import NollieCore

/// One conversation with a bot, drawn from a `ConversationEngine`: the list of its rows and the questions it waits
/// on (a collection view, `ConversationList`), the composer in the bottom safe area and the jump-to-newest
/// button. It follows the newest row until the person scrolls up, and from then on nothing on screen moves until
/// they come back. See `Docs/specs/conversation-ui.md`.
struct ConversationScreen: View {
    let engine: ConversationEngine

    @State private var follower = ConversationFollower()
    @State private var draft = ""
    /// The night shift card whose picture is being shared.
    @State private var sharing: ConversationPost?
    /// Runs whose actions are all shown, as `<post id>/<run id>`. Kept here because cells are recycled.
    @State private var expanded: Set<String> = []

    var body: some View {
        // The list runs under the header and the composer (their glass shows it through); the insets it is given
        // are the room between them, keyboard included.
        GeometryReader { proxy in
            ConversationList(engine: engine, items: items, follower: follower, insets: proxy.safeAreaInsets,
                             answer: { card, action in engine.perform(action, on: card) },
                             post: { post, tap in tapped(tap, on: post) })
                .ignoresSafeArea()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ConversationComposer(draft: $draft, running: engine.state.running, send: send, stop: engine.interrupt)
                .frame(maxWidth: ConversationMetrics.column)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity)
                // The jump button floats above the composer without changing the list's inset.
                .overlay(alignment: .top) {
                    if !follower.isFollowing {
                        Button { follower.jumpToNewest() } label: {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Ink.text)
                                .frame(width: 40, height: 40)
                                .nollieGlass(.regular.interactive(), in: Circle(), solid: Ink.canvas)
                                .contentShape(.circle)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Newest")
                        .accessibilityIdentifier("conversation.jump")
                        .offset(y: -50)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    }
                }
                .animation(.snappy(duration: 0.2), value: follower.isFollowing)
        }
        .background(Ink.canvas)
        .sheet(item: $sharing) { post in
            NightShiftShareSheet(post: post).sheetFrame().withAppModel()
        }
    }

    private var items: [ConversationListItem] {
        ConversationListItem.make(transcript: engine.transcript, cards: engine.state.cards,
                                  activity: engine.state.activity.shownWords, atNewestEnd: engine.historyAtNewestEnd,
                                  expanded: expanded)
    }

    private func tapped(_ tap: ConversationPostTap, on post: ConversationPost) {
        switch tap {
        case .turnOn: engine.perform(.turnOn, on: post.id)
        case .keepOff: engine.perform(.keepOff, on: post.id)
        case .share: sharing = post
        case .showAll(let run):
            let key = ConversationListItem.expandedKey(post: post.id, run: run)
            if expanded.remove(key) == nil { expanded.insert(key) }
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        engine.send(text)
        // Already following, the new row arrives at the bottom by itself.
        if !follower.isFollowing { follower.jumpToNewest() }
    }
}

extension ConversationActivity {
    /// The short line under the chat; nil while idle or once words are arriving.
    var shownWords: String? {
        switch self {
        case .idle, .writing: nil
        case .sending: "Sending"
        case .thinking: "Thinking"
        case .runningTool, .preparingTool: "Working"
        case .summarizing: "Summarizing"
        case .status(let words): words
        }
    }
}
