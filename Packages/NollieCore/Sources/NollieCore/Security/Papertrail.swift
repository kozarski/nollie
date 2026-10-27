import Foundation

/// Papertrail: a bot's record of what left this Mac, kept in each bot's home by the workflow add-on
/// (model calls, searches, pages) and by Nollie Runtime's door (every connection Hermes and the
/// programs it starts make through it), read from `GET /api/plugins/nollie-workflow/papertrail?bot=`.
/// Only when, where to and roughly how much; never the words. Replies that stayed on this Mac are
/// counted, not listed.
public struct Papertrail: Decodable, Equatable, Sendable {
    /// Entries counted since local midnight on the Mac, and over the whole window.
    public struct Counts: Decodable, Equatable, Sendable {
        public var today: Int?
        public var window: Int?
    }

    /// One reply or background job that sent something out.
    public struct Entry: Decodable, Equatable, Sendable, Identifiable {
        public var id: String
        public var at: Double
        public var startedAt: Double?
        /// `online` when any part went online, else `network`, else `icloud` (notes for the person's own iPhone).
        public var route: String?
        public var provider: String?
        public var providerName: String?
        public var host: String?
        public var model: String?
        public var calls: Int?
        public var helpers: [String]?
        public var services: [String]?
        public var inputTokens: Int?
        public var outputTokens: Int?
        public var cacheReadTokens: Int?
        public var reasoningTokens: Int?
        public var searches: Int?
        public var pages: Int?
        public var images: Int?
        /// What the reply read on the Mac before its words went out: "calendar", "reminders", "contacts".
        public var localReads: [String]?
        /// Why it went, as the add-on kept it. Nil for entries kept before 1.1: the app then says it wasn't kept.
        public var why: Why?
        /// Cards Nollie filled in and sent to a site in this reply: the site and the last four digits only.
        public var payments: [Payment]?
        /// Notes sealed for the person's own iPhone and put in their iCloud while they were away.
        public var icloudNotes: Int?
        /// Every connection the door saw in it, most used first.
        public var connections: [Connection]?

        /// One place it connected to, and how many times.
        public struct Connection: Decodable, Equatable, Sendable {
            public var host: String
            public var port: Int?
            /// `hermes` (Hermes itself), `terminal`, `code`, `mcp` (a connected app), `model`, `reader`, `program`,
            /// or `direct` (the network filter saw it go around the door).
            public var kind: String?
            public var route: String?
            public var count: Int?

            public init(host: String, port: Int? = 443, kind: String? = "hermes", route: String? = "online", count: Int? = 1) {
                self.host = host; self.port = port; self.kind = kind; self.route = route; self.count = count
            }
        }

        /// One card sent to a site.
        public struct Payment: Decodable, Equatable, Sendable {
            public var site: String
            public var card: String?

            public init(site: String, card: String?) {
                self.site = site
                self.card = card
            }
        }

        public init(id: String, at: Double, route: String? = "online", provider: String? = nil, providerName: String? = nil,
                    host: String? = nil, model: String? = nil, services: [String]? = nil, inputTokens: Int? = nil,
                    outputTokens: Int? = nil, searches: Int? = nil, pages: Int? = nil, images: Int? = nil, calls: Int? = nil,
                    connections: [Connection]? = nil) {
            self.id = id; self.at = at; self.route = route; self.provider = provider; self.providerName = providerName
            self.host = host; self.model = model; self.services = services; self.inputTokens = inputTokens
            self.outputTokens = outputTokens; self.searches = searches; self.pages = pages; self.images = images; self.calls = calls
            self.connections = connections
        }
    }

    /// Why one entry went: what started the work, how much of the chat went with it, whether the backup model
    /// answered, and the person's own answers in the same turn. Ids and short names only, never the words.
    public struct Why: Decodable, Equatable, Sendable {
        /// `chat`, `schedule`, `board` or `helper` (a helper a schedule started).
        public var origin: String?
        /// The schedule's or Board task's name, read when the week was asked for.
        public var task: String?
        /// The chat app a chat came from, when Hermes said: `telegram`, `discord`, ...
        public var platform: String?
        /// The most messages one request carried.
        public var messages: Int?
        /// The bot's backup model answered, not its main one.
        public var backup: Bool?
        public var approvals: [Approval]?

        /// The person's answer to a question in that turn.
        public struct Approval: Decodable, Equatable, Sendable {
            public var at: Double
            /// `once`, `session`, `always` or `deny`.
            public var choice: String?
            /// What Ask first asked about: `send`, `buy`, `post`, `delete` or `unsure`.
            public var ask: String?
            /// The device that answered, when it was recorded.
            public var device: String?

