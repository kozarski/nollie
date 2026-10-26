import SwiftUI
import NollieCore

// The bots half of the Chats page: the bots as rows (and on the phone, pinned ones as big
// faces on top), what sits over the list, and the menus on the bar.

extension ChatListView {
    /// The list: the bots (the page Chats opens on), or, while searching or choosing several,
    /// what was found. One search field and one foot serve both, so typing never rebuilds them.
    @ViewBuilder func list(_ runtime: GatewayRuntime) -> some View {
        Group {
            if showingBots && searchText.isEmpty {
                botsScroll(runtime)
            } else {
                sessionsList(runtime)
            }
        }
        #if os(macOS)
        // Command-F from the Chat menu.
        .onChange(of: model.focusSearchRequest) { _, request in if request != nil { searchFocused = true } }
        // Chat menu's Option-Command Down and Up step to the row below or above the one that is open.
        .onChange(of: model.chatStepRequest?.id) { _, fresh in
            guard fresh != nil, let request = model.chatStepRequest else { return }
            step(request.direction, runtime: runtime)
        }
        // The foot of the list: you, the gateway, Settings.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                SummaryProgressStrip()
                MacSidebarFooter()
            }
        }
        // This is a bar rather than an ordinary inset, so rows fade out beneath it and do not show through.
        .safeAreaBar(edge: .top, spacing: 0) { topBars(runtime) }
        .scrollEdgeEffectStyle(.soft, for: .top)
        #else
        .scrollDismissesKeyboard(.immediately)
        .overlay(alignment: .bottom) { SummaryProgressStrip().padding(.bottom, 6) }
        .safeAreaInset(edge: .top, spacing: 0) { topBars(runtime) }
        // Beside a chat, Settings sits at the foot of the sidebar.
        .safeAreaInset(edge: .bottom, spacing: 0) { if opensBeside { besideFoot } }
        .background((showingBots && searchText.isEmpty ? Ink.canvas : Color(.systemGroupedBackground)).ignoresSafeArea())
        #endif
        .animation(.snappy, value: [runtime.restartRequired == nil, model.needsSignIn == nil])
    }

    /// The bots as Messages lists conversations. On the phone the pinned ones sit big along the
    /// top, then a row for each bot. Each face and row has its own menu, so a long press lifts
    /// that one alone.
    @ViewBuilder func botsScroll(_ runtime: GatewayRuntime) -> some View {
        let ordered = home.ordered(runtime)
        let pins = home.pinned(ordered, raw: pinnedRaw)
        let openName = openBotName
        #if os(iOS)
        let rows = ordered.filter { bot in !pins.contains { $0.name == bot.name } }
        #else
        let rows = home.visibleOrder(ordered, raw: pinnedRaw)
        #endif
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                #if os(iOS)
                if let reach = model.linkReach {
                    LinkReachLine(reach: reach, alertsOn: model.cloudAlerts.isEnabled || DemoMode.alertsOn) { model.awayPrompt = true }
                }
                #endif
                if let errorText, model.needsSignIn == nil {
                    Text(errorText).font(.footnote).foregroundStyle(.red)
                        .inset(h: 12, v: 6)
                }
                #if os(iOS)
                if !pins.isEmpty { pinnedFaces(pins, front: ordered.first?.name, open: openName, runtime: runtime) }
                #endif
                #if os(iOS)
                if opensBeside, runtime.kanban.isPresent { BoardToolbarButton(asRow: true) }
                #endif
                ForEach(rows) { botRow($0, runtime: runtime, selected: openName == $0.name) }
                #if os(iOS)
                if opensBeside {
                    SidebarActionRow(title: "New bot", symbol: "plus") { model.newBotRequest = UUID() }
                        .accessibilityIdentifier("chats.newBot")
                }
                #endif
            }
            .inset(h: 8, v: 2)
        }
        .refreshable {
            await load()
            await home.refresh(runtime, force: true)
        }
        // Each bot drawn in a row faces toward the direction the list is heading.
        .feedsBotAmbient()
        .accessibilityIdentifier("bots.list")
    }

    #if os(iOS)
    /// The pinned faces share the width evenly. Where four do not fit (a narrow list column, very
    /// large text) the row scrolls sideways instead of running off the edge.
    private func pinnedFaces(_ pins: [ProfileInfo], front: String?, open: String?, runtime: GatewayRuntime) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(pins) { pinnedFace($0, front: front, open: open, runtime: runtime).spread(.center) }
            }
            .padding(EdgeInsets(top: 4, leading: 4, bottom: 8, trailing: 4))
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 4) {
                    ForEach(pins) { pinnedFace($0, front: front, open: open, runtime: runtime) }
                }
                .padding(EdgeInsets(top: 4, leading: 4, bottom: 8, trailing: 4))
            }
            .scrollIndicators(.hidden)
        }
    }

    private func pinnedFace(_ bot: ProfileInfo, front: String?, open: String?, runtime: GatewayRuntime) -> some View {
        Button { openBot(bot.name) } label: {
            BotTile(runtime: runtime, profile: bot, entry: home.entry(runtime, bot.name),
                    star: bot.name == front, unread: home.unread(runtime, bot.name))
        }
        .buttonStyle(BotRowButtonStyle())
        .background(open == bot.name ? Ink.selected : Ink.canvas, in: .rect(cornerRadius: 18, style: .continuous))
        .contentShape(.contextMenuPreview, .rect(cornerRadius: 18, style: .continuous))
        .contextMenu { botMenu(bot, runtime: runtime) }
        .accessibilityAddTraits(open == bot.name ? .isSelected : [])
    }

    /// The foot of the sidebar: Settings, where the Mac keeps it.
    private var besideFoot: some View {
        SidebarActionRow(title: "Settings", symbol: "gearshape") { model.selectedTab = .settings }
            .accessibilityIdentifier("chats.settings")
            .inset(h: 8, v: 6)
    }
    #endif

    /// A bot's row, the same in the list and among what a search finds.
    @ViewBuilder func botRow(_ bot: ProfileInfo, runtime: GatewayRuntime, selected: Bool) -> some View {
        let isPinned = home.pinned(home.ordered(runtime), raw: pinnedRaw).contains { $0.name == bot.name }
        Button { openBot(bot.name) } label: {
            BotListRow(runtime: runtime, profile: bot, entry: home.entry(runtime, bot.name),
                       unread: home.unread(runtime, bot.name), selected: selected, pinned: isPinned)
        }
        .buttonStyle(BotRowButtonStyle())
        #if os(iOS)
        // Lifted by a long press, the row sits on the page's own colour in a rounded card of its
        // own, not see-through over the dimmed list.
        .background(Ink.canvas, in: .rect(cornerRadius: 12, style: .continuous))
        .contentShape(.contextMenuPreview, .rect(cornerRadius: 12, style: .continuous))
        #endif
        .contextMenu { botMenu(bot, runtime: runtime) }
        // Inside a search's list: no list chrome around the row of its own.
        .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    /// A bot's menu: the same as the one over its chat, with Pin on the list.
    @ViewBuilder func botMenu(_ bot: ProfileInfo, runtime: GatewayRuntime) -> some View {
        let isPinned = home.pinned(home.ordered(runtime), raw: pinnedRaw).contains { $0.name == bot.name }
        BotMenuItems(profile: bot.name, label: bot.shownName, pinned: isPinned,
                     togglePin: { withAnimation(.snappy) { pinnedRaw = BotsHome.toggledPin(pinnedRaw, bot.name) } })
            .buttonStyle(.automatic)
            .labelStyle(.titleAndIcon)
    }

    /// The bots in the order drawn, pins first on both platforms.
    func botOrder(_ runtime: GatewayRuntime) -> [ProfileInfo] {
        home.visibleOrder(home.ordered(runtime), raw: pinnedRaw)
    }

    /// The bot whose chat is open beside the list (the Mac, a wide iPad or iPhone), for its row's highlight.
    var openBotName: String? {
        #if os(macOS)
        model.selectedTab == .chats ? model.visibleChat?.profileName : nil
        #else
        opensBeside && model.selectedTab == .chats ? model.visibleChat?.profileName : nil
        #endif
    }

    /// A bot's one continuous chat, looked up fresh (compression moves it on to a new id), or
    /// started when the bot has none yet. When the bot is busy in a side chat of its own, the
    /// click goes there, to the work.
    func openBot(_ name: String) {
        guard let runtime else { return }
        home.markSeen(runtime, name)
        model.composeReturnTab = nil
        let entry = home.entry(runtime, name)
        if let live = BotPresence(runtime: runtime, profile: name, mainID: entry.storedID).live,
           !live.storedID.isEmpty, live.storedID != entry.storedID {
            open(ChatRoute(storedID: live.storedID, title: live.title, profile: name))
            return
        }
        Task { if let why = await model.openMainChat(name) { errorText = why } }
    }

    // MARK: Over the list

    /// A custom search field stands in for `.searchable`, whose system version sat where the refresh
    /// spinner is drawn and cannot contain a button. Papertrail goes inside it on the trailing edge, as
    /// Mail's and Safari's fields keep a button there. The field stays pinned under the title and the
    /// list scrolls behind it.
    var searchField: some View {
        InkSearchField(text: $searchText, prompt: "Search", focused: $searchFocused) {
            if model.runtime != nil { PapertrailSearchButton() }
        }
        .clipShape(.capsule)
        #if os(macOS)
        .padding(EdgeInsets(top: 4, leading: 14, bottom: 10, trailing: 14))
        #else
        .padding(EdgeInsets(top: 2, leading: 16, bottom: 6, trailing: 16))
        #endif
    }

    /// Everything above the list: first the search field, then any message that has to be shown.
    func topBars(_ runtime: GatewayRuntime) -> some View {
        VStack(spacing: 0) {
            #if os(macOS)
            // The Board and New Bot sit beside the window's buttons. Picking several chats
            // brings their actions in here.
            if selecting {
                HStack(spacing: 8) {
                    doneButton
                    Spacer(minLength: 0)
                    selectionActions
                }
                .padding(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
            }
            #endif
            searchField
            if let waiting = model.needsSignIn {
                GatewaySignInBanner(connection: waiting)
                    .padding(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let message = runtime.restartRequired {
                RestartRequiredBanner(runtime: runtime, message: message)
                    .padding(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            #if os(iOS)
            QuickAnswerAwayBar(runtime: runtime)
            #endif
        }
    }

    /// Leaves choosing several chats.
    var doneButton: some View {
        Button("Done", action: endSelecting).accessibilityIdentifier("chats.select.done")
    }

    #if !os(macOS)
    /// Beside a chat the list is a sidebar with its own header: the title and one button, New chat.
    /// Board, New bot and Settings are rows in the sidebar itself, as the Mac's sidebar has them.
    var besideHeader: some View {
        HStack(spacing: 10) {
            if selecting {
                doneButton.buttonStyle(.glass)
            } else {
                Text(listTitle)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Ink.text)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 0)
            if selecting {
                HStack(spacing: 8) { selectionActions }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
            } else {
                Button { model.newChatSheetRequest = UUID() } label: { Label("New chat", systemImage: "square.and.pencil") }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityIdentifier("chats.newChat")
            }
        }
        .controlSize(.large)
        .padding(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 16))
    }

    /// The conversations keep their own navigation while Board and Settings open above them.
    @ToolbarContentBuilder var listToolbar: some ToolbarContent {
        let hasBoard = runtime?.kanban.isPresent == true
        ToolbarItem(placement: .topBarLeading) {
            if selecting {
                doneButton
            } else {
                Button { model.selectedTab = .settings } label: { Label("Settings", systemImage: "gearshape") }
                    .accessibilityIdentifier("chats.settings")
            }
        }
        if selecting {
            ToolbarItemGroup(placement: .topBarTrailing) { selectionActions }
        } else {
            // The Board and New Bot, each on glass of its own. Schedules is in each bot's menu.
            if hasBoard {
                ToolbarItem(placement: .topBarTrailing) { BoardToolbarButton() }
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
            }
            ToolbarItem(placement: .topBarTrailing) { NewBotButton() }
        }
    }
    #endif
}

/// New Bot, over the bot list: in the phone's bar, and on the Mac beside the window's own
/// buttons. The list's sheet opens on the request.
struct NewBotButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { model.newBotRequest = UUID() } label: { Label("New Bot", systemImage: "plus") }
            #if os(macOS)
            .labelStyle(.iconOnly)
            .buttonStyle(HeaderIconStyle())
            .help("New bot (⌘N)")
            #else
            .tint(.primary)
            #endif
            .accessibilityLabel("New bot")
            .accessibilityIdentifier("chats.newBot")
    }
}

/// The bots' part of the Chats list, kept out of its long modifier chain (the type checker gave
/// up on it there): the rows' data kept fresh when the gateway or its bots change, when the
/// socket comes back, and at once when a reply finishes here.
struct BotsHomeHooks: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var pinnedRaw: String
    @Binding var showNewBot: Bool

    private var runtime: GatewayRuntime? { model.runtime }
    private var home: BotsHome { BotsHome.shared }

    private func refresh(force: Bool = false) {
        guard let runtime else { return }
        Task { await home.refresh(runtime, force: force) }
    }

    func body(content: Content) -> some View {
        content
            .task(id: runtime?.connection.id) { await keepFresh() }
            .onChange(of: runtime?.profiles.map(\.name) ?? []) { _, _ in refresh(force: true) }
            .onChange(of: runtime?.socketState) { _, state in if case .open? = state { refresh() } }
            .onReceive(NotificationCenter.default.publisher(for: .hermesSessionsChanged)) { _ in refresh() }
            .onReceive(NotificationCenter.default.publisher(for: .hermesReplyCompleted)) { note in
                guard let runtime, let id = note.userInfo?["storedID"] as? String,
                      let text = note.userInfo?["text"] as? String, !text.isEmpty else { return }
                home.noteReply(runtime, storedID: id, text: text, visible: model.visibleChatID == id)
            }
            #if DEBUG
            // The build bot's `-nollie-demo-new-bot`: the new-bot sheet, for its picture.
            .task {
                guard ProcessInfo.processInfo.arguments.contains("-nollie-demo-new-bot") else { return }
                try? await Task.sleep(for: .seconds(4))
                showNewBot = true
            }
            #endif
    }

    /// Fresh while on screen: every 25 seconds, every 8 while a bot is mid-turn, so a bot that
    /// starts or finishes work elsewhere shows it here.
    private func keepFresh() async {
        guard let runtime else { return }
        await home.refresh(runtime, force: true)
        if let first = home.firstPins(home.ordered(runtime), raw: pinnedRaw) { pinnedRaw = first }
        while !Task.isCancelled {
            let busy = runtime.profiles.contains { home.entry(runtime, $0.name).busy }
            try? await Task.sleep(for: .seconds(busy ? 8 : 25))
            guard !Task.isCancelled, model.runtime === runtime else { return }
            await home.refresh(runtime, force: busy)
        }
    }
}
