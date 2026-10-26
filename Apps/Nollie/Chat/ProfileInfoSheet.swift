import SwiftUI
import NollieCore

/// Sheet behind a chat's title pill. It holds the bot's card, plus a tab for the chat itself if
/// that is where it was launched.
struct ProfileInfoSheet: View {
    var chat: ChatSession?
    var profileName: String
    var initialTab: ProfileTab?
    @Environment(\.dismiss) private var dismiss
    /// Starts half-height with the full height one drag up. Opening from a bot's menu for its
    /// settings starts at full height.
    @State private var detent: PresentationDetent
    private static let heights: Set<PresentationDetent> = [.medium, .large]

    init(chat: ChatSession?, profileName: String, startTall: Bool = false, initialTab: ProfileTab? = nil) {
        self.chat = chat
        self.profileName = profileName
        self.initialTab = initialTab
        _detent = State(initialValue: startTall ? .large : .medium)
    }

    var body: some View {
        NavigationStack { card }
        .presentationDetents(Self.heights, selection: $detent)
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder private var card: some View {
        #if os(iOS)
        // On the phone the card brings its own round buttons, so the bar goes.
        ProfileCardView.floating(profileName: profileName, chat: chat, tab: initialTab, close: { dismiss() })
            .toolbar(.hidden, for: .navigationBar)
        #else
        ProfileCardView(profileName: profileName, chat: chat, initialTab: initialTab)
            .doneToolbar()
        #endif
    }
}

#if os(macOS)
/// On the Mac, the Apps and access page gets a sheet to itself.
private struct BotAppsAccessSheet: View {
    let profileName: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ToolsView(profileName: profileName)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }.accessibilityIdentifier("profile.apps.done")
                    }
                }
        }
    }
}
#endif

/// A bot's card. At the top are its face and name with the day's Papertrail answer, then the row
/// of tabs and the chosen tab below. Changing any setting saves it straight away.
struct ProfileCardView: View {
    let profileName: String
    let chat: ChatSession?
    /// True in a sheet, where round buttons float above the header. A pushed page uses the
    /// navigation bar's own.
    let floatingControls: Bool
    let onClose: (() -> Void)?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var state: ProfileCardState
    /// Which tab is open. A chat starts on its own tab; the Bots page and everything else on Look.
    @State private var tab: ProfileTab
    /// Scroll distance of the card, which decides how visible the band behind the buttons is.
    @State private var scrolled: CGFloat = 0
    @State private var papertrail = PapertrailModel()
    /// Set when the latest Papertrail read failed but an older result is still displayed.
    @State private var papertrailStale = false
    /// Incremented by Try again on the Papertrail tab to start another read.
    @State private var papertrailAttempt = 0
    @State private var renaming = false
    @State private var showingPreview = false
    #if os(macOS)
    @State private var showingApps = false
    #endif

    init(profileName: String, chat: ChatSession? = nil, floatingControls: Bool = false,
         onClose: (() -> Void)? = nil, initialTab: ProfileTab? = nil) {
        _state = State(initialValue: ProfileCardState(name: profileName))
        _tab = State(initialValue: initialTab ?? (chat == nil ? .look : .thisChat))
        self.onClose = onClose
        self.floatingControls = floatingControls
        self.chat = chat
        self.profileName = profileName
    }

    /// The sheet version of the card: round buttons float over the header and close the sheet.
    static func floating(profileName: String, chat: ChatSession?, tab: ProfileTab?,
                         close: @escaping () -> Void) -> ProfileCardView {
        ProfileCardView(profileName: profileName, chat: chat, floatingControls: true,
                        onClose: close, initialTab: tab)
    }

    private var runtime: GatewayRuntime? { model.runtime }
    private var gatewayKey: String { runtime?.connection.id.uuidString ?? "" }

    /// Today from this bot's Papertrail, once read. Never for a private bot.
    private var today: PapertrailToday? {
        guard !state.isHidden, case .on(let trail) = papertrail.state else { return nil }
        return PapertrailToday(trail)
    }

    var body: some View {
        ScrollViewReader { proxy in page.task { await scrollForDemo(proxy) } }
    }

    /// The demo copy's `-nollie-demo-bot-scroll ownComputer`: that section in view, for its picture.
    private func scrollForDemo(_ proxy: ScrollViewProxy) async {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard DemoMode.isOn, let flag = args.firstIndex(of: "-nollie-demo-bot-scroll"), flag + 1 < args.count else { return }
        try? await Task.sleep(for: .seconds(2))
        proxy.scrollTo(args[flag + 1], anchor: .bottom)
        #endif
    }

