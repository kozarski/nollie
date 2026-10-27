import SwiftUI
import NollieCore

/// One of a bot's own pages: its history, what it knows, its settings and, on the phone, the
/// Board and the schedules (the Mac shows those two in the window, where the chat was).
struct BotSheet: Identifiable, Hashable {
    enum Kind: String, Sendable { case history, knows, settings, board, schedules, share }
    var kind: Kind
    var profile: String
    /// The chat the menu was opened from: Bot settings opens on its "This chat" tab.
    var chatID: String? = nil
    var id: String { kind.rawValue + "|" + profile }
}

extension AppModel {
    /// A bot's page, from its menu wherever that menu is: the list's right-click or long press,
    /// the ⋯ over its chat, the Chat menu. Each item opens its own page and none opens the chat.
    func openBotPage(_ kind: BotSheet.Kind, profile: String, chatID: String? = nil) {
        #if os(macOS)
        switch kind {
        case .board: selectedTab = .kanban; return
        case .schedules: selectedTab = .cron; return
        default: break
        }
        #endif
        botSheet = BotSheet(kind: kind, profile: profile, chatID: chatID)
    }

    /// The bot of the chat on screen, or the selected bot otherwise; what the Chat menu's History and
    /// the like are about.
    var frontBot: String? { visibleChat?.profileName ?? runtime?.selectedProfile ?? runtime?.profiles.first?.name }
}

/// A bot's menu, the same wherever it opens: its history, the Board, its schedules, what it
/// knows, a side chat, System control, its settings and Pin from the list.
struct BotMenuItems: View {
    var profile: String
    var label: String
    var chatID: String? = nil
    /// The ⋯ over a chat on the Mac shows the Chat menu's keys beside History and Board.
    var shortcuts = false
    /// The list: whether the bot is pinned to the top, and the toggle.
    var pinned: Bool? = nil
    var togglePin: () -> Void = {}
    /// The app's one model, read directly: a menu's items are not promised the window's environment.
    private var model: AppModel { AppModel.shared }

    /// One menu row: its words, symbol, test id and what it does. `key` adds a Command shortcut
    /// where `shortcuts` is on.
    private func row(_ title: LocalizedStringKey, _ symbol: String, id: String, key: Character? = nil,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol) }
            .modifier(MenuKey(key: key ?? " ", on: shortcuts && key != nil))
            .accessibilityIdentifier("botmenu." + id)
    }

    private func page(_ kind: BotSheet.Kind) -> () -> Void {
        { model.openBotPage(kind, profile: profile, chatID: kind == .history || kind == .settings ? chatID : nil) }
    }

    private var hidesMacControl: Bool {
        model.runtime?.profiles.first(where: { $0.name == profile })?.isPrivateBot(on: model.runtime?.connection.id) == true
    }

    var body: some View {
        if model.family.isMember(model) {
            // Someone at home has their chats and nothing of the owner's.
            row("New chat", "square.and.pencil", id: "sideChat") { model.requestNewChat(profile: profile) }
        } else {
            ownerItems
        }
    }

    @ViewBuilder private var ownerItems: some View {
        row("History", "clock", id: "history", key: "y", action: page(.history))
        if model.runtime?.kanban.isPresent == true {
            row("Board", "rectangle.split.3x1", id: "board", key: "b", action: page(.board))
        }
        row("Schedules", "calendar", id: "schedules", action: page(.schedules))
        row("What \(label) knows", "star", id: "knows", action: page(.knows))
        Divider()
        row("New side chat", "plus", id: "sideChat") { model.requestNewChat(profile: profile) }
        if let pinned {
            row(pinned ? "Unpin" : "Pin to top", pinned ? "pin.slash" : "pin", id: "pin", action: togglePin)
        }
        Divider()
        // The private bot keeps to itself, so its switch lives only in its own settings.
        if !hidesMacControl { SystemControlToggle(profile: profile) }
        if model.family.canShare(model, profile: profile) {
            row("Share…", "person.2", id: "share", action: page(.share))
        }
        row("Bot settings…", "slider.horizontal.3", id: "settings", action: page(.settings))
    }
}

/// System control in a bot's menu: ticked while the bot may use this Mac's apps and screen. The
/// tick is the choice (no second question); unticking stops its next screen action at once.
struct SystemControlToggle: View {
    var profile: String
    private var control: SystemControl { .shared }
    private var runtime: GatewayRuntime? { AppModel.shared.runtime }

    var body: some View {
        Toggle(isOn: Binding(get: { control.isOn(profile, runtime) }, set: { on in
            guard let rt = runtime else { return }
            Task { await control.set(on, profile: profile, rt: rt) }
        })) {
            Label("Allow Mac control", systemImage: "cursorarrow.rays")
        }
        .disabled(control.isBusy(profile, runtime))
        .accessibilityHint(control.isOn(profile, runtime) ? "Stops this bot using your Mac" : "Lets this bot use your Mac's apps without asking each time")
        .accessibilityIdentifier("botmenu.systemControl")
    }
}

