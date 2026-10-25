import SwiftUI
import NollieCore

// The chats half of the Chats page: what a search finds, what is picked, and the rows.

extension ChatListView {
    /// Search results (bots matching by name, then chats) and the set of chats ticked in
    /// multi-select.
    @ViewBuilder func sessionsList(_ runtime: GatewayRuntime) -> some View {
        let rows = shownRows(runtime)
        ScrollViewReader { proxy in
            List {
                failureLine
                if !searchText.isEmpty && !selecting { matchingBots(runtime) }
                if rows.isEmpty && !loading && !searchText.isEmpty {
                    ContentUnavailableView("No chats found", systemImage: "magnifyingglass", description: Text("Try other words."))
                        .listRowSeparator(.hidden)
                }
                ForEach(rows) { SessionRowCell(list: self, session: $0, runtime: runtime) }
            }
            .modifier(SessionListChrome())
            .overlay { if loading && sessions.isEmpty && !searchText.isEmpty { ProgressView() } }
            .onChange(of: scrollToTop) {
                guard let first = rows.first?.id else { return }
                withAnimation(.snappy) { proxy.scrollTo(first, anchor: .top) }
            }
        }
    }

    /// Chats to show: the loaded ones or the search hits, with the filters applied.
    func shownRows(_ runtime: GatewayRuntime) -> [StoredSession] {
        filtered(searchText.isEmpty ? sessions : searchResults, runtime: runtime)
    }

    /// When this device is signed out, the banner above already says so and offers the button.
    /// The gateway's red "session expired" message under it would only say the same thing again.
    @ViewBuilder var failureLine: some View {
        if let errorText, model.needsSignIn == nil {
            Text(errorText).quiet(.footnote, .red)
        }
    }

    @ViewBuilder private func matchingBots(_ runtime: GatewayRuntime) -> some View {
        let needle = searchText.trimmingCharacters(in: .whitespaces)
        let hits = home.ordered(runtime).filter { bot in
            needle.isEmpty || [bot.shownName, bot.name].contains { $0.localizedCaseInsensitiveContains(needle) }
        }
        ForEach(hits) { botRow($0, runtime: runtime, selected: openBotName == $0.name) }
    }

    // MARK: Filtering and order

    static func isWorkSession(_ session: StoredSession) -> Bool { SessionListRules.isWork(session) }

    /// Runs the loaded or searched sessions through the filters and the chosen sort order.
    func filtered(_ list: [StoredSession], runtime: GatewayRuntime) -> [StoredSession] {
        let rules = SessionListRules(pinnedOnly: pinnedOnly, needsYouOnly: needsYouOnly, liveOnly: liveOnly,
                                     archivedShown: showArchived, runsShown: showRuns, sort: sortKey)
        return rules.shown(list, runtime: runtime)
    }

    // MARK: Selecting several chats

    /// The ticked chats, ordered as they appear in the list.
    var picked: [StoredSession] {
        (searchText.isEmpty ? sessions : searchResults).filter { selection.contains($0.id) }
    }

    func endSelecting() {
        withAnimation(.snappy) { (selecting, selection) = (false, []) }
    }

    @ViewBuilder var selectionActions: some View {
        selectionButton("Archive", symbol: "archivebox", role: nil) {
            let chosen = picked
            endSelecting()
            Task { await archive(chosen) }
        }
        selectionButton("Delete", symbol: "trash", role: .destructive) { pendingDeleteMany = true }
    }

    private func selectionButton(_ title: LocalizedStringKey, symbol: String, role: ButtonRole?,
                                 _ act: @escaping () -> Void) -> some View {
        Button(role: role, action: act) { Label(title, systemImage: symbol) }
            .help(title)
            .disabled(selection.isEmpty)
    }
}

/// The two switches a chat has on the gateway.
enum RowFlag {
    case pin, archive

    var key: String { self == .pin ? "pinned" : "archived" }

    func isSet(on session: StoredSession) -> Bool {
        (self == .pin ? session.pinned : session.archived) == true
    }

    func title(whenSet set: Bool) -> String {
        switch self {
        case .pin: set ? "Unpin" : "Pin"
        case .archive: set ? "Unarchive" : "Archive"
        }
    }

    func symbol(whenSet set: Bool) -> String {
        switch self {
        case .pin: set ? "pin.slash" : "pin"
        case .archive: "archivebox"
        }
    }
}

/// One chat in the list, with its menus and swipes.
private struct SessionRowCell: View {
    let list: ChatListView
    let session: StoredSession
    let runtime: GatewayRuntime

    private var route: ChatRoute { ChatRoute(storedID: session.id, title: session.displayTitle, profile: session.profile) }
    private var live: ChatSession? { runtime.chatForStored(session.id) }
    private var waiting: Bool { runtime.needsAttention.contains(session.id) }
    /// In all-bots mode a chat is read via the bot it belongs to, not the selected one.
    private var peekProfile: String? { list.allBots ? session.profile : nil }

