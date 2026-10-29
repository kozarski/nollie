import SwiftUI
import NollieCore

/// What the header and its menu share about a chat.
private extension ChatSession {
    /// The bot's display name, falling back to its profile name.
    var botDisplayName: String {
        runtime.profiles.first(where: { $0.name == profileName })?.shownName ?? profileName
    }
}

/// Cuts text to `keep` characters plus an ellipsis, but only when it is longer than `limit`.
private func shortened(_ text: String, limit: Int, keep: Int, trimming: Bool = false) -> String {
    guard text.count > limit else { return text }
    let head = String(text.prefix(keep))
    return (trimming ? head.trimmingCharacters(in: .whitespaces) : head) + "…"
}

/// The header floating above a chat, modelled on Messages. It has a glass circle for Back, a middle
/// pill showing the avatar over the name (and a status line during work), and a circle for the menu.
struct ChatHeader: View {
    typealias Action = () -> Void

    let chat: ChatSession
    let onBack: Action
    let onProfile: Action
    let onComputer: Action
    let onRename: Action
    let onContext: Action
    let onEditBot: Action
    let onNewChat: Action
    let onClose: Action

    init(chat: ChatSession, onBack: @escaping Action, onProfile: @escaping Action,
         onComputer: @escaping Action = {}, onRename: @escaping Action, onContext: @escaping Action,
         onEditBot: @escaping Action = {}, onNewChat: @escaping Action, onClose: @escaping Action) {
        self.chat = chat
        self.onBack = onBack
        self.onProfile = onProfile
        self.onComputer = onComputer
        self.onRename = onRename
        self.onContext = onContext
        self.onEditBot = onEditBot
        self.onNewChat = onNewChat
        self.onClose = onClose
    }

    /// Sends VoiceOver to Back on opening. Left alone it would start on the earliest
    /// message, because the header comes last in the screen's reading order (`ConversationTopBar`).
    @AccessibilityFocusState private var backFocused: Bool
    /// Beside the list there is nowhere to go back to; the list itself switches chats.
    @Environment(\.chatOpensBeside) private var besideList

    /// On a member's phone: no computer, no bot info, only their own chat.
    @Environment(\.familyOwner) private var familyOwner

    var body: some View {
        // Deliberately not inside a glass container: that draws its glass above everything and
        // would hide the bot standing on the pill.
        HStack(alignment: .top, spacing: 12) {
            backButton
            Spacer(minLength: 0)
            ChatHeaderPill(chat: chat, onProfile: familyOwner == nil ? onProfile : {}, onRename: onRename)
            Spacer(minLength: 0)
            trailing
        }
        .inset(h: 16)
        .padding(.top, 4)
        // The whole bar swallows taps, so none fall through to the thread (and open a tool card).
        .contentShape(.rect)
        .onTapGesture {}
        .task(focusBackAfterPush)
    }

    /// VoiceOver moves to the first element when the push animation ends, and would override
    /// anything asked for sooner, so wait it out.
    @Sendable private func focusBackAfterPush() async {
        try? await Task.sleep(nanoseconds: 600_000_000)
        await MainActor.run { backFocused = true }
    }

    /// Back, or beside the list an empty slot of the same width, which keeps the pill centred.
    private var backButton: some View {
        Group {
            if besideList {
                Color.clear.frame(height: 44)
            } else {
                HeaderCircle(symbol: "chevron.left", action: onBack)
                    .accessibilityLabel("Back")
                    .accessibilityIdentifier("chat.back")
                    .accessibilityFocused($backFocused)
            }
        }
        .frame(width: 100, alignment: .leading)
    }

    private var trailing: some View {
        HStack(spacing: 12) {
            if familyOwner == nil { ComputerControlsButton(profile: chat.profileName, action: onComputer) }
            Menu {
                ChatMenuItems(chat: chat, onProfile: onProfile, onRename: onRename, onContext: onContext,
                              onEditBot: onEditBot, onNewChat: onNewChat, onClose: onClose)
            } label: {
                HeaderCircle.face("ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.more")
        }
    }
}

/// A round glass button, 44 points across, holding one symbol.
private struct HeaderCircle: View {
    var symbol: String
    var action: () -> Void