/// A key shown beside a menu item (and answered while that menu is the window's).
private struct MenuKey: ViewModifier {
    var key: Character
    var on: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if on { content.keyboardShortcut(KeyEquivalent(key), modifiers: .command) } else { content }
    }
}

/// Shows whichever bot page was asked for, over the window. Put once at the root.
struct BotSheetHost: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { model.botSheet }, set: { model.botSheet = $0 })) { sheet in
                BotSheetContent(sheet: sheet)
                    .sheetFrame(sheet.kind == .board ? .wide : .form)
                    .withAppModel()
            }
    }
}

private struct BotSheetContent: View {
    var sheet: BotSheet
    @Environment(AppModel.self) private var model

    /// The demo copy's `-nollie-demo-bot-tab computer`: Bot settings open on that tab, for its picture.
    private var demoTab: ProfileTab? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if DemoMode.isOn, let i = args.firstIndex(of: "-nollie-demo-bot-tab"), i + 1 < args.count { return ProfileTab(rawValue: args[i + 1]) }
        #endif
        return nil
    }

    var body: some View {
        switch sheet.kind {
        case .history:
            BotHistoryView(profile: sheet.profile)
        case .knows:
            // The Memory tab reads through the add-on, which keeps the private bot's memory to itself.
            ProfileInfoSheet(chat: sheet.chatID.flatMap { model.runtime?.chatForStored($0) }, profileName: sheet.profile, startTall: true,
                             initialTab: .memory)
        case .settings:
            // Opened for its settings: tall from the start, so the tabs and the rows under them show.
            ProfileInfoSheet(chat: sheet.chatID.flatMap { model.runtime?.chatForStored($0) }, profileName: sheet.profile, startTall: true,
                             initialTab: demoTab)
        case .board:
            NavigationStack { KanbanView(embedded: true).doneToolbar() }
        case .schedules:
            NavigationStack { CronView().navigationTitle("Schedules").doneToolbar(id: "schedules.close") }
        case .share:
            FamilyShareView(profile: sheet.profile)
        }
    }
}

// MARK: - History

/// A bot's other chats, newest first: its side chats and its scheduled runs, with its main chat
/// on top. A click opens one where the chat was and closes this; the chat's header says whose it
/// is and has the way back to the main chat.
struct BotHistoryView: View {
    var profile: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [StoredSession] = []
    @State private var found: [StoredSession]?
    @State private var query = ""
    @State private var loading = true
    @State private var errorText: String?
    @State private var pendingDelete: StoredSession?

