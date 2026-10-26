import SwiftUI
import NollieCore
#if os(macOS)
import AppKit
#endif

/// The Chats page. It lists the bots in the style of Messages, and switches to the chats
/// themselves while searching or when several are being picked. Its work is spread over the
/// extension files, so the state they all use is kept here and left internal.
struct ChatListView: View {
    @Environment(AppModel.self) var model

    /// The path chats open on, owned by whoever holds the stack: the Mac's detail column, or on
    /// iPhone and iPad `ChatsRoot`, whose one stack carries the chat whether the list sits under it
    /// or beside it. Without one, the list has a stack of its own.
    var detailPath: Binding<NavigationPath>? = nil
    #if os(iOS)
    /// Set by `ChatsRoot` when the chat shows beside the list: a chat then replaces the one open.
    @Environment(\.chatOpensBeside) var opensBeside
    #endif

    // Loaded data and what is displayed
    @State var sessions: [StoredSession] = []
    @State var searchResults: [StoredSession] = []
    @State var searchText = ""
    @FocusState var searchFocused: Bool
    @State var loading = false
    @State var errorText: String?
    /// Ids of the chats deleted on this screen; keeps a pinned row from coming back from memory.
    @State var droppedIDs: Set<String> = []
    /// Counts taps on the already selected Chats tab; each one scrolls the list to the top.
    @State var scrollToTop = 0

    // Navigation state
    @State var ownPath = NavigationPath()
    @State var lastRouted: PendingRoute?
    /// The row being previewed by a force click (Mac only).
    @State var peeking: StoredSession?
    /// Id of the chat open in the detail column (Mac only), used to highlight its row.
    @State var selectedID: String?

    // Sheets and alerts state
    @State var showNewChat = false
    /// Whether the New Message sheet ended by starting a chat rather than being dismissed.
    @State var sheetStarted = false
    @State var showNewBot = false
    @State var pendingDelete: StoredSession?
    @State var pendingDeleteMany = false

    // Multi-select, for archiving or deleting several chats at once
    @State var selecting = false
    @State var selection: Set<String> = []

    // Stored preferences
    /// All bots' chats together in a single list, latest first, with each row wearing its bot's avatar.
    @AppStorage("chats.allBots") var allBots = false
    @AppStorage(BotsHome.pinnedKey) var pinnedRaw = ""
    @AppStorage(ChatSummarizer.titlesKey) var aiTitles = ChatSummarizer.titlesOn
    @AppStorage(ChatSummarizer.previewsKey) var aiPreviews = ChatSummarizer.previewsOn
    @AppStorage("chats.filter.pinned") var pinnedOnly = false
    @AppStorage("chats.filter.needsYou") var needsYouOnly = false
    @AppStorage("chats.filter.live") var liveOnly = false
    @AppStorage("chats.filter.archived") var showArchived = true
    @AppStorage("chats.sort") var sortKey = "recent"
    /// Scheduled runs and card workers each leave a session behind. They are hidden unless asked
    /// for, which keeps the list to conversations with the bot's main chat first.
    @AppStorage("chats.filter.showRuns") var showRuns = false

    var path: Binding<NavigationPath> { detailPath ?? $ownPath }
    var runtime: GatewayRuntime? { model.runtime }
    var home: BotsHome { BotsHome.shared }
    var summarizer: ChatSummarizer { ChatSummarizer.shared }
    var aiSummaries: Bool { aiTitles || aiPreviews }
    /// The bots view is what Chats opens on; picking several chats is the only alternative.
    var showingBots: Bool { !selecting }

    /// Inputs whose change means the list must be loaded again: gateway, bot, and all-bots mode.
    fileprivate var reloadTrigger: String {
        [runtime?.connection.id.description ?? "", runtime?.selectedProfile ?? "", allBots ? "all" : "one"].joined(separator: "|")
    }

    var body: some View {
        #if os(macOS)
        // On the Mac this view is one column, and the chats sit on the detail column's stack (`detailPath`).
        decorated
        #else
        if detailPath != nil {
            decorated
        } else {
            NavigationStack(path: path) { decorated }
        }
        #endif
    }