            public init(at: Double, choice: String?, ask: String? = nil, device: String? = nil) {
                self.at = at; self.choice = choice; self.ask = ask; self.device = device
            }
        }

        public init(origin: String?, task: String? = nil, platform: String? = nil, messages: Int? = nil,
                    backup: Bool? = nil, approvals: [Approval]? = nil) {
            self.origin = origin; self.task = task; self.platform = platform; self.messages = messages
            self.backup = backup; self.approvals = approvals
        }
    }

    /// One time a bot used apps on this Mac: which apps and how many steps. Pictures of the screen stayed on the Mac.
    public struct MacSession: Decodable, Equatable, Sendable {
        public var at: Double
        public var apps: [String]?
        public var actions: Int?
        public var looks: Int?
        /// Always 0: the add-on keeps the line to say so.
        public var screenshotsLeft: Int?

        public init(at: Double, apps: [String]?, actions: Int?, looks: Int? = nil, screenshotsLeft: Int? = 0) {
            self.at = at; self.apps = apps; self.actions = actions; self.looks = looks; self.screenshotsLeft = screenshotsLeft
        }

        /// "Notes", "Notes and TextEdit".
        public var appsText: String {
            let names = (apps ?? []).filter { !$0.isEmpty }
            return names.isEmpty ? String(localized: "An app", table: "Core") : Papertrail.list(names)
        }

        /// "6 actions", "1 action, 2 looks".
        public var stepsText: String {
            var parts = [Papertrail.count(actions ?? 0, { String(localized: "\($0) actions", table: "Core", comment: "Steps a bot took in apps on the Mac") },
                                          { String(localized: "\($0) actions", table: "Core", comment: "Steps a bot took in apps on the Mac") })]
            if let looks, looks > 0 {
                parts.append(Papertrail.count(looks, { String(localized: "\($0) looks", table: "Core", comment: "Times a bot looked at the Mac's screen") },
                                              { String(localized: "\($0) looks", table: "Core", comment: "Times a bot looked at the Mac's screen") }))
            }
            return parts.joined(separator: ", ")
        }
    }

    public var bot: String?
    public var days: Int?
    public var now: Double?
    public var todayStartsAt: Double?
    /// The Mac's next local midnight; not always a day after `todayStartsAt` when clocks change.
    public var tomorrowStartsAt: Double?
    public var since: Double?
    public var recordingSince: Double?
    public var stayed: Counts?
    public var left: Counts?
    public var entries: [Entry]?
    public var more: Int?
    /// Newest first. Not counted in what left: no picture of the screen went anywhere.
    public var macSessions: [MacSession]?

    public init(todayStartsAt: Double?, tomorrowStartsAt: Double? = nil, stayed: Int = 0, left: Int = 0, entries: [Entry]) {
        self.todayStartsAt = todayStartsAt
        self.tomorrowStartsAt = tomorrowStartsAt
        self.stayed = Counts(today: nil, window: stayed)
        self.left = Counts(today: nil, window: left)
        self.entries = entries
    }

    /// A reply with none of Papertrail's own fields (an older gateway's empty answer) is not one.
    public var isAnswer: Bool { entries != nil || stayed != nil || left != nil }
    public var stayedCount: Int { stayed?.window ?? 0 }
    public var leftCount: Int { left?.window ?? 0 }
    /// What went online: everything that left, less the replies that only reached your network.
    /// Rows past the 200 listed are counted as online, since Papertrail errs on the side of saying so.
    /// Entries that went online: not to the home network, and not to the person's own iPhone through iCloud.
    public var onlineCount: Int { max(0, leftCount - (entries ?? []).filter { $0.route == "network" || $0.route == "icloud" }.count) }
    /// The Mac's next midnight, when Today needs reading again. An older add-on sends only today's.
    public var nextDayStartsAt: Double? { tomorrowStartsAt ?? todayStartsAt.map { $0 + 86_400 } }

    /// Newest first, split at the Mac's local midnight (`today_starts_at`), so the phone does not
    /// guess the Mac's time zone. Without it, this device's midnight. A read from before a later
    /// midnight moves the split along by whole days.
    public func split(now: Date = Date(), calendar: Calendar = .current) -> (today: [Entry], earlier: [Entry]) {
        var midnight = todayStartsAt ?? calendar.startOfDay(for: now).timeIntervalSince1970
        let seconds = now.timeIntervalSince1970
        if let next = tomorrowStartsAt {
            // The Mac's own next midnight first: a clock-change day is 23 or 25 hours long.
            if seconds >= next {
                midnight = next
                while seconds >= midnight + 86_400 { midnight += 86_400 }
            }
        } else {
            while seconds >= midnight + 86_400 { midnight += 86_400 }
        }
        let sorted = (entries ?? []).sorted { $0.at > $1.at }
        return (sorted.filter { $0.at >= midnight }, sorted.filter { $0.at < midnight })
    }
}