    private var runtime: GatewayRuntime? { model.runtime }
    private var bot: ProfileInfo? { runtime?.profiles.first { $0.name == profile } }
    private var name: String { bot?.shownName ?? profile }
    private var mainID: String? { runtime.map { BotsHome.shared.entry($0, profile).storedID } ?? nil }
    private var shown: [StoredSession] {
        let list = found ?? sessions
        // The main chat first, then the rest by when they were last used.
        return list.sorted { a, b in
            if (a.id == mainID) != (b.id == mainID) { return a.id == mainID }
            return (a.lastActive ?? a.startedAt ?? 0) > (b.lastActive ?? b.startedAt ?? 0)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if let errorText {
                    Text(errorText).font(.footnote).foregroundStyle(.red)
                }
                ForEach(shown) { chat in
                    Button { open(chat) } label: {
                        BotHistoryRow(session: chat, profile: profile, isMain: chat.id == mainID)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { menu(for: chat) }
                    #if os(iOS)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) { swipes(for: chat) }
                    #endif
                    .accessibilityIdentifier("history.row")
                }
            }
            .listStyle(.plain)
            .overlay {
                if loading && sessions.isEmpty {
                    ProgressView()
                } else if shown.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "No other chats yet" : "Nothing found", systemImage: "clock",
                                           description: Text(query.isEmpty ? "Side chats and scheduled runs with \(name) will show here." : "Try other words."))
                }
            }
            .searchable(text: $query, prompt: "Search \(name)'s chats")
            .onChange(of: query) { _, q in Task { await search(q) } }
            .navigationTitle("\(name)'s history")
            .doneToolbar()
            .task { await load() }
            .alert("Delete this chat?", isPresented: confirmingDelete) {
                Button("Delete", role: .destructive) {
                    if let doomed = pendingDelete { Task { await delete(doomed) } }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The chat and its messages are removed from the gateway.")
            }
        }
    }

    private var confirmingDelete: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    @ViewBuilder private func menu(for chat: StoredSession) -> some View {
        Button { open(chat) } label: { Label("Open", systemImage: "bubble.left") }
        if chat.id != mainID {
            archiveButton(chat)
            Divider()
            Button(role: .destructive) { pendingDelete = chat } label: { Label("Delete…", systemImage: "trash") }
        }
    }

    @ViewBuilder private func swipes(for chat: StoredSession) -> some View {
        if chat.id != mainID {
            Button(role: .destructive) { pendingDelete = chat } label: { Label("Delete", systemImage: "trash") }
            archiveButton(chat).tint(.orange)
        }
    }

    private func archiveButton(_ chat: StoredSession) -> some View {
        Button { Task { await archive(chat) } } label: { Label("Archive", systemImage: "archivebox") }
    }

    /// Opens where the chat was (the window's chat on the Mac, pushed on the phone), once this
    /// has gone, so the two do not move at the same moment.
    private func open(_ s: StoredSession) {
        let isMain = s.id == mainID
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(320))
            if isMain { _ = await model.openMainChat(profile) } else { model.openStoredChat(id: s.id, profile: profile) }
        }
    }

    private func load() async {
        defer { loading = false }
        guard let runtime else { return }
        let firstHundred = [URLQueryItem(name: "order", value: "recent"), URLQueryItem(name: "limit", value: "100")]
        do {
            let reply: SessionListResponse = try await runtime.api.get("/api/sessions", query: firstHundred,
                                                                       profile: profile)
            sessions = reply.sessions.map { listed in
                var tagged = listed
                if tagged.profile?.isEmpty != false { tagged.profile = profile }
                return tagged
            }
            errorText = nil
        } catch is CancellationError {
            // A newer load took over.
        } catch {
            let said = error.localizedDescription
            if !said.localizedCaseInsensitiveContains("cancelled") { errorText = said }
        }
    }

    private func search(_ words: String) async {
        let wanted = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let runtime, !wanted.isEmpty else { found = nil; return }
        let asked = [URLQueryItem(name: "q", value: wanted)]
        guard let reply: JSONValue = try? await runtime.api.get("/api/sessions/search", query: asked, profile: profile) else { return }
        // The field moved on while the gateway answered: this answer is for an older question.
        guard query.trimmingCharacters(in: .whitespacesAndNewlines) == wanted else { return }
        let hits = reply["sessions"]?.arrayValue ?? reply["results"]?.arrayValue ?? reply.arrayValue ?? []
        found = hits.compactMap { try? $0.decode(StoredSession.self) }
    }

    /// Takes a chat out of both lists at once.
    private func forget(_ session: StoredSession) {
        sessions.removeAll { $0.id == session.id }
        found?.removeAll { $0.id == session.id }
    }

    private func archive(_ session: StoredSession) async {
        guard let runtime else { return }
        forget(session)
        let change: [String: JSONValue] = ["archived": .bool(true), "pinned": .bool(false), "profile": .string(profile)]
        let _: JSONValue? = try? await runtime.api.send("PATCH", "/api/sessions/\(session.id)", json: .object(change))
        NotificationCenter.default.post(name: .hermesSessionsChanged, object: nil)
    }

    private func delete(_ session: StoredSession) async {
        guard let runtime else { return }
        if let open = runtime.chatForStored(session.id) { runtime.closeChat(open) }
        forget(session)
        let _: JSONValue? = try? await runtime.api.send("DELETE", "/api/sessions/\(session.id)", profile: profile, body: EmptyBody())
        NotificationCenter.default.post(name: .hermesSessionsChanged, object: nil)
    }
}

/// One chat in a bot's history: what kind it is, its title, its first words, when.
struct BotHistoryRow: View {
    var session: StoredSession
    var profile: String
    var isMain: Bool

    private var isRun: Bool { (session.source ?? "").lowercased() == "cron" || session.id.hasPrefix("cron_") }
    private var title: String {
        if isMain { return String(localized: "Main chat") }
        return MainChatCard.shownTitle(session.displayTitle)
    }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if isMain {
                    // Only a picture: the row takes the tap.
                    BotAvatar(profile: profile, size: 30).allowsHitTesting(false)
                } else {
                    Image(systemName: isRun ? "clock" : "bubble.left")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Ink.text2)
                        .frame(square: 30)
                        .background(Ink.bubble, in: .circle)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title).font(Ink.rowName).foregroundStyle(Ink.text).lineLimit(1)
                    if isRun {
                        Text("Scheduled run").font(Ink.pill).foregroundStyle(Ink.text2)
                            .inset(h: 7, v: 1)
                            .overlay(Capsule().strokeBorder(Ink.line, lineWidth: 1))
                    }
                    Spacer(minLength: 4)
                    if let d = session.lastDate {
                        Text(BotsHome.when(d)).font(Ink.rowTime).foregroundStyle(Ink.text3).monospacedDigit().lineLimit(1)
                    }
                }
                if let p = session.preview?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty, !isMain {
                    Text(MainChatCard.oneLine(p)).font(Ink.rowPreview).foregroundStyle(Ink.text2).lineLimit(1)
                } else if isMain {
                    Text("Where a click on the bot goes").font(Ink.rowPreview).foregroundStyle(Ink.text3).lineLimit(1)
                }
            }
        }
        .inset(v: 6)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}
