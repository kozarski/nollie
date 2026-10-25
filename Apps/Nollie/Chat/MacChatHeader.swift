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

    var body: some View {
        HStack(spacing: 8) {
            nameButton
            if !isMain {
                Glyph("chevron.right", .system(size: 10, weight: .semibold), Ink.text3)
                    .accessibilityHidden(true)
                Text(MainChatCard.shownTitle(chat.title))
                    .font(Ink.headerName.weight(.regular))
                    .foregroundStyle(Ink.text2)
                    .lineLimit(1)
                    .frame(maxWidth: 320, alignment: .leading)
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
        .accessibilityLabel(isMain ? name : "Back to \(name)'s main chat")
        .accessibilityIdentifier("chat.bot")
    }
}
#endif
