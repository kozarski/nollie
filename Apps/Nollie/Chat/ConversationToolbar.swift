import SwiftUI
import NollieCore

#if os(macOS)
/// The Mac window's toolbar for a chat: the sidebar button, the identity centred, Watch, the
/// computer switch and the menu.
struct ConversationToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model
    var chat: ChatSession
    var actions: ConversationActions

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) { MacChatLeading() }.sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .principal) { MacChatTitle(chat: chat) { actions.show(.profile) } }
            .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .primaryAction) {
            WatchPill(chat: chat) { if !model.awayBlocks() { actions.show(.watch) } }
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .primaryAction) {
            ComputerControlsButton(profile: chat.profileName) { actions.show(.computer) }
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .primaryAction) { more }.sharedBackgroundVisibility(.hidden)
    }

    private var more: some View {
        Menu {
            ChatMenuItems(chat: chat, onProfile: { actions.show(.profile) }, onRename: { actions.show(.rename) },
                          onContext: { actions.show(.context) }, onEditBot: { actions.show(.profile) },
                          onNewChat: actions.newChat, onClose: actions.close)
        } label: { Label("More", systemImage: "ellipsis") }
        .labelStyle(.iconOnly)
        .menuStyle(.button)
        .buttonStyle(HeaderIconStyle())
        .menuIndicator(.hidden)
        .help("History, Board, Schedules, what it knows, settings")
        .accessibilityIdentifier("chat.more")
    }
}
#endif
