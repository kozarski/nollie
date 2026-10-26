import Foundation

/// A card Nollie's workflow add-on posted into the default bot's main chat: the morning's night shift, or the
/// report of a new schedule's rehearsal. Fetched and acted on over REST, never through the model. See
/// `Docs/specs/night-shift.md`.
public struct ConversationPost: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var at: Date
    public var kind: Kind
    /// The tap in flight, while it runs.
    public var pending: ConversationPostAction?
    /// Why the last tap didn't go through, in words the person can read.
    public var problem: String?

    public enum Kind: Codable, Hashable, Sendable {
        case nightShift(NightShift)
        case rehearsal(Rehearsal)
    }

    public init(id: String, at: Date, kind: Kind, pending: ConversationPostAction? = nil, problem: String? = nil) {
        self.id = id
        self.at = at
        self.kind = kind
        self.pending = pending
        self.problem = problem
    }

    /// What unattended runs did in a window of the night.
    public struct NightShift: Codable, Hashable, Sendable {
        public var from: Date?
        public var to: Date?
        public var counts: Counts
        /// Bots whose runs Nollie could not watch.
        public var unwatched: [String]
        public var runs: [Run]
        /// Runs past the ones listed (the add-on lists at most 100).
        public var moreRuns: Int
        /// When the Mac was asleep or off in the window, as the add-on saw it.
        public var sleep: [SleepGap]
        /// Schedules that were due while the Mac slept and never ran for those times.
        public var missed: [Missed]

        public init(from: Date? = nil, to: Date? = nil, counts: Counts = Counts(), unwatched: [String] = [], runs: [Run] = [],
                    moreRuns: Int = 0, sleep: [SleepGap] = [], missed: [Missed] = []) {
            self.from = from
            self.to = to
            self.counts = counts
            self.unwatched = unwatched
            self.runs = runs
            self.moreRuns = moreRuns
            self.sleep = sleep
            self.missed = missed
        }
    }

    /// A stretch when the Mac was asleep, off, or on without Hermes running.
    public struct SleepGap: Codable, Hashable, Sendable {
        public var from: Date
        public var to: Date
        public var kind: Kind

        public enum Kind: String, Codable, Hashable, Sendable {
            case asleep, off, stopped
        }

        public init(from: Date, to: Date, kind: Kind) {
            self.from = from
            self.to = to
            self.kind = kind
        }

        public func holds(_ date: Date) -> Bool { from <= date && date < to }
    }

    /// One schedule's times that went by while the Mac slept, with nothing run for them.
    public struct Missed: Codable, Hashable, Sendable {
        public var bot: String
        public var botName: String
        public var jobId: String
        public var title: String
        public var firstDue: Date?
        public var lastDue: Date?
        public var count: Int

        public init(bot: String, botName: String, jobId: String, title: String, firstDue: Date? = nil, lastDue: Date? = nil,
                    count: Int) {
            self.bot = bot
            self.botName = botName
            self.jobId = jobId
            self.title = title
            self.firstDue = firstDue
            self.lastDue = lastDue
            self.count = count
        }
    }

    public struct Counts: Codable, Hashable, Sendable {
        public var runs: Int
        public var actions: Int
        public var held: Int
        public var stopped: Int
        /// Actions the recorder had to drop.
        public var unrecorded: Int

        public init(runs: Int = 0, actions: Int = 0, held: Int = 0, stopped: Int = 0, unrecorded: Int = 0) {
            self.runs = runs
            self.actions = actions
            self.held = held
            self.stopped = stopped
            self.unrecorded = unrecorded
        }
    }

    /// One schedule run, Board outcome, helper or rehearsal in the window.
    public struct Run: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        /// `schedule`, `board`, `helper` or `rehearsal`, as the add-on names it.
        public var kind: String
        public var bot: String
        public var botName: String
        public var title: String
        public var outcome: Outcome?
        public var startedAt: Date?
        public var finishedAt: Date?
        public var actions: [Action]
        /// Actions past the ones listed.
        public var more: Int
        /// When a schedule run was due.
        public var dueAt: Date?
        /// It started more than five minutes after it was due.
        public var late: Bool

        public init(id: String, kind: String = "schedule", bot: String, botName: String, title: String, outcome: Outcome? = nil,
                    startedAt: Date? = nil, finishedAt: Date? = nil, actions: [Action] = [], more: Int = 0, dueAt: Date? = nil,
                    late: Bool = false) {
            self.dueAt = dueAt
            self.late = late
            self.id = id
            self.kind = kind
            self.bot = bot
            self.botName = botName
            self.title = title
            self.outcome = outcome
            self.startedAt = startedAt
            self.finishedAt = finishedAt
            self.actions = actions
            self.more = more
        }
    }

    public enum Outcome: String, Codable, Hashable, Sendable {
        case done, failed, stopped, skipped, rehearsal
    }

    /// One tool call of a run, or one held or looked-at call of a rehearsal.
    public struct Action: Codable, Hashable, Sendable {
        public var tool: String
        public var target: String
        public var status: Status?
        public var at: Date?
        public var receipt: Receipt?

        public enum Status: String, Codable, Hashable, Sendable {
            case done, failed, blocked
        }

        public init(tool: String, target: String = "", status: Status? = nil, at: Date? = nil, receipt: Receipt? = nil) {
            self.tool = tool
            self.target = target
            self.status = status
            self.at = at
            self.receipt = receipt
        }
    }

    /// Why an action was allowed, or what stopped it, as the add-on recorded it when the tool ran.
    public struct Receipt: Codable, Hashable, Sendable {
        public var kind: Kind
        /// The allow list entry, what Always allowed, or what stopped it (`mac`, `risky`, `deny_rule`, ...).
        public var detail: String?
        /// When the person chose Always, when the add-on saw it.
        public var grantedAt: Date?
        /// The words of the rule that decided it, when the safety check gave some: what made a command risky or
        /// never allowed ("recursive delete"), or the person's own rule that says no. Nil on receipts from before 1.1.
        public var rule: String?
        /// What Ask first held it for: `send`, `buy`, `post`, `delete` or `unsure`. Nil on receipts from before 1.1.
        public var ask: String?

        /// A kind this build does not know reads as `unknown`.
        public enum Kind: String, Codable, Hashable, Sendable {
            case tool, safe, allowlist, always, held, blocked, unknown
        }

        public init(kind: Kind, detail: String? = nil, grantedAt: Date? = nil, rule: String? = nil, ask: String? = nil) {
            self.kind = kind
            self.detail = detail
            self.grantedAt = grantedAt
            self.rule = rule
            self.ask = ask
        }
    }

    /// A new schedule's first run, done as a rehearsal, or a schedule Nollie can't rehearse (`check`).
    public struct Rehearsal: Codable, Hashable, Sendable {
        public var bot: String
        public var botName: String
        public var jobId: String
        public var title: String
        public var schedule: String?
        public var state: State?
        public var check: Check?
        public var outcome: Outcome?
        /// What it would have done.
        public var held: [Action]
        public var looked: [Action]
        /// The reply it would have sent.
        public var reply: String

        public enum State: String, Codable, Hashable, Sendable {
            case ready, on, keptOff = "kept_off", changed
        }

        public init(bot: String, botName: String, jobId: String, title: String, schedule: String? = nil, state: State? = nil,
                    check: Check? = nil, outcome: Outcome? = nil, held: [Action] = [], looked: [Action] = [], reply: String = "") {
            self.bot = bot
            self.botName = botName
            self.jobId = jobId
            self.title = title
            self.schedule = schedule
            self.state = state
            self.check = check
            self.outcome = outcome
            self.held = held
            self.looked = looked
            self.reply = reply
        }
    }

    /// Why a schedule can't be rehearsed, and what it will do.
    public struct Check: Codable, Hashable, Sendable {
        public var reason: Reason?
        public var prompt: String
        public var script: String?
        /// The first characters of the script's hash.
        public var hash: String?

        public enum Reason: String, Codable, Hashable, Sendable {
            case script, once, `repeat`, unwatched
        }

        public init(reason: Reason?, prompt: String = "", script: String? = nil, hash: String? = nil) {
            self.reason = reason
            self.prompt = prompt
            self.script = script
            self.hash = hash
        }
    }

    public var nightShift: NightShift? {
        if case .nightShift(let card) = kind { return card }
        return nil
    }

    public var rehearsal: Rehearsal? {
        if case .rehearsal(let card) = kind { return card }
        return nil
    }

    /// The same post as the add-on sent it, without what only this device knows.
    var content: ConversationPost {
        var plain = self
        plain.pending = nil
        plain.problem = nil
        return plain
    }
}

