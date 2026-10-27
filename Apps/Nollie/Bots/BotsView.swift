import SwiftUI
import NollieCore

/// The Bots page. Each bot maps to a gateway profile that has its own instructions, model and
/// chats, the chats being that profile's saved sessions.
struct BotsView: View {
    /// Pushed from a bot's long-press menu: its settings page.
    struct BotSettingsRoute: Hashable { var profile: String }

    @Environment(AppModel.self) private var model
    @State private var path = NavigationPath()
    @State private var query = ""
    @State private var showNewBot = false

    var body: some View {
        NavigationStack(path: $path) {
            content
                .modifier(BotsChrome(query: $query, adding: $showNewBot))
                .tabRoot(.bots)
                .background(InteractivePopEnabler())
                .overlay { debugOverlay }
                .modifier(BotsRoutes())
                .reloadable { await fetchProfiles() }
                .task(id: model.runtime?.connection.id) { await fetchProfiles() }
        }
    }

    private var content: some View {
        ScrollView {
            // On the Mac the cards stay phone-sized in a column rather than stretching into window-wide pills.
            Group {
                if let runtime = model.runtime {
                    BotGrid(runtime: runtime, query: query, open: { path.append($0) })
                } else {
                    Placeholder("No gateway selected", symbol: "antenna.radiowaves.left.and.right.slash")
                }
            }
            .readingColumn()
        }
        .onScrollGeometryChange(for: CGFloat.self, of: \.contentOffset.y) { before, after in
            BotAmbient.shared.scrolled(dy: after - before)
        }
    }

    @ViewBuilder private var debugOverlay: some View {
        #if DEBUG
        let flags = ProcessInfo.processInfo.arguments
        if flags.contains("-nollie-look-grid") { LookSeatGrid() }
        if flags.contains("-nollie-motion-demo") { MotionDemoView() }
        #endif
    }

    private func fetchProfiles() async {
        guard let runtime = model.runtime, runtime.profiles.isEmpty else { return }
        await runtime.loadProfiles()
    }
}

/// The bots laid out as cards: two columns on the phone, as many as fit on the Mac, with a note
/// beneath.
private struct BotGrid: View {
    var runtime: GatewayRuntime
    var query: String
    /// Pushes a route on the page's stack.
    var open: (any Hashable) -> Void

    #if os(macOS)
    private let columns = [GridItem(GridItem.Size.adaptive(minimum: 150, maximum: 210), spacing: 18)]
    #else
    private let columns = [GridItem](repeating: .init(.flexible(), spacing: 14), count: 2)
    #endif

    private var matching: [ProfileInfo] {
        guard !query.isEmpty else { return runtime.profiles }
        return runtime.profiles.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.label.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            LazyVGrid(columns: columns, spacing: 22) {
                ForEach(matching) { bot in
                    NavigationLink(value: bot) {
                        BotCard(
                            profile: bot,
                            isActive: runtime.selectedProfile == bot.name,
                            working: runtime.chats.contains { $0.profileName == bot.name && $0.isRunning })
                    }
                    .buttonStyle(.plain)
                    .contextMenu { menu(for: bot) }
                }
            }
            .inset(h: 16)
            .padding(.top, 18)
            if runtime.profiles.isEmpty {
                Text("This gateway has no profiles yet.").small(.footnote).padding()
            }
            Text("A bot is a Hermes profile with its own SOUL.md, model and sessions. \(DeviceWords.Tap) one to see its chats.")
                .multilineTextAlignment(.center)
                .small(.footnote)
                .inset(h: 28)
                .padding(.top, 14)
        }
    }

    /// The long-press menu: shortcuts to things you would otherwise hunt for.
    @ViewBuilder private func menu(for bot: ProfileInfo) -> some View {
        Button("New chat", systemImage: "square.and.pencil") {
            open(ChatRoute(storedID: nil, title: nil, profile: bot.name))
        }
        Button("Chats", systemImage: "bubble.left.and.bubble.right") { open(bot) }
        Button("Bot settings", systemImage: "slider.horizontal.3") {
            open(BotsView.BotSettingsRoute(profile: bot.name))
        }
        if runtime.selectedProfile != bot.name {
            Button("Make active", systemImage: "checkmark.circle") { runtime.selectedProfile = bot.name }
        }
    }
}

