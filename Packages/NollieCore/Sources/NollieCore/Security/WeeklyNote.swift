import Foundation

/// One bot's week as Nollie recorded it: `GET /api/plugins/nollie-workflow/week?bot=`. Counts, names and times
/// only, from Papertrail, the bot's schedules and their runs, the Board outcomes the add-on followed and the bot's
/// connected apps. See `Docs/specs/weekly-note.md`.
public struct WeekRecord: Decodable, Equatable, Sendable {
    public var bot: String
    /// The start of the week: local midnight on the Mac, six days before today.
    public var since: Double
    public var now: Double?
    /// The first day Papertrail kept for this bot, or nil when it has kept nothing.
    public var recordingSince: Double?
    /// Papertrail is on for this bot.
    public var papertrail: Bool?
    public var replies: Replies?
    /// Where things went this week, most used first.
    public var places: [Place]
    public var placesMore: Int?
    /// The person's answers to this bot's questions this week.
    public var answers: Answers
    /// How many answers each earlier full week had, newest first.
    public var earlierAnswers: [Int]?
    public var schedules: [Schedule]
    /// The bot's schedules could be listed.
    public var schedulesKept: Bool?
    /// Hermes's run ledger could be read; without it no run is counted.
    public var runsKept: Bool?
    public var board: Board?
    public var apps: [App]?
    public var web: Web?
    /// Papertrail's network filter: `on`, `off`, or `none` when there is no door.
    public var filter: String?

    public struct Replies: Decodable, Equatable, Sendable {
        public var stayed: Int
        public var left: Int
        public var online: Int
        public init(stayed: Int, left: Int, online: Int) { (self.stayed, self.left, self.online) = (stayed, left, online) }
    }

    /// One place things went: a model, a search service, web pages, pictures, a payment, the person's iCloud, or a
    /// host one of the bot's programs connected to (`kind` is the door's: `terminal`, `code`, `mcp`, ...).
    public struct Place: Decodable, Equatable, Sendable {
        public var kind: String
        public var count: Int
        /// When it was first seen in all Papertrail keeps.
        public var firstAt: Double?
        public var host: String?
        public var provider: String?
        public var label: String?
        public var service: String?

        public init(kind: String, count: Int, firstAt: Double? = nil, host: String? = nil, provider: String? = nil,
                    label: String? = nil, service: String? = nil) {
            self.kind = kind; self.count = count; self.firstAt = firstAt; self.host = host; self.provider = provider
            self.label = label; self.service = service
        }
    }

    public struct Answers: Decodable, Equatable, Sendable {
        public var once: Int
        public var session: Int
        public var always: Int
        public var deny: Int
        public init(once: Int = 0, session: Int = 0, always: Int = 0, deny: Int = 0) {
            (self.once, self.session, self.always, self.deny) = (once, session, always, deny)
        }
        public var total: Int { once + session + always + deny }
        public var yes: Int { once + session }
    }

    public struct Schedule: Decodable, Equatable, Sendable {
        public var id: String
        /// The name the person gave it; nil when it has none, or it names a private bot.
        public var name: String?
        public var createdAt: Double?
        public var paused: Bool
        public var finished: Bool?
        /// This week's finished runs; nil when the ledger couldn't be read.
        public var runs: Runs?

        public struct Runs: Decodable, Equatable, Sendable {
            public var done: Int
            public var failed: Int
            public var unfinished: Int
            public init(done: Int = 0, failed: Int = 0, unfinished: Int = 0) {
                (self.done, self.failed, self.unfinished) = (done, failed, unfinished)
            }
            public var total: Int { done + failed + unfinished }
        }

        public init(id: String, name: String?, createdAt: Double? = nil, paused: Bool = false, finished: Bool? = false,
                    runs: Runs? = Runs()) {
            self.id = id; self.name = name; self.createdAt = createdAt; self.paused = paused; self.finished = finished
            self.runs = runs
        }
    }

    public struct Board: Decodable, Equatable, Sendable {
        public var done: Int
        public var stopped: Int
        public var failed: Int
        public init(done: Int = 0, stopped: Int = 0, failed: Int = 0) { (self.done, self.stopped, self.failed) = (done, stopped, failed) }
    }

    /// A connected app (an MCP server): its name, whether it is on, and the host of one reached by URL.
    public struct App: Decodable, Equatable, Sendable {
        public var name: String
        public var on: Bool
        public var host: String?
        public init(name: String, on: Bool = true, host: String? = nil) { (self.name, self.on, self.host) = (name, on, host) }
    }

