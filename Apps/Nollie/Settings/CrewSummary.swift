import SwiftUI
import Observation
import NollieCore

/// The two things Settings shows first: what left your Mac today across your bots (Papertrail),
/// and what the crew did overnight (the latest Night shift card). Private bots are never read.
@MainActor @Observable
final class CrewSummaryModel {
    /// One bot's day, as Papertrail keeps it.
    struct BotDay: Identifiable, Equatable {
        var bot: String
        var name: String
        var today: PapertrailToday
        var id: String { bot }
    }

    /// Bots that keep a Papertrail, with what left today. Nil until read, or when none keeps one.
    private(set) var bots: [BotDay]?
    /// The newest Night shift card of the last day and a half. Nil when there is none.
    private(set) var night: ConversationPost.NightShift?
    private(set) var loaded = false
    private var key: String?

    /// Across every bot that keeps a Papertrail: what left today, and the part that went online.
    var leftToday: Int? { bots.map { $0.reduce(0) { $0 + $1.today.left } } }
    var onlineToday: Int? { bots.map { $0.reduce(0) { $0 + $1.today.online } } }

    func load(_ runtime: GatewayRuntime) async {
        let key = runtime.connection.id.uuidString
        if self.key != key { bots = nil; night = nil; loaded = false; self.key = key }
        async let days = Self.days(runtime)
        async let card = Self.latestNight(runtime)
        let (read, latest) = await (days, card)
        guard !Task.isCancelled, self.key == key else { return }
        bots = read
        night = latest
        loaded = true
    }

    private static func days(_ runtime: GatewayRuntime) async -> [BotDay]? {
        var found: [BotDay] = []
        for profile in runtime.profiles where !PrivateBots.isPrivate(profile.name, connection: runtime.connection.id) {
            guard case .on(let trail)? = try? await Papertrail.load(bot: profile.name, days: 1, api: runtime.api) else { continue }
            found.append(BotDay(bot: profile.name, name: profile.shownName, today: PapertrailToday(trail)))
        }
        return found.isEmpty ? nil : found
    }

    /// The newest Night shift card of the last day and a half, or nil. The Watch's note reads it too.
    static func latestNight(_ runtime: GatewayRuntime) async -> ConversationPost.NightShift? {
        let posts = try? await HermesConversationPosts(api: runtime.api).posts(since: Date().addingTimeInterval(-36 * 3600))
        return posts?.filter { $0.nightShift != nil }.max { $0.at < $1.at }?.nightShift
    }
}

/// What the summary says, in the person's words, as each bot's own Papertrail says it.
@MainActor
enum CrewSummaryWords {
    /// The tile's few words.
    static func left(_ summary: CrewSummaryModel) -> String {
        guard let left = summary.leftToday else { return String(localized: "Not kept yet", comment: "Papertrail has no record yet") }
        if left == 0 { return String(localized: "Nothing today", comment: "Safety: Papertrail; keep exact meaning") }
        let online = summary.onlineToday ?? 0
        if online == 0 { return String(localized: "Your network only", comment: "Safety: Papertrail; keep exact meaning") }
        return String(localized: "Went online \(online) times", comment: "Safety: Papertrail; keep exact meaning")
    }

    /// The page's answer.
    static func leftHero(_ summary: CrewSummaryModel) -> String {
        guard let left = summary.leftToday else { return String(localized: "Not kept yet", comment: "Papertrail has no record yet") }
        if left == 0 { return String(localized: "Nothing seen leaving today", comment: "Safety: Papertrail; keep exact meaning") }
        let online = summary.onlineToday ?? 0
        return online == 0 ? String(localized: "Nothing seen going online today", comment: "Safety: Papertrail; keep exact meaning") : PapertrailToday.wentOnline(online)
    }

    /// One bot's row.
    static func bot(_ today: PapertrailToday) -> String {
        if today.left == 0 { return String(localized: "Nothing", comment: "Safety: Papertrail, nothing left the device today") }
        if today.online == 0 { return String(localized: "Your network", comment: "Safety: Papertrail; keep exact meaning") }
        return String(localized: "Online \(today.online) times", comment: "Safety: Papertrail; keep exact meaning")
    }

    static func symbol(_ summary: CrewSummaryModel) -> String {
        // Until it knows, a plain Papertrail symbol: the shield would claim nothing left.
        guard let left = summary.leftToday else { return "scroll.fill" }
        guard left > 0 else { return "lock.shield.fill" }
        return (summary.onlineToday ?? 0) > 0 ? "globe" : "network"
    }

    static func tint(_ summary: CrewSummaryModel) -> Color {
        guard let left = summary.leftToday, left > 0 else { return summary.leftToday == nil ? Ink.text2 : .green }
        return (summary.onlineToday ?? 0) > 0 ? .blue : .teal
    }

    static func night(_ card: ConversationPost.NightShift?) -> String {
        guard let card, card.counts.runs > 0 else { return String(localized: "A quiet night") }
        if card.counts.held > 0 { return String(localized: "\(card.counts.held) things wait for you") }
        return String(localized: "\(card.counts.runs) jobs overnight")
    }
}