    /// The symbol stops growing at the largest standard text size so it stays inside its circle;
    /// a long press shows it large, as bar buttons do.
    static func face(_ symbol: String) -> some View {
        Glyph(symbol, .title3.weight(.semibold))
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .frame(square: 44)
            .nollieGlass(.regular.interactive(), in: .circle)
            .accessibilityShowsLargeContentViewer()
    }

    var body: some View {
        PlainButton(action: action) { Self.face(symbol) }
    }
}

/// The centre of the header: the bot standing on a plate with the chat's name and what it is up to.
private struct ChatHeaderPill: View {
    var chat: ChatSession
    var onProfile: () -> Void
    var onRename: () -> Void

    @AppStorage(ChatStyle.headerShowsTitle) private var headerShowsTitle = false
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Flips on first appearance so the bot fades in, as a contact photo does in Messages.
    @State private var popped = false

    /// The line under the name, plus the goal (when one is shown) so a change can animate.
    private struct StatusLine {
        var text: String
        var goal: String? = nil
    }

    /// The main chat is called "Main chat" in the header.
    private var shownTitle: String { MainChatCard.shownTitle(chat.title) }

    private var workingOnComputer: Bool {
        let now = BotComputerActivity.status(runtime: chat.runtime, profile: chat.profileName)
        return now == .working || now == .usingComputer
    }

    /// The chat's own state, except that a quiet chat whose bot is busy on its computer looks busy.
    private var botState: CharacterState {
        if chat.botState == .idle && workingOnComputer { return .working }
        return chat.botState
    }

    private var status: StatusLine {
        if chat.isRunning {
            // Use the goal that the device model wrote, falling back to the current step.
            let goal = ChatGoals.shared.goal(for: chat.storedID)
            return StatusLine(text: goal ?? chat.statusWords ?? String(localized: "Thinking…"), goal: goal)
        }
        if workingOnComputer { return StatusLine(text: String(localized: "Working…")) }
        if chat.isResuming { return StatusLine(text: String(localized: "Syncing…")) }
        if headerShowsTitle { return StatusLine(text: chat.subtitle) }
        return StatusLine(text: shortened(shownTitle, limit: 30, keep: 29))
    }

    var body: some View {
        PlainButton(action: openCard, label: { stage })
            // Offered its full width before the spacers divide what remains, so only text that
            // truly does not fit gets cut.
            .layoutPriority(1)
            .onAppear(perform: popIn)
            .contextMenu { pressMenu }
            .accessibilityLabel("Chat info: \(shownTitle), \(chat.subtitle)")
            .accessibilityValue(!chat.isRunning && workingOnComputer ? "Working on a task" : "")
            // Reads as a heading, like a navigation title, so the rotor can jump to it.
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("chat.titlePill")
    }

    private func popIn() {
        withAnimation(.easeOut(duration: 0.25).delay(0.05)) { popped = true }
    }

    @ViewBuilder private var pressMenu: some View {
        Button(action: onRename) { Label("Rename chat", systemImage: "pencil") }
        Button(action: onProfile) { Label("Bot info", systemImage: "person.text.rectangle") }
    }

    private func openCard() {
        BotAmbient.shared.tap(profile: chat.profileName)
        onProfile()
    }

    /// Bot above plate; its feet overlap the plate's top edge by a few points.
    private var stage: some View {
        let overlap = BotAvatarStore.seat(for: chat.profileName, size: 52, overlap: 8)
        return VStack(spacing: -overlap) {
            BotAvatar(profile: chat.profileName, size: 52, state: botState)
                .opacity(popped ? 1 : 0)
                .zIndex(1)
                .allowsHitTesting(false)   // the plate and bot are a single tap target
            plate
        }
        .contentShape(.rect)
    }

    private func nameText(_ name: String) -> some View {
        Text(shortened(name, limit: 26, keep: 25))
            .font(.caption.weight(.semibold))
            .multilineTextAlignment(.center)
    }

    /// At the accessibility text sizes the pill keeps the name whole: it may take two lines and
    /// shrink a little, and the status line steps aside (the bot's pose still shows it, and
    /// VoiceOver still reads it).
    private var roomy: Bool { !typeSize.isAccessibilitySize }

