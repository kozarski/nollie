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
    /// When that card was posted.
    private(set) var nightAt: Date?
    private(set) var loaded = false
    private var key: String?
    /// When the card was last read, for the main chat's capsule.
    private var nightReadAt: Date?
    /// The time of the morning card last put away from the main chat (`NightShiftMorning`).
    private(set) var nightPutAway: Date?
    private let defaults: UserDefaults

    /// Night shift's switch on the Mac. Nil until read, from an add-on without one, and for a shared member,
    /// whose phone never reaches it.
    private(set) var nightOn: Bool?
    /// A change of the switch on its way to the Mac.
    private(set) var nightSwitching = false
    /// Why the last change didn't go through.
    private(set) var nightProblem: String?
    /// Reads and saves the switch; tests put their own in.
    var nightSwitch = NightSwitchSource.gateway

    static let nightPutAwayKey = "nollie.nightShift.putAway"
    /// How often the main chat reads the card again while it stays open.
    static let nightEvery: TimeInterval = 15 * 60

    /// Across every bot that keeps a Papertrail: what left today, and the part that went online.
    var leftToday: Int? { bots.map { $0.reduce(0) { $0 + $1.today.left } } }
    var onlineToday: Int? { bots.map { $0.reduce(0) { $0 + $1.today.online } } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        nightPutAway = defaults.object(forKey: Self.nightPutAwayKey) as? Date
    }

    /// `owner`: false for a shared member, whose phone never reads Night shift's switch.
    func load(_ runtime: GatewayRuntime, owner: Bool = true) async {
        let key = switchTo(runtime)
        async let days = Self.days(runtime)
        async let posts = Self.nightPosts(runtime)
        async let switched = owner ? nightSwitch.load(runtime) : nil
        let (read, answered, on) = await (days, posts, switched)
        guard !Task.isCancelled, self.key == key else { return }
        bots = read
        if let answered { keep(Self.newestNight(answered)) }
        if !nightSwitching { nightOn = owner ? on : nil }
        loaded = true
    }

    /// Reads only Night shift's switch, for its page opened from the chat. Never for a shared member.
    func loadNightSwitch(_ runtime: GatewayRuntime, owner: Bool) async {
        let key = switchTo(runtime)
        guard owner else { nightOn = nil; return }
        let on = await nightSwitch.load(runtime)
        guard !Task.isCancelled, self.key == key, !nightSwitching else { return }
        nightOn = on
    }

    /// Turns Night shift on or off on the Mac. It shows at once, and goes back with a word if the Mac says no.
    func setNight(_ on: Bool, runtime: GatewayRuntime) async {
        let key = switchTo(runtime)
        let before = nightOn
        nightOn = on
        nightSwitching = true
        nightProblem = nil
        let saved = await nightSwitch.save(on, runtime)
        guard self.key == key else { return }
        nightSwitching = false
        if let saved {
            nightOn = saved
        } else {
            nightOn = before
            nightProblem = String(localized: "That didn't go through. Try again in a moment.")
        }
    }

    /// Reads only the Night shift card, at most every `nightEvery` unless `force`: the main chat's capsule.
    func loadNight(_ runtime: GatewayRuntime, force: Bool = false, now: Date = Date()) async {
        let key = switchTo(runtime)
        if !force, let read = nightReadAt, now.timeIntervalSince(read) < Self.nightEvery { return }
        // A read that fails keeps the card already shown, and tries again next time.
        guard let answered = await Self.nightPosts(runtime), !Task.isCancelled, self.key == key else { return }
        keep(Self.newestNight(answered))
    }

    /// Whether the main chat shows this morning's card (`NightShiftMorning`).
    func nightCardShows(now: Date = Date()) -> Bool {
        night != nil && NightShiftMorning.cardShows(postedAt: nightAt, now: now, putAway: nightPutAway)
    }

    /// Puts this morning's card away from the main chat until the next one. It stays in Settings › Night shift.
    func putNightAway() {
        guard let nightAt else { return }
        nightPutAway = nightAt
        defaults.set(nightAt, forKey: Self.nightPutAwayKey)
    }

    /// Forgets what was read from another gateway; answers this one's key.
    private func switchTo(_ runtime: GatewayRuntime) -> String {
        let key = runtime.connection.id.uuidString
        if self.key != key {
            bots = nil; night = nil; nightAt = nil; nightReadAt = nil; nightOn = nil; nightProblem = nil; loaded = false
            self.key = key
        }
        return key
    }

    private func keep(_ post: ConversationPost?) {
        night = post?.nightShift
        nightAt = post?.at
        nightReadAt = Date()
    }

    #if DEBUG
    /// For tests: a card as if just read.
    func show(_ post: ConversationPost?) { keep(post) }
    #endif

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
        await nightPosts(runtime).flatMap(newestNight)?.nightShift
    }

    /// The add-on's posts of the last day and a half, or nil when they could not be read.
    private static func nightPosts(_ runtime: GatewayRuntime) async -> [ConversationPost]? {
        try? await HermesConversationPosts(api: runtime.api).posts(since: Date().addingTimeInterval(-36 * 3600))
    }

    /// The newest Night shift card among `posts`.
    static func newestNight(_ posts: [ConversationPost]) -> ConversationPost? {
        posts.filter { $0.nightShift != nil }.max { $0.at < $1.at }
    }
}