/// What a Papertrail read found.
public enum PapertrailLoad: Equatable, Sendable {
    case on(Papertrail)
    /// The add-on is missing, or Papertrail has not recorded for this bot yet.
    case off
    /// Private bots never record.
    case privateBot
}

public extension Papertrail.Entry {
    /// Where it went, in a few words: "Claude plan", "OpenRouter", "Your network", "Exa".
    var routeLabel: String { routePlace.label }

    /// The label, and whether it is the plain "Web" said when only web tools went online.
    private var routePlace: (label: String, webOnly: Bool) {
        if route == "network" { return (String(localized: "Your network", table: "Core", comment: "Safety: Papertrail; keep exact meaning"), false) }
        if route == "icloud" { return (String(localized: "Your iCloud", table: "Core"), false) }
        let provider = (provider ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        // A model on your network with a search that went online: the search names the row,
        // not the machine down the hall.
        let modelInside = hostName.map(Papertrail.isNetworkHost) ?? false
        if !modelInside {
            if let known = Papertrail.providerLabel(provider) { return (known, false) }
            if let name = providerName?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return (name, false) }
            if let host = hostName { return (host, false) }
        }
        // Only tools went online: the search service when one is known.
        if modelInside || provider.isEmpty && (model?.isEmpty ?? true), (searches ?? 0) > 0 || (pages ?? 0) > 0 {
            if (searches ?? 0) > 0, let service = services?.lazy.compactMap(Papertrail.serviceLabel).first { return (service, false) }
            return (String(localized: "Web", table: "Core", comment: "Where something went: the web"), true)
        }
        // Only connections: the place it reached most.
        if let host = outsideHosts.first { return (host, false) }
        return (String(localized: "Online", table: "Core", comment: "Where something went: online"), false)
    }

    /// The places it connected to that are off this Mac, most used first, each once.
    var outsideHosts: [String] {
        var seen = Set<String>()
        return (connections ?? []).filter { $0.route != "mac" }.map(\.host).filter { seen.insert($0).inserted }
    }

    /// How many connections the door saw.
    var connectionCount: Int { (connections ?? []).reduce(0) { $0 + max(1, $1.count ?? 1) } }

    /// The host without its scheme, for the label; Developer Mode shows the whole `host`.
    var hostName: String? {
        guard let host, !host.isEmpty else { return nil }
        return URLComponents(string: host)?.host ?? host
    }

    /// Tokens sent and received. Cache reads are left out: the provider already held them,
    /// and adding them would make a short reply look many times its size.
    var tokens: Int { (inputTokens ?? 0) + (outputTokens ?? 0) }

    /// "18k tokens · 2 searches · 3 pages", "1 picture", "4k tokens · read your calendar".
    var amountText: String { amountParts().joined(separator: " · ") }

    /// The same for VoiceOver: "18 thousand tokens, 2 searches, 3 pages".
    var spokenAmount: String { amountParts(spoken: true).joined(separator: ", ") }

