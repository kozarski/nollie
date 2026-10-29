import SwiftUI
import NollieCore

/// What kind of row an item is, decided once so drawing can switch on one value.
private enum RowShape {
    case injectedNote(InjectedNote)
    case botMessage(AgentMessage)
    case person(String, [AttachmentPreview])
    case interrupted(InterruptedTurn)
    case reply(String, reasoning: String?, streaming: Bool)
    case steer(String, status: String)
    case crewNote(CrewNote)
    case delivery(ToolActivity)
    case tool(ToolActivity)
    case terminal(String)
    case notice(String, symbol: String)
    case startFailure(StartFailure, raw: String)
    case failure(String)
    case helper(SubagentActivity)

    init(_ kind: TranscriptItem.Kind) {
        switch kind {
        case .user(let text, let files):
            self = Self.fromPerson(text, files)
        case .assistant(let text, let reasoning, let streaming):
            let cutShort = streaming ? nil : InterruptedTurn.parse(text)
            self = cutShort.map(RowShape.interrupted) ?? .reply(text, reasoning: reasoning, streaming: streaming)
        case .steer(let text, let status):
            self = .steer(text, status: status)
        case .tool(let activity):
            self = Self.fromTool(activity)
        case .system(let text, let symbol):
            self = symbol == "terminal" ? .terminal(text) : .notice(text, symbol: symbol)
        case .error(let text):
            self = StartFailure.parse(text).map { .startFailure($0, raw: text) } ?? .failure(text)
        case .subagent(let helper):
            self = .helper(helper)
        }
    }

    /// A "user" row can really be the gateway or another bot talking, when nothing is attached.
    private static func fromPerson(_ text: String, _ files: [AttachmentPreview]) -> RowShape {
        guard files.isEmpty else { return .person(text, files) }
        if let note = InjectedNote.parse(text) { return .injectedNote(note) }
        if let message = AgentMessage.parse(text) { return .botMessage(message) }
        return .person(text, files)
    }

    private static func fromTool(_ activity: ToolActivity) -> RowShape {
        if let note = activity.crewNote { return .crewNote(note) }
        return activity.delivery == nil ? .tool(activity) : .delivery(activity)
    }
}

/// One entry in the thread, drawn to suit its kind: your bubble, the bot's reply, a steer, a tool
/// card, a note or an error. Equatable on what it draws, so a scroll or a new token doesn't
/// rebuild rows whose message stayed the same.
struct TranscriptRow: View, Equatable {
    var item: TranscriptItem
    /// Which bot to draw beside the bubble, or nil for none. Within a run of replies just the final one
    /// displays it (`botShown`) while the rest keep the same left margin.
    var profile: String? = nil
    /// This chat's own bot; pictures always need it to locate the gateway's images folder.
    var bot: String? = nil
    var botShown: Bool = true
    /// While a reply is being written: nil gives the grey typing bubble, a tool name gives the dark
    /// one with that tool's badge.
    var typingTool: String? = nil
    var showReasoning: Bool = true
    var showStats: Bool = true
    var onEdit: RowActions.WithText = { _ in }
    var onOpenBot: RowActions.WithText = { _ in }
    var onReply: RowActions.WithText = { _ in }
    /// When the gateway cut a turn short: the reason if this device knows it, and a way to the setting.
    var interruptCause: InterruptedTurn.Cause? = nil
    var onKeepRunning: () -> Void = {}
    var reasoningOpen: Binding<Bool> = Binding.constant(false)
    var onSelectText: RowActions.WithText = { _ in }
    var toolOpen: Binding<Bool> = .constant(false)
    var showToolOutput: Bool = true
    var compactTools: Bool = false
    /// Lets reply bubbles stretch to the right edge.
    var wide: Bool = false
    /// Largest width for a bubble or card; on the Mac this is its portion of the reading column.
    var maxBubble: CGFloat = .infinity

    @AppStorage(ChatStyle.bubbleStyle) private var bubbleStyle = "rounded"
    @AppStorage(ChatStyle.botTint) private var botTint = false
    @AppStorage(ChatStyle.userBubble) private var userBubble = "ink"
    @Environment(\.colorScheme) private var scheme

    static func == (lhs: TranscriptRow, rhs: TranscriptRow) -> Bool {
        lhs.item == rhs.item
            && lhs.sameSetting(as: rhs)
            && lhs.reasoningOpen.wrappedValue == rhs.reasoningOpen.wrappedValue
            && lhs.toolOpen.wrappedValue == rhs.toolOpen.wrappedValue
    }

    private func sameSetting(as other: TranscriptRow) -> Bool {
        profile == other.profile && bot == other.bot && botShown == other.botShown
            && typingTool == other.typingTool && interruptCause == other.interruptCause
            && showReasoning == other.showReasoning && showStats == other.showStats
            && showToolOutput == other.showToolOutput && compactTools == other.compactTools
            && wide == other.wide && maxBubble == other.maxBubble
    }

    private var look: BubbleLook {
        BubbleLook(style: bubbleStyle, tinted: botTint, inkForMe: userBubble == "ink", profile: profile, dark: scheme == .dark)
    }

    var body: some View {
        placed
            .onChange(of: item.kind) { old, new in
                guard let heard = ReplyArrival.announcement(from: old, to: new) else { return }
                AccessibilityNotification.Announcement(heard).post()
            }
    }

    // MARK: Placement