    private var decorated: some View {
        page
            .navigationTitle(listTitle)
            .navigationBarTitleDisplayMode(.inline)
            .background(InteractivePopEnabler())
            .modifier(PathWatcher(list: self))
            #if !os(macOS)
            .toolbar { if !opensBeside { listToolbar } }
            .toolbar(opensBeside ? .hidden : .automatic, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) { if opensBeside { besideHeader } }
            #endif
            .modifier(ComposeRequests(list: self))
            .sheet(isPresented: $showNewBot) { if let runtime { NewBotSheet(runtime: runtime).sheetFrame().withAppModel() } }
            // Sheets for the bots and the data behind the rows are in their own modifier, because this
            // long chain exceeded what the type checker can handle.
            .modifier(BotsHomeHooks(pinnedRaw: $pinnedRaw, showNewBot: $showNewBot))
            #if os(iOS)
            // A stack owned elsewhere (`ChatsRoot`, the Mac's detail column) has the destinations.
            .modifier(OwnChatDestinations(enabled: detailPath == nil))
            #endif
            .modifier(Reloads(list: self))
            .onChange(of: searchText) { _, typed in Task { await search(typed) } }
            .onChange(of: model.pendingRoute, initial: true) { _, pending in routeNotification(pending) }
            .onChange(of: model.lock.isLocked) { _, locked in if !locked { routeNotification(model.pendingRoute) } }
            .modifier(DeleteAlerts(list: self))
    }