/// What the person can tap on a rehearsal card.
public enum ConversationPostAction: String, Codable, Hashable, Sendable {
    case turnOn = "turn-on"
    case keepOff = "keep-off"
}

// MARK: Reading the add-on's posts

extension ConversationPost {
    /// One post of `GET /api/plugins/nollie-workflow/posts`, read leniently: fields this build doesn't know are
    /// ignored. Nil for a kind it doesn't know, or without an id and time.
    public init?(wire json: GatewayJSON) {
        guard let id = json["id"]?.stringValue, !id.isEmpty, let at = Self.date(json["at"]) else { return nil }
        switch json["kind"]?.stringValue {
        case "night_shift":
            let window = json["window"]
            let counts = json["counts"]
            self.init(id: id, at: at, kind: .nightShift(NightShift(
                from: Self.date(window?["from"]), to: Self.date(window?["to"]),
                counts: Counts(runs: counts?["runs"]?.intValue ?? 0, actions: counts?["actions"]?.intValue ?? 0,
                               held: counts?["held"]?.intValue ?? 0, stopped: counts?["stopped"]?.intValue ?? 0,
                               unrecorded: counts?["unrecorded"]?.intValue ?? 0),
                unwatched: (json["unwatched"]?.arrayValue ?? []).compactMap { entry in
                    entry.stringValue ?? entry["bot_name"]?.stringValue ?? entry["bot"]?.stringValue
                },
                runs: (json["runs"]?.arrayValue ?? []).compactMap(Run.init(wire:)),
                moreRuns: max(json["more_runs"]?.intValue ?? 0, 0),
                sleep: (json["sleep"]?.arrayValue ?? []).compactMap(SleepGap.init(wire:)),
                missed: (json["missed"]?.arrayValue ?? []).compactMap(Missed.init(wire:)))))
        case "rehearsal":
            let check = json["check"].flatMap { value -> Check? in
                guard value.objectValue != nil else { return nil }
                return Check(reason: value["reason"]?.stringValue.flatMap(Check.Reason.init(rawValue:)),
                             prompt: value["prompt"]?.stringValue ?? "", script: Self.text(value["script"]),
                             hash: Self.text(value["hash"]))
            }
            self.init(id: id, at: at, kind: .rehearsal(Rehearsal(
                bot: json["bot"]?.stringValue ?? "", botName: json["bot_name"]?.stringValue ?? "",
                jobId: json["job_id"]?.stringValue ?? "", title: json["title"]?.stringValue ?? "",
                schedule: Self.text(json["schedule"]),
                state: json["state"]?.stringValue.flatMap(Rehearsal.State.init(rawValue:)),
                check: check,
                outcome: json["outcome"]?.stringValue.flatMap(Outcome.init(rawValue:)),
                held: (json["held"]?.arrayValue ?? []).compactMap(Action.init(wire:)),
                looked: (json["looked"]?.arrayValue ?? []).compactMap(Action.init(wire:)),
                reply: json["reply"]?.stringValue ?? "")))
        default:
            return nil
        }
    }