    private func amountParts(spoken: Bool = false) -> [String] {
        var parts: [String] = []
        if tokens > 0 {
            parts.append(Papertrail.count(tokens, spoken: spoken, { String(localized: "\($0) tokens", table: "Core") },
                                          { String(localized: "\($0) tokens", table: "Core", comment: "A rounded number of tokens: 18k tokens") }))
        }
        if let n = searches, n > 0 {
            parts.append(Papertrail.count(n, { String(localized: "\($0) searches", table: "Core") }, { String(localized: "\($0) searches", table: "Core") }))
        }
        if let n = pages, n > 0 {
            parts.append(Papertrail.count(n, { String(localized: "\($0) pages", table: "Core") }, { String(localized: "\($0) pages", table: "Core") }))
        }
        if let n = images, n > 0 {
            parts.append(Papertrail.count(n, { String(localized: "\($0) pictures", table: "Core") }, { String(localized: "\($0) pictures", table: "Core") }))
        }
        for payment in payments ?? [] {
            // "paid shop.example.com, card ending 4242"
            let site = payment.site
            if let card = payment.card {
                let digits = spoken ? card.map(String.init).joined(separator: " ") : card
                parts.append(String(localized: "paid \(site), card ending \(digits)", table: "Core",
                                    comment: "Safety: a payment Papertrail recorded, the site and the card's last four digits; keep exact meaning"))
            } else {
                parts.append(String(localized: "paid \(site)", table: "Core", comment: "Safety: a payment Papertrail recorded; keep exact meaning"))
            }
        }
        if let n = icloudNotes, n > 0 {
            parts.append(Papertrail.count(n, { String(localized: "\($0) notes to your iPhone", table: "Core") },
                                          { String(localized: "\($0) notes to your iPhone", table: "Core") }))
        }
        if parts.isEmpty, let n = calls, n > 0 {
            parts.append(Papertrail.count(n, { String(localized: "\($0) requests", table: "Core") }, { String(localized: "\($0) requests", table: "Core") }))
        }
        if connectionCount > 0 {
            parts.append(Papertrail.count(connectionCount, { String(localized: "\($0) connections", table: "Core") },
                                          { String(localized: "\($0) connections", table: "Core") }))
        }
        let read = AppleDataArea.allCases.filter { localReads?.contains($0.rawValue) ?? false }.map(\.inSentence)
        if !read.isEmpty {
            parts.append(String(localized: "read your \(Papertrail.list(read))", table: "Core",
                                comment: "Safety: what a reply read on the Mac before it went out, such as: read your calendar"))
        }
        return parts
    }
}

/// The answer to "Why?" on one Papertrail entry: why it went, then what went at a glance.
public struct PapertrailWhy: Equatable, Sendable {
    /// One to four short sentences: what started it, why it went where it did, and the person's own answers.
    public var reason: String
    /// "What went: 24 messages (about 19k tokens), 2 web searches.", or nil when nothing is known.
    public var sent: String?
    /// False for entries kept before reasons were.
    public var kept: Bool

    public static var notKept: String { String(localized: "Nollie didn't keep the reason for this one.", table: "Core") }
}

public extension Papertrail.Entry {
    /// Why it went, in plain words. `bot` is the name the person knows the bot by; `time` writes a time of day in
    /// their own format. Says only what the add-on kept: an entry from before 1.1 says so instead.
    func why(bot: String, time: (Date) -> String = { $0.formatted(.dateTime.hour().minute()) }) -> PapertrailWhy {
        let sent = sentText
        guard let why, let origin = why.origin, Papertrail.origins.contains(origin) else {
            // Connections alone: the door kept who made them, so that is the reason.
            if !outsideHosts.isEmpty, let went = wentLine(bot: bot, backup: false) {
                // One place, already named in the reason, needs no second line.
                return PapertrailWhy(reason: went, sent: outsideHosts.count == 1 && tokens == 0 ? nil : sent, kept: true)
            }
            return PapertrailWhy(reason: PapertrailWhy.notKept, sent: sent, kept: false)
        }
        var lines = [Papertrail.startLine(origin: origin, task: why.task, platform: why.platform, bot: bot)]
        if let went = wentLine(bot: bot, backup: why.backup == true) { lines.append(went) }
        lines += (why.approvals ?? []).suffix(3).compactMap { Papertrail.answerLine($0, time: time) }
        return PapertrailWhy(reason: lines.joined(separator: " "), sent: sent, kept: true)
    }

    /// Why it went where it went: the bot's model, its backup, your network, or a web search.
    private func wentLine(bot: String, backup: Bool) -> String? {
        let label = routeLabel
        let hasModel = !(model ?? "").isEmpty || !(provider ?? "").isEmpty || hostName != nil
        if route == "network", hasModel || outsideHosts.isEmpty {
            return String(localized: "\(bot)'s model runs on another computer on your network, so it went there.", table: "Core",
                          comment: "Safety: why something left the Mac; keep exact meaning")
        }
        if route == "icloud" {
            return String(localized: "You were away from home, so it went to your iPhone through your own iCloud, sealed for your devices.",
                          table: "Core", comment: "Safety: why something left the Mac; keep exact meaning")
        }
        let place = routePlace
        if hasModel, !place.webOnly {
            let label = place.label
            if backup {
                return String(localized: "\(bot)'s main model didn't answer, so its backup, \(label), took over.", table: "Core",
                              comment: "Safety: why something left the Mac; keep exact meaning")
            }
            return String(localized: "\(bot) uses \(label), which runs online, so it went there to be answered.", table: "Core",
                          comment: "Safety: why something left the Mac; keep exact meaning")
        }
        if (searches ?? 0) > 0 {
            if let service = services?.lazy.compactMap(Papertrail.serviceLabel).first {
                return String(localized: "\(bot) searched the web with \(service), which is online.", table: "Core",
                              comment: "Safety: why something left the Mac; keep exact meaning")
            }
            return String(localized: "\(bot) searched the web.", table: "Core", comment: "Safety: why something left the Mac; keep exact meaning")
        }
        if (pages ?? 0) > 0 {
            return String(localized: "\(bot) read pages on the web.", table: "Core", comment: "Safety: why something left the Mac; keep exact meaning")
        }
        if (images ?? 0) > 0 {
            return String(localized: "\(bot) asked an online service for a picture.", table: "Core",
                          comment: "Safety: why something left the Mac; keep exact meaning")
        }
        if let first = (connections ?? []).first(where: { $0.route != "mac" }) {
            return Papertrail.connectionLine(kind: first.kind ?? "program", host: first.host, bot: bot)
        }
        return nil
    }

