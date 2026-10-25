import NollieCore
import SwiftUI

/// Where a chat opens. Today that is `ConversationView`. In Debug builds with Developer Mode and Settings ›
/// Advanced › New chat view on, a stored chat of your own opens on the new conversation screen instead, run by
/// `ConversationEngine` on its own gateway client. See "Switching over" in `Docs/specs/conversation-ui.md`.
struct ChatDestination: View {
    static let newChatViewKey = "nollie.newChatView"

    let route: ChatRoute
    #if DEBUG
    @AppStorage("nollie.developerMode") private var developerMode = false
    @AppStorage(Self.newChatViewKey) private var newChatView = false

    /// The stored chat to open in the new screen when the route allows it. A brand new chat, a first
    /// message written in the compose sheet, or reading another bot's chat all remain on the old view,
    /// because the engine only attaches to an existing chat and sends plain text.
    private var liveTarget: String? {
        guard developerMode, newChatView, !route.readOnly else { return nil }
        guard route.initialText == nil, route.initialAttachments.isEmpty else { return nil }
        return route.storedID
    }
    #endif

    var body: some View {
        #if DEBUG
        if let stored = liveTarget {
            LiveConversationView(route: route, storedID: stored)
        } else {
            ConversationView(route: route)
        }
        #else
        ConversationView(route: route)
        #endif
    }
}

extension ProfileInfo {
    /// A profile's name with a capital, for a bot the runtime has not listed yet.
    static func shownName(of profile: String) -> String {
        guard let first = profile.first else { return profile }
        return first.uppercased() + profile.dropFirst()
    }
}

#if DEBUG
/// An actual chat in the new screen, with a gateway client and engine of its own while it is open.
struct LiveConversationView: View {
    let route: ChatRoute
    let storedID: String

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var live: LiveConversation?
    @State private var failure: String?

    var body: some View {
        stage
            .inlineTitle(route.title ?? botName(route.profile ?? "default"))
            .hidesTabBar()
            .task(id: storedID) { await open() }
            .onAppear { model.visibleChatID = storedID }
            .onDisappear {
                if model.visibleChatID == storedID { model.visibleChatID = nil }
                live?.close()
                live = nil
            }
    }

    @ViewBuilder private var stage: some View {
        if let live {
            screen(for: live)
        } else if let failure {
            Placeholder("Could not open chat", symbol: "exclamationmark.triangle", detail: failure)
        } else {
            ProgressView()
        }
    }

    @ViewBuilder private func screen(for live: LiveConversation) -> some View {
        let name = botName(live.profile)
        #if os(iOS)
        // The bot appears once above the thread, name below it, like the header of the old chat.
        ConversationScreen(engine: live.engine)
            .safeAreaInset(edge: .top, spacing: 0) {
                ConversationHeader(engine: live.engine, profile: live.profile, name: name, back: { dismiss() })
            }
            .toolbar(.hidden, for: .navigationBar)
            .background(InteractivePopEnabler())
        #else
        ConversationScreen(engine: live.engine)
            .toolbar {
                ToolbarItem(placement: .principal) { ConversationBotTitle(profile: live.profile, name: name) }
                    .sharedBackgroundVisibility(.hidden)
            }
        #endif
    }

    private func botName(_ profile: String) -> String {
        model.runtime?.profiles.first { $0.name == profile }?.shownName ?? ProfileInfo.shownName(of: profile)
    }

    private func open() async {
        guard live == nil else { return }
        guard let runtime = model.runtime,
              route.connectionID == nil || route.connectionID == runtime.connection.id
        else {
            failure = "The connection for this conversation is no longer open."
            return
        }
        let profile = route.profile ?? runtime.selectedProfile ?? "default"
        // Nollie's cards (the night shift, rehearsals) go only to the default bot's main chat.
        let isMainChat = route.isMain || storedID == BotsHome.shared.entry(runtime, "default").storedID
        let opened = LiveConversation(
            runtime: runtime, storedID: storedID, profile: profile, posts: profile == "default" && isMainChat)
        live = opened
        await opened.start()
    }
}

/// Thread header for the phone: a Back button, and the bot shown once and centred, resting on a
/// translucent pill with its name and current activity below. Never drawn next to bubbles.
struct ConversationHeader: View {
    let engine: ConversationEngine
    let profile: String
    let name: String
    let back: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            HStack {
                GlassCircleButton(symbol: "chevron.left", diameter: 44, font: .title3, action: back)
                    .accessibilityLabel("Back")
                    .testID("chat.back")
                Spacer()
            }
            ConversationBotPill(engine: engine, profile: profile, name: name)
        }
        .inset(h: 16)
        .padding(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
        .frame(maxWidth: .infinity)
        .background(Ink.canvas.ignoresSafeArea(edges: .top))
    }
}