    private var plate: some View {
        let line = status
        let name = headerShowsTitle ? shownTitle : chat.botDisplayName
        return VStack(spacing: 1) {
            // Hugs its text like Messages does. The cut happens in code because a max-width
            // frame would widen the pill to the full screen.
            HStack(spacing: 3) {
                if roomy {
                    nameText(name).lineLimit(1)
                    Glyph("chevron.right", .caption2.weight(.bold), .secondary)
                } else {
                    // On one line when it fits, else on two, broken between words where it can be.
                    ViewThatFits(in: .horizontal) {
                        nameText(name).lineLimit(1)
                        nameText(name).lineLimit(2).minimumScaleFactor(0.7)
                    }
                }
            }
            if roomy {
                // A compaction notice can be a whole sentence, so cut this line the same way.
                Text(shortened(line.text, limit: 42, keep: 41, trimming: true))
                    .quiet(.caption2)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: [chat.statusLine, line.goal, String(chat.botState == .needsYou)])
            }
        }
        // Grows with the text up to a size that still fits between the circles.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .padding(EdgeInsets(top: 11, leading: 14, bottom: 6, trailing: 14))
        // Keeps its natural height yet stays within the space between the circles, so large text is cut with
        // "…". A pill that held its width once shoved the back circle off screen.
        .fixedSize(horizontal: false, vertical: true)
        .nollieGlass(.regular.interactive(), in: .capsule)
    }
}

/// Opens the computer controls for this bot. It does not change what the bot may touch.
struct ComputerControlsButton: View {
    var profile: String
    var action: () -> Void

    @Environment(AppModel.self) private var model

    private var inUse: Bool {
        guard let runtime = model.runtime else { return false }
        return BotComputerActivity.isActive(runtime: runtime, profile: profile)
    }

    var body: some View {
        Button(action: action) { icon }
            #if os(macOS)
            .buttonStyle(HeaderIconStyle())
            #else
            .buttonStyle(.plain)
            #endif
            .help("Computer controls")
            .accessibilityLabel("Computer controls")
            .accessibilityValue(inUse ? "In use" : "Idle")
            .accessibilityIdentifier("bot.computer")
    }

    private var icon: some View {
        Label("Computer", systemImage: "desktopcomputer")
            .labelStyle(.iconOnly)
            .foregroundStyle(inUse ? Color.blue : Color.primary)
            .shadow(color: inUse ? .blue.opacity(0.55) : .clear, radius: 6)
            #if os(iOS)
            .font(.title3)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .frame(square: 44)
            .nollieGlass(.regular.interactive(), in: .circle)
            .background(inUse ? Color.blue.opacity(0.12) : Color.clear, in: .circle)
            .accessibilityShowsLargeContentViewer()
            #endif
    }
}

/// The chat menu on phone and Mac. The bot's own entries come first (history, board, schedules,
/// what it knows, a side chat, settings), then a "This chat" submenu for this conversation.
struct ChatMenuItems: View {
    let chat: ChatSession
    let onProfile: () -> Void
    let onRename: () -> Void
    let onContext: () -> Void
    let onEditBot: () -> Void
    let onNewChat: () -> Void
    let onClose: () -> Void

    init(chat: ChatSession, onProfile: @escaping () -> Void, onRename: @escaping () -> Void,
         onContext: @escaping () -> Void, onEditBot: @escaping () -> Void = {},
         onNewChat: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.chat = chat
        self.onProfile = onProfile
        self.onRename = onRename
        self.onContext = onContext
        self.onEditBot = onEditBot
        self.onNewChat = onNewChat
        self.onClose = onClose
    }

    private var contextTitle: String {
        guard let percent = chat.usage?.computedContextPercent else { return String(localized: "Context usage") }
        return String(localized: "Context usage · \(percent)%")
    }

    private var showsShortcuts: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    var body: some View {
        BotMenuItems(profile: chat.profileName, label: chat.botDisplayName, chatID: chat.storedID,
                     shortcuts: showsShortcuts)
        Divider()
        Menu { thisChatItems } label: { Label("This chat", systemImage: "bubble.left") }
    }

    /// On a member's phone, the owner's model choices stay the owner's.
    @Environment(\.familyOwner) private var familyOwner

    @ViewBuilder private var thisChatItems: some View {
        if familyOwner == nil {
            ReasoningEffortMenu(chat: chat)
            ChatModeToggles(chat: chat)
        }
        entry(String(localized: "Rename…"), "pencil", onRename)
        entry(contextTitle, "gauge.with.dots.needle.33percent", onContext)
        Divider()
        Button(role: .destructive, action: onClose) { Label("Close chat", systemImage: "xmark.circle") }
    }

    private func entry(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol) }
    }
}