    /// What went, at a glance: sizes and kinds, never the words.
    private var sentText: String? {
        var parts: [String] = []
        let messages = why?.messages ?? 0
        let size = tokens > 0 ? String(localized: "about \(Papertrail.rounded(tokens)) tokens", table: "Core") : nil
        if messages > 0 {
            let count = Papertrail.count(messages, { String(localized: "\($0) messages", table: "Core") },
                                         { String(localized: "\($0) messages", table: "Core") })
            parts.append(size.map { String(localized: "\(count) (\($0))", table: "Core", comment: "How many messages went, then their size in brackets") } ?? count)
        } else if let size {
            parts.append(size)
        }
        if let n = searches, n > 0 {
            parts.append(Papertrail.count(n, { String(localized: "\($0) web searches", table: "Core") }, { String(localized: "\($0) web searches", table: "Core") }))
        }
        if let n = pages, n > 0 {
            parts.append(Papertrail.count(n, { String(localized: "\($0) web pages", table: "Core") }, { String(localized: "\($0) web pages", table: "Core") }))
        }
        if let n = images, n > 0 {
            parts.append(Papertrail.count(n, { String(localized: "\($0) picture requests", table: "Core") },
                                          { String(localized: "\($0) picture requests", table: "Core") }))
        }
        for helper in helpers ?? [] {
            if let words = Papertrail.helperWords[helper] { parts.append(words) }
        }
        var text = parts.isEmpty ? nil
            : String(localized: "What went: \(Papertrail.list(parts)).", table: "Core", comment: "Safety: what left the Mac; keep exact meaning")
        let hosts = outsideHosts
        if !hosts.isEmpty {
            // Exactly where: every place, up to six by name.
            let named = hosts.count > 6
                ? Array(hosts.prefix(5)) + [String(localized: "\(hosts.count - 5) more", table: "Core", comment: "The rest of a list of places")] : hosts
            let line = String(localized: "Connected to \(Papertrail.list(named)).", table: "Core", comment: "Safety: where things went; keep exact meaning")
            text = text.map { Papertrail.sentences($0, line) } ?? line
        }
        let read = AppleDataArea.allCases.filter { localReads?.contains($0.rawValue) ?? false }.map(\.inSentence)
        if !read.isEmpty {
            let first = String(localized: "It read your \(Papertrail.list(read)) on your Mac first.", table: "Core",
                               comment: "Safety: what a reply read on the Mac before it went out; keep exact meaning")
            text = text.map { Papertrail.sentences($0, first) } ?? first
        }
        return text
    }
}

public extension Papertrail {
    static let origins: Set<String> = ["chat", "schedule", "board", "helper"]

    /// Hermes's own small requests a reply can make on the side, in plain words.
    static var helperWords: [String: String] {
        ["title_generation": String(localized: "a request to name the chat", table: "Core"),
         "compression": String(localized: "a request to shorten a long chat", table: "Core")]
    }

    /// Who connected, when nothing else in the entry says: "Scout ran a command that connected to github.com."
    static func connectionLine(kind: String, host: String, bot: String) -> String {
        switch kind {
        case "terminal": String(localized: "\(bot) ran a command that connected to \(host).", table: "Core", comment: "Safety: Papertrail line; keep exact meaning")
        case "code": String(localized: "\(bot) ran code that connected to \(host).", table: "Core", comment: "Safety: Papertrail line; keep exact meaning")
        case "mcp": String(localized: "\(bot) used a connected app that reached \(host).", table: "Core", comment: "Safety: Papertrail line; keep exact meaning")
        case "model": String(localized: "\(bot)'s model connected to \(host).", table: "Core", comment: "Safety: Papertrail line; keep exact meaning")
        case "reader": String(localized: "\(bot) read a page at \(host).", table: "Core", comment: "Safety: Papertrail line; keep exact meaning")
        case "hermes": String(localized: "\(bot) connected to \(host) by itself, outside a reply.", table: "Core", comment: "Safety: Papertrail line; keep exact meaning")
        case "direct": String(localized: "A program \(bot) started reached \(host) directly.", table: "Core", comment: "Safety: Papertrail line; keep exact meaning")
        default: String(localized: "A program \(bot) started connected to \(host).", table: "Core", comment: "Safety: Papertrail line; keep exact meaning")
        }
    }