/// Where Night shift's switch is read and saved: the gateway, or a test's stand-in. Each answers nil when it couldn't.
struct NightSwitchSource {
    var load: @MainActor (GatewayRuntime) async -> Bool?
    var save: @MainActor (Bool, GatewayRuntime) async -> Bool?

    static let gateway = NightSwitchSource(
        load: { runtime in (try? await NightShiftSwitch.load(api: runtime.api)).flatMap { $0?.on } },
        save: { on, runtime in (try? await NightShiftSwitch.save(on, api: runtime.api))?.on })
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

    static func nightSymbol(_ summary: CrewSummaryModel) -> String {
        summary.nightOn == false ? "moon.zzz" : "moon.stars.fill"
    }

    static func nightTint(_ summary: CrewSummaryModel) -> Color {
        if summary.nightOn == false { return Ink.text2 }
        return (summary.night?.counts.held ?? 0) > 0 ? .orange : .indigo
    }

    static func night(_ card: ConversationPost.NightShift?, off: Bool = false) -> String {
        if off { return String(localized: "Off", comment: "Night shift is switched off") }
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
                tile(title: String(localized: "Night shift"), symbol: CrewSummaryWords.nightSymbol(summary),
                     tint: CrewSummaryWords.nightTint(summary),
                     word: CrewSummaryWords.night(summary.night, off: summary.nightOn == false))
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
                            LeftBotRow(day: day)
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

/// Settings › Night shift: its switch, what the crew did overnight, and the morning card itself. Only the owner sees
/// the switch; while it is off the page says so first.
struct NightShiftPage: View {
    var summary: CrewSummaryModel
    @Environment(AppModel.self) private var model
    @State private var expanded: Set<String> = []
    @State private var sharing: ConversationPost?

    private var owner: Bool { !model.family.isMember(model) }
    private var off: Bool { summary.nightOn == false }

    var body: some View {
        SettingsPage("night.page") {
            PageHero(symbol: CrewSummaryWords.nightSymbol(summary),
                     title: .verbatim(CrewSummaryWords.night(summary.night, off: off)),
                     line: .verbatim(heroLine), tint: CrewSummaryWords.nightTint(summary), id: "night.hero")
            if owner, let on = summary.nightOn {
                VStack(alignment: .leading, spacing: 10) {
                    GlassSwitch("Night shift", isOn: Binding(get: { on }, set: { turn($0) }), id: "night.switch")
                        .disabled(summary.nightSwitching)
                    if let problem = summary.nightProblem {
                        Text(problem).font(.footnote).foregroundStyle(Ink.warnText)
                            .padding(.horizontal, 22)
                            .testID("night.switch.problem")
                    }
                }
            }
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
        .animation(.snappy, value: summary.nightOn)
        .untitledPage()
        .task(id: model.runtime?.connection.id) {
            if let runtime = model.runtime { await summary.loadNightSwitch(runtime, owner: owner) }
        }
        .sheet(item: $sharing) { post in NightShiftShareSheet(post: post).sheetFrame().withAppModel() }
    }

    /// Off says what turning it on gives; on with no card yet says where the work will show.
    private var heroLine: String? {
        if off { return String(localized: "Turn it on to see each morning what your helpers did overnight, and why.") }
        return summary.night == nil ? String(localized: "Each morning your crew's work shows here and in Nollie's chat.") : nil
    }

    private func turn(_ on: Bool) {
        guard let runtime = model.runtime else { return }
        Task { await summary.setNight(on, runtime: runtime) }
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
            if let rt = model.runtime { await summary.load(rt, owner: !model.family.isMember(model)) }
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

/// One helper on What left your Mac: its face, its name and how often it went online. At the
/// largest text sizes the count goes under the name, whole words only, in a softly rounded box,
/// so "Online" is never cut into "On-" beside a squeezed name.
private struct LeftBotRow: View {
    var day: CrewSummaryModel.BotDay
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let large = typeSize.isAccessibilitySize
        let shape = large ? AnyShape(.rect(cornerRadius: 26, style: .continuous)) : AnyShape(Capsule())
        HStack(spacing: 14) {
            BotAvatar(profile: day.bot, size: 34)
            let words = large ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(spacing: 8))
            words {
                Text(day.name).font(.headline).foregroundStyle(Ink.text)
                if !large { Spacer(minLength: 0) }
                Text(verbatim: large ? LineBreaks.wholeWords(CrewSummaryWords.bot(day.today)) : CrewSummaryWords.bot(day.today))
                    .font(.body).foregroundStyle(Ink.text2)
                    .accessibilityLabel(CrewSummaryWords.bot(day.today))
            }
            if large { Spacer(minLength: 0) }
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Ink.text3)
                .accessibilityHidden(true)
        }
        .padding(.leading, 14).padding(.trailing, 22).padding(.vertical, 10)
        .frame(minHeight: 54)
        .contentShape(shape)
        .nollieGlass(.regular, in: shape, solid: Ink.card)
        .accessibilityElement(children: .combine)
    }
}