    /// The list, or the invitation to set up when there is no gateway yet.
    @ViewBuilder private var page: some View {
        if let runtime {
            list(runtime)
        } else {
            ContentUnavailableView {
                Label("Make yourself at home", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text(model.activationError ?? "Connect Hermes when you're ready to start chatting.")
            } actions: {
                Button("Set up Nollie", action: restartSetup)
                Button("Open Settings") { model.selectedTab = .settings }
            }
        }
    }

    private func restartSetup() {
        var progress = OnboardingProgress()
        progress.step = .home
        UserDefaults.standard.set(progress.encoded, forKey: OnboardingProgress.storageKey)
    }

    var listTitle: String {
        guard !selecting else { return selection.isEmpty ? "Select Chats" : "\(selection.count) Selected" }
        return showingBots ? "Chats" : historyTitle
    }

    private var historyTitle: String {
        if allBots { return "All Chats" }
        #if os(macOS)
        guard let bot = runtime?.selectedProfile, let runtime else { return "History" }
        return "Chats with " + (runtime.profiles.first { $0.name == bot }?.shownName ?? bot)
        #else
        // The phone's bar is crowded here already, so the bot's face in it tells whose history this is.
        return "History"
        #endif
    }

    // MARK: Opening chats

    /// Opens a chat. On the phone it is pushed onto the stack. On the Mac it replaces the detail
    /// column, the way picking a conversation works in Messages. `back` names the tab to return to
    /// once the chat closes (set when compose was tapped on another tab). Opening any other way
    /// clears one that is pending.
    func open(_ route: some Hashable, back: AppModel.AppTab? = nil) {
        model.composeReturnTab = back
        #if os(macOS)
        if var blank = route as? ChatRoute, blank.storedID == nil {
            blank.token = UUID()
            path.wrappedValue = NavigationPath([blank])
        } else {
            path.wrappedValue = NavigationPath([route])
        }
        selectedID = (route as? ChatRoute)?.storedID
        #else
        if opensBeside {
            // Beside the list, as on the Mac: the new chat takes the open one's place at once.
            selectedID = (route as? ChatRoute)?.storedID
            var instantly = Transaction()
            instantly.disablesAnimations = true
            withTransaction(instantly) {
                if var blank = route as? ChatRoute, blank.storedID == nil {
                    blank.token = UUID()
                    path.wrappedValue = NavigationPath([blank])
                } else {
                    path.wrappedValue = NavigationPath([route])
                }
            }
        } else {
            path.wrappedValue.append(route)
        }
        #endif
    }

    func routeNotification(_ pending: PendingRoute?) {
        guard let pending, !model.lock.isLocked, pending != lastRouted else { return }
        guard pending.connectionID == nil || model.runtime?.connection.id == pending.connectionID else { return }
        lastRouted = pending
        if let showing = model.visibleChat,
           NotificationNavigation.matches(pending, connectionID: showing.runtime.connection.id, profile: showing.profileName,
                                          sessionID: showing.storedID, requestedSessionID: model.visibleChatRequestedID) {
            return
        }
        let readOnly = pending.kind == "readonly"
        let isMain = pending.kind == "main"
        let title: String? = isMain
            ? runtime?.profiles.first(where: { $0.name == pending.profile })?.shownName
            : (readOnly ? "Bot Chat" : nil)
        let route = ChatRoute(storedID: pending.storedSessionID, title: title, profile: pending.profile,
                              readOnly: readOnly, isMain: isMain, connectionID: pending.connectionID)
        open(route, back: isMain ? model.composeReturnTab : nil)
    }

    /// What a tap on the compose circle does: opens the current bot's main chat, its single
    /// ongoing conversation. `/new` and the New Chat intent still make a separate chat, and so does
    /// the long-press sheet (other bots, a first message).
    func openFreshChat() {
        let wantsSideChat = model.sideChatWanted
        model.sideChatRequestedAt = nil
        guard model.selectedTab == .chats, let runtime else { return returnFromCompose() }
        let bot = model.composeProfile ?? runtime.selectedProfile
        if !wantsSideChat {
            Task {
                guard let why = await model.openMainChat(bot) else { return }
                model.composeReturnTab = nil
                errorText = why
            }
            return
        }
        var route = ChatRoute(storedID: nil, title: nil, profile: bot)
        #if DEBUG
        if let first = model.demoFirstMessage {
            route.initialText = first
            model.demoFirstMessage = nil
        }
        #endif
        open(route, back: model.composeReturnTab)
    }

    /// Returns to the tab where compose was tapped, unless that was this tab.
    func returnFromCompose() {
        let back = model.composeReturnTab
        model.composeReturnTab = nil
        guard let back else { return }
        let glide = Animation.snappy(duration: 0.28)
        withAnimation(glide) { model.selectedTab = back }
    }

    #if os(macOS)
    /// Opens the chat `direction` rows from the open one, or the first row if none is open.
    func step(_ direction: Int, runtime: GatewayRuntime) {
        func landing(_ count: Int, from current: Int?) -> Int {
            guard let current else { return 0 }
            return min(max(current + direction, 0), count - 1)
        }
        if showingBots && searchText.isEmpty {
            let bots = botOrder(runtime)
            guard !bots.isEmpty else { return }
            let here = bots.firstIndex { $0.name == openBotName }
            openBot(bots[landing(bots.count, from: here)].name)
            return
        }
        let rows = filtered(searchText.isEmpty ? sessions : searchResults, runtime: runtime)
        guard !rows.isEmpty else { return }
        let next = rows[landing(rows.count, from: rows.firstIndex { $0.id == selectedID })]
        open(ChatRoute(storedID: next.id, title: next.displayTitle, profile: next.profile))
    }
    #endif
}

#if os(iOS)
/// The list's own chat destinations, for when it holds its own stack.
private struct OwnChatDestinations: ViewModifier {
    var enabled: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content.navigationDestination(for: ChatRoute.self) { ChatDestination(route: $0) }
        } else {
            content
        }
    }
}
#endif

/// Keeps the tab bar and tab state matched to how deep the Chats stack goes.
private struct PathWatcher: ViewModifier {
    let list: ChatListView