    /// What started the work, and who did it.
    static func startLine(origin: String, task: String?, platform: String?, bot: String) -> String {
        let task = task.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        switch origin {
        case "schedule":
            if let task { return String(localized: "\(bot) was running your schedule \u{201C}\(task)\u{201D}.", table: "Core") }
            return String(localized: "\(bot) was running one of your schedules.", table: "Core")
        case "board":
            if let task { return String(localized: "\(bot) was working on the Board task \u{201C}\(task)\u{201D}.", table: "Core") }
            return String(localized: "\(bot) was working on a Board task.", table: "Core")
        case "helper":
            return String(localized: "A helper was working on one of \(bot)'s schedules.", table: "Core")
        default:
            if let app = platform.flatMap(chatApp) {
                return String(localized: "\(bot) was answering you \(app).", table: "Core", comment: "The second value is a chat app, such as: on Telegram, by email")
            }
            return String(localized: "\(bot) was answering you in a chat.", table: "Core")
        }
    }

    /// "on Telegram", for the chat apps people know by name. Anything else is just a chat.
    static func chatApp(_ platform: String) -> String? {
        switch platform.lowercased() {
        case "telegram": String(localized: "on Telegram", table: "Core", comment: "As in: Scout was answering you on Telegram")
        case "discord": String(localized: "on Discord", table: "Core", comment: "As in: Scout was answering you on Discord")
        case "slack": String(localized: "on Slack", table: "Core", comment: "As in: Scout was answering you on Slack")
        case "whatsapp": String(localized: "on WhatsApp", table: "Core", comment: "As in: Scout was answering you on WhatsApp")
        case "signal": String(localized: "on Signal", table: "Core", comment: "As in: Scout was answering you on Signal")
        case "matrix": String(localized: "on Matrix", table: "Core", comment: "As in: Scout was answering you on Matrix")
        case "email": String(localized: "by email", table: "Core", comment: "As in: Scout was answering you by email")
        case "sms": String(localized: "by text message", table: "Core", comment: "As in: Scout was answering you by text message")
        default: nil
        }
    }

    /// The person's answer: "You said yes to sending at 14:02." Nil for an answer this build doesn't know.
    /// Each case is a whole sentence: with or without what was asked about, and with or without the device.
    static func answerLine(_ answer: Why.Approval, time: (Date) -> String) -> String? {
        let at = time(Date(timeIntervalSince1970: answer.at))
        let device = answer.device.flatMap(deviceName)
        let activity = answer.ask.flatMap(askWords)
        switch (answer.choice, activity, device) {
        case ("once", nil, nil):
            return String(localized: "You said yes at \(at).", table: "Core", comment: "Safety: the person's answer to Ask first; keep exact meaning")
        case ("once", nil, let device?):
            return String(localized: "You said yes at \(at) on \(device).", table: "Core", comment: "Safety: the person's answer to Ask first; keep exact meaning")
        case ("once", let activity?, nil):
            return String(localized: "You said yes to \(activity) at \(at).", table: "Core", comment: "Safety: the person's answer to Ask first; keep exact meaning")
        case ("once", let activity?, let device?):
            return String(localized: "You said yes to \(activity) at \(at) on \(device).", table: "Core",
                          comment: "Safety: the person's answer to Ask first; keep exact meaning")
        case ("session", nil, nil):
            return String(localized: "You said yes for the rest of the chat at \(at).", table: "Core",
                          comment: "Safety: the person's answer to Ask first; keep exact meaning")
        case ("session", nil, let device?):
            return String(localized: "You said yes for the rest of the chat at \(at) on \(device).", table: "Core",
                          comment: "Safety: the person's answer to Ask first; keep exact meaning")
        case ("session", let activity?, nil):
            return String(localized: "You said yes to \(activity) for the rest of the chat at \(at).", table: "Core",
                          comment: "Safety: the person's answer to Ask first; keep exact meaning")
        case ("session", let activity?, let device?):
            return String(localized: "You said yes to \(activity) for the rest of the chat at \(at) on \(device).", table: "Core",
                          comment: "Safety: the person's answer to Ask first; keep exact meaning")
        case ("always", nil, nil):
            return String(localized: "You chose Always at \(at).", table: "Core", comment: "Safety: the person's answer to Ask first; keep exact meaning")
        case ("always", nil, let device?):
            return String(localized: "You chose Always at \(at) on \(device).", table: "Core",
                          comment: "Safety: the person's answer to Ask first; keep exact meaning")
        case ("always", let activity?, nil):
            return String(localized: "You chose Always for \(activity) at \(at).", table: "Core",
                          comment: "Safety: the person's answer to Ask first; keep exact meaning")
        case ("always", let activity?, let device?):
            return String(localized: "You chose Always for \(activity) at \(at) on \(device).", table: "Core",
                          comment: "Safety: the person's answer to Ask first; keep exact meaning")
        case ("deny", nil, nil):
            return String(localized: "You said no at \(at), so it wasn't done.", table: "Core",
                          comment: "Safety: the person's answer to Ask first; keep exact meaning")
        case ("deny", nil, let device?):
            return String(localized: "You said no at \(at) on \(device), so it wasn't done.", table: "Core",
                          comment: "Safety: the person's answer to Ask first; keep exact meaning")
        case ("deny", let activity?, nil):
            return String(localized: "You said no to \(activity) at \(at), so it wasn't done.", table: "Core",
                          comment: "Safety: the person's answer to Ask first; keep exact meaning")
        case ("deny", let activity?, let device?):
            return String(localized: "You said no to \(activity) at \(at) on \(device), so it wasn't done.", table: "Core",
                          comment: "Safety: the person's answer to Ask first; keep exact meaning")
        default:
            return nil
        }
    }

