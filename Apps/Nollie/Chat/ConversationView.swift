import SwiftUI
import NollieCore

/// One chat on screen: the thread, the dock under it and the header over it.
struct ConversationView: View {
    var route: ChatRoute

    @State private var loader = ConversationLoader()
    @State private var panels = Set<ConversationPanel>()
    @State private var metrics = ThreadMetrics()
    @State private var composerText = ""
    /// Text picked with Reply, shown quoted over the next message the way Messages does.
    @State private var composerQuote = ""
    @State private var confirming: ApprovalConfirm?
    @Namespace private var glass
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    var body: some View {
        content
            // Like Messages, the composer takes the bottom edge inside a conversation.
            .hidesTabBar()
            // With the navigation bar hidden UIKit drops swipe-back, so turn it on again.
            .background(InteractivePopEnabler())
            .task { await start() }
    }

    @ViewBuilder private var content: some View {
        if let chat = loader.chat {
            opened(chat)
        } else if let failure = loader.failure {
            unopened(failure)
        } else {
            ProgressView("Opening…")
        }
    }

    private func unopened(_ why: String) -> some View {
        ContentUnavailableView("Could not open chat", systemImage: "exclamationmark.triangle",
                               description: Text(why))
    }

    private func actions(for chat: ChatSession) -> ConversationActions {
        ConversationActions(
            show: { panels.insert($0) },
            newChat: { Task { await loader.startFresh(model: model) } },
            back: { dismiss() },
            close: { model.runtime?.closeChat(chat); dismiss() })
    }

    /// An open chat with everything that reacts to it.
    private func opened(_ chat: ChatSession) -> some View {
        frame(of: chat)
            .handsOff(chat)
            #if os(macOS)
            .navigationTitle("")
            .toolbar(removing: .title)
            #else
            .navigationTitle(MainChatCard.shownTitle(chat.title))
            #endif
            .toolbar(.hidden, for: .navigationBar)
            .modifier(ConversationSheets(chat: chat, open: $panels))
            .modifier(ApprovalConfirmation(chat: chat, asked: $confirming))
            .modifier(ChatVisibility(chat: chat, requestedID: loader.requestedID,
                                     obscured: !panels.isEmpty || confirming != nil,
                                     clearRead: { clearDelivered(for: chat) }))
            .onReceive(NotificationCenter.default.publisher(for: .hermesNewChatRequested)) { note in
                guard model.visibleChatID == chat.storedID else { return }
                model.composeProfile = (note.userInfo?["profile"] as? String) ?? chat.profileName
                // `/new` asks for a chat of its own, not the bot's main chat.
                model.sideChatRequestedAt = Date()
                model.newChatRequest = UUID()
            }
            .onChange(of: model.pendingRoute) { _, pending in take(pending, for: chat) }
            .onChange(of: model.lock.isLocked) { _, locked in if !locked { take(model.pendingRoute, for: chat) } }
            .onAppear { take(model.pendingRoute, for: chat) }
            // Typed text is kept when leaving the chat. It is saved for each chat and cleared on send.
            .onChange(of: composerText) { _, typed in ComposerDrafts.save(typed, for: chat) }
            #if DEBUG
            .task { await openWatchForDemo(chat) }
            #endif
    }

    private func frame(of chat: ChatSession) -> some View {
        let actions = actions(for: chat)
        return ConversationFrame(metrics: $metrics) {
            thread(chat)
        } dock: {
            BottomDock(chat: chat, text: $composerText, quote: $composerQuote, namespace: glass, readOnly: route.readOnly)
                .disabled(chat.resumeError != nil && chat.items.isEmpty)
                .modifier(DockMeasured(metrics: $metrics))
        } header: {
            #if os(macOS)
            BoardContextStrip(chat: chat)
            #else
            ConversationTopBar(chat: chat, actions: actions, metrics: $metrics)
            #endif
        }
        #if os(macOS)
        .toolbar { ConversationToolbar(chat: chat, actions: actions) }
        #endif
    }