    public struct Web: Decodable, Equatable, Sendable {
        public var on: Bool
        public var service: String?
        public init(on: Bool, service: String? = nil) { (self.on, self.service) = (on, service) }
    }

    public init(bot: String, since: Double, recordingSince: Double? = nil, papertrail: Bool? = true, replies: Replies? = nil,
                places: [Place] = [], answers: Answers = Answers(), earlierAnswers: [Int]? = [], schedules: [Schedule] = [],
                runsKept: Bool? = true, board: Board? = nil, apps: [App]? = [], web: Web? = nil, filter: String? = nil) {
        self.bot = bot; self.since = since; self.recordingSince = recordingSince; self.papertrail = papertrail
        self.replies = replies; self.places = places; self.answers = answers; self.earlierAnswers = earlierAnswers
        self.schedules = schedules; self.runsKept = runsKept; self.board = board; self.apps = apps; self.web = web
        self.filter = filter
    }

    /// At least one whole week was recorded before this one, so something can be told apart as new.
    public var hasEarlierWeek: Bool {
        guard let recordingSince else { return false }
        return recordingSince <= since - 7 * 86_400 + 3_600 // An hour's slack for a clock change.
    }

    nonisolated static let path = "/api/plugins/nollie-workflow/week"

    /// Reads one bot's week, in the main bot's scope with `bot=`, as Papertrail is. Nil for an add-on without the route.
    public static func load(bot: String, api: HermesAPI) async throws -> WeekRecord? {
        do {
            return try await api.get(path, query: [URLQueryItem(name: "bot", value: bot)])
        } catch HermesAPIError.http(let status, _) where status == 404 {
            return nil
        }
    }
}

// MARK: Actions

/// One tap beside a line of the note. Each is real: a schedule is paused or resumed by Hermes, an app or the web
/// tools are switched by the add-on in the bot's config, This Mac goes through the bot's switch, and Mute is this
/// device's own. Each has its undo, except Remove, which asks first.
public enum WeeklyAction: Hashable, Sendable {
    case pause(bot: String, job: String)
    case resume(bot: String, job: String)
    case remove(bot: String, job: String)
    case appOff(bot: String, app: String)
    case appOn(bot: String, app: String)
    case webOff(bot: String)
    case webOn(bot: String)
    case macOff(bot: String)
    case macOn(bot: String)
    case mute(bot: String)
    case unmute(bot: String)

    /// What a tap changes.
    public enum Effect: Equatable, Sendable {
        /// A call to the gateway, through the Link door from a phone.
        case gateway(WeeklyRequest)
        /// The bot's This Mac switch.
        case mac(bot: String, on: Bool)
        /// This device's banners for the bot's replies.
        case mute(bot: String, muted: Bool)
    }

    public var bot: String {
        switch self {
        case .pause(let bot, _), .resume(let bot, _), .remove(let bot, _), .appOff(let bot, _), .appOn(let bot, _),
             .webOff(let bot), .webOn(let bot), .macOff(let bot), .macOn(let bot), .mute(let bot), .unmute(let bot):
            bot
        }
    }

    /// The tap that puts it back. Remove has none.
    public var undo: WeeklyAction? {
        switch self {
        case .pause(let bot, let job): .resume(bot: bot, job: job)
        case .resume(let bot, let job): .pause(bot: bot, job: job)
        case .remove: nil
        case .appOff(let bot, let app): .appOn(bot: bot, app: app)
        case .appOn(let bot, let app): .appOff(bot: bot, app: app)
        case .webOff(let bot): .webOn(bot: bot)
        case .webOn(let bot): .webOff(bot: bot)
        case .macOff(let bot): .macOn(bot: bot)
        case .macOn(let bot): .macOff(bot: bot)
        case .mute(let bot): .unmute(bot: bot)
        case .unmute(let bot): .mute(bot: bot)
        }
    }

    /// Anything that deletes asks first.
    public var asksFirst: Bool { if case .remove = self { true } else { false } }