    /// What Ask first asked about, as an activity: "sending".
    static func askWords(_ ask: String) -> String? {
        switch ask {
        case "send": String(localized: "sending", table: "Core", comment: "Safety: an activity Ask first asks about, as in: You said yes to sending")
        case "buy": String(localized: "buying", table: "Core", comment: "Safety: an activity Ask first asks about, as in: You said yes to buying")
        case "post": String(localized: "posting", table: "Core", comment: "Safety: an activity Ask first asks about, as in: You said yes to posting")
        case "delete": String(localized: "deleting", table: "Core", comment: "Safety: an activity Ask first asks about, as in: You said yes to deleting")
        default: nil
        }
    }

    static func deviceName(_ device: String) -> String? {
        switch device.lowercased() {
        case "iphone": String(localized: "your iPhone", table: "Core", comment: "As in: You said yes at 14:02 on your iPhone")
        case "ipad": String(localized: "your iPad", table: "Core", comment: "As in: You said yes at 14:02 on your iPad")
        case "mac": String(localized: "your Mac", table: "Core", comment: "As in: You said yes at 14:02 on your Mac")
        case "watch": String(localized: "your Apple Watch", table: "Core", comment: "As in: You said yes at 14:02 on your Apple Watch")
        default: nil
        }
    }

    /// "a, b and c". The joins are the app's own words, not the system list format, which says "a, b, and c" in
    /// American English.
    static func list(_ parts: [String]) -> String {
        guard parts.count > 1 else { return parts.joined() }
        let head = parts.dropLast().joined(separator: String(localized: ", ", table: "Core", comment: "Between items of a list: a, b and c"))
        let last = parts[parts.count - 1]
        return String(localized: "\(head) and \(last)", table: "Core", comment: "The last item of a list: a, b and c")
    }

    /// Two whole sentences one after the other.
    static func sentences(_ first: String, _ second: String) -> String {
        String(localized: "\(first) \(second)", table: "Core", comment: "Two whole sentences one after the other")
    }
}

public extension Papertrail {
    /// Short names for the providers people know by name. Anything else falls back to Hermes's
    /// display name, then the host.
    static func providerLabel(_ id: String) -> String? {
        if id.hasPrefix("claude-subscription") { return "Claude plan" }
        switch id {
        case "openai-codex": return "ChatGPT plan"
        case "anthropic": return "Anthropic"
        case "openai", "openai-api": return "OpenAI"
        case "openrouter": return "OpenRouter"
        case "nous": return "Nous Portal"
        case "gemini", "google", "google-gemini", "google-ai-studio", "vertex": return "Google"
        case "xai", "xai-oauth": return "xAI"
        case "github-copilot", "copilot", "copilot-acp": return "GitHub Copilot"
        case "deepseek": return "DeepSeek"
        case "zai": return "Z.ai"
        case "kimi-for-coding": return "Kimi"
        case "minimax", "minimax-oauth", "minimax-cn": return "MiniMax"
        case "huggingface": return "Hugging Face"
        case "bedrock": return "Amazon Bedrock"
        case "ollama-cloud": return "Ollama Cloud"
        default: return nil
        }
    }

