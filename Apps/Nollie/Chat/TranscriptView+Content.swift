import SwiftUI
import NollieCore

// Everything inside the thread: the greeting of an empty chat, the rows, waiting approvals and
// the working bubble. Kept out of `body` because the type checker gave up on one long chain.

extension TranscriptView {
    @ViewBuilder var threadContent: some View {
        Group {
            if chat.items.isEmpty, chat.resumeError == nil { emptyThread }
            threadRows
            // One plain card per approval that is waiting.
            ForEach(approvals) { card in
                ThreadApprovalCard(chat: chat, card: card)
                    .atLeading(upTo: bubbleCap)
                    .transition(.opacity)
                    .id("card-" + card.id)
            }
            // If the turn stopped for want of System control, one tap switches it on and the bot
            // picks up again.
            if let stop = systemControlStop, stop != dismissedStop { systemControlCard(stop: stop) }
            // Working, with nothing on screen yet: show the typing bubble (dark and badged during tools).
            if showsWorkingBubble { workingBubble }
        }
    }

    private var showsWorkingBubble: Bool {
        chat.isRunning && approvals.isEmpty && !liveRunAtEnd && !lastIsStreamingReply
    }

    private var emptyThread: some View {
        VStack(spacing: 24) {
            BotAvatar(profile: chat.profileName, size: 72)
            if let onStartIdea {
                FirstTaskIdeas(onChoose: onStartIdea)
            } else {
                Text("Say something to \(botDisplayName)").quiet(Ink.message, Ink.text3)
            }
        }
        .spread(.center)
        .padding(EdgeInsets(top: 36, leading: 16, bottom: 0, trailing: 16))
    }

    private func systemControlCard(stop: String) -> some View {
        SystemControlAskCard(botName: botDisplayName, onTurnOn: turnOnSystemControl) {
            withAnimation(.snappy) { dismissedStop = stop }
        }
        .atLeading(upTo: bubbleCap)
        .transition(.opacity)
        .id("system-control-stop")
    }

    private func turnOnSystemControl() {
        Task {
            let enabled = await SystemControl.shared.set(true, profile: chat.profileName, rt: chat.runtime)
            guard enabled else { return }
            _ = await chat.send("System control is on now. Carry on.")
        }
    }

    /// Deliberately transition-free: the streaming reply that follows draws an identical bubble
    /// at the same spot, so any fade or slide would show the two overlapping.
    private var workingBubble: some View {
        HStack(spacing: 10) {
            TypingBubble(tool: typingTool)
            Spacer(minLength: 24)
        }
        .id("typing")
        .accessibilityIdentifier("thread.typing")
        .accessibilityElement(children: .contain)
    }

    /// Older rows sit in a lazy stack and the newest ones are built normally. Lazy stacks estimate
    /// the height of unbuilt rows, and a freshly appended row counts as unbuilt, so the end could
    /// be mis-located and the view would briefly show its top or nothing. On the Mac, with every
    /// row lazy, each scroll to the end changed the estimate and triggered another scroll, which
    /// pinned the CPU. Building every row eagerly instead exhausted memory on long chats. Rows
    /// are handed to the lazy stack only between turns (`settleTail`), because their height
    /// shifts as they cross.
    @ViewBuilder var threadRows: some View {
        let all = rows
        let split = TranscriptRowModel.split(count: all.count, tailFrom: tailFrom)
        let context = rowContext
        if split > 0 {
            // This view is Equatable, so while nothing the older rows depend on changes they are not
            // re-evaluated; a streaming token then only touches the tail.
            OlderRows(rows: Array(all[..<split]), context: context).equatable()
        }
        let fadeIn = Self.enteringRowID(all, opening: settling || chat.isResuming)
        ForEach(all[split...]) { context.rowView($0, entering: $0.id == fadeIn) }
    }

    /// Picks the row that should fade in: the newest, but only after the chat is fully open, and
    /// not while it is a streaming reply (which replaces the typing bubble in place, so fading
    /// would look like a flicker). Everything else appears at once.
    static func enteringRowID(_ rows: [TranscriptRowModel], opening: Bool) -> String? {
        guard !opening, let newest = rows.last, !isStreaming(newest.item) else { return nil }
        return newest.id
    }

    /// The inputs rows draw from, apart from the rows themselves. Callbacks are stored on a
    /// long-lived object, so new closures do not make contexts compare as different.
    var rowContext: RowContext {
        actions.onEdit = onEditMessage
        actions.onOpenBot = onOpenBot
        actions.onReply = onReply
        actions.onKeepRunning = { showAwayGrace = true }
        actions.onSelectText = { selectText = $0 }
        actions.setReasoningOpen = { id, open in openReasoning.mark(id, present: open) }
        actions.setToolOpen = { id, open in openTools.mark(id, present: open) }
        return RowContext(
            profile: nil, bot: chat.profileName, typingTool: typingTool, showReasoning: prefs.showReasoning,
            currentStepOnly: prefs.currentStepOnly, showStats: prefs.showTurnStats, interruptCause: chat.interruptCause,
            lastID: visibleItems.last?.id, openReasoning: openReasoning, openTools: openTools,
            showToolOutput: prefs.showToolOutput, compactTools: prefs.compactTools, wide: prefs.wideReplies,
            maxBubble: bubbleCap, actions: actions, highlightedMessage: highlightedMessage)
    }
}

private extension View {
    /// Sits at the leading edge and grows no wider than `cap`.
    func atLeading(upTo cap: CGFloat) -> some View {
        frame(maxWidth: cap, alignment: .leading).spread()
    }
}

private extension Set {
    /// Adds or removes one element according to `present`.
    mutating func mark(_ element: Element, present: Bool) {
        if present { insert(element) } else { remove(element) }
    }
}