/// The page's title, its search box, and the plus button in the corner with the sheet it opens.
private struct BotsChrome: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var query: String
    @Binding var adding: Bool

    func body(content: Content) -> some View {
        content
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search bots")
            .navigationTitle("Bots")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New bot", systemImage: "plus") { adding = true }.labelStyle(.iconOnly)
                }
            }
            .sheet(isPresented: $adding) {
                if let runtime = model.runtime {
                    NewBotSheet(runtime: runtime).sheetFrame().withAppModel()
                }
            }
    }
}

/// Where the page's links lead: a bot's chats, its settings, a chat.
private struct BotsRoutes: ViewModifier {
    func body(content: Content) -> some View {
        content
            .navigationDestination(for: BotsView.BotSettingsRoute.self) {
                ProfileCardView(profileName: $0.profile).untitledPage()
            }
            .navigationDestination(for: ChatRoute.self) { ChatDestination(route: $0) }
            .navigationDestination(for: ProfileInfo.self) { BotDetailView(profile: $0) }
    }
}

/// One bot card: the character stands on a glass pill showing the bot's name and model, styled
/// as at the top of its chat. It blinks, glances around and moves while working.
struct BotCard: View {
    var profile: ProfileInfo
    var isActive: Bool
    var working: Bool

    static let size: CGFloat = 78
    /// How far the character's feet reach over the top of the pill.
    static let overlap: CGFloat = 10

    /// The model without the provider in front of it.
    private var modelName: String {
        profile.model.map { String($0.split(separator: "/").last ?? Substring($0)) } ?? Self.noModel
    }

    private static let noModel = String(localized: "no model", comment: "A bot with no model set")

    private var spokenLabel: String {
        var words = [String(localized: "\(profile.label), \(profile.model ?? Self.noModel)", comment: "VoiceOver: a bot's name, then its model")]
        if isActive { words.append(String(localized: "active", comment: "VoiceOver: the bot in use")) }
        if working { words.append(String(localized: "working", comment: "VoiceOver: the bot is busy")) }
        return words.joined(separator: ", ")
    }

    var body: some View {
        let seat = BotAvatarStore.seat(for: profile.name, size: Self.size, overlap: Self.overlap)
        VStack(spacing: -seat) {
            BotAvatar(profile: profile.name, size: Self.size, state: working ? .working : .idle)
                .zIndex(1)
            namePill
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenLabel)
    }

    private var namePill: some View {
        VStack(spacing: 2) {
            HStack(spacing: 5) {
                Text(profile.label).lineLimit(1).font(.subheadline.weight(.semibold))
                if isActive { activeDot }
            }
            Text(modelName).small(.caption2).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 7, trailing: 14))
        .nollieGlass(.regular.interactive(), in: .capsule)
    }

    private var activeDot: some View {
        Circle()
            .fill(Color.nollie)
            .frame(square: 6)
            .accessibilityLabel(Text("active", comment: "VoiceOver: the bot in use"))
    }
}

#if DEBUG
/// Every character look on its pill, to check they all sit the same way.
private struct LookSeatGrid: View {
    private let pair = [GridItem](repeating: GridItem(.flexible(), spacing: 14), count: 2)

    var body: some View {
        ScrollView {
            LazyVGrid(columns: pair, spacing: 22) {
                ForEach(CharacterLookID.allCases) { look in
                    let gap = CharacterDrawing.footGap(look, size: BotCard.size) + BotCard.overlap
                    VStack(spacing: -gap) {
                        CharacterView(look: look, size: BotCard.size, seed: CharacterLookID.seed("grid-" + look.rawValue))
                            .zIndex(1)
                        VStack(spacing: 2) {
                            Text(look.name).font(.subheadline.weight(.semibold))
                            Text("model").small(.caption2)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(EdgeInsets(top: 12, leading: 14, bottom: 7, trailing: 14))
                        .nollieGlass(.regular, in: .capsule)
                    }
                }
            }
            .padding(16)
        }
        .background { Color(.systemBackground) }
    }
}
#endif