    /// Search services by their Hermes backend name.
    static func serviceLabel(_ id: String) -> String? {
        switch id.trimmingCharacters(in: .whitespaces).lowercased() {
        case "exa": return "Exa"
        case "tavily": return "Tavily"
        case "firecrawl": return "Firecrawl"
        case "parallel": return "Parallel"
        case "perplexity": return "Perplexity"
        case "brave", "brave_free": return "Brave"
        case "searxng": return "SearXNG"
        case "ddgs": return "DuckDuckGo"
        case "keenable": return "Keenable"
        case "xai": return "xAI"
        case "openai_native": return "OpenAI"
        default: return nil
        }
    }

    /// Under 1,000 as is, then `1.2k`, `18k`, `1.4M`. Spoken: "18 thousand", "1.4 million".
    static func rounded(_ n: Int, spoken: Bool = false) -> String {
        func short(_ value: Double) -> String {
            value.formatted(.number.precision(.fractionLength(value < 10 ? 0...1 : 0...0)).grouping(.never))
        }
        if n < 1_000 { return "\(n)" }
        let k = Double(n) / 1_000
        if (k < 10 ? (k * 10).rounded() / 10 : k.rounded()) < 1_000 {
            let text = short(k)
            return spoken ? String(localized: "\(text) thousand", table: "Core", comment: "A rounded number read aloud: 18 thousand")
                : String(localized: "\(text)k", table: "Core", comment: "A rounded number of thousands, short: 18k")
        }
        let text = short(Double(n) / 1_000_000)
        return spoken ? String(localized: "\(text) million", table: "Core", comment: "A rounded number read aloud: 1.4 million")
            : String(localized: "\(text)M", table: "Core", comment: "A rounded number of millions, short: 1.4M")
    }

    /// A host inside your own network, as the route rule reads it: loopback, private and
    /// link-local addresses, Tailscale's 100.64.0.0/10, `.local` names and bare names.
    static func isNetworkHost(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.contains(":") {
            return host == "::1" || host.hasPrefix("fc") || host.hasPrefix("fd")
                || ["fe8", "fe9", "fea", "feb"].contains { host.hasPrefix($0) }
        }
        let pieces = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = pieces.compactMap { UInt8($0) }
        if pieces.count == 4, octets.count == 4 {
            switch (octets[0], octets[1]) {
            case (127, _), (10, _), (0, _), (192, 168), (169, 254): return true
            case (172, 16...31), (100, 64...127): return true
            default: return false
            }
        }
        return host.hasSuffix(".local") || !host.contains(".")
    }

    /// A count with its word, rounded past 999: "3 pages", "1.2k pages". `small` says a count under 1,000 with the
    /// number itself, so each language can use its own plural forms; `large` says the rounded one.
    fileprivate static func count(_ n: Int, spoken: Bool = false, _ small: (Int) -> String, _ large: (String) -> String) -> String {
        n < 1_000 ? small(n) : large(rounded(n, spoken: spoken))
    }

    /// Reads a bot's week. Asked of the main bot's scope with `bot=`, never `?profile=`: the
    /// route lives with the other workflow routes, which refuse any other profile.
    static func load(bot: String, days: Int = 7, api: HermesAPI) async throws -> PapertrailLoad {
        do {
            let reply: Papertrail = try await api.get(GatewayRuntime.papertrailPath, query: [
                URLQueryItem(name: "bot", value: bot), URLQueryItem(name: "days", value: String(days)),
            ])
            return reply.isAnswer ? .on(reply) : .off
        } catch HermesAPIError.http(let status, _) where status == 404 {
            return .off
        } catch HermesAPIError.http(let status, let detail) where status == 403 && detail.localizedCaseInsensitiveContains("private") {
            // Only the add-on's own refusal. A Link door that does not know the route yet also
            // answers 403, and that is a failed read, not a private bot.
            return .privateBot
        }
    }
}

@MainActor
extension GatewayRuntime {
    nonisolated static let papertrailPath = "/api/plugins/nollie-workflow/papertrail"

    /// The bot's Papertrail for the last `days` days.
    public func papertrail(for bot: String, days: Int = 7) async throws -> PapertrailLoad {
        try await Papertrail.load(bot: bot, days: days, api: api)
    }
}