    /// Whether a bot avatar sits next to each chat: in all-bots mode on the phone, and always on
    /// the Mac, so that the list resembles conversations with people.
    private var showsBot: Bool {
        #if os(macOS)
        true
        #else
        list.allBots
        #endif
    }

    private var summary: ChatSummarizer.Summary? {
        let shared = ChatSummarizer.shared
        return shared.shown(shared.summary(for: session), title: session.displayTitle, preview: session.preview ?? "",
                            renamed: ChatSession.renamedByPerson(session.id))
    }

    var body: some View {
        PickableRow(list: list, route: route, selected: list.selectedID == session.id, pick: session.id) {
            SessionRow(session: session, needsYou: waiting, live: live?.isRunning ?? false, showBot: showsBot,
                       botProfile: session.profile ?? runtime.selectedProfile,
                       thinking: live.map { $0.isRunning && ($0.statusLine ?? "Thinking…") == "Thinking…" } ?? false,
                       step: waiting ? nil : live?.statusLine, summary: summary)
                .task(id: "\(session.id)-\(session.lastActive ?? 0)-\(list.aiSummaries)") {
                    if list.aiSummaries { list.summarizer.refresh(session, runtime: runtime, profile: peekProfile) }
                }
        }
        .listRowInsets(EdgeInsets(top: 10, leading: ChatRowStyle.rowInset, bottom: 10, trailing: 8))
        #if os(macOS)
        // A hard press on the trackpad previews the conversation, matching the phone's long press.
        .onForceClick { list.peeking = session }
        .popover(isPresented: Binding(get: { list.peeking?.id == session.id }, set: { if !$0 { list.peeking = nil } })) {
            peek.withAppModel()
        }
        #endif
        .contextMenu { menu } preview: { peek.withAppModel() }
        // Only Delete sits on the trailing edge. Archive goes next to Pin on the leading edge, which
        // keeps the two from ending up a thumb apart.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) { deleteButton }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            flagButton(.pin).tint(.yellow)
            flagButton(.archive).tint(.orange)
        }
    }

    private var peek: some View {
        SessionPreview(session: session, runtime: runtime, profile: peekProfile)
    }

    private func flagButton(_ flag: RowFlag) -> some View {
        let set = flag.isSet(on: session)
        return Button { Task { await list.patch(session, [flag.key: .bool(!set)]) } } label: {
            Label(flag.title(whenSet: set), systemImage: flag.symbol(whenSet: set))
        }
    }

    private var deleteButton: some View {
        Button(role: .destructive) { list.pendingDelete = session } label: { Label("Delete", systemImage: "trash") }
    }

    @ViewBuilder private var menu: some View {
        Button { list.open(route) } label: { Label("Open", systemImage: "bubble.left") }
        flagButton(.pin)
        flagButton(.archive)
        Button {
            withAnimation(.snappy) { (list.selecting, list.selection) = (true, [session.id]) }
        } label: { Label("Select", systemImage: "checkmark.circle") }
        Divider()
        deleteButton
    }
}

/// The list's look: sidebar on the Mac, grouped cards on the phone, rows close to the edges.
private struct SessionListChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            #if os(macOS)
            .listStyle(.sidebar)
            // The list extends slightly beneath the column edge, which sliced the scroll bar lengthwise.
            // This pulls the bar back inside the column.
            .contentMargins(.trailing, 8, for: .scrollIndicators)
            #else
            .listStyle(.insetGrouped)
            #endif
            .scrollContentBackground(.hidden)
            // Wide rows: the card stretches to the screen's edges and the rows stretch to the card's.
            .contentMargins(.horizontal, ChatRowStyle.cardInset, for: .scrollContent)
            .feedsBotAmbient()
    }
}

/// Row that opens `route`. Phone: a navigation link. Mac: a button that fills the detail column.
/// In multi-select mode the row carries a tick circle. `pick` holds the chat's id.
private struct PickableRow<Label: View>: View {
    let list: ChatListView
    let route: ChatRoute
    var selected = false
    var pick: String
    @ViewBuilder var label: Label

    private var ticked: Bool { list.selection.contains(pick) }

    var body: some View {
        if list.selecting { choosing } else { opening }
    }

    private var choosing: some View {
        PlainButton {
            if ticked { list.selection.remove(pick) } else { list.selection.insert(pick) }
        } label: {
            HStack(spacing: 10) {
                Glyph(ticked ? "checkmark.circle.fill" : "circle", .title3, ticked ? Color.accentColor : Color.secondary.opacity(0.7))
                label
            }
            .contentShape(.rect)
        }
        .accessibilityAddTraits(ticked ? .isSelected : [])
    }

    @ViewBuilder private var opening: some View {
        #if os(macOS)
        PlainButton { list.open(route) } label: { label.contentShape(.rect) }
            // The row of the open chat is tinted, as the selected conversation is in Messages. The tint is painted
            // here because the Mac list did not honour listRowBackground on these rows.
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .inset(h: -8, v: -7)
                    .foregroundStyle(Color.accentColor.opacity(selected ? 0.16 : 0))
            }
        #else
        NavigationLink(value: route) { label }
        #endif
    }
}