    /// Unix seconds.
    fileprivate static func date(_ value: GatewayJSON?) -> Date? {
        value?.doubleValue.map { Date(timeIntervalSince1970: $0) }
    }

    fileprivate static func text(_ value: GatewayJSON?) -> String? {
        value?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    }
}

extension ConversationPost.Run {
    init?(wire json: GatewayJSON) {
        guard let id = json["id"]?.stringValue else { return nil }
        self.init(id: id, kind: json["kind"]?.stringValue ?? "schedule", bot: json["bot"]?.stringValue ?? "",
                  botName: json["bot_name"]?.stringValue ?? "", title: json["title"]?.stringValue ?? "",
                  outcome: json["outcome"]?.stringValue.flatMap(ConversationPost.Outcome.init(rawValue:)),
                  startedAt: ConversationPost.date(json["started_at"]), finishedAt: ConversationPost.date(json["finished_at"]),
                  actions: (json["actions"]?.arrayValue ?? []).compactMap(ConversationPost.Action.init(wire:)),
                  more: json["more"]?.intValue ?? 0, dueAt: ConversationPost.date(json["due_at"]),
                  late: json["late"]?.boolValue ?? false)
    }
}

extension ConversationPost.SleepGap {
    /// One gap of the add-on's card or of `GET /api/plugins/nollie-workflow/sleep`. Nil without both ends, or for
    /// a kind this build doesn't know.
    public init?(wire json: GatewayJSON) {
        guard let from = ConversationPost.date(json["from"]), let to = ConversationPost.date(json["to"]), to > from,
              let kind = json["kind"]?.stringValue.flatMap(Kind.init(rawValue:)) else { return nil }
        self.init(from: from, to: to, kind: kind)
    }
}

