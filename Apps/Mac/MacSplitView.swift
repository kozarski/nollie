import NollieCore
import SwiftUI

/// The app proper: the bot list on the left, and a chat or a page on the right. Pages (Board,
/// schedules, settings) have a way back to the chat, and administration lives inside Settings.
struct MainSplitView: View {
    @Environment(AppModel.self) private var model
    let glassPolicy: GlassAppearance.Policy

    @State private var columns = NavigationSplitViewVisibility.all
    @State private var chatPath = NavigationPath()
    @State private var firstChatOpened = false
    @AppStorage(BotsHome.pinnedKey) private var pinnedRaw = ""

    /// Everything that can change which chat should open first; when any of it changes the choice is made again.
    private struct FirstChatCues: Equatable {
        var gateway: UUID?
        var profiles: [String]
        var tab: AppModel.AppTab
        var pathEmpty: Bool
        var routePending: Bool
    }

    private var cues: FirstChatCues {
        FirstChatCues(gateway: model.runtime?.connection.id, profiles: model.runtime?.profiles.map(\.name) ?? [],
                      tab: model.selectedTab, pathEmpty: chatPath.isEmpty, routePending: model.pendingRoute != nil)
    }

    /// Pages the gateway can show right now; the Board waits for its plugin.
    private var shownPages: [AppModel.AppTab] {
        AppModel.AppTab.allCases.filter { !model.hiddenTabs.contains($0) }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            MacSidebarColumn(policy: glassPolicy, path: $chatPath)
        } detail: {
            MacDetailColumn(path: $chatPath, sidebarHidden: columns == .detailOnly)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: columns, initial: true) { _, shown in MacSidebar.shared.hidden = shown == .detailOnly }
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .scrollEdgeEffectStyle(.soft, for: .top)
        // A new identity per page drops any Settings screen pushed on the old one. The chat path and
        // the sidebar state live outside it and carry over.
        .id(model.selectedTab)
        .modifier(BotSheetHost())
        // Enough width for the sidebar plus a reading column that can hold a table.
        .frame(minWidth: 760, minHeight: 520)
        .onChange(of: shownPages) { _, pages in
            // The page on show went away (its plugin was removed), so go back to the chats.
            if !pages.contains(model.selectedTab) { model.selectedTab = .chats }
        }
        .task(id: cues) { await openFirstChat() }
        #if DEBUG
        .task { await hideSidebarForDemo() }
        #endif
    }

    #if DEBUG
    private func hideSidebarForDemo() async {
        guard DemoMode.isOn, ProcessInfo.processInfo.arguments.contains("-nollie-demo-sidebar") else { return }
        try? await Task.sleep(for: .seconds(4))
        columns = .detailOnly
    }
    #endif

    /// Opens the first visible bot once its profiles arrive, even after a slow connection. A route
    /// that is already pending, or a click somewhere else, wins over this.
    private func openFirstChat() async {
        guard !firstChatOpened, model.selectedTab == .chats, chatPath.isEmpty, model.pendingRoute == nil,
              let runtime = model.runtime, !runtime.profiles.isEmpty else { return }
        let home = BotsHome.shared
        let ordered = home.ordered(runtime)
        if let pins = home.firstPins(ordered, raw: pinnedRaw) { pinnedRaw = pins }
        guard let first = home.visibleOrder(ordered, raw: pinnedRaw).first else { return }
        let failure = await model.openMainChat(first.name)
        firstChatOpened = firstChatOpened || (!Task.isCancelled && failure == nil)
    }
}

// MARK: Sidebar

/// The bot list inside its frosted card, with the Board and New Bot buttons at the card's top right.
private struct MacSidebarColumn: View {
    @Environment(AppModel.self) private var model
    let policy: GlassAppearance.Policy
    @Binding var path: NavigationPath

