import SwiftUI
import NollieCore

/// A bot's character in the list. It shows what it is doing by itself: working, it moves (the
/// routine for that kind of work); waiting on you, it wears its needs-you pose; idle, it holds
/// still and costs nothing. Only a photo, which can't move, gets a ring: a short arc of the bot's
/// colour circling it while the bot works, and a motionless ring when it needs you.
struct BotPresenceAvatar: View {
    var profile: String
    var size: CGFloat
    var working = false
    var needsYou = false
    /// What the working chat is doing, for the character's pose (thinking, a tool, writing).
    var state: CharacterState? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Watched so a bot changed to or from a photo redraws here at once.
    @AppStorage(BotAvatarStore.storageKey) private var avatarsRaw = ""

    private var busy: Bool { working || needsYou }
    private var shownState: CharacterState {
        if needsYou { return .needsYou }
        guard working else { return .idle }
        // Busy on the gateway while its chat here reads idle: it still works.
        if let state, state != .idle { return state }
        return .working
    }
    /// The bot wears a photo (which can't animate), not one of the characters.
    private var isPhoto: Bool {
        _ = avatarsRaw
        return BotAvatarStore.showsPhoto(profile)
    }

    var body: some View {
        if isPhoto { ringed } else {
            BotAvatar(profile: profile, size: size, state: shownState)
                .frame(square: size)
                // Only a picture: a gesture on the character would go first and keep the row or
                // pinned tile around it from opening the chat. The row or tile is the one target.
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// A photo: smaller inside the ring while it works or waits.
    private var ringed: some View {
        ZStack {
            BotAvatar(profile: profile, size: busy ? size * 0.81 : size, state: shownState)
            if needsYou {
                Circle().strokeBorder(Ink.warnText, lineWidth: max(1.5, size * 0.046))
                    .padding(size * 0.02)
            } else if working {
                if reduceMotion {
                    arc(at: -60)
                } else {
                    TimelineView(.animation(minimumInterval: 1 / 40)) { context in
                        let t = context.date.timeIntervalSinceReferenceDate
                        arc(at: t.truncatingRemainder(dividingBy: 1.4) / 1.4 * 360 - 60)
                    }
                }
            }
        }
        .frame(square: size)
        .animation(.snappy(duration: 0.3), value: busy)
        // Only a picture, as above: the row or tile takes the tap.
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// A photo's working mark: a quarter of a circle, round-capped, in the bot's colour.
    private func arc(at degrees: Double) -> some View {
        Circle()
            .trim(from: 0, to: 0.24)
            .stroke(BotColors.color(for: profile), style: StrokeStyle(lineWidth: max(1.5, size * 0.046), lineCap: .round))
            .rotationEffect(.degrees(degrees))
            .padding(size * 0.031)
            .allowsHitTesting(false)
    }
}

/// The few words on a bot's row about its current work. Order of preference: the goal summed up
/// by the on-device model, the step the gateway reported, then a plain "Working…".
@MainActor
enum BotActivity {
    static func line(_ presence: BotPresence) -> String {
        guard let live = presence.live else { return presence.onBoard ? String(localized: "Working on a task…") : String(localized: "Working…") }
        // Held on an approval it is waiting on the person, not typing (the Mac's header reads this).
        if live.botState == .needsYou { return String(localized: "Needs your OK") }
        if let goal = ChatGoals.shared.goal(for: live.storedID), !goal.isEmpty { return goal }
        if live.botState == .thinking { return String(localized: "Thinking…") }
        return humanize(live.statusLine)
    }

    /// The gateway's step in plain words: "Running computer_use…" reads "Using your Mac…", and a
    /// Cua Spaces tool ("mcp__cua__space_bash") "Using its own computer…".
    static func humanize(_ status: String?) -> String {
        let s = (status ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s.hasPrefix("Writing") || s.hasPrefix("Replying") || s.hasPrefix("Streaming") { return String(localized: "Typing…", comment: "A bot is writing its reply") }
        let lower = s.lowercased()
        // The keys are the gateway's tool names; only the phrases are shown.
        let words: [(String, String)] = [
            ("request_sign_in", String(localized: "Signing in…")), ("cua_recorder", String(localized: "Recording the screen…")),
            ("mcp__cua__", String(localized: "Using its own computer…")),
            ("computer_use", String(localized: "Using your Mac…")), ("browser", String(localized: "Browsing…")),
            ("web_search", String(localized: "Searching the web…")), ("web_fetch", String(localized: "Reading a page…")),
            ("terminal", String(localized: "Running a command…")),
            ("read_file", String(localized: "Reading files…")), ("write_file", String(localized: "Writing a file…")),
            ("patch", String(localized: "Editing a file…")),
            ("kanban", String(localized: "Checking the board…")), ("cron", String(localized: "Checking schedules…")),
            ("memory", String(localized: "Remembering…")),
            ("delegate", String(localized: "Asking a helper…")), ("send_message", String(localized: "Sending a message…")),
            ("image", String(localized: "Looking at a picture…")),
        ]
        if lower.hasPrefix("running ") || lower.hasPrefix("preparing ") {
            for (key, phrase) in words where lower.contains(key) { return phrase }
        }
        let shown = ChatSession.statusWords(s)
        return shown.hasSuffix("…") || shown.hasSuffix("...") ? shown : shown + "…"
    }
}

/// One bot in the list, as the mockup drew it: the face, the name and when it last spoke on one
/// line, and under it the last thing it said, what it is doing while it works, that it waits on
/// Corey, or, for a bot that keeps to this Mac, only that.
struct BotListRow: View {
    let runtime: GatewayRuntime
    let profile: ProfileInfo
    var entry: BotsHome.Entry
    var unread = false
    var selected = false
    var pinned = false
    @State private var hovering = false
    @Environment(\.dynamicTypeSize) private var typeSize

    /// At the largest text sizes the time goes under the name, and the name and the last line may
    /// take two lines, so a narrow sidebar never cuts a name to "Def…".
    private var large: Bool { typeSize.isAccessibilitySize }

    var body: some View {
        let presence = BotPresence(runtime: runtime, profile: profile.name, mainID: entry.storedID, remoteBusy: entry.busy)
        HStack(spacing: 12) {
            BotPresenceAvatar(profile: profile.name, size: Ink.rowAvatar, working: presence.working, needsYou: presence.needsYou, state: presence.live?.botState)
            VStack(alignment: .leading, spacing: 2) {
                let top = large ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                    : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 6))
                top {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: large ? LineBreaks.wholeWords(profile.shownName) : profile.shownName)
                            .font(Ink.rowName)
                            .foregroundStyle(Ink.text)
                            .lineLimit(large ? 2 : 1)
                        if pinned {
                            Image(systemName: "pin.fill")
                                .font(.caption2)
                                .foregroundStyle(Ink.text3)
                                .accessibilityHidden(true)
                        }
                    }
                    if !large { Spacer(minLength: 4) }
                    if presence.working {
                        Text("Now").font(Ink.rowTime).foregroundStyle(Ink.text3)
                    } else if let d = entry.lastDate {
                        Text(BotsHome.when(d))
                            .font(Ink.rowTime)
                            .foregroundStyle(unread && !selected ? Color.nollie : Ink.text3)
                            .lineLimit(1)
                            .monospacedDigit()
                    }
                }
                preview(presence)
            }
        }
        .inset(h: 12, v: 11)
        .background(selected ? Ink.selected : (hovering ? Ink.hover : Color.clear), in: highlight)
        // Messages' unread dot, in the margin before the face.
        .overlay(alignment: .leading) {
            if unread && !selected {
                Circle().fill(Color.nollie).frame(square: 7).offset(x: 2.5)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(.rect(cornerRadius: 12, style: .continuous))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(profile.shownName)
        .accessibilityValue([pinned ? String(localized: "Pinned") : nil, presence.needsYou ? String(localized: "needs your OK") : nil,
                             presence.working ? BotActivity.line(presence) : nil,
                             unread ? String(localized: "new message") : nil, isPrivate ? nil : entry.lastText].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Opens your chat with \(profile.shownName).")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("bots.row.\(profile.name)")
    }

    /// The open bot's soft highlight: a pill beside a chat on iPhone and iPad, as their sidebars draw it.
    private var highlight: AnyShape {
        #if os(iOS)
        // A row of several lines at the largest sizes gets soft corners, not a circle's ends.
        large ? AnyShape(.rect(cornerRadius: 22, style: .continuous)) : AnyShape(Capsule())
        #else
        AnyShape(.rect(cornerRadius: 12, style: .continuous))
        #endif
    }

    @ViewBuilder private func preview(_ presence: BotPresence) -> some View {
        Group {
            if presence.needsYou {
                HStack(spacing: 5) {
                    Circle().fill(Ink.warnText).frame(square: 6)
                    Text("Needs your OK")
                }
                .foregroundStyle(Ink.warnText)
            } else if presence.working {
                Text(BotActivity.line(presence))
                    .foregroundStyle(Ink.text3)
                    .contentTransition(.opacity)
            } else if isPrivate {
                HStack(spacing: 5) {
                    Image(systemName: "lock.fill").font(.system(size: 10, weight: .semibold))
                    Text("Private, stays on this Mac")
                }
                .foregroundStyle(Ink.text2)
            } else {
                Text(lastLine)
                    .foregroundStyle(Ink.text2)
            }
        }
        .font(Ink.rowPreview)
        .lineLimit(large ? 2 : 1)
        .truncationMode(.tail)
    }

    private var isPrivate: Bool { profile.isPrivateBot(on: runtime.connection.id) }

    private var lastLine: String {
        if let t = entry.lastText, !t.isEmpty { return t }
        if entry.storedID == nil { return String(localized: "Say hello to start your chat.") }
        if let d = profile.description, !d.isEmpty { return d }
        return String(localized: "No messages yet.")
    }
}

/// A pinned bot on the phone: its face big and its name under it, Grok's favourites row.
struct BotTile: View {
    let runtime: GatewayRuntime
    let profile: ProfileInfo
    var entry: BotsHome.Entry
    var star = false
    var unread = false

    static let avatar: CGFloat = 64

    var body: some View {
        let presence = BotPresence(runtime: runtime, profile: profile.name, mainID: entry.storedID, remoteBusy: entry.busy)
        VStack(spacing: 7) {
            BotPresenceAvatar(profile: profile.name, size: Self.avatar, working: presence.working, needsYou: presence.needsYou, state: presence.live?.botState)
                .overlay(alignment: .bottomTrailing) {
                    if star {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(square: 21)
                            .background(Circle().fill(Color.orange))
                            .overlay(Circle().strokeBorder(Ink.canvas, lineWidth: 2))
                            .offset(x: 2, y: 2)
                            .accessibilityHidden(true)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if unread {
                        Circle().fill(Color.nollie).frame(square: 12)
                            .overlay(Circle().strokeBorder(Ink.canvas, lineWidth: 2))
                            .accessibilityHidden(true)
                    }
                }
            Text(profile.shownName)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Ink.text)
                .lineLimit(1)
        }
        .frame(width: 84)
        .inset(v: 8)
        .contentShape(.rect(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(profile.shownName)
        .accessibilityValue([presence.needsYou ? String(localized: "needs your OK") : nil,
                             presence.working ? String(localized: "working", comment: "A bot's state, read by VoiceOver") : nil,
                             unread ? String(localized: "new message") : nil].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Opens your chat with \(profile.shownName).")
        .accessibilityIdentifier("bots.pinned.\(profile.name)")
    }
}

/// A row's press on the phone: a soft shade while held. On the Mac the row's own hover and
/// selection say enough.
struct BotRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            #if os(iOS)
            .background(Ink.hover.opacity(configuration.isPressed ? 1 : 0), in: .rect(cornerRadius: 16, style: .continuous))
            #endif
            .contentShape(.rect)
    }
}

#if os(iOS)
/// A quiet row in the sidebar for a place or an action (Board, New bot, Settings): its symbol where
/// a bot's face would be, so the words line up with the bots' names.
struct SidebarActionRow<Trailing: View>: View {
    var title: String
    var symbol: String
    var action: () -> Void
    @ViewBuilder var trailing: Trailing

    init(title: String, symbol: String, action: @escaping () -> Void, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.symbol = symbol
        self.action = action
        self.trailing = trailing()
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(Ink.text2)
                    .frame(width: Ink.rowAvatar)
                    .accessibilityHidden(true)
                Text(title).font(.body.weight(.medium)).foregroundStyle(Ink.text)
                Spacer(minLength: 0)
                trailing
            }
            .inset(h: 12, v: 10)
            .frame(minHeight: 44)
        }
        .buttonStyle(BotRowButtonStyle())
    }
}
#endif
