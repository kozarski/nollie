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
    /// Each ending is a whole sentence with the clause about the Mac, the runs and the wake filled in.
    public static func line(gaps: [ConversationPost.SleepGap], waited: Int, skipped: Int,
                            clock: Clock = SleepNote.clock) -> String? {
        let gaps = gaps.sorted { $0.from < $1.from }
        guard !gaps.isEmpty else { return nil }
        let head = when(gaps, clock: clock)
        let back = wake(gaps)
        switch (waited > 0, skipped > 0) {
        case (false, false):
            return String(localized: "\(head).", table: "Core", comment: "A sentence about when the Mac was asleep or off, with its full stop")
        case (true, false):
            let runs = runs(waited)
            return String(localized: "\(head), so \(runs) waited \(back).", table: "Core",
                          comment: "Your Mac was asleep from 1:10 to 6:40, so two runs waited until it woke.")
        case (false, true):
            let runs = runs(skipped)
            return skipped == 1
                ? String(localized: "\(head), so \(runs) was skipped.", table: "Core", comment: "Your Mac was asleep from 1:10 to 6:40, so one run was skipped.")
                : String(localized: "\(head), so \(runs) were skipped.", table: "Core", comment: "Your Mac was asleep from 1:10 to 6:40, so three runs were skipped.")
        case (true, true):
            let runs = capitalised(runs(waited)), others = number(skipped)
            return skipped == 1
                ? String(localized: "\(head). \(runs) waited \(back) and \(others) was skipped.", table: "Core",
                         comment: "Your Mac was asleep from 1:10 to 6:40. Two runs waited until it woke and one was skipped.")
                : String(localized: "\(head). \(runs) waited \(back) and \(others) were skipped.", table: "Core",
                         comment: "Your Mac was asleep from 1:10 to 6:40. One run waited until it woke and three were skipped.")
        }
    }

    /// A schedule's last run, when it started late: "Your Mac was asleep at 7:00, so this ran at 7:41." Nil when it
    /// ran on time, or when the gap can't be told.
    public static func scheduleLine(due: Date, ran: Date, gaps: [ConversationPost.SleepGap],
                                    clock: Clock = SleepNote.clock) -> String? {
        guard ran.timeIntervalSince(due) > lateSeconds else { return nil }
        let kind = gaps.first(where: { $0.holds(due) })?.kind
        let due = clock(due), ran = clock(ran)
        switch kind {
        case .asleep?: return String(localized: "Your Mac was asleep at \(due), so this ran at \(ran).", table: "Core")
        case .off?: return String(localized: "Your Mac was off at \(due), so this ran at \(ran).", table: "Core")
        case .stopped?: return String(localized: "Your crew wasn't running at \(due), so this ran at \(ran).", table: "Core")
        case nil: return String(localized: "Due at \(due). It ran late, at \(ran).", table: "Core")
        }
    }

    /// Hermes counts a run as late past five minutes.
    public static let lateSeconds: TimeInterval = 300

    // MARK: Pieces

    /// Who was out and when: one or two stretches by their times, more by how long in all. A whole clause each, so
    /// the subject and its times can be said in any order.
    private static func when(_ gaps: [ConversationPost.SleepGap], clock: Clock) -> String {
        enum Subject { case crewStopped, crewCouldNot, asleep, off, asleepOrOff }
        let kinds = Set(gaps.map(\.kind))
        let subject: Subject
        if kinds == [.stopped] {
            subject = .crewStopped
        } else if kinds.contains(.stopped) {
            subject = .crewCouldNot
        } else if kinds == [.asleep] {
            subject = .asleep
        } else if kinds == [.off] {
            subject = .off
        } else {
            subject = .asleepOrOff
        }
        if gaps.count <= 2, kinds.count == 1 {
            let stretches = gaps.map { gap in
                let from = clock(gap.from), to = clock(gap.to)
                return String(localized: "from \(from) to \(to)", table: "Core", comment: "A stretch of time, as in: Your Mac was asleep from 1:10 to 6:40")
            }
            let times = stretches.count == 2
                ? String(localized: "\(stretches[0]) and \(stretches[1])", table: "Core", comment: "Two stretches of time: from 1:10 to 2:00 and from 3:15 to 6:40")
                : stretches.joined()
            switch subject {
            case .crewStopped: return String(localized: "Your crew wasn't running \(times)", table: "Core", comment: "Followed by more of the sentence")
            case .crewCouldNot: return String(localized: "Your crew couldn't run \(times)", table: "Core", comment: "Followed by more of the sentence")
            case .asleep: return String(localized: "Your Mac was asleep \(times)", table: "Core", comment: "Followed by more of the sentence")
            case .off: return String(localized: "Your Mac was off \(times)", table: "Core", comment: "Followed by more of the sentence")
            case .asleepOrOff: return String(localized: "Your Mac was asleep or off \(times)", table: "Core", comment: "Followed by more of the sentence")
            }
        }
        let seconds = gaps.reduce(0) { $0 + $1.to.timeIntervalSince($1.from) }
        let total = length(seconds)
        switch subject {
        case .crewStopped: return String(localized: "Your crew wasn't running for \(total) in all", table: "Core", comment: "Followed by more of the sentence")
        case .crewCouldNot: return String(localized: "Your crew couldn't run for \(total) in all", table: "Core", comment: "Followed by more of the sentence")
        case .asleep: return String(localized: "Your Mac was asleep for \(total) in all", table: "Core", comment: "Followed by more of the sentence")
        case .off: return String(localized: "Your Mac was off for \(total) in all", table: "Core", comment: "Followed by more of the sentence")
        case .asleepOrOff: return String(localized: "Your Mac was asleep or off for \(total) in all", table: "Core", comment: "Followed by more of the sentence")
        }
    }

    private static func wake(_ gaps: [ConversationPost.SleepGap]) -> String {
        switch Set(gaps.map(\.kind)) {
        case [.asleep]: String(localized: "until it woke", table: "Core", comment: "As in: two runs waited until it woke (the Mac)")
        case [.off]: String(localized: "until it was back on", table: "Core", comment: "As in: two runs waited until it was back on (the Mac)")
        case [.stopped]: String(localized: "until it started again", table: "Core", comment: "As in: two runs waited until it started again (the crew)")
        default: String(localized: "until it was back", table: "Core", comment: "As in: two runs waited until it was back (the Mac)")
        }
    }

    /// "about 5 hours", "about an hour", "40 minutes".
    static func length(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 55 {
            let shown = max(minutes, 1)
            return String(localized: "\(shown) minutes", table: "Core")
        }
        let hours = Int((seconds / 3600).rounded())
        return hours <= 1 ? String(localized: "about an hour", table: "Core") : String(localized: "about \(hours) hours", table: "Core")
    }

    /// "two runs", "one run", "14 runs".
    static func runs(_ count: Int) -> String {
        if count == 1 { return String(localized: "one run", table: "Core", comment: "A number of schedule runs, in a sentence") }
        guard count <= 12 else { return String(localized: "\(count) runs", table: "Core") }
        let word = number(count)
        return String(localized: "\(word) runs", table: "Core", comment: "A number of schedule runs spelled out: two runs")
    }

    /// One to twelve in words, as people say them; bigger numbers in figures.
    static func number(_ count: Int) -> String {
        guard (0...12).contains(count) else { return String(count) }
        let words = NumberFormatter()
        words.numberStyle = .spellOut
        return words.string(from: NSNumber(value: count)) ?? String(count)
    }

    private static func capitalised(_ text: String) -> String { text.prefix(1).uppercased(with: .current) + text.dropFirst() }
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