    /// The button's one word or two.
    public var label: String {
        switch self {
        case .pause: String(localized: "Pause", table: "Core", comment: "A button that pauses a schedule")
        case .resume: String(localized: "Resume", table: "Core", comment: "A button that resumes a schedule")
        case .remove: String(localized: "Remove", table: "Core", comment: "Safety: a button that deletes a schedule after asking")
        // The web tools are search and pages together, so the button says so.
        case .webOff: String(localized: "Turn off web", table: "Core")
        case .webOn: String(localized: "Turn on web", table: "Core")
        case .appOff, .macOff: String(localized: "Turn off", table: "Core", comment: "A button")
        case .appOn, .macOn: String(localized: "Turn on", table: "Core", comment: "A button")
        case .mute: String(localized: "Mute", table: "Core", comment: "A button that mutes a helper's banners")
        case .unmute: String(localized: "Unmute", table: "Core", comment: "A button")
        }
    }

    /// What the line says once it is done.
    public var done: String {
        switch self {
        case .pause: String(localized: "Paused", table: "Core", comment: "A schedule's state")
        case .resume: String(localized: "Resumed", table: "Core", comment: "A schedule's state")
        case .remove: String(localized: "Removed", table: "Core", comment: "A schedule's state")
        case .appOff, .webOff, .macOff: String(localized: "Off", table: "Core", comment: "A switch state")
        case .appOn, .webOn, .macOn: String(localized: "On", table: "Core", comment: "A switch state")
        case .mute: String(localized: "Muted here", table: "Core", comment: "A helper's banners are muted on this device")
        case .unmute: String(localized: "Unmuted", table: "Core", comment: "A state")
        }
    }

    public var symbol: String {
        switch self {
        case .pause: "pause.fill"
        case .resume: "play.fill"
        case .remove: "trash"
        case .appOff, .webOff, .macOff: "power"
        case .appOn, .webOn, .macOn: "power"
        case .mute: "bell.slash.fill"
        case .unmute: "bell.fill"
        }
    }

    public var effect: Effect {
        switch self {
        case .pause(let bot, let job): .gateway(WeeklyRequest(method: "POST", path: "/api/cron/jobs/\(job)/pause", profile: bot, body: .object([:])))
        case .resume(let bot, let job): .gateway(WeeklyRequest(method: "POST", path: "/api/cron/jobs/\(job)/resume", profile: bot, body: .object([:])))
        case .remove(let bot, let job): .gateway(WeeklyRequest(method: "DELETE", path: "/api/cron/jobs/\(job)", profile: bot, body: nil))
        case .appOff(let bot, let app): .gateway(Self.switchRequest(bot: bot, kind: "app", name: app, on: false))
        case .appOn(let bot, let app): .gateway(Self.switchRequest(bot: bot, kind: "app", name: app, on: true))
        case .webOff(let bot): .gateway(Self.switchRequest(bot: bot, kind: "web", name: nil, on: false))
        case .webOn(let bot): .gateway(Self.switchRequest(bot: bot, kind: "web", name: nil, on: true))
        case .macOff(let bot): .mac(bot: bot, on: false)
        case .macOn(let bot): .mac(bot: bot, on: true)
        case .mute(let bot): .mute(bot: bot, muted: true)
        case .unmute(let bot): .mute(bot: bot, muted: false)
        }
    }

    private static func switchRequest(bot: String, kind: String, name: String?, on: Bool) -> WeeklyRequest {
        var body: [String: JSONValue] = ["bot": .string(bot), "kind": .string(kind), "on": .bool(on)]
        if let name { body["name"] = .string(name) }
        return WeeklyRequest(method: "PUT", path: WeekRecord.path + "/switch", profile: nil, body: .object(body))
    }

    /// A Hermes job id is a short hex id; anything else is not put in a path.
    static func safeJob(_ id: String) -> Bool {
        (1...64).contains(id.utf8.count) && id.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }
}

/// A gateway call a tap makes.
public struct WeeklyRequest: Equatable, Sendable {
    public var method: String
    public var path: String
    /// The bot's own scope, for Hermes's cron routes; nil for the add-on's, which live in the main bot's.
    public var profile: String?
    public var body: JSONValue?
}

// MARK: The note

/// What goes into one helper's part of the note: its week, and the switches this device can read.
public struct WeeklyHelperInput: Sendable {
    public var profile: String
    public var name: String
    /// Nil when the week couldn't be read.
    public var record: WeekRecord?
    /// The This Mac switch, when this device can read it.
    public var macOn: Bool?
    public var muted: Bool