    private var page: some View {
        ScrollView {
            VStack(spacing: 0) {
                ProfileCardHeader(state: state, today: today, botState: chat?.botState ?? .idle, floating: floatingControls)
                ProfileTabRow(tabs: ProfileTab.available(withChat: chat != nil, privateBot: state.isHidden,
                                                         memory: ProfileMemoryTab.access(state: state, runtime: runtime) != .hidden),
                              selected: $tab)
                    .frame(maxWidth: 640)
                    .padding(.top, 18)
                VStack(spacing: 32) {
                    tabContent
                    if let note = state.note { CardNote(words: note, id: "profile.status") }
                }
                .frame(maxWidth: 560)
                .padding(EdgeInsets(top: 24, leading: 24, bottom: 40, trailing: 24))
            }
            .spread(.center)
            .toggleStyle(.switch)
        }
        .background(Ink.canvas.ignoresSafeArea())
        .navigationTitle(floatingControls ? "" : state.label)
        #if os(iOS)
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentInsets.top + $0.contentOffset.y }, action: { _, y in scrolled = y })
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .top) {
            if floatingControls {
                ProfileCardControls(scrolled: scrolled, canRename: chat != nil, close: close, rename: { renaming = true })
            }
        }
        #endif
        // This sits on the card rather than the Name row, because the header menu asks before that row exists.
        .renameSheet(for: chat, isPresented: $renaming)
        .sheet(isPresented: $showingPreview) {
            if let chat { ComputerView(chat: chat).withAppModel() }
        }
        #if os(macOS)
        .sheet(isPresented: $showingApps) { BotAppsAccessSheet(profileName: profileName).sheetFrame().withAppModel() }
        #endif
        .onChange(of: gatewayKey, initial: true) { _, _ in
            state.runtime = runtime
            state.leave = close
            state.start()
        }
        .task(id: "\(gatewayKey)/\(state.isHidden)") { await readToday() }
        // Keyed on the gateway too: a switch while the card is open reads the new one.
        .task(id: "\(tab.rawValue)/\(gatewayKey)/\(papertrailAttempt)") { await readForTab() }
        // A save's note belongs to the tab it was made on.
        .onChange(of: tab) { state.note = nil }
        .accessibilityIdentifier("bot.editor." + profileName)
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    @ViewBuilder private var tabContent: some View {
        switch tab {
        case .look: ProfileLookTab(state: state)
        case .instructions: ProfileInstructionsTab(state: state)
        case .memory: ProfileMemoryTab(state: state)
        case .model: ProfileModelTab(state: state)
        case .papertrail:
            if !state.isHidden {
                PapertrailView(model: papertrail, stale: papertrailStale, retry: { papertrailAttempt += 1 })
            }
        case .apps:
            ProfileAppsTab(state: state) {
                #if os(macOS)
                showingApps = true
                #endif
            }
        case .computer: ProfileComputerTab(state: state, chat: chat) { showingPreview = true }
        case .thisChat:
            if let chat { ProfileChatTab(state: state, chat: chat) { renaming = true } }
        case .display: ProfileDisplayTab(state: state)
        }
    }

    // MARK: Reading

    /// Today's line under the name: one read as the card opens. The Papertrail tab keeps
    /// reading by itself while it is open.
    private func readToday() async {
        guard let runtime, !state.isHidden, tab != .papertrail else { return }
        if case .on = papertrail.state { return }
        await papertrail.load(bot: profileName, runtime: runtime)
    }

    private func readForTab() async {
        guard let runtime else { return }
        if tab == .model, state.options == nil {
            state.options = try? await runtime.api.get("/api/model/options", profile: profileName)
        }
        if tab == .papertrail, !state.isHidden {
            // Read again just after the Mac's midnight while the tab stays open.
            repeat {
                let read = await papertrail.load(bot: profileName, runtime: runtime)
                guard !Task.isCancelled, model.runtime?.connection.id == runtime.connection.id else { return }
                papertrailStale = !read
            } while await papertrail.waitForNextDay()
            return
        }
        papertrailStale = false
        // A bot made Private while its Papertrail was open: nothing of it stays on show.
        if tab == .papertrail { tab = .look; papertrail = PapertrailModel() }
        if tab == .computer {
            state.controlChecked = false
            await SystemControl.shared.refresh(profileName, runtime)
            guard !Task.isCancelled else { return }
            state.controlChecked = true
        }
    }
}