/// What the bot's pill shows, worked out from where the engine is: one word under the name, and the
/// character's pose.
@MainActor
private struct PillReading {
    var word: String?
    var pose: CharacterState

    init(_ engine: ConversationEngine) {
        let chat = engine.state
        if engine.phase != .ready {
            word = "Connecting"
        } else {
            word = chat.activity.shownWords ?? (chat.running ? "Writing" : nil)
        }
        // Pending questions take the line first; otherwise it shows the turn's current step.
        if !chat.cards.isEmpty {
            pose = .needsYou
            return
        }
        switch chat.activity {
        case .sending, .thinking: pose = .thinking
        case .writing: pose = .speaking
        case .runningTool, .preparingTool: pose = .usingTool
        case .summarizing, .status: pose = .working
        case .idle: pose = chat.running ? .working : .idle
        }
    }
}

/// The bot this chat is with: its character seated on a glass pill that holds its name and, while it works, one word.
struct ConversationBotPill: View {
    let engine: ConversationEngine
    let profile: String
    let name: String

    /// Names past 26 letters are cut to 25 and an ellipsis.
    private var shortName: String {
        name.count > 26 ? String(name.prefix(25)) + "…" : name
    }

    var body: some View {
        let reading = PillReading(engine)
        // Sits with its base on the pill, same as the header in the old chat.
        VStack(spacing: -BotAvatarStore.seat(for: profile, size: 52, overlap: 8)) {
            BotAvatar(profile: profile, size: 52, state: reading.pose)
                .zIndex(1)
                .allowsHitTesting(false)
            plate(word: reading.word)
        }
        .animation(.snappy(duration: 0.2), value: reading.word)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .testID("conversation.botPill")
    }

    private func plate(word: String?) -> some View {
        VStack(spacing: 1) {
            Text(shortName).font(.caption.weight(.semibold)).foregroundStyle(Ink.text).lineLimit(1)
            if let word {
                Text(word).small(.caption2).lineLimit(1).contentTransition(.opacity)
            }
        }
        .padding(EdgeInsets(top: 11, leading: 14, bottom: 6, trailing: 14))
        .fixedSize(horizontal: false, vertical: true)
        .nollieGlass(.regular, in: .capsule)
    }
}

#if os(macOS)
/// The bot in the Mac's toolbar: its character, its name under it.
struct ConversationBotTitle: View {
    let profile: String
    let name: String

    var body: some View {
        VStack(spacing: 1) {
            BotAvatar(profile: profile, size: 22)
            Text(name).font(.caption.weight(.semibold)).foregroundStyle(Ink.text).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .testID("conversation.botPill")
    }
}
#endif

/// One open chat on the new engine: a gateway client of its own on the runtime's connection, Hermes's stored
/// history over the runtime's REST client, and a cache on disk.
@MainActor
final class LiveConversation {
    let engine: ConversationEngine
    let profile: String
    private let client: GatewayClient
    private var feed: Task<Void, Never>?

    /// The cards this screen can answer.
    private static let answerable: Set<String> = ["approval", "clarify", "sudo", "secret"]

    /// `posts`: the chat shows the workflow add-on's cards.
    init(runtime: GatewayRuntime, storedID: String, profile: String, posts: Bool = false) {
        self.profile = profile
        var setup = GatewayConfiguration()
        setup.shownQuestions = Self.answerable
        let socket = WebSocketGatewayTransport(configuration: HermesAPI.sessionConfiguration())
        let link = GatewayClient(transport: socket, configuration: setup) { [weak runtime] in
            guard let runtime else { throw CancellationError() }
            return try await runtime.gatewayEndpoint()
        }
        client = link
        let api = runtime.api
        let history = HermesConversationHistory(profile: profile) { path, query in
            try await api.raw("GET", path, query: query, body: nil, authenticated: true).0
        }
        let cache: any ConversationCacheStore =
            (try? FileConversationCacheStore.applicationSupport()) ?? MemoryConversationCacheStore()
        engine = ConversationEngine(
            key: [runtime.connection.id.uuidString, profile, storedID].joined(separator: "/"),
            sessionId: storedID, link: link, history: history, lineageSource: history, store: cache,
            posts: posts ? HermesConversationPosts(api: api) : nil,
            configuration: .init(profile: profile))
    }

    func start() async {
        let (engine, client) = (engine, client)
        feed = Task { await engine.run(client.notices) }
        await client.start()
        await engine.start()
    }

    func close() {
        engine.close()
        feed?.cancel()
        let client = client
        Task { await client.stop() }
    }
}
#endif