    public init(profile: String, name: String, record: WeekRecord?, macOn: Bool? = nil, muted: Bool = false) {
        self.profile = profile; self.name = name; self.record = record; self.macOn = macOn; self.muted = muted
    }
}

/// The weekly note: what each helper did and what left the Mac, in fixed sentences filled with counts and names
/// from the records. Nothing is summarised by a model, so nothing is said that wasn't recorded.
public struct WeeklyNote: Equatable, Sendable {
    public var since: Date
    public var until: Date
    /// New this week, across helpers, each with its taps.
    public var news: [Line]
    /// Helpers with something recorded, busiest first.
    public var helpers: [Helper]
    /// Helpers with nothing recorded this week.
    public var quiet: [String]
    /// Helpers whose week couldn't be read.
    public var unread: [String]
    /// What Papertrail can't see, when its filter is off or there is no door.
    public var filter: String?

    public struct Helper: Equatable, Sendable, Identifiable {
        public var id: String { profile }
        public var profile: String
        public var name: String
        /// What it did: schedules, Board tasks, questions, and This Mac when it may use it.
        public var did: [Line]
        /// "Went online 31 times. 40 replies stayed on your Mac."
        public var leftLine: String
        /// Where things went, most used first.
        public var left: [Line]
        /// "and 3 more places".
        public var morePlaces: Int
        /// Replies that went online.
        public var online: Int
        public var mute: WeeklyAction
        public var hasNews: Bool { did.contains(where: \.isNew) || left.contains(where: \.isNew) }
    }

    public struct Line: Equatable, Sendable, Identifiable {
        public enum Kind: String, Equatable, Sendable {
            case schedule, board, asked, mac, place
        }

        public var id: String
        public var kind: Kind
        public var symbol: String
        public var text: String
        public var detail: String?
        /// What the line counted: a schedule's runs, Board tasks, questions, a place's uses.
        public var count: Int
        /// The schedule's name, for the news.
        public var subject: String?
        public var isNew: Bool
        public var actions: [WeeklyAction]

        public init(id: String, kind: Kind, symbol: String, text: String, detail: String? = nil, count: Int = 0,
                    isNew: Bool = false, actions: [WeeklyAction] = [], subject: String? = nil) {
            self.id = id; self.kind = kind; self.symbol = symbol; self.text = text; self.detail = detail; self.count = count
            self.isNew = isNew; self.actions = actions; self.subject = subject
        }
    }

    /// Nothing recorded for anyone.
    public var isQuiet: Bool { helpers.isEmpty }

    /// The note's one line: "3 helpers busy. 2 new things." or "A quiet week."
    public var headline: String {
        guard !helpers.isEmpty else {
            if !unread.isEmpty { return String(localized: "Couldn't read the week.", table: "Core") }
            return quiet.isEmpty ? String(localized: "No helpers to tell about.", table: "Core")
                : String(localized: "A quiet week.", table: "Core")
        }
        let busy = String(localized: "\(helpers.count) helpers busy.", table: "Core")
        guard !news.isEmpty else { return busy }
        return WeeklyWords.sentences(busy, String(localized: "\(news.count) new things.", table: "Core"))
    }

    /// The Watch's few lines: each helper, with what it did and what went online.
    public var short: [(name: String, detail: String)] {
        helpers.map { helper in
            var parts: [String] = []
            let runs = helper.did.filter { $0.kind == .schedule }.reduce(0) { $0 + $1.count }
            if runs > 0 { parts.append(String(localized: "\(runs) runs", table: "Core")) }
            let tasks = helper.did.filter { $0.kind == .board }.reduce(0) { $0 + $1.count }
            if tasks > 0 { parts.append(String(localized: "\(tasks) tasks", table: "Core")) }
            let asked = helper.did.filter { $0.kind == .asked }.reduce(0) { $0 + $1.count }
            if asked == 2 {
                parts.append(String(localized: "asked twice", table: "Core", comment: "A helper asked the person twice this week"))
            } else if asked > 0 {
                parts.append(String(localized: "asked \(asked) times", table: "Core", comment: "A helper asked the person this many times this week"))
            }
            if helper.online == 2 {
                parts.append(String(localized: "online twice", table: "Core", comment: "A helper went online twice this week"))
            } else if helper.online > 0 {
                parts.append(String(localized: "online \(helper.online) times", table: "Core", comment: "A helper went online this many times this week"))
            }
            let new = helper.did.filter(\.isNew).count + helper.left.filter(\.isNew).count
            if new > 0 { parts.append(String(localized: "\(new) new", table: "Core", comment: "How many new things a helper had this week")) }
            return (helper.name, parts.joined(separator: " · "))
        }
    }