extension ConversationPost.Missed {
    init?(wire json: GatewayJSON) {
        guard let count = json["count"]?.intValue, count > 0 else { return nil }
        self.init(bot: json["bot"]?.stringValue ?? "", botName: json["bot_name"]?.stringValue ?? "",
                  jobId: json["job_id"]?.stringValue ?? "", title: json["title"]?.stringValue ?? "",
                  firstDue: ConversationPost.date(json["first_due"]), lastDue: ConversationPost.date(json["last_due"]),
                  count: count)
    }
}

extension ConversationPost.Action {
    init?(wire json: GatewayJSON) {
        guard let tool = json["tool"]?.stringValue else { return nil }
        let receipt = json["receipt"].flatMap { value -> ConversationPost.Receipt? in
            guard value.objectValue != nil else { return nil }
            return ConversationPost.Receipt(
                kind: value["kind"]?.stringValue.flatMap(ConversationPost.Receipt.Kind.init(rawValue:)) ?? .unknown,
                detail: ConversationPost.text(value["detail"]), grantedAt: ConversationPost.date(value["granted_at"]),
                rule: ConversationPost.text(value["rule"]), ask: ConversationPost.text(value["ask"]))
        }
        self.init(tool: tool, target: json["target"]?.stringValue ?? "",
                  status: json["status"]?.stringValue.flatMap(Status.init(rawValue:)),
                  at: ConversationPost.date(json["at"]), receipt: receipt)
    }
}

// MARK: Where posts come from

/// The add-on's posts for one chat, and the taps on them.
public protocol ConversationPostSource: Sendable {
    /// Posts made at or after `since`, in any order.
    func posts(since: Date) async throws -> [ConversationPost]
    /// Turn on or Keep off; answers the updated post.
    func perform(_ action: ConversationPostAction, on postId: String) async throws -> ConversationPost
}

/// The add-on's REST routes, `GET /api/plugins/nollie-workflow/posts` and
/// `POST /api/plugins/nollie-workflow/rehearsals/{id}/turn-on|keep-off`, always for the default profile.
public struct HermesConversationPosts: ConversationPostSource {
    /// Sends one request (`method`, path, query) and returns the body with its status. A 409 comes back as an
    /// answer, since its body is the post as it is now; other failures throw.
    public typealias Call = @Sendable (_ method: String, _ path: String, _ query: [URLQueryItem]) async throws -> (body: Data, status: Int)

    static let path = "/api/plugins/nollie-workflow"
    public static let limit = 60

    private let call: Call

    public init(call: @escaping Call) {
        self.call = call
    }

    /// On a gateway's REST client, as the default profile.
    public init(api: HermesAPI) {
        self.init { method, path, query in
            let body: (Data, String)? = method == "GET" ? nil : (Data("{}".utf8), "application/json")
            let (data, http) = try await api.raw(method, path, query: query, profile: "default", body: body, authenticated: true,
                                                 answers: [409])
            return (data, http.statusCode)
        }
    }

    public func posts(since: Date) async throws -> [ConversationPost] {
        let query = [URLQueryItem(name: "since", value: String(Int(since.timeIntervalSince1970))),
                     URLQueryItem(name: "limit", value: String(Self.limit)),
                     URLQueryItem(name: "profile", value: "default")]
        let answer = try await call("GET", Self.path + "/posts", query)
        guard answer.status < 400 else { throw HermesAPIError.http(status: answer.status, detail: "") }
        let body = try GatewayJSON.parse(answer.body)
        return (body["posts"]?.arrayValue ?? []).compactMap(ConversationPost.init(wire:))
    }

    public func perform(_ action: ConversationPostAction, on postId: String) async throws -> ConversationPost {
        // The id goes into the path: only what the add-on makes ids from.
        guard !postId.isEmpty, postId.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            throw URLError(.badURL)
        }
        let answer = try await call("POST", Self.path + "/rehearsals/\(postId)/\(action.rawValue)",
                                    [URLQueryItem(name: "profile", value: "default")])
        // A 409 (the schedule changed, or a one-off's time passed) carries the post as it is now: that is the answer.
        guard answer.status < 400 || answer.status == 409 else { throw HermesAPIError.http(status: answer.status, detail: "") }
        let body = try GatewayJSON.parse(answer.body)
        // The updated post, on its own or under `post`.
        guard let post = ConversationPost(wire: body["post"] ?? body), post.id == postId else {
            throw answer.status == 409 ? HermesAPIError.http(status: 409, detail: "") : HermesAPIError.decoding("no post in the answer")
        }
        return post
    }
}