    func body(content: Content) -> some View {
        let model = list.model
        content
            // It reads the stack's own path, not the pushed screen, so the tab bar starts returning as
            // soon as a pop begins rather than once the transition has finished.
            .onChange(of: list.path.wrappedValue.isEmpty, initial: true) { wasEmpty, isEmpty in
                model.chatsPathOpen = !isEmpty
                model.tabAtRoot[.chats] = isEmpty
                // A chat that was started from some other tab returns to that tab and not to this list.
                if !wasEmpty && isEmpty { list.returnFromCompose() }
            }
            .onChange(of: model.popToRoot[.chats]) { list.path.wrappedValue = NavigationPath() }
            // Tapping the Chats tab again while it is selected returns the list to the top.
            .onChange(of: model.tabReselected[.chats]) { list.scrollToTop += 1 }
    }
}

/// All the triggers that make the list fetch from the gateway again.
private struct Reloads: ViewModifier {
    let list: ChatListView

    func body(content: Content) -> some View {
        content
            .task(id: list.reloadTrigger) { await list.load() }
            .refreshable { await list.load() }
            // A socket coming up means the gateway is reachable now, so don't wait for a pull to refresh.
            .onChange(of: list.runtime?.socketState) { _, state in
                guard case .open? = state else { return }
                Task { await list.load() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .hermesSessionsChanged)) { _ in
                Task { await list.load() }
            }
    }
}

/// Requests from elsewhere in the app aimed at the list: a new chat, a new bot, the compose
/// sheet. Tapping compose once goes directly to the bot's main chat, while pressing and holding
/// brings up the Messages-like sheet with To: bots, a first message and files.
private struct ComposeRequests: ViewModifier {
    let list: ChatListView

    func body(content: Content) -> some View {
        content
            .onChange(of: list.model.newChatRequest) { _, request in
                if request != nil { list.openFreshChat() }
            }
            .onChange(of: list.model.newBotRequest) { _, request in
                if request != nil && list.runtime != nil { list.showNewBot = true }
            }
            .onChange(of: list.model.newChatSheetRequest) { _, request in
                guard request != nil, list.model.selectedTab == .chats, list.runtime != nil else { return list.returnFromCompose() }
                list.sheetStarted = false
                list.showNewChat = true
            }
            // A sheet dismissed after being opened from another tab's compose circle sends the person back there.
            .sheet(isPresented: list.$showNewChat, onDismiss: { if !list.sheetStarted { list.returnFromCompose() } }) {
                if let runtime = list.runtime {
                    NewChatSheet(runtime: runtime, onStart: begin)
                        .sheetFrame()
                        .withAppModel()
                }
            }
    }

    private func begin(_ start: NewChatSheet.Start) {
        list.sheetStarted = true
        let route = ChatRoute(storedID: nil, title: nil, profile: start.profile, initialText: start.text,
                              initialAttachments: start.attachments)
        list.open(route, back: list.model.composeReturnTab)
    }
}

/// The confirmations before chats are deleted, one or several.
private struct DeleteAlerts: ViewModifier {
    let list: ChatListView

    private var singleAsked: Binding<Bool> {
        Binding(get: { list.pendingDelete != nil }, set: { if !$0 { list.pendingDelete = nil } })
    }

    func body(content: Content) -> some View {
        let count = list.selection.count
        content
            .modifier(AskBeforeDelete(
                title: count == 1 ? "Delete 1 chat?" : "Delete \(count) chats?",
                detail: "The gateway will lose these chats and everything said in them.",
                isPresented: list.$pendingDeleteMany
            ) {
                let doomed = list.picked
                list.endSelecting()
                Task { await list.delete(doomed) }
            })
            .modifier(AskBeforeDelete(
                title: "Delete chat?",
                detail: "The gateway will lose this chat and everything said in it.",
                isPresented: singleAsked
            ) {
                guard let doomed = list.pendingDelete else { return }
                Task { await list.delete(doomed) }
            })
    }
}

private struct AskBeforeDelete: ViewModifier {
    var title: String
    var detail: String
    var isPresented: Binding<Bool>
    var confirmed: () -> Void

    func body(content: Content) -> some View {
        content.alert(title, isPresented: isPresented) {
            Button("Delete", role: .destructive, action: confirmed)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(detail)
        }
    }
}
