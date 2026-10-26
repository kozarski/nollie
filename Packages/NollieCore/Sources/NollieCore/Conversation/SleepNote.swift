import Foundation

/// The one plain line a Night shift card or a schedule's page says when the Mac was asleep or off while work was
/// due: "Your Mac was asleep from 1:10 to 6:40, so two runs waited until it woke." It never says a run ran when it
/// didn't. Times come from the workflow add-on's sleep watch; see `Docs/specs/night-shift.md`.
public enum SleepNote {
    /// Formats a time of day. Tests hand in a fixed one.
    public typealias Clock = @Sendable (Date) -> String

    public static let clock: Clock = { $0.formatted(.dateTime.hour().minute()) }

    /// The card's line, or nil when the Mac never slept in its window.
    public static func line(for card: ConversationPost.NightShift, clock: Clock = SleepNote.clock) -> String? {
        let waited = card.runs.filter { run in
            run.late && run.dueAt.map { due in card.sleep.contains { $0.holds(due) } } == true
        }.count
        return line(gaps: card.sleep, waited: waited, skipped: card.missed.reduce(0) { $0 + $1.count }, clock: clock)
    }

    /// "Your Mac was asleep from 1:10 to 6:40, so two runs waited until it woke and one was skipped."
    public static func line(gaps: [ConversationPost.SleepGap], waited: Int, skipped: Int,
                            clock: Clock = SleepNote.clock) -> String? {
        let gaps = gaps.sorted { $0.from < $1.from }
        guard !gaps.isEmpty else { return nil }
        let head = when(gaps, clock: clock)
        let back = wake(gaps)
        switch (waited > 0, skipped > 0) {
        case (false, false):
            return head + "."
        case (true, false):
            return "\(head), so \(runs(waited)) waited \(back)."
        case (false, true):
            return "\(head), so \(runs(skipped)) \(skipped == 1 ? "was" : "were") skipped."
        case (true, true):
            return "\(head). \(capitalised(runs(waited))) waited \(back) and \(number(skipped)) \(skipped == 1 ? "was" : "were") skipped."
        }
    }

    /// A schedule's last run, when it started late: "Your Mac was asleep at 7:00, so this ran at 7:41." Nil when it
    /// ran on time, or when the gap can't be told.
    public static func scheduleLine(due: Date, ran: Date, gaps: [ConversationPost.SleepGap],
                                    clock: Clock = SleepNote.clock) -> String? {
        guard ran.timeIntervalSince(due) > lateSeconds else { return nil }
        switch gaps.first(where: { $0.holds(due) })?.kind {
        case .asleep?: return "Your Mac was asleep at \(clock(due)), so this ran at \(clock(ran))."
        case .off?: return "Your Mac was off at \(clock(due)), so this ran at \(clock(ran))."
        case .stopped?: return "Your crew wasn't running at \(clock(due)), so this ran at \(clock(ran))."
        case nil: return "Due at \(clock(due)). It ran late, at \(clock(ran))."
        }
    }

    /// Hermes counts a run as late past five minutes.
    public static let lateSeconds: TimeInterval = 300

    // MARK: Pieces

    /// Who was out and when: one or two stretches by their times, more by how long in all.
    private static func when(_ gaps: [ConversationPost.SleepGap], clock: Clock) -> String {
        let kinds = Set(gaps.map(\.kind))
        let subject: String
        if kinds == [.stopped] {
            subject = "Your crew wasn't running"
        } else if kinds.contains(.stopped) {
            subject = "Your crew couldn't run"
        } else if kinds == [.asleep] {
            subject = "Your Mac was asleep"
        } else if kinds == [.off] {
            subject = "Your Mac was off"
        } else {
            subject = "Your Mac was asleep or off"
        }
        if gaps.count <= 2, kinds.count == 1 {
            let stretches = gaps.map { "from \(clock($0.from)) to \(clock($0.to))" }
            return "\(subject) \(stretches.joined(separator: " and "))"
        }
        let seconds = gaps.reduce(0) { $0 + $1.to.timeIntervalSince($1.from) }
        return "\(subject) for \(length(seconds)) in all"
    }

    private static func wake(_ gaps: [ConversationPost.SleepGap]) -> String {
        switch Set(gaps.map(\.kind)) {
        case [.asleep]: "until it woke"
        case [.off]: "until it was back on"
        case [.stopped]: "until it started again"
        default: "until it was back"
        }
    }

    /// "about 5 hours", "about an hour", "40 minutes".
    static func length(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 55 { return "\(max(minutes, 1)) \(minutes == 1 ? "minute" : "minutes")" }
        let hours = Int((seconds / 3600).rounded())
        return hours <= 1 ? "about an hour" : "about \(hours) hours"
    }

    /// "two runs", "one run", "14 runs".
    static func runs(_ count: Int) -> String { "\(number(count)) \(count == 1 ? "run" : "runs")" }

    /// One to twelve in words, as people say them; bigger numbers in figures.
    static func number(_ count: Int) -> String {
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve"]
        return words.indices.contains(count) ? words[count] : String(count)
    }

    private static func capitalised(_ text: String) -> String { text.prefix(1).uppercased() + text.dropFirst() }
}

// MARK: Where the gaps come from, for a schedule's page

/// `GET /api/plugins/nollie-workflow/sleep?since=`, always for the default profile: when the Mac was asleep, off
/// or without Hermes. Times and a kind, nothing else.
public struct HermesSleepGaps: Sendable {
    public typealias Call = @Sendable (_ path: String, _ query: [URLQueryItem]) async throws -> Data

    private let call: Call

    public init(call: @escaping Call) {
        self.call = call
    }

    public init(api: HermesAPI) {
        self.init { path, query in
            try await api.raw("GET", path, query: query, profile: "default", body: nil, authenticated: true).0
        }
    }

    public func gaps(since: Date) async throws -> [ConversationPost.SleepGap] {
        let body = try GatewayJSON.parse(try await call("/api/plugins/nollie-workflow/sleep", [
            URLQueryItem(name: "since", value: String(Int(since.timeIntervalSince1970))),
            URLQueryItem(name: "profile", value: "default")]))
        return (body["gaps"]?.arrayValue ?? []).compactMap(ConversationPost.SleepGap.init(wire:))
    }
}