    /// How many places a helper's part names before "and 3 more places".
    public static let shownPlaces = 6

    /// Builds the note from the records. A private bot is left out whatever is handed in.
    public static func build(_ inputs: [WeeklyHelperInput], isPrivate: (String) -> Bool, now: Date = Date()) -> WeeklyNote {
        var helpers: [Helper] = [], quiet: [String] = [], unread: [String] = [], news: [Line] = []
        var filter: String?
        var since: Double?
        for input in inputs where !isPrivate(input.profile) && !PrivateBots.carriedOver.contains(PrivateBots.key(input.profile)) {
            guard let record = input.record, record.bot == input.profile else { unread.append(input.name); continue }
            since = since.map { min($0, record.since) } ?? record.since
            if filter == nil { filter = WeeklyWords.filter(record.filter) }
            let helper = part(for: input, record: record)
            news += helper.did.filter(\.isNew).map { WeeklyWords.news($0, helper: input.name) }
            news += helper.left.filter(\.isNew).map { WeeklyWords.news($0, helper: input.name) }
            if helper.did.contains(where: { $0.kind != .mac }) || !helper.left.isEmpty {
                helpers.append(helper)
            } else {
                quiet.append(input.name)
            }
        }
        helpers.sort { ($0.weight, $1.name) > ($1.weight, $0.name) }
        let start = since.map { Date(timeIntervalSince1970: $0) } ?? Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: now))!
        return WeeklyNote(since: start, until: now, news: news, helpers: helpers, quiet: quiet, unread: unread, filter: filter)
    }

    private static func part(for input: WeeklyHelperInput, record: WeekRecord) -> Helper {
        let bot = input.profile
        var did: [Line] = []
        // Schedules: each that ran this week, and each made this week, with Pause beside it.
        for schedule in record.schedules {
            let isNew = (schedule.createdAt ?? 0) >= record.since
            let ran = schedule.runs?.total ?? 0
            guard ran > 0 || isNew, WeeklyAction.safeJob(schedule.id) else { continue }
            var actions: [WeeklyAction] = []
            if !schedule.paused, schedule.finished != true { actions.append(.pause(bot: bot, job: schedule.id)) }
            if isNew { actions.append(.remove(bot: bot, job: schedule.id)) }
            did.append(Line(id: "\(bot)/schedule/\(schedule.id)", kind: .schedule, symbol: "clock.arrow.circlepath",
                            text: WeeklyWords.schedule(schedule, isNew: isNew), detail: WeeklyWords.runs(schedule),
                            count: ran, isNew: isNew, actions: actions, subject: schedule.name))
        }
        if let board = record.board, board.done + board.stopped + board.failed > 0 {
            did.append(Line(id: "\(bot)/board", kind: .board, symbol: "checklist", text: WeeklyWords.board(board),
                            detail: WeeklyWords.boardDetail(board), count: board.done > 0 ? board.done : board.stopped + board.failed))
        }
        let answers = record.answers
        if answers.total > 0 {
            let more = WeeklyWords.moreThanUsual(answers.total, earlier: record.earlierAnswers ?? [], hasEarlierWeek: record.hasEarlierWeek)
            did.append(Line(id: "\(bot)/asked", kind: .asked, symbol: "hand.raised.fill", text: WeeklyWords.asked(answers.total, more: more),
                            detail: WeeklyWords.answered(answers), count: answers.total, isNew: more))
        }
        if input.macOn == true {
            did.append(Line(id: "\(bot)/mac", kind: .mac, symbol: "macbook", text: String(localized: "Can use your Mac", table: "Core"), actions: [.macOff(bot: bot)]))
        }
        // What left: each place, most used first, with a tap where one is real.
        var left: [Line] = []
        var webOffered = false
        let apps = record.apps ?? []
        for (index, place) in record.places.enumerated() {
            let isNew = record.hasEarlierWeek && (place.firstAt ?? 0) >= record.since
            var actions: [WeeklyAction] = []
            switch place.kind {
            case "search", "pages":
                if record.web?.on == true, !webOffered { actions.append(.webOff(bot: bot)); webOffered = true }
            case "mcp":
                if let app = apps.first(where: { $0.on && $0.host != nil && $0.host?.lowercased() == place.host?.lowercased() }) {
                    actions.append(.appOff(bot: bot, app: app.name))
                }
            default:
                break
            }
            left.append(Line(id: "\(bot)/place/\(index)/\(place.kind)/\(place.host ?? place.provider ?? place.service ?? "")",
                             kind: .place, symbol: WeeklyWords.placeSymbol(place.kind), text: WeeklyWords.placeName(place),
                             detail: WeeklyWords.placeDetail(place), count: place.count, isNew: isNew, actions: actions))
        }
        // New places first among those shown, so nothing new hides behind "and 3 more".
        let shown = left.filter(\.isNew) + left.filter { !$0.isNew }
        let kept = Array(shown.prefix(shownPlaces))
        let more = shown.count - kept.count + (record.placesMore ?? 0)
        return Helper(profile: bot, name: input.name, did: did, leftLine: WeeklyWords.leftLine(record, name: input.name),
                      left: kept, morePlaces: more, online: record.replies?.online ?? 0,
                      mute: input.muted ? .unmute(bot: bot) : .mute(bot: bot))
    }
}