    private func thread(_ chat: ChatSession) -> some View {
        let margins = metrics.thread
        let canOfferIdeas = !route.readOnly && chat.profileName == "default" && composerText.isEmpty && !chat.isRunning
        return TranscriptView(
            chat: chat,
            onEditMessage: { composerText = $0 },
            onOpenBot: { handle in Task { if let why = await model.openBotChat(handle) { chat.banner = why } } },
            onReply: { text in withAnimation(.snappy) { composerQuote = text } },
            onStartIdea: canOfferIdeas ? { idea in
                guard !route.readOnly, !model.lock.isLocked, model.runtime === chat.runtime,
                      composerText.isEmpty, !chat.isRunning else { return }
                composerText = idea
            } : nil,
            notificationFocus: loader.focus, dockTop: margins.dockTop, fallbackInset: margins.fallback, topInset: margins.top)
        #if os(iOS)
        // The header, dock and keyboard margins together demand some minimum height. On a compact phone with the
        // keyboard showing, that exceeds the available room; the screen then came out too tall and
        // centred, with the header under the status bar. So the thread simply takes what it is offered.
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
        #endif
        .overlay {
            if let problem = chat.resumeError, chat.items.isEmpty {
                unopened(problem)
                    // Middle of the space left above the composer and keyboard.
                    .padding(.bottom, metrics.dock + metrics.keyboard)
            }
        }
    }

    // MARK: Opening

    private func start() async {
        guard let session = await loader.open(route, model: model) else { return }
        if composerText.isEmpty, let draft = ComposerDrafts.load(for: session) { composerText = draft }
        #if DEBUG
        stageTestFile(in: session)
        #endif
        await loader.sendFirstMessage(of: route, in: session)
    }

    /// A notification's route for this chat brings its message into focus.
    private func take(_ pending: PendingRoute?, for chat: ChatSession) {
        guard let pending, !model.lock.isLocked, model.runtime === chat.runtime, loader.chat === chat,
              NotificationNavigation.matches(pending, connectionID: chat.runtime.connection.id, profile: chat.profileName,
                                             sessionID: chat.storedID, requestedSessionID: loader.requestedID) else { return }
        if let focus = pending.messageFocus { loader.focus = focus }
        model.pendingRoute = nil
    }

    private func clearDelivered(for chat: ChatSession) {
        let reading = ForegroundNotificationPolicy.isReading(
            connectionID: chat.runtime.connection.id, profile: chat.profileName, sessionID: chat.storedID,
            context: ForegroundNotificationPolicy.context(model))
        if reading {
            LocalNotifier.clearDelivered(for: chat.storedID, connection: chat.runtime.connection, profile: chat.profileName)
        }
    }

    /// What the approval alert reads back. Ask first shows its action and the "you're about to"
    /// line; a plugin's rule never shows the gateway's "(plugin approval rule)" command.
    nonisolated static func confirmWords(_ request: ApprovalRequest) -> String {
        if let ask = AskFirstAsk(request) { return [ask.summary, ask.check].compactMap { $0 }.joined(separator: "\n\n") }
        let command = request.patternKey?.hasPrefix("plugin_rule:") == true ? nil : request.command
        return [request.description, command].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    #if DEBUG
    /// UI tests can pass `-nollie-test-stage <name>.pdf` to stage a small PDF under that name when the
    /// chat opens, since automation cannot operate the system file picker.
    private func stageTestFile(in session: ChatSession) {
        guard session.staged.isEmpty, let name = UserDefaults.standard.string(forKey: "nollie-test-stage"), !name.isEmpty else { return }
        let pdf = "%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[]/Count 0>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n"
        session.stageAttachment(data: Data(pdf.utf8), name: name, kind: .pdf)
    }

    /// For design pictures, `-nollie-demo-watch` opens Watch once the helper is on its computer.
    private func openWatchForDemo(_ chat: ChatSession) async {
        guard DemoMode.isOn, ProcessInfo.processInfo.arguments.contains("-nollie-demo-watch") else { return }
        for _ in 0..<40 {
            let active = BotComputerActivity.isActive(runtime: chat.runtime, profile: chat.profileName)
            let held = ComputerHandoff.shared.isHeld(chat.runtime, chat.profileName)
            if WatchPolicy.showsWatch(active: active, held: held, isPrivate: PrivateBots.isPrivate(chat.profileName)) {
                panels.insert(.watch)
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }
    #endif
}
