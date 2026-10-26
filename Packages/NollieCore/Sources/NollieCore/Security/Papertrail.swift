import Foundation

/// Papertrail: a bot's record of what left this Mac, kept by the workflow add-on in each bot's
/// home and read from `GET /api/plugins/nollie-workflow/papertrail?bot=`. Only when, which route
/// and roughly how much; never the words. Replies that stayed on this Mac are counted, not listed.
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
        /// `online` when any part went online, else `network`.
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
                    outputTokens: Int? = nil, searches: Int? = nil, pages: Int? = nil, images: Int? = nil, calls: Int? = nil) {
            self.id = id; self.at = at; self.route = route; self.provider = provider; self.providerName = providerName
            self.host = host; self.model = model; self.services = services; self.inputTokens = inputTokens
            self.outputTokens = outputTokens; self.searches = searches; self.pages = pages; self.images = images; self.calls = calls
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
    public var onlineCount: Int { max(0, leftCount - (entries ?? []).filter { $0.route == "network" }.count) }
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
    var routeLabel: String {
        if route == "network" { return "Your network" }
        let provider = (provider ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        // A model on your network with a search that went online: the search names the row,
        // not the machine down the hall.
        let modelInside = hostName.map(Papertrail.isNetworkHost) ?? false
        if !modelInside {
            if let known = Papertrail.providerLabel(provider) { return known }
            if let name = providerName?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
            if let host = hostName { return host }
        }
        // Only tools went online: the search service when one is known.
        if modelInside || provider.isEmpty && (model?.isEmpty ?? true), (searches ?? 0) > 0 || (pages ?? 0) > 0 {
            if (searches ?? 0) > 0, let service = services?.lazy.compactMap(Papertrail.serviceLabel).first { return service }
            return "Web"
        }
        return "Online"
    }

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
        if tokens > 0 { parts.append("\(Papertrail.rounded(tokens, spoken: spoken)) \(tokens == 1 ? "token" : "tokens")") }
        if let n = searches, n > 0 { parts.append(Papertrail.count(n, "search", "searches")) }
        if let n = pages, n > 0 { parts.append(Papertrail.count(n, "page", "pages")) }
        if let n = images, n > 0 { parts.append(Papertrail.count(n, "picture", "pictures")) }
        for payment in payments ?? [] {
            // "paid shop.example.com, card ending 4242"
            let card = payment.card.map { spoken ? ", card ending \($0.map(String.init).joined(separator: " "))" : ", card ending \($0)" } ?? ""
            parts.append("paid \(payment.site)\(card)")
        }
        if parts.isEmpty, let n = calls, n > 0 { parts.append(Papertrail.count(n, "request", "requests")) }
        let read = AppleDataArea.allCases.filter { localReads?.contains($0.rawValue) ?? false }.map { $0.title.lowercased() }
        if !read.isEmpty {
            let names = read.count == 1 ? read[0] : read.dropLast().joined(separator: ", ") + " and " + read[read.count - 1]
            parts.append("read your " + names)
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

    public static let notKept = "Nollie didn't keep the reason for this one."
}

public extension Papertrail.Entry {
    /// Why it went, in plain words. `bot` is the name the person knows the bot by; `time` writes a time of day in
    /// their own format. Says only what the add-on kept: an entry from before 1.1 says so instead.
    func why(bot: String, time: (Date) -> String = { $0.formatted(.dateTime.hour().minute()) }) -> PapertrailWhy {
        let sent = sentText
        guard let why, let origin = why.origin, Papertrail.origins.contains(origin) else {
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
        if route == "network" {
            return "\(bot)'s model runs on another computer on your network, so it went there."
        }
        if hasModel, label != "Web" {
            if backup { return "\(bot)'s main model didn't answer, so its backup, \(label), took over." }
            return "\(bot) uses \(label), which runs online, so it went there to be answered."
        }
        if (searches ?? 0) > 0 {
            let service = services?.lazy.compactMap(Papertrail.serviceLabel).first
            return service.map { "\(bot) searched the web with \($0), which is online." } ?? "\(bot) searched the web."
        }
        if (pages ?? 0) > 0 { return "\(bot) read pages on the web." }
        if (images ?? 0) > 0 { return "\(bot) asked an online service for a picture." }
        return nil
    }

    /// What went, at a glance: sizes and kinds, never the words.
    private var sentText: String? {
        var parts: [String] = []
        let messages = why?.messages ?? 0
        let size = tokens > 0 ? "about \(Papertrail.rounded(tokens)) tokens" : nil
        if messages > 0 {
            parts.append(Papertrail.count(messages, "message", "messages") + (size.map { " (\($0))" } ?? ""))
        } else if let size {
            parts.append(size)
        }
        if let n = searches, n > 0 { parts.append(Papertrail.count(n, "web search", "web searches")) }
        if let n = pages, n > 0 { parts.append(Papertrail.count(n, "web page", "web pages")) }
        if let n = images, n > 0 { parts.append(Papertrail.count(n, "picture request", "picture requests")) }
        for helper in helpers ?? [] {
            if let words = Papertrail.helperWords[helper] { parts.append(words) }
        }
        var text = parts.isEmpty ? nil : "What went: " + Papertrail.list(parts) + "."
        let read = AppleDataArea.allCases.filter { localReads?.contains($0.rawValue) ?? false }.map { $0.title.lowercased() }
        if !read.isEmpty {
            let first = "It read your \(Papertrail.list(read)) on your Mac first."
            text = text.map { $0 + " " + first } ?? first
        }
        return text
    }
}

public extension Papertrail {
    static let origins: Set<String> = ["chat", "schedule", "board", "helper"]

    /// Hermes's own small requests a reply can make on the side, in plain words.
    static let helperWords = ["title_generation": "a request to name the chat",
                              "compression": "a request to shorten a long chat"]

    /// What started the work, and who did it.
    static func startLine(origin: String, task: String?, platform: String?, bot: String) -> String {
        let task = task.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        switch origin {
        case "schedule":
            return task.map { "\(bot) was running your schedule \u{201C}\($0)\u{201D}." } ?? "\(bot) was running one of your schedules."
        case "board":
            return task.map { "\(bot) was working on the Board task \u{201C}\($0)\u{201D}." } ?? "\(bot) was working on a Board task."
        case "helper":
            return "A helper was working on one of \(bot)'s schedules."
        default:
            if let app = platform.flatMap(chatApp) { return "\(bot) was answering you \(app)." }
            return "\(bot) was answering you in a chat."
        }
    }

    /// "on Telegram", for the chat apps people know by name. Anything else is just a chat.
    static func chatApp(_ platform: String) -> String? {
        switch platform.lowercased() {
        case "telegram": "on Telegram"
        case "discord": "on Discord"
        case "slack": "on Slack"
        case "whatsapp": "on WhatsApp"
        case "signal": "on Signal"
        case "matrix": "on Matrix"
        case "email": "by email"
        case "sms": "by text message"
        default: nil
        }
    }

    /// The person's answer: "You said yes to sending at 14:02." Nil for an answer this build doesn't know.
    static func answerLine(_ answer: Why.Approval, time: (Date) -> String) -> String? {
        let at = time(Date(timeIntervalSince1970: answer.at))
        let device = answer.device.flatMap(deviceName).map { " on \($0)" } ?? ""
        let activity = answer.ask.flatMap(askWords)
        let what = activity.map { " to \($0)" } ?? ""
        switch answer.choice {
        case "once": return "You said yes\(what) at \(at)\(device)."
        case "session": return "You said yes\(what) for the rest of the chat at \(at)\(device)."
        case "always": return "You chose Always\(activity.map { " for \($0)" } ?? "") at \(at)\(device)."
        case "deny": return "You said no\(what) at \(at)\(device), so it wasn't done."
        default: return nil
        }
    }

    /// What Ask first asked about, as an activity: "sending".
    static func askWords(_ ask: String) -> String? {
        switch ask {
        case "send": "sending"
        case "buy": "buying"
        case "post": "posting"
        case "delete": "deleting"
        default: nil
        }
    }

    static func deviceName(_ device: String) -> String? {
        switch device.lowercased() {
        case "iphone": "your iPhone"
        case "ipad": "your iPad"
        case "mac": "your Mac"
        case "watch": "your Apple Watch"
        default: nil
        }
    }

    /// "a, b and c".
    fileprivate static func list(_ parts: [String]) -> String {
        parts.count <= 1 ? parts.joined() : parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
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
        func short(_ value: Double, _ unit: String) -> String {
            let text = value < 10 ? String(format: "%.1f", value) : String(format: "%.0f", value)
            return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + unit
        }
        if n < 1_000 { return "\(n)" }
        let k = Double(n) / 1_000
        if (k < 10 ? (k * 10).rounded() / 10 : k.rounded()) < 1_000 { return short(k, spoken ? " thousand" : "k") }
        return short(Double(n) / 1_000_000, spoken ? " million" : "M")
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

    fileprivate static func count(_ n: Int, _ one: String, _ many: String) -> String {
        "\(rounded(n)) \(n == 1 ? one : many)"
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