private extension WeeklyNote.Helper {
    /// Busiest first: new things, then everything counted.
    var weight: Int { (hasNews ? 1_000_000 : 0) + did.reduce(0) { $0 + $1.count } + left.count }
}

// MARK: Words

/// The note's sentences. Each is fixed, filled only with counts and names from the records. Each count is said in a
/// whole sentence of its own (with twice as its own line), so every language can say it its own way.
public enum WeeklyWords {
    /// Two sentences one after the other: "1 helper busy. 3 new things."
    static func sentences(_ first: String, _ second: String) -> String {
        String(localized: "\(first) \(second)", table: "Core", comment: "Two whole sentences one after the other")
    }

    /// A count of times said alone at the start of a line: "Once", "Twice", "3 times".
    static func times(_ n: Int) -> String {
        n == 2 ? String(localized: "Twice", table: "Core", comment: "How many times, alone at the start of a line")
            : String(localized: "\(n) times", table: "Core", comment: "How many times, alone at the start of a line")
    }

    /// A label and how often: "Model · 31 times", "Commands · twice".
    static func labelTimes(_ label: String, _ n: Int) -> String {
        n == 2 ? String(localized: "\(label) · twice", table: "Core", comment: "What went somewhere, and that it went twice")
            : String(localized: "\(label) · \(n) times", table: "Core", comment: "What went somewhere, and how many times")
    }

    /// The schedule's own name, or "A schedule" when it has none to show.
    static func schedule(_ schedule: WeekRecord.Schedule, isNew: Bool) -> String {
        schedule.name ?? (isNew ? String(localized: "A new schedule", table: "Core") : String(localized: "A schedule", table: "Core"))
    }

