import SwiftUI
import NollieCore

/// How a fresh row appears in the thread: a quick fade in place and nothing more.
/// The fade brings its own animation, so neighbours are not animated along with it.
/// No slide (a row sliding up from below painted over the rows beneath it) and no fade out
/// (a row that faded in place while its neighbours slid in was drawn over by them).
@MainActor
enum ChatRowTransition {
    private static let quickEase = Animation.easeOut(duration: 0.2)
    static let fadeIn = AnyTransition.asymmetric(insertion: AnyTransition.opacity.animation(quickEase), removal: .identity)
}

/// A reply that just finished pops in where it sits, without animating the row's size.
@MainActor
enum ReplyArrival {
    static func transition(reduceMotion: Bool) -> AnyTransition {
        let look: AnyTransition = reduceMotion ? .opacity : .scale(scale: 0.9, anchor: .bottomLeading).combined(with: .opacity)
        let pace: Animation = reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.28, bounce: 0.15)
        return .asymmetric(insertion: look.animation(pace), removal: .identity)
    }

    /// What VoiceOver should say when a streaming reply turns into a finished one.
    /// Nothing for a stored reply, an empty one, or the interrupted-turn notice.
    static func announcement(from old: TranscriptItem.Kind, to new: TranscriptItem.Kind) -> String? {
        guard case .assistant(_, _, true) = old, case .assistant(let reply, _, false) = new else { return nil }
        if reply.allSatisfy(\.isWhitespace) { return nil }
        return InterruptedTurn.parse(reply) == nil ? reply : nil
    }
}

/// What a tap on a row does. One object for the whole life of the thread, so the context holding
/// it stays equal between updates (closures never compare equal).
final class RowActions {
    typealias WithText = (String) -> Void
    typealias WithFlag = (String, Bool) -> Void

    var onEdit: WithText = { _ in }
    var onOpenBot: WithText = { _ in }
    var onReply: WithText = { _ in }
    var onKeepRunning: () -> Void = {}
    var onSelectText: WithText = { _ in }
    var setReasoningOpen: WithFlag = { _, _ in }
    var setToolOpen: WithFlag = { _, _ in }
}

/// Everything a row is drawn from apart from the row: display settings, the chat's activity, which
/// cards are expanded, and the actions. It is Equatable, so an update that alters none of these leaves
/// already drawn rows alone.
@MainActor
struct RowContext: Equatable {
    private static let glowOpacity = 0.08
    /// The bot shown beside its bubbles, or nil when bots are hidden.
    var profile: String?
    /// Bot that owns the chat, set even when bots are not displayed. Images sit in that bot's folder
    /// on the gateway, and with bots hidden an attachment from a non-default bot used to load blank.
    var bot: String?
    var typingTool: String?
    var showReasoning: Bool
    var currentStepOnly: Bool
    var showStats: Bool
    var interruptCause: InterruptedTurn.Cause?
    var lastID: String?
    var openReasoning: Set<String>
    var openTools: Set<String>
    var showToolOutput: Bool
    var compactTools: Bool
    var wide: Bool
    var maxBubble: CGFloat
    var actions: RowActions
    var highlightedMessage: String? = nil

    /// Display choices, as one comparable list.
    private var choices: [AnyHashable] {
        [showReasoning, currentStepOnly, showStats, showToolOutput, compactTools, wide, maxBubble]
    }

    /// Live state of the chat, as one comparable list.
    private var liveState: [AnyHashable] {
        [typingTool, interruptCause, lastID, openReasoning, openTools, highlightedMessage]
    }

    static func == (lhs: RowContext, rhs: RowContext) -> Bool {
        guard lhs.actions === rhs.actions else { return false }
        return lhs.profile == rhs.profile && lhs.bot == rhs.bot
            && lhs.choices == rhs.choices && lhs.liveState == rhs.liveState
    }

    /// A binding onto one member of an open-set. Reads the value taken now, writes via the callback.
    private func toggle(_ key: String, in set: Set<String>, write: @escaping (String, Bool) -> Void) -> Binding<Bool> {
        let now = set.contains(key)
        return Binding(get: { now }, set: { write(key, $0) })
    }

