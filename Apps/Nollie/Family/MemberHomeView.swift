import SwiftUI
import NollieCore

/// The app on the phone of someone a helper was shared with: the helpers they were given, each with
/// its chats and a New chat button. No Board, no settings, no memory, nothing of the owner's. The
/// Mac's door already refuses all of that; this screen just doesn't offer it.
struct MemberHomeView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [ChatRoute] = []
    @State private var chats: [String: [StoredSession]] = [:]

    private var runtime: GatewayRuntime? { model.runtime }
    private var owner: String { model.family.ownerName(model) }

    /// The helpers this phone may reach. The door lists only those; the demo copy filters for itself.
    private var helpers: [ProfileInfo] {
        let all = runtime?.profiles ?? []
        guard let given = model.family.me?.helpers else { return all }
        return all.filter { given.contains($0.name) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                MemberHomePage(owner: owner, helpers: helpers.map { .init(profile: $0.name, name: $0.shownName) }, chats: chats,
                               newChat: { path.append(ChatRoute(profile: $0, token: UUID())) },
                               open: { chat, profile in path.append(ChatRoute(storedID: chat.id, title: chat.title, profile: profile)) })
                    .frame(maxWidth: 560)
                    .padding(EdgeInsets(top: 20, leading: 20, bottom: 40, trailing: 20))
                    .frame(maxWidth: .infinity)
            }
            .background(Ink.canvas.ignoresSafeArea())
            .refreshable { await load() }
            .navigationDestination(for: ChatRoute.self) { route in
                ConversationView(route: route)
            }
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
        }
        .environment(\.familyOwner, owner)
        .testID("member.home")
        .task(id: runtime?.connection.id) {
            await model.family.refreshMe(model)
            if runtime?.profiles.isEmpty == true { await runtime?.loadProfiles() }
            await load()
        }
        .task {
            #if DEBUG
            // Pictures: `-nollie-demo-member-chat` opens the first helper's new chat, and sends
            // `-nollie-demo-say` there when it is given.
            let args = ProcessInfo.processInfo.arguments
            if FamilyModel.demoRole == "member", args.contains("-nollie-demo-member-chat") {
                for _ in 0..<40 where helpers.isEmpty { try? await Task.sleep(for: .milliseconds(150)) }
                let say = args.firstIndex(of: "-nollie-demo-say").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
                if let first = helpers.first {
                    path.append(ChatRoute(profile: first.name, initialText: say?.replacingOccurrences(of: "-", with: " "), token: UUID()))
                }
            }
            #endif
        }
        .onChange(of: path) { _, now in if now.isEmpty { Task { await load() } } }
    }

    /// Each helper's chats: only theirs, as the Mac's door answers.
    private func load() async {
        guard let runtime else { return }
        for helper in helpers {
            let query = [URLQueryItem(name: "limit", value: "20"), URLQueryItem(name: "order", value: "recent")]
            if let reply: SessionListResponse = try? await runtime.api.get("/api/sessions", query: query, profile: helper.name) {
                chats[helper.name] = reply.sessions
            }
        }
    }
}

/// What a member sees, apart from where it comes from: also drawn by the design snapshots.
struct MemberHomePage: View {
    struct Helper: Identifiable, Hashable {
        var profile: String
        var name: String
        var id: String { profile }
    }

    var owner: String
    var helpers: [Helper]
    var chats: [String: [StoredSession]] = [:]
    var newChat: (String) -> Void = { _ in }
    var open: (StoredSession, String) -> Void = { _, _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Shared with you")
                    .font(.largeTitle.weight(.bold)).foregroundStyle(Ink.text)
                    .accessibilityAddTraits(.isHeader)
                    .testID("member.title")
                Text("From \(owner)")
                    .font(.title3).foregroundStyle(Ink.text2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 12)

            if helpers.isEmpty {
                Text("Nothing is shared with you right now.")
                    .font(.title3).foregroundStyle(Ink.text2)
                    .testID("member.empty")
            }
            ForEach(helpers) { helper in
                MemberHelperCard(helper: helper, chats: chats[helper.profile] ?? [], newChat: { newChat(helper.profile) },
                                 open: { open($0, helper.profile) })
            }

            // Safety: who says yes, and where the chats are kept.
            Label("\(owner) says yes to anything that matters. Your chats are kept on \(owner)'s Mac.", systemImage: "checkmark.shield.fill")
                .font(.footnote).foregroundStyle(Ink.text2)
                .fixedSize(horizontal: false, vertical: true)
                .testID("member.note")
        }
    }
}

/// One shared helper: its face and name, New chat, and the chats this person started with it.
struct MemberHelperCard: View {
    var helper: MemberHomePage.Helper
    var chats: [StoredSession]
    var newChat: () -> Void
    var open: (StoredSession) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                BotAvatar(profile: helper.profile, size: 64)
                Text(helper.name)
                    .font(.title.weight(.bold)).foregroundStyle(Ink.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
            }
            Button(action: newChat) { PageActionLabel(LocalizedStringResource("New chat"), symbol: "square.and.pencil") }
                .pageAction(tint: .teal)
                .accessibilityLabel("New chat with \(helper.name)")
                .testID("member.newChat")
            if !chats.isEmpty {
                VStack(spacing: 8) {
                    ForEach(chats.prefix(8)) { chat in
                        Button { open(chat) } label: { MemberChatRow(chat: chat) }
                            .buttonStyle(.plain)
                            .testID("member.chat")
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .testID("member.helper")
    }
}

/// A chat on a capsule: its title and when it was last used.
struct MemberChatRow: View {
    var chat: StoredSession

    private var when: String? {
        guard let stamp = chat.lastActive ?? chat.startedAt else { return nil }
        return Date(timeIntervalSince1970: stamp).formatted(.relative(presentation: .named))
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(chat.title.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "New chat"))
                .font(.body.weight(.medium)).foregroundStyle(Ink.text)
                .lineLimit(2)
            Spacer(minLength: 8)
            if let when { Text(when).font(.subheadline).foregroundStyle(Ink.text2) }
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Ink.text3)
                .accessibilityHidden(true)
        }
        .inset(h: 18, v: 12)
        .frame(minHeight: 48)
        .background(Ink.field, in: Capsule())
        .contentShape(Capsule())
        .accessibilityElement(children: .combine)
    }
}
