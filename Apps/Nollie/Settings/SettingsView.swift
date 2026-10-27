import NollieCore
import SwiftUI
import UserNotifications

/// The rows in a few groups, with air between them instead of lines.
private let settingsGroups: [[SettingsCategory]] = [
    [.bots, .appearance, .speech],
    [.notifications, .weekly, .privacy, .signIns, .cards, .siri],
    [.connection, .away, .keepAwake],
    [.about, .advanced],
]

struct SettingsView: View {
    var onClose: (() -> Void)? = nil
    @Environment(AppModel.self) private var model
    @AppStorage("nollie.developerMode") private var developerMode = false
    @State private var search = ""
    @State private var path: [SettingsCategory] = []
    @State private var showLeft = false
    #if DEBUG
    @State private var demoSummary: String?
    #endif

    private var summary: CrewSummaryModel { model.crewSummary }

    var body: some View {
        NavigationStack(path: $path) {
            SettingsPage("settings.page") {
                // The answer first: what left your Mac today, and what the crew did overnight.
                if model.isDemo { LeaveDemoRow() }
                if search.isEmpty, model.runtime != nil { CrewSummaryTiles(summary: summary) }
                categoryRows
            }
            .task(id: refreshKey) {
                if let runtime = model.runtime { await summary.load(runtime) }
            }
            .navigationDestination(for: SettingsCategory.self) { SettingsDestination(category: $0, developerMode: developerMode) }
            // The Mac sidebar's Papertrail button opens What left your Mac, from anywhere.
            .navigationDestination(isPresented: $showLeft) { LeftYourMacPage(summary: summary) }
            .onChange(of: model.papertrailRequest, initial: true) {
                guard model.papertrailRequest != nil else { return }
                model.papertrailRequest = nil
                path = []
                showLeft = true
            }
            .navigationTitle("Settings")
            #if DEBUG
            .task { await openDemoPage() }
            .navigationDestination(item: $demoSummary) { DemoSettingsPage(name: $0, summary: summary) }
            #endif
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search settings")
            .background(InteractivePopEnabler())
            .tabRoot(.settings)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if let onClose { Button("Done", action: onClose).testID("settings.done") }
                }
            }
        }
    }

    /// The summary is read again when the gateway, or the number of bots on it, changes.
    private var refreshKey: String {
        "\(model.runtime?.connection.id.uuidString ?? "")/\(model.runtime?.profiles.count ?? 0)"
    }

    @ViewBuilder private var categoryRows: some View {
        let visible = SettingsCategory.visible(developerMode: developerMode, away: showsAway,
                                               weekly: !model.family.isMember(model), matching: search)
        ForEach(settingsGroups.indices, id: \.self) { index in
            let members = settingsGroups[index].filter(visible.contains)
            if !members.isEmpty {
                GlassStack {
                    ForEach(members) { category in
                        NavigationLink(value: category) {
                            GlassRowLabel(
                                title: category.title, symbol: category.symbol, value: word(for: category),
                                badge: category == .advanced && model.companionUpdateAvailable ? 1 : 0)
                        }
                        .buttonStyle(.plain)
                        .testID("settings.row.\(category.id)")
                    }
                }
            }
        }
        if visible.isEmpty { PageNote("Nothing matches \u{201C}\(search)\u{201D}.", id: "settings.noMatch") }
    }

    /// Away from home: on the Direct Mac's own assistant, and on a phone linked to such a Mac.
    private var showsAway: Bool {
        #if os(macOS)
        DemoMode.isOn || NollieLinkMacClient.isAvailable(for: model.runtime?.connection)
        #else
        AwayFromHomeView.shows(reach: model.linkReach, isMember: model.family.isMember(model))
        #endif
    }

    /// A word on the right of a row, when it says something worth knowing at a glance.
    private func word(for category: SettingsCategory) -> String? {
        guard category == .connection, let socket = model.runtime?.socketState else { return nil }
        switch socket {
        case .open: return String(localized: "Connected", comment: "The connection's state beside its Settings row")
        case .connecting, .reconnecting: return String(localized: "Connecting", comment: "The connection's state beside its Settings row")
        case .authRejected: return String(localized: "Sign in again", comment: "The connection's state beside its Settings row")
        case .failed, .idle: return String(localized: "Offline", comment: "The connection's state beside its Settings row")
        }
    }

    #if DEBUG
    /// For pictures: `-nollie-demo-settings <page>` opens that page (its raw name),
    /// `left` or `night` the summary pages, `models-advanced` Models › Advanced, and `bot-<tab>`
    /// the default bot's settings.
    private func openDemoPage() async {
        let words = ProcessInfo.processInfo.arguments
        guard let flag = words.firstIndex(of: "-nollie-demo-settings"), flag + 1 < words.count, path.isEmpty else { return }
        try? await Task.sleep(for: .seconds(1))
        let page = words[flag + 1]
        if let category = SettingsCategory(rawValue: page) { path = [category] } else { demoSummary = page }
    }
    #endif
}

