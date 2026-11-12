import Foundation

/// Which schedules are running right now, from the gateway's own scheduler record: every bot's jobs
/// in one `GET /api/cron/jobs`, where Hermes 0.23 puts each job's run in flight under
/// `live_execution` (a claimed or running attempt whose process is still alive). It carries a
/// job's name, its bot and when the run began, nothing of what the run says. Private bots' runs
/// are left out when it is read.
public struct ScheduleActivity: Equatable, Sendable {
    public struct Run: Equatable, Sendable, Identifiable {
        public var jobID: String
        public var name: String
        public var profile: String
        public var startedAt: Date
        /// The attempt Hermes is running, when it says.
        public var executionID: String?
        public var id: String { jobID }

        public init(jobID: String, name: String, profile: String, startedAt: Date, executionID: String? = nil) {
            self.jobID = jobID; self.name = name; self.profile = profile; self.startedAt = startedAt; self.executionID = executionID
        }
    }

    /// Longest-running first.
    public var runs: [Run]
    public var checkedAt: Date

    public init(runs: [Run] = [], checkedAt: Date = .distantPast) {
        self.runs = runs.sorted { ($0.startedAt, $0.name) < ($1.startedAt, $1.name) }
        self.checkedAt = checkedAt
    }

    /// A look older than this says nothing: the gateway may have finished the run since.
    public static let freshFor: TimeInterval = 150

    /// The last look is recent enough to go by.
    public func isFresh(now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(checkedAt)
        return age >= -5 && age < Self.freshFor
    }

    /// The runs, while the last look is fresh.
    public func current(now: Date = Date()) -> [Run] {
        isFresh(now: now) ? runs : []
    }

    /// The bot's runs now, longest-running first.
    public func runs(for profile: String, now: Date = Date()) -> [Run] {
        current(now: now).filter { $0.profile == profile }
    }

    public func run(job jobID: String, now: Date = Date()) -> Run? {
        current(now: now).first { $0.jobID == jobID }
    }

    // MARK: Reading the gateway's answer

    /// The jobs in a `GET /api/cron/jobs` answer: a bare list, or one under `jobs` or `items`.
    public static func entries(_ reply: JSONValue) -> [JSONValue] {
        reply["jobs"]?.arrayValue ?? reply["items"]?.arrayValue ?? reply.arrayValue ?? []
    }

    /// The runs in flight in a jobs list. `connection` is the gateway, whose Private list counts.
    public static func read(_ reply: JSONValue, connection: UUID? = nil, now: Date = Date()) -> Self {
        let runs = entries(reply).compactMap { entry -> Run? in
            guard let run = live(entry) else { return nil }
            return PrivateBots.isPrivate(run.profile, connection: connection) ? nil : run
        }
        return Self(runs: runs, checkedAt: now)
    }

    /// The job's run in flight, if it has one. Hermes 0.23 says so in `live_execution`; an older
    /// gateway only in its latest attempt, which is used when `live_execution` is not there at all.
    public static func live(_ job: JSONValue) -> Run? {
        // The same name the app keys a job by (`CronJob.identity`): its job id, else its id.
        guard let id = job["job_id"]?.stringValue ?? job["id"]?.stringValue, !id.isEmpty else { return nil }
        let attempt: JSONValue?
        if let live = job["live_execution"] { attempt = live.isNull ? nil : live } else { attempt = job["latest_execution"] }
        guard let attempt, ["claimed", "running"].contains(attempt["status"]?.stringValue ?? "") else { return nil }
        let began = (attempt["started_at"]?.stringValue).flatMap(date) ?? (attempt["claimed_at"]?.stringValue).flatMap(date)
        guard let began else { return nil }
        let profile = job["profile"]?.stringValue ?? job["profile_name"]?.stringValue ?? "default"
        let name = job["name"]?.stringValue.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        return Run(jobID: id, name: name ?? String(localized: "Schedule", table: "Core"), profile: profile, startedAt: began,
                   executionID: attempt["id"]?.stringValue)
    }

    /// Hermes's timestamps: ISO 8601 with an offset, often with microseconds ("…T09:41:00.123456-05:00").
    public static func date(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let found = plain.date(from: text) { return found }
        // Down to milliseconds, which the formatter reads everywhere.
        var trimmed = text
        if let dot = text.firstIndex(of: ".") {
            let digits = text[text.index(after: dot)...].prefix { $0.isNumber }
            let rest = text[text.index(after: dot)...].dropFirst(digits.count)
            trimmed = String(text[..<dot]) + "." + String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0) + rest
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions.insert(.withFractionalSeconds)
        return fractional.date(from: trimmed)
    }
}

/// Hermes's answer to Stop on one schedule's run (`POST /api/cron/jobs/{id}/cancel`). The schedule
/// itself stays as it was.
public struct ScheduleCancel: Equatable, Sendable {
    /// Hermes asked the run to stop; it ends at its next check.
    public var cancelled: Bool
    public var executionID: String?
    /// Hermes's own sentence, passed through untouched.
    public var detail: String?

    public init(cancelled: Bool, executionID: String? = nil, detail: String? = nil) {
        self.cancelled = cancelled; self.executionID = executionID; self.detail = detail
    }

    /// Nil when the reply is not an answer to a cancel (no `cancelled` in it, or `success` false).
    public init?(_ reply: JSONValue) {
        guard let cancelled = reply["cancelled"]?.boolValue, reply["success"]?.boolValue != false else { return nil }
        self.init(cancelled: cancelled, executionID: reply["execution_id"]?.stringValue, detail: reply["detail"]?.stringValue)
    }
}