    @ViewBuilder private var placed: some View {
        #if os(macOS)
        // As in Messages, yours goes right and the bot's goes left, each inside its share of the
        // column. Notices stay centred.
        let edge = macSide
        content
            .frame(maxWidth: widthLimit(for: edge), alignment: edge)
            .frame(maxWidth: .infinity, alignment: edge)
        #else
        content
        #endif
    }

    #if os(macOS)
    private func widthLimit(for edge: Alignment) -> CGFloat {
        switch edge {
        case .center: .infinity
        case .trailing: min(maxBubble, Ink.myBubble)
        default: maxBubble
        }
    }

    private var macSide: Alignment {
        switch RowShape(item.kind) {
        case .injectedNote, .botMessage, .delivery, .notice: .center
        case .person, .steer: .trailing
        default: .leading
        }
    }
    #endif

    // MARK: Kinds

    @ViewBuilder private var content: some View {
        let _ = Perf.tick("row")
        switch RowShape(item.kind) {
        case .injectedNote(let note):
            // The gateway talking from the person's seat, such as a background job reporting back.
            // It shows as a folded notice, not as a bubble of your own words.
            InjectedNoteRow(note: note)
        case .botMessage(let message):
            // Another bot wrote to this one: a compact notice, words folded beneath.
            BotMessageNotice(handle: message.key, label: message.sender, headline: String(localized: "Message from \(message.sender)", comment: "A bot's name follows"),
                             body: message.body, pending: false, onOpen: onOpenBot)
        case .person(let text, let files):
            PersonBubble(text: text, files: files, bot: bot, look: look, tailed: botShown,
                         onSelect: onSelectText, onEdit: onEdit, onReply: onReply)
        case .interrupted(let turn):
            InterruptedTurnCard(turn: turn, cause: interruptCause, onKeepRunning: onKeepRunning)
        case .reply(let text, let reasoning, let streaming):
            replyLine(text, reasoning: reasoning, streaming: streaming)
        case .steer(let text, let status):
            SteerBubble(text: text, status: status, onEdit: onEdit)
        case .crewNote(let note):
            CrewNoteCard(note: note, onOpenBot: onOpenBot)
        case .delivery(let activity):
            deliveryRow(activity)
        case .tool(let activity):
            ToolCardView(activity: activity, itemID: item.id, open: toolOpen, showOutput: showToolOutput, compact: compactTools)
        case .terminal(let text):
            CommandReply(text: text)
        case .notice(let text, let symbol):
            noticeLine(text, symbol: symbol)
        case .startFailure(let failure, let raw):
            StartFailureCard(failure: failure, raw: raw)
        case .failure(let text):
            failureBox(text)
        case .helper(let helper):
            SubagentRow(activity: helper)
        }
    }

    private func replyLine(_ text: String, reasoning: String?, streaming: Bool) -> some View {
        ReplyLine(item: item, text: text, reasoning: reasoning, streaming: streaming, look: look, scheme: scheme,
                  profile: profile, bot: bot, botShown: botShown, typingTool: typingTool,
                  showReasoning: showReasoning, showStats: showStats, reasoningOpen: reasoningOpen,
                  wide: wide, onSelect: onSelectText, onReply: onReply)
    }

    private func noticeLine(_ text: String, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(text)
        }
        .quiet()
        .frame(maxWidth: .infinity)
        .inset(v: 2)
    }

    private func failureBox(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.red)
            .textSelection(.enabled)
            .padding(12)
            .spread()
            .background(.red.opacity(0.12), in: .rect(cornerRadius: 16, style: .continuous))
    }

    /// A message to another bot shows "Messaging X…", then "Messaged X", followed by X's reply.
    @ViewBuilder private func deliveryRow(_ activity: ToolActivity) -> some View {
        if let sent = activity.delivery {
            let inFlight = activity.status == .running
            VStack(spacing: 4) {
                BotMessageNotice(handle: sent.target, label: sent.target,
                                 headline: inFlight ? String(localized: "Messaging \(sent.target)…", comment: "Sending a message to another bot, named after")
                                                    : String(localized: "Messaged \(sent.target)", comment: "Sent a message to another bot, named after"),
                                 body: sent.message, pending: inFlight, onOpen: onOpenBot)
                if let answer = activity.deliveryReply {
                    BotMessageNotice(handle: sent.target, label: sent.target, headline: String(localized: "Message from \(sent.target)", comment: "A bot's name follows"),
                                     body: answer, pending: false, onOpen: onOpenBot)
                }
            }
        }
    }
}

/// The three settings that style bubbles, gathered once per row.
struct BubbleLook {
    var style: String
    var tinted: Bool
    var inkForMe: Bool
    var profile: String?
    var dark: Bool

    var plain: Bool { style == "plain" }
    var tailed: Bool { style == "tailed" }

    /// Fill for the reply bubble: plain grey, or a light wash of the bot's colour.
    var replyFill: Color {
        guard tinted, let profile else { return Ink.bubble }
        return BotColors.color(for: profile).opacity(dark ? 0.22 : 0.16)
    }
}

/// The answer to a slash command, in body size, selectable, with a Copy button. A terminal mark and
/// a muted background set it apart from what the bot says.
private struct CommandReply: View {
    var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6.0) {
            Label("Command", systemImage: "terminal").quiet(.caption.weight(.semibold))
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .font(.body)
        }
        .padding(12)
        .padding(.trailing, 20)
        .spread()
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .topTrailing) { CopyButton(text: text).padding(6) }
    }
}