/// The page a settings row opens.
private struct SettingsDestination: View {
    var category: SettingsCategory
    var developerMode: Bool

    var body: some View {
        switch category {
        case .bots: BotsSettingsView()
        case .appearance: AppearanceView().untitledPage()
        case .speech: VoiceSettingsView().untitledPage()
        case .notifications: NotificationsView().untitledPage()
        case .weekly: WeeklyNoteSettingsView()
        case .privacy: PrivacyView().untitledPage()
        case .signIns: signIns
        case .cards: cards
        case .siri: SiriSettingsView().untitledPage()
        case .connection: GatewaysView(includesSetup: true).untitledPage()
        case .away: AwayFromHomeView().untitledPage()
        case .keepAwake: keepAwake
        case .about: AboutView()
        case .advanced: if developerMode { AdvancedSettingsView() }
        }
    }

    @ViewBuilder private var keepAwake: some View {
        #if os(macOS)
        KeepAwakeView().untitledPage()
        #else
        EmptyView()
        #endif
    }

    /// The Mac adds and removes cards; the iPhone shows them and says where to add one.
    @ViewBuilder private var cards: some View {
        #if os(macOS)
        CardsSettingsView().untitledPage()
        #else
        PhoneCardsView().untitledPage()
        #endif
    }

    @ViewBuilder private var signIns: some View {
        #if os(macOS)
        SignInsSettingsView().untitledPage()
        #else
        EmptyView()
        #endif
    }
}

#if DEBUG
/// A page opened by name from the launch flags, for pictures.
private struct DemoSettingsPage: View {
    var name: String
    var summary: CrewSummaryModel
    @Environment(AppModel.self) private var model

    var body: some View {
        if name == "night" {
            NightShiftPage(summary: summary)
        } else if name == "permissions" {
            PermissionsSettingsView().untitledPage()
        } else if name == "models-advanced" {
            DemoModelsAdvanced()
        } else if name.hasPrefix("bot-") {
            ProfileCardView(
                profileName: model.runtime?.defaultProfile ?? "default",
                initialTab: ProfileTab(rawValue: String(name.dropFirst(4))) ?? .look)
        } else {
            LeftYourMacPage(summary: summary)
        }
    }
}

/// Models › Advanced on its own, checked against the demo gateway as the Models page would.
private struct DemoModelsAdvanced: View {
    @Environment(AppModel.self) private var model
    @State private var check = ModelCheck()
    @State private var download = LocalModelDownload()

    var body: some View {
        ModelsAdvancedView(check: check, download: download, refresh: {})
            .untitledPage()
            .task { await check.refresh(model, identity: { "demo" }) }
    }
}
#endif

/// Red count bubble in the style of the tab bar, put on rows that lead to something needing attention.
struct CountBadge: View {
    let count: Int
    init(_ amount: Int) { count = amount }

    /// Two digits get a little room at the sides.
    private var edge: CGFloat { count > 9 ? 6 : 0 }

    var body: some View {
        Text(count, format: .number.grouping(.never))
            .monospacedDigit()
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(EdgeInsets(top: 0, leading: edge, bottom: 0, trailing: edge))
            .frame(minWidth: 20)
            .frame(height: 20)
            .background { Capsule().fill(.red) }
            .accessibilityLabel("\(count) waiting")
    }
}
