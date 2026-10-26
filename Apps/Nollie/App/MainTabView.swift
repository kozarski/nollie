import SwiftUI
import NollieCore

/// The phone's and iPad's main screen: the chats (`ChatsRoot`, one stack on a narrow screen, the list
/// beside the chat on a wide one), with Settings, the Board and Tasks opening above them as sheets.
/// The chats keep the open conversation, scroll position and draft while a utility page is up.
/// There is no bottom tab bar.
struct MainTabView: View {
    @Environment(AppModel.self) private var model
    @State private var page: Page?
    /// Opens Papertrail beside the chat on a wide screen (see `ChatsRoot`).
    @State private var papertrailBeside: UUID?
    /// Whether the chats sit beside the list right now.
    @State private var chatsWide = false

    private enum Page: String, Identifiable {
        case settings, board, schedules
        var id: String { rawValue }

        /// The page that a tab selection stands for. Chats has none; it is the screen underneath.
        init?(_ tab: AppModel.AppTab) {
            switch tab {
            case .settings: self = .settings
            case .cron: self = .schedules
            case .kanban: self = .board
            case .chats, .bots: return nil
            }
        }
    }

    var body: some View {
        chats
            .modifier(BotSheetHost())
            .sheet(item: $page, onDismiss: returnToChats) { content(for: $0).withAppModel() }
            .onChange(of: model.selectedTab, initial: true) { follow(model.selectedTab) }
            .onChange(of: model.pendingRoute) { clearPage(if: model.pendingRoute != nil) }
            .onChange(of: model.newChatRequest) { clearPage(if: model.newChatRequest != nil) }
            .onChange(of: model.lock.isLocked) { clearPage(if: model.lock.isLocked) }
            .onChange(of: model.signInPrompt.isEmpty) { clearPage(if: !model.signInPrompt.isEmpty) }
    }

    @ViewBuilder private var chats: some View {
        #if os(iOS)
        ChatsRoot(papertrailRequest: papertrailBeside, isWide: $chatsWide)
        #else
        ChatListView()
        #endif
    }

    private func clearPage(if condition: Bool) {
        if condition { page = nil }
    }

    private func returnToChats() {
        if Page(model.selectedTab) != nil { model.selectedTab = .chats }
    }

    /// Older links and shared controls still ask for a destination through the selected tab.
    private func follow(_ tab: AppModel.AppTab) {
        guard let wanted = Page(tab) else {
            page = nil
            if tab != .chats { model.selectedTab = .chats }
            return
        }
        if wanted == .board, model.runtime?.kanban.isPresent != true {
            model.selectedTab = .chats
        } else if wanted == .settings, chatsWide, model.papertrailRequest != nil {
            // Papertrail from the search field: on a wide screen it opens beside the chat instead.
            // Settings keeps the request when the chats are too narrow for that.
            model.papertrailRequest = nil
            papertrailBeside = UUID()
            model.selectedTab = .chats
        } else {
            page = wanted
        }
    }

    @ViewBuilder private func content(for page: Page) -> some View {
        switch page {
        case .settings:
            SettingsView(onClose: { model.selectedTab = .chats }).withAppModel()
        case .board:
            NavigationStack {
                KanbanView(embedded: true)
                    .navigationTitle("Board")
                    .toolbar { doneButton(id: "board.close") }
            }
            .withAppModel()
        case .schedules:
            NavigationStack {
                CronView().toolbar { doneButton(id: "schedules.close") }
            }
            .withAppModel()
        }
    }

    @ToolbarContentBuilder private func doneButton(id: String) -> some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button("Done") { model.selectedTab = .chats }.testID(id)
        }
    }
}