/// The top of Settings: two tiles side by side, each the answer to one question, each the way to
/// the whole story.
struct CrewSummaryTiles: View {
    var summary: CrewSummaryModel
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // One above the other at the largest text sizes.
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 14)) : AnyLayout(HStackLayout(alignment: .top, spacing: 14))
        layout {
            NavigationLink { LeftYourMacPage(summary: summary) } label: {
                tile(title: String(localized: "What left your Mac"), symbol: CrewSummaryWords.symbol(summary),
                     tint: CrewSummaryWords.tint(summary), word: CrewSummaryWords.left(summary))
            }
            .accessibilityIdentifier("settings.summary.left")
            NavigationLink { NightShiftPage(summary: summary) } label: {
                tile(title: String(localized: "Night shift"), symbol: "moon.stars.fill",
                     tint: (summary.night?.counts.held ?? 0) > 0 ? .orange : .indigo, word: CrewSummaryWords.night(summary.night))
            }
            .accessibilityIdentifier("settings.summary.night")
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: false, vertical: true)
        .redacted(reason: summary.loaded ? [] : .placeholder)
    }

    private func tile(title: String, symbol: String, tint: Color, word: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(word).font(.headline).foregroundStyle(Ink.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(Ink.text2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Ink.card, in: .rect(cornerRadius: 26, style: .continuous))
        .contentShape(.rect(cornerRadius: 26, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(word)")
        .accessibilityAddTraits(.isButton)
    }
}

/// Settings › What left your Mac: today's answer, then each bot, each the way to its Papertrail.
struct LeftYourMacPage: View {
    var summary: CrewSummaryModel

    var body: some View {
        SettingsPage("left.page") {
            PageHero(symbol: CrewSummaryWords.symbol(summary),
                     title: .verbatim(CrewSummaryWords.leftHero(summary)),
                     line: .verbatim(summary.bots == nil ? String(localized: "Papertrail starts with your next chat.")
                         : String(localized: "Only when, and where to. Never your words.", comment: "Safety: Papertrail; keep exact meaning")),
                     tint: CrewSummaryWords.tint(summary), id: "left.hero")
            if let bots = summary.bots {
                GlassStack {
                    ForEach(bots) { day in
                        NavigationLink { ProfileCardView(profileName: day.bot, initialTab: .papertrail) } label: {
                            HStack(spacing: 14) {
                                BotAvatar(profile: day.bot, size: 34)
                                Text(day.name).font(.headline).foregroundStyle(Ink.text)
                                Spacer(minLength: 8)
                                Text(CrewSummaryWords.bot(day.today)).font(.body).foregroundStyle(Ink.text2)
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Ink.text3)
                                    .accessibilityHidden(true)
                            }
                            .padding(.leading, 14).padding(.trailing, 22).padding(.vertical, 10)
                            .frame(minHeight: 54)
                            .contentShape(Capsule())
                            .nollieGlass(.regular, in: Capsule(), solid: Ink.card)
                            .accessibilityElement(children: .combine)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("left.bot." + day.bot)
                    }
                }
            }
            #if os(macOS) && NOLLIE_DIRECT
            // Papertrail's network filter: on, nothing leaves around Nollie's door.
            PapertrailFilterToggle()
            #endif
        }
        .untitledPage()
    }
}

/// Settings › Night shift: what the crew did overnight, the morning card itself.
struct NightShiftPage: View {
    var summary: CrewSummaryModel
    @State private var expanded: Set<String> = []
    @State private var sharing: ConversationPost?

    var body: some View {
        SettingsPage("night.page") {
            PageHero(symbol: "moon.stars.fill", title: .verbatim(CrewSummaryWords.night(summary.night)),
                     line: .verbatim(summary.night == nil ? String(localized: "Each morning your crew's work shows here and in Nollie's chat.") : nil),
                     tint: (summary.night?.counts.held ?? 0) > 0 ? .orange : .indigo, id: "night.hero")
            if let card = summary.night {
                NightShiftCard(card: card, expanded: expanded) { tap in
                    switch tap {
                    case .showAll(let key), .why(let key):
                        withAnimation(.snappy) { if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) } }
                    case .share:
                        sharing = ConversationPost(id: "settings-night", at: card.to ?? Date(), kind: .nightShift(card))
                    case .turnOn, .keepOff:
                        break
                    }
                }
            }
        }
        .untitledPage()
        .sheet(item: $sharing) { post in NightShiftShareSheet(post: post).sheetFrame().withAppModel() }
    }
}

/// Papertrail inside the chat list's search field, at its right edge: a small plain glyph, the
/// same symbol as Settings' What left your Mac tile, opening that page.
struct PapertrailSearchButton: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    private var summary: CrewSummaryModel { model.crewSummary }

    var body: some View {
        Button(action: open) {
            Image(systemName: CrewSummaryWords.symbol(summary))
                #if os(macOS)
                .font(.system(size: 13, weight: .medium))
                #else
                .font(.body.weight(.medium))
                #endif
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(summary.leftToday == nil ? Ink.text3 : CrewSummaryWords.tint(summary))
                .contentTransition(.symbolEffect(.replace))
                // Small inside the field; a round hover on the Mac, a finger's width on the phone.
                #if os(macOS)
                .frame(width: 26, height: 26)
                .background(hovering ? Ink.text.opacity(0.1) : Color.clear, in: .circle)
                #else
                .frame(width: 36, height: 44)
                #endif
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .onHover { hovering = $0 }
        .help("Papertrail: \(CrewSummaryWords.leftHero(summary))")
        #endif
        .accessibilityLabel("Papertrail")
        .accessibilityValue(CrewSummaryWords.leftHero(summary))
        .accessibilityIdentifier("chats.papertrail")
        // Read again when the gateway or its bots change.
        .task(id: "\(model.runtime?.connection.id.uuidString ?? "")/\(model.runtime?.profiles.count ?? 0)") {
            if let rt = model.runtime { await summary.load(rt) }
        }
        #if DEBUG
        // For pictures: `-nollie-demo-papertrail` taps it once the window has settled.
        .task {
            guard DemoMode.isOn, ProcessInfo.processInfo.arguments.contains("-nollie-demo-papertrail") else { return }
            try? await Task.sleep(for: .seconds(6))
            open()
        }
        #endif
    }

    private func open() {
        model.selectedTab = .settings
        model.papertrailRequest = UUID()
    }
}
