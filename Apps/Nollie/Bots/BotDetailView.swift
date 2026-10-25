import SwiftUI
import NollieCore

/// What the bot's page knows about its chats, and the two calls it makes for them.
@MainActor @Observable
final class BotChats {
    let botName: String
    private(set) var sessions: [StoredSession] = []
    private(set) var failure: String?

    init(botName: String) { self.botName = botName }

    private static let newestFirst = [
        URLQueryItem(name: "order", value: "recent"),
        URLQueryItem(name: "limit", value: "100"),
    ]

    func refresh(from runtime: GatewayRuntime) async {
        do {
            let list: SessionListResponse = try await runtime.api.get(
                "/api/sessions", query: Self.newestFirst, profile: botName)
            sessions = list.sessions
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    func delete(_ session: StoredSession, from runtime: GatewayRuntime) async {
        if let open = runtime.chatForStored(session.id) { runtime.closeChat(open) }
        let _: JSONValue? = try? await runtime.api.send(
            "DELETE", "/api/sessions/\(session.id)", profile: botName, body: EmptyBody())
        await refresh(from: runtime)
    }
}

/// One bot's page: a link to its settings, then its chats. Opening a chat first makes this bot
/// the selected profile, since every session call is scoped to a profile.
struct BotDetailView: View {
    var profile: ProfileInfo

    @Environment(AppModel.self) private var model
    @State private var chats: BotChats
    @State private var doomed: StoredSession?
    @State private var startingChat = false

    init(profile: ProfileInfo) {
        self.profile = profile
        _chats = State(initialValue: BotChats(botName: profile.name))
    }

    var body: some View {
        SettingsList {
            Section { SettingsEntry(profile: profile) }
            Section("Chats") {
                ChatRows(chats: chats, profile: profile, askToDelete: { doomed = $0 })
            }
        }
        .inlineTitle(profile.label)
        .modifier(ComposeTarget(profile: profile.name, starting: $startingChat))
        .reloadable { await reload() }
        .task { await reload() }
        .alert("Delete chat?", isPresented: .present($doomed), presenting: doomed) { session in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { Task { await erase(session) } }
        } message: { _ in
            Text("The chat and its transcript are deleted from the gateway.")
        }
    }

    private func reload() async {
        if let runtime = model.runtime { await chats.refresh(from: runtime) }
    }

    private func erase(_ session: StoredSession) async {
        if let runtime = model.runtime { await chats.delete(session, from: runtime) }
    }
}

/// The row that opens the bot's own settings.
private struct SettingsEntry: View {
    var profile: ProfileInfo

    var body: some View {
        NavigationLink(destination: ProfileCardView(profileName: profile.name)) {
            Label {
                Text("Bot settings")
            } icon: {
                BotAvatar(profile: profile.name, size: 36)
            }
            .labelStyle(AvatarBesideText())
        }
    }
}

/// Icon first, then words, with a little room between.
private struct AvatarBesideText: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.icon
            configuration.title
        }
    }
}

/// While this page shows, a new chat from the tab bar's compose circle goes to this bot.
private struct ComposeTarget: ViewModifier {
    @Environment(AppModel.self) private var model
    var profile: String
    @Binding var starting: Bool

    private var freshChat: ChatRoute { ChatRoute(storedID: nil, title: nil, profile: profile) }

    func body(content: Content) -> some View {
        content
            .onAppear { model.composeProfile = profile }
            .onDisappear {
                if model.composeProfile == profile { model.composeProfile = nil }
            }
            .onChange(of: model.newChatRequest) { _, request in
                let onThisPage = model.selectedTab == .bots && model.composeProfile == profile
                if request != nil && onThisPage { starting = true }
            }
            .navigationDestination(isPresented: $starting) { ConversationView(route: freshChat) }
    }
}

/// The rows under "Chats": a note when there is nothing or something went wrong, else one row a chat.
private struct ChatRows: View {
    var chats: BotChats
    var profile: ProfileInfo
    var askToDelete: (StoredSession) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        if let failure = chats.failure {
            Text(failure).small(.footnote, .red)
        } else if chats.sessions.isEmpty {
            Text("No chats with this bot yet.").small(.footnote)
        }
        ForEach(chats.sessions) { session in
            NavigationLink(value: route(for: session)) {
                SessionRow(
                    session: session,
                    needsYou: model.runtime?.needsAttention.contains(session.id) == true,
                    live: model.runtime?.chatForStored(session.id)?.isRunning == true)
            }
            .contextMenu {
                Button("Delete", systemImage: "trash", role: .destructive) { askToDelete(session) }
            } preview: {
                SessionPreview(session: session).withAppModel()
            }
        }
    }

    private func route(for session: StoredSession) -> ChatRoute {
        ChatRoute(storedID: session.id, title: session.displayTitle, profile: profile.name)
    }
}