    /// One thread row: a time heading on top when it is due, then the message with its
    /// time parked past the right edge. `entering` fades a brand new row in (see
    /// `TranscriptView.enteringRowID`); all other rows just appear and leave.
    @ViewBuilder func rowView(_ row: TranscriptRowModel, entering: Bool = false) -> some View {
        let id = row.item.id
        let isTarget = id == highlightedMessage
        if let heading = row.separator {
            Text(heading).quiet(Ink.stamp, Ink.text3).spread(.center).inset(v: 6)
        }
        content(of: row)
            .id(id)
            // Each message is a single group for VoiceOver, tagged by kind. The UI tests compare
            // these frames to show that no row is ever painted over another.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(isTarget ? "notification.message.target" : "thread.row." + row.kindTag)
            .background { if isTarget { Self.targetGlow } }
            .transition(entering ? ChatRowTransition.fadeIn : .identity)
            .modifier(TimeBeside(date: row.item.timestamp))
    }

    private static var targetGlow: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.accentColor.opacity(glowOpacity))
    }

    @ViewBuilder private func content(of row: TranscriptRowModel) -> some View {
        if row.run.isEmpty { messageRow(row) } else { toolRun(row) }
    }

    private func messageRow(_ row: TranscriptRowModel) -> some View {
        let id = row.item.id
        let reasoningShown = showReasoning && (!currentStepOnly || TranscriptView.isStreaming(row.item))
        return TranscriptRow(
            item: row.item, profile: profile, bot: bot, botShown: row.lastOfRun, typingTool: typingTool,
            showReasoning: reasoningShown,
            showStats: showStats,
            onEdit: actions.onEdit, onOpenBot: actions.onOpenBot, onReply: actions.onReply,
            interruptCause: id == lastID ? interruptCause : nil, onKeepRunning: actions.onKeepRunning,
            reasoningOpen: toggle(id, in: openReasoning, write: actions.setReasoningOpen),
            onSelectText: actions.onSelectText,
            toolOpen: toggle(id, in: openTools, write: actions.setToolOpen),
            showToolOutput: showToolOutput, compactTools: compactTools, wide: wide, maxBubble: maxBubble)
            // Compared by what it draws, so an unchanged message isn't rebuilt on every re-evaluation.
            .equatable()
    }

    /// A turn's tool calls folded into one line. Its open flag lives with the tool cards, so the
    /// end of the turn can fold both together, but under its own "run:" key.
    private func toolRun(_ row: TranscriptRowModel) -> some View {
        ToolRunRow(items: row.run,
                   open: toggle("run:" + row.item.id, in: openTools, write: actions.setToolOpen),
                   openSteps: openTools.intersection(row.run.map(\.id)),
                   setStepOpen: { actions.setToolOpen($0, $1) },
                   showToolOutput: showToolOutput, maxBubble: maxBubble)
            .equatable()
    }
}

/// Shows when a message was sent. On the phone the time waits just beyond the right edge until
/// the column slides left. The Mac has no slide, so hovering a message tells you instead.
private struct TimeBeside: ViewModifier {
    var date: Date

    func body(content: Content) -> some View {
        #if os(macOS)
        // Labels are made once for each minute, rather than for every row at every streamed token.
        content.help(TimeLabels.hover(date))
        #else
        content.overlay(alignment: .trailing) {
            Text(date, style: .time)
                .quiet(.caption2.monospacedDigit())
                // Starts 20 pt past the row, clear of the 16 pt screen margin, so none of it
                // stays visible until the column slides across.
                .fixedSize()
                .alignmentGuide(.trailing) { $0[.leading] - 20 }
                .accessibilityHidden(true)
        }
        #endif
    }
}

/// The older rows of the thread, lazily laid out. This view is equal while its rows and their
/// context are, so a reply streaming at the bottom never disturbs them.
@MainActor
struct OlderRows: View, Equatable {
    var rows: [TranscriptRowModel]
    var context: RowContext

    static func == (lhs: OlderRows, rhs: OlderRows) -> Bool {
        lhs.context == rhs.context && lhs.rows == rhs.rows
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(rows) { row in context.rowView(row) }
        }
        .scrollTargetLayout(isEnabled: context.highlightedMessage != nil)
    }
}