    var body: some View {
        ChatListView(detailPath: $path)
            .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 4)
            .clipShape(.rect(cornerRadius: 24, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if model.runtime != nil { MacSidebarTopButtons().ignoresSafeArea(.container, edges: .top) }
            }
            .background {
                MacSidebarCard(policy: policy).padding(.top, 12).ignoresSafeArea(.container, edges: .top)
            }
            .inset(h: 12)
            .padding(.bottom, 12)
            // The window's frosting continues behind the whole column.
            .background { MacFrostedBackdrop(policy: policy).ignoresSafeArea() }
            .navigationSplitViewColumnWidth(min: 284, ideal: 300, max: 380)
            .toolbar(removing: .sidebarToggle)
    }
}

/// The Board and New Bot, level with the window's own buttons (which `OnboardingWindowSize` moves into
/// the sidebar card) and as far from the card's right edge as the search field ends.
private struct MacSidebarTopButtons: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Each has its own glass: the Board is a sideways capsule, New Bot a round button.
        HStack(spacing: 8) {
            if model.runtime?.kanban.isPresent == true {
                BoardToolbarButton().nollieGlass(.regular, in: Capsule(), solid: Ink.field)
            }
            NewBotButton().nollieGlass(.regular, in: Circle(), solid: Ink.field)
        }
        .padding(.top, 21)
        .padding(.trailing, 20)
    }
}

// MARK: Detail

/// Shows the chat while the chats page is selected, or else whatever page replaces it.
private struct MacDetailColumn: View {
    @Environment(AppModel.self) private var model
    @Binding var path: NavigationPath
    let sidebarHidden: Bool

    var body: some View {
        if model.selectedTab == .chats {
            chatStack
        } else {
            MacPageContent(tab: model.selectedTab).toolbar {
                ToolbarItem(placement: .navigation) { backToChat }.sharedBackgroundVisibility(.hidden)
            }
        }
    }

    private var chatStack: some View {
        NavigationStack(path: $path) {
            NoChatView()
                .navigationDestination(for: ChatRoute.self, destination: chat(for:))
        }
        .toolbar(removing: .title)
    }

    /// No back chevron here; the chat list alongside is how you switch chats.
    private func chat(for route: ChatRoute) -> some View {
        ChatDestination(route: route)
            .navigationBarBackButtonHidden(true)
            .id(route)
    }

    // A page takes the chat's place, so the way back sits where the chat's header does.
    private var backToChat: some View {
        HStack(spacing: 6) {
            if sidebarHidden { SidebarShowButton() }
            Button { model.selectedTab = .chats } label: { Label("Back to the chat", systemImage: "chevron.backward") }
                .labelStyle(.iconOnly)
                .buttonStyle(HeaderIconStyle())
                .help("Back to the chat")
                .accessibilityIdentifier("page.back")
        }
    }
}

/// One of the pages that replace the chat.
private struct MacPageContent: View {
    let tab: AppModel.AppTab

    var body: some View {
        switch tab {
        case .chats: EmptyView()   // the chat column draws this one
        case .bots: BotsView()
        case .cron: NavigationStack { CronView().fillingWindow() }
        case .kanban: NavigationStack { MacBoardView().fillingWindow() }
        // Settings pages are forms, and the grouped style matches System Settings.
        case .settings: SettingsView().formStyle(.grouped)
        }
    }
}

private extension View {
    func fillingWindow() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity).scrollContentBackground(.hidden)
    }
}

/// What the right-hand side shows before a chat is chosen.
private struct NoChatView: View {
    var body: some View {
        VStack(spacing: 12) {
            // Idle, the guide holds still; it only plays while something is working (#248).
            CharacterView(look: .main, state: BotAmbient.shared.decorativeActive ? .listening : .idle,
                          size: 72, seed: CharacterLookID.seed("nollie-mac-empty"))
            Text("Pick a bot").font(Ink.headerName).foregroundStyle(Ink.text)
            Text("Its chat opens here. + makes a new bot.").font(Ink.cardBody).foregroundStyle(Ink.text2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Same top left as over a chat: the way back to a hidden sidebar.
        .toolbar {
            ToolbarItem(placement: .navigation) { MacChatLeading() }.sharedBackgroundVisibility(.hidden)
        }
    }
}
