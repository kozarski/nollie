#if os(macOS)
import SwiftUI
import NollieCore

/// The chat column's top left on the Mac, with a chat open or none. With the sidebar hidden it
/// holds the button that brings it back, clear of the window's own buttons (they sit further in
/// than AppKit's).
struct MacChatLeading: View {
    var body: some View {
        if MacSidebar.shared.hidden { SidebarShowButton().padding(.leading, 8) }
    }
}

/// How wide the chat column is, for the header in the window's toolbar (which does not see the
/// chat's own layout). The chat measures itself and writes it here.
@MainActor @Observable final class MacChatRoom {
    static let shared = MacChatRoom()
    var columnWidth: CGFloat = 0
}

/// How much of the toolbar a side chat's title may take. The toolbar asks the header for its
/// full width and, when that does not fit, hides the whole header behind a » button; so the
/// title gives way first and the bot's name never shrinks.
enum MacChatTitleRoom {
    /// The widest a title gets, even in a wide window.
    static let widest: CGFloat = 320
    /// Below this a title shows too little to help, so it is left out (the bot's name stays).
    static let narrowest: CGFloat = 72
    /// The chevron between the name and the title, with its spacing.
    static let chevron: CGFloat = 26

    /// The header sits centred, so the room on each side is the trailing buttons' width: the
    /// computer button and the menu, plus Watch while it shows.
    static func side(watch: Bool) -> CGFloat { watch ? 160 : 84 }

    /// The title's widest frame for a column and a bot name of these widths; nil leaves it out.
    static func cap(column: CGFloat, name: CGFloat, watch: Bool) -> CGFloat? {
        // Before the chat has measured itself, keep to the old rule.
        guard column > 0 else { return widest }
        let room = column - 2 * side(watch: watch) - name - chevron
        return room >= narrowest ? min(room, widest) : nil
    }
}

/// The chat's header on the Mac, as in the mockup: the bot's face and name. In a side chat the
/// name leads back to the bot's main chat and the chat's own title follows it, so where you are
/// and the way back are one thing.
struct MacChatTitle: View {
    @Bindable var chat: ChatSession
    var onSettings: () -> Void

    @Environment(AppModel.self) private var model

    private var bot: ProfileInfo? { chat.runtime.profiles.first { $0.name == chat.profileName } }
    private var name: String { bot?.shownName ?? chat.profileName }
    private var mainID: String? { BotsHome.shared.entry(chat.runtime, chat.profileName).storedID }
    private var presence: BotPresence {
        BotPresence(runtime: chat.runtime, profile: chat.profileName, mainID: mainID)
    }
    private var isMain: Bool { chat.title == "Bot Chat" || mainID == chat.storedID }
    @State private var nameWidth: CGFloat = 0
    private var titleCap: CGFloat? {
        MacChatTitleRoom.cap(column: MacChatRoom.shared.columnWidth, name: nameWidth, watch: WatchPill.isShown(for: chat))
    }

    var body: some View {
        HStack(spacing: 8) {
            nameButton
                // The name is never cut short; a side chat's title gives way instead.
                .fixedSize()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { nameWidth = $0 }
            if !isMain, let titleCap {
                Glyph("chevron.right", .system(size: 10, weight: .semibold), Ink.text3)
                    .accessibilityHidden(true)
                Text(MainChatCard.shownTitle(chat.title))
                    .font(Ink.headerName.weight(.regular))
                    .foregroundStyle(Ink.text2)
                    .lineLimit(1)
                    .frame(maxWidth: titleCap, alignment: .leading)
                    .help(MainChatCard.shownTitle(chat.title))
                    .accessibilityIdentifier("chat.title")
            }
        }
        .padding(.leading, 4)
    }

    private var nameButton: some View {
        Button {
            if isMain { onSettings() } else { Task { _ = await model.openMainChat(chat.profileName) } }
        } label: {
            HStack(spacing: 10) {
                BotAvatar(profile: chat.profileName, size: 26,
                          state: chat.botState == .idle && presence.working ? .working : chat.botState)
                    // Only a picture; the button takes the click.
                    .allowsHitTesting(false)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(Ink.headerName).foregroundStyle(Ink.text).lineLimit(1)
                    if presence.working {
                        Text(BotActivity.line(presence)).font(.caption).foregroundStyle(Ink.text3).lineLimit(1)
                            .accessibilityIdentifier("chat.activity.status")
                    }
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(isMain ? "\(name)'s settings" : "Back to \(name)'s main chat")
        .accessibilityLabel(isMain ? name : String(localized: "Back to \(name)'s main chat"))
        .accessibilityIdentifier("chat.bot")
    }
}
#endif