    /// "Ran 6 times · 1 didn't finish · Paused".
    static func runs(_ schedule: WeekRecord.Schedule) -> String? {
        var parts: [String] = []
        if let runs = schedule.runs, runs.total > 0 {
            parts.append(runs.total == 2 ? String(localized: "Ran twice", table: "Core", comment: "A schedule ran twice this week")
                : String(localized: "Ran \(runs.total) times", table: "Core", comment: "A schedule ran this many times this week"))
            let missed = runs.failed + runs.unfinished
            if missed > 0 { parts.append(String(localized: "\(missed) didn't finish", table: "Core", comment: "How many of a schedule's runs didn't finish")) }
        }
        if schedule.paused { parts.append(String(localized: "Paused", table: "Core", comment: "A schedule's state")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func board(_ board: WeekRecord.Board) -> String {
        if board.done > 0 { return String(localized: "Finished \(board.done) Board tasks", table: "Core") }
        let other = board.stopped + board.failed
        return String(localized: "Worked on \(other) Board tasks", table: "Core")
    }

    static func boardDetail(_ board: WeekRecord.Board) -> String? {
        var parts: [String] = []
        if board.stopped > 0 { parts.append(String(localized: "\(board.stopped) stopped", table: "Core", comment: "How many Board tasks were stopped")) }
        if board.failed > 0 { parts.append(String(localized: "\(board.failed) gave up", table: "Core", comment: "How many Board tasks the helper gave up on")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func asked(_ total: Int, more: Bool) -> String {
        switch (total, more) {
        case (2, false): String(localized: "Asked you twice", table: "Core")
        case (2, true): String(localized: "Asked you twice, more than usual", table: "Core")
        case (_, false): String(localized: "Asked you \(total) times", table: "Core")
        case (_, true): String(localized: "Asked you \(total) times, more than usual", table: "Core")
        }
    }

    /// "Yes 3 · No 1 · Always 1", in the order people say them.
    static func answered(_ answers: WeekRecord.Answers) -> String {
        var parts: [String] = []
        if answers.yes > 0 { parts.append(String(localized: "Yes \(answers.yes)", table: "Core", comment: "How many times the person said yes")) }
        if answers.always > 0 { parts.append(String(localized: "Always \(answers.always)", table: "Core", comment: "How many times the person said always allow")) }
        if answers.deny > 0 { parts.append(String(localized: "No \(answers.deny)", table: "Core", comment: "How many times the person said no")) }
        return parts.joined(separator: " · ")
    }

    /// More than usual: at least three questions, and at least twice the average of the earlier whole weeks.
    public static func moreThanUsual(_ count: Int, earlier: [Int], hasEarlierWeek: Bool) -> Bool {
        guard hasEarlierWeek, !earlier.isEmpty, count >= 3 else { return false }
        let average = Double(earlier.reduce(0, +)) / Double(earlier.count)
        return Double(count) >= max(2 * average, average + 3)
    }

    static func leftLine(_ record: WeekRecord, name: String) -> String {
        guard record.papertrail != false else {
            return String(localized: "Papertrail isn't on for \(name) yet.", table: "Core", comment: "Safety: Papertrail line; keep exact meaning")
        }
        let nothing = String(localized: "Nothing seen leaving.", table: "Core", comment: "Safety: Papertrail line; keep exact meaning")
        guard let replies = record.replies else { return nothing }
        let went: String
        if replies.online == 2 {
            went = String(localized: "Went online twice.", table: "Core", comment: "Safety: Papertrail line; keep exact meaning")
        } else if replies.online > 0 {
            went = String(localized: "Went online \(replies.online) times.", table: "Core", comment: "Safety: Papertrail line; keep exact meaning")
        } else if replies.left > 0 {
            went = String(localized: "Stayed on your network.", table: "Core", comment: "Safety: Papertrail line; keep exact meaning")
        } else {
            went = nothing
        }
        guard replies.stayed > 0 else { return went }
        return sentences(went, String(localized: "\(replies.stayed) replies stayed on your Mac.", table: "Core",
                                      comment: "Safety: Papertrail line; keep exact meaning"))
    }

    static func placeSymbol(_ kind: String) -> String {
        switch kind {
        case "model": "brain"
        case "search": "magnifyingglass"
        case "pages", "reader": "doc.text"
        case "pictures": "photo"
        case "paid": "creditcard"
        case "icloud": "icloud"
        case "terminal": "terminal"
        case "code": "curlybraces"
        case "mcp": "app.connected.to.app.below.fill"
        case "direct": "exclamationmark.shield"
        default: "network"
        }
    }

    /// The place's name: a provider or service people know, else the host.
    static func placeName(_ place: WeekRecord.Place) -> String {
        switch place.kind {
        case "model":
            if let provider = place.provider, let known = Papertrail.providerLabel(provider.lowercased()) { return known }
            if let label = place.label?.trimmingCharacters(in: .whitespaces), !label.isEmpty { return label }
            if let host = place.host, let name = URLComponents(string: host)?.host ?? Optional(host), !name.isEmpty { return name }
            return String(localized: "Its model", table: "Core", comment: "Where a helper's words went: its own model")
        case "search": return place.service.flatMap(Papertrail.serviceLabel) ?? String(localized: "Web search", table: "Core")
        case "pages": return String(localized: "Web pages", table: "Core")
        case "pictures": return String(localized: "Pictures", table: "Core", comment: "A place things went: a picture service")
        case "icloud": return String(localized: "Your iCloud", table: "Core")
        default: return place.host ?? String(localized: "Somewhere online", table: "Core")
        }
    }

    /// What went there and how often: "Model · 31 times", "4 searches", "Commands · 3 times".
    static func placeDetail(_ place: WeekRecord.Place) -> String {
        let n = place.count
        switch place.kind {
        case "model": return labelTimes(String(localized: "Model", table: "Core", comment: "What went somewhere: words to a model"), n)
        case "search": return String(localized: "\(n) searches", table: "Core")
        case "pages": return String(localized: "\(n) pages read", table: "Core")
        case "pictures": return String(localized: "\(n) asked for", table: "Core", comment: "How many pictures a helper asked for")
        case "paid":
            return n == 2 ? String(localized: "Paid twice", table: "Core", comment: "Safety: payment count; keep exact meaning")
                : String(localized: "Paid \(n) times", table: "Core", comment: "Safety: payment count; keep exact meaning")
        case "icloud": return String(localized: "\(n) notes to your iPhone", table: "Core")
        case "terminal": return labelTimes(String(localized: "Commands", table: "Core", comment: "What went somewhere: terminal commands"), n)
        case "code": return labelTimes(String(localized: "Code", table: "Core", comment: "What went somewhere: code a helper ran"), n)
        case "mcp": return labelTimes(String(localized: "Connected app", table: "Core"), n)
        case "reader": return labelTimes(String(localized: "Pages read", table: "Core"), n)
        case "hermes": return labelTimes(String(localized: "The assistant itself", table: "Core"), n)
        case "direct": return labelTimes(String(localized: "Around the door", table: "Core", comment: "A program that went online without passing Nollie's network door"), n)
        default: return labelTimes(String(localized: "A program", table: "Core"), n)
        }
    }

    /// The same line, said as news: "Scout reached github.com for the first time."
    static func news(_ line: WeeklyNote.Line, helper: String) -> WeeklyNote.Line {
        var said = line
        said.id = "news/" + line.id
        switch line.kind {
        case .place:
            let service = line.symbol == placeSymbol("search") || line.symbol == placeSymbol("mcp")
            said.text = service ? String(localized: "\(helper) used something new", table: "Core")
                : String(localized: "\(helper) reached a new place", table: "Core")
            said.detail = [line.text, line.detail].compactMap { $0 }.joined(separator: " · ")
        case .schedule:
            said.text = String(localized: "\(helper) has a new schedule", table: "Core")
            said.detail = [line.subject.map { String(localized: "\u{201C}\($0)\u{201D}", table: "Core", comment: "A schedule's name in quotation marks") }, line.detail].compactMap { $0 }.joined(separator: " · ")
            if said.detail?.isEmpty == true { said.detail = nil }
        case .asked:
            said.text = String(localized: "\(helper) asked more than usual", table: "Core")
            said.detail = [times(line.count), line.detail]
                .compactMap { $0 }.joined(separator: " · ")
        case .board, .mac:
            break
        }
        return said
    }

    /// What Papertrail can't see, in a few words. Nil when the filter is on or nothing was said.
    public static func filter(_ state: String?) -> String? {
        switch state {
        case "off": String(localized: "Papertrail's filter is off, so a program that skips Nollie's door could go unseen.", table: "Core",
                           comment: "Safety: what Papertrail can't see; keep exact meaning")
        case "none": String(localized: "This setup has no door, so Papertrail sees model calls, searches and pages only.", table: "Core",
                            comment: "Safety: what Papertrail can't see; keep exact meaning")
        default: nil
        }
    }
}

// MARK: When it goes out

/// When the note goes out, and when its card shows at the top of the main chat. The day is the person's choice
/// (Sunday by default), always in the evening.
public struct WeeklyNoteTiming: Equatable, Sendable {
    /// 1 is Sunday, as `Calendar` counts.
    public var weekday: Int
    public var hour: Int

    public static let standard = WeeklyNoteTiming(weekday: 1, hour: 18)

    public init(weekday: Int, hour: Int = 18) {
        self.weekday = (1...7).contains(weekday) ? weekday : 1
        self.hour = (0...23).contains(hour) ? hour : 18
    }

    /// The latest time the note went out at or before `now`.
    public func latest(before now: Date, calendar: Calendar = .current) -> Date {
        let next = calendar.nextDate(after: now, matching: DateComponents(hour: hour, minute: 0, weekday: weekday),
                                     matchingPolicy: .nextTime, direction: .backward) ?? now
        return next
    }

    /// The card shows from the note's time until the person puts it away.
    public func cardShows(now: Date, putAwayAt: Date?, calendar: Calendar = .current) -> Bool {
        let latest = latest(before: now, calendar: calendar)
        return putAwayAt.map { $0 < latest } ?? true
    }
}
