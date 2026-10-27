import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

/// The weekly note: built only from what Nollie recorded (Papertrail, schedules and their runs, the Board, answers),
/// in fixed sentences. Private bots never appear, new things are told apart from earlier weeks, and every tap does
/// one real thing with its undo.
@MainActor
@Suite struct WeeklyNoteTests {
    /// Sunday 25 Oct 2026, 18:00 local, when the note goes out by default.
    static let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 18))!
    static let since = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 19))!.timeIntervalSince1970
    static let day = 86_400.0

    nonisolated private static let sample = #"""
    {
      "bot": "career", "days": 7, "now": 1793034000, "since": 1792450800, "recording_since": 1790460000,
      "papertrail": true, "replies": {"stayed": 40, "left": 11, "online": 10},
      "places": [
        {"kind": "model", "count": 31, "first_at": 1790500000, "provider": "claude-subscription-direct", "label": null, "host": null},
        {"kind": "search", "count": 6, "first_at": 1790500000, "service": "exa"},
        {"kind": "mcp", "count": 4, "first_at": 1792900000, "host": "mcp.notes.example.com"},
        {"kind": "terminal", "count": 3, "first_at": 1791000000, "host": "github.com"}
      ],
      "places_more": 0,
      "answers": {"once": 3, "session": 1, "always": 0, "deny": 1}, "asks": {"send": 3, "delete": 2},
      "earlier_answers": [1, 2, 1],
      "schedules": [
        {"id": "a1b2c3", "name": "Morning prices", "created_at": 1780000000, "paused": false, "finished": false,
         "runs": {"done": 5, "failed": 1, "unfinished": 0}},
        {"id": "d4e5f6", "name": "Bin day", "created_at": 1792700000, "paused": true, "finished": false,
         "runs": {"done": 0, "failed": 0, "unfinished": 0}}
      ],
      "runs_kept": true, "schedules_kept": true, "board": {"done": 3, "stopped": 0, "failed": 1},
      "apps": [{"name": "notes", "on": true, "host": "mcp.notes.example.com"}],
      "web": {"on": true, "service": "exa"}, "filter": "off"
    }
    """#

    private func record(_ bot: String = "career", recordingWeeksBefore: Double = 4, places: [WeekRecord.Place] = [],
                        answers: WeekRecord.Answers = .init(), earlier: [Int] = [], schedules: [WeekRecord.Schedule] = [],
                        board: WeekRecord.Board? = nil, replies: WeekRecord.Replies? = .init(stayed: 0, left: 0, online: 0),
                        apps: [WeekRecord.App] = [], web: WeekRecord.Web? = .init(on: true), filter: String? = nil) -> WeekRecord {
        WeekRecord(bot: bot, since: Self.since, recordingSince: Self.since - recordingWeeksBefore * 7 * Self.day, replies: replies,
                   places: places, answers: answers, earlierAnswers: earlier, schedules: schedules, board: board, apps: apps,
                   web: web, filter: filter)
    }

    private func note(_ inputs: [WeeklyHelperInput], isPrivate: @escaping (String) -> Bool = { _ in false }) -> WeeklyNote {
        WeeklyNote.build(inputs, isPrivate: isPrivate, now: Self.now)
    }

    // MARK: Reading the record

    @Test func theRoutesAnswerDecodesAndBuildsTheWholeNote() throws {
        let decoded = try JSONCoding.decoder.decode(WeekRecord.self, from: Data(Self.sample.utf8))
        #expect(decoded.places.count == 4)
        #expect(decoded.answers.total == 5)
        #expect(decoded.schedules[0].runs == .init(done: 5, failed: 1, unfinished: 0))
        let built = note([WeeklyHelperInput(profile: "career", name: "Scout", record: decoded)])
        let scout = try #require(built.helpers.first)
        #expect(scout.did.map(\.text) == ["Morning prices", "Bin day",
                                           "Finished 3 Board tasks", "Asked you 5 times, more than usual"])
        #expect(scout.did.map(\.detail) == ["Ran 6 times · 1 didn't finish", "Paused", "1 gave up", "Yes 4 · No 1"])
        #expect(scout.did.map(\.isNew) == [false, true, false, true])
        #expect(scout.leftLine == "Went online 10 times. 40 replies stayed on your Mac.")
        // The new place first, then the rest, most used first.
        #expect(scout.left.map(\.text) == ["mcp.notes.example.com", "Claude plan", "Exa", "github.com"])
        #expect(scout.left.map(\.detail) == ["Connected app · 4 times", "Model · 31 times", "6 searches", "Commands · 3 times"])
        #expect(built.news.map(\.text) == ["Scout has a new schedule", "Scout asked more than usual", "Scout used something new"])
        #expect(built.news.map(\.detail) == ["\u{201C}Bin day\u{201D} · Paused", "5 times · Yes 4 · No 1",
                                             "mcp.notes.example.com · Connected app · 4 times"])
        #expect(built.headline == "1 helper busy. 3 new things.")
        #expect(built.filter == "Papertrail's filter is off, so a program that skips Nollie's door could go unseen.")
    }

    @Test func everyNumberInTheNoteComesFromTheRecord() throws {
        let decoded = try JSONCoding.decoder.decode(WeekRecord.self, from: Data(Self.sample.utf8))
        let built = note([WeeklyHelperInput(profile: "career", name: "Scout", record: decoded)])
        let recorded: Set<Int> = [31, 6, 4, 3, 5, 1, 0, 40, 11, 10, 2]
        let words = (built.helpers.flatMap { $0.did + $0.left } + built.news).flatMap { [$0.text, $0.detail ?? ""] }
            + built.helpers.map(\.leftLine) + [built.headline]
        for number in words.joined(separator: " ").split(whereSeparator: { !$0.isNumber }).compactMap({ Int($0) }) {
            #expect(recorded.contains(number), "\(number) isn't in the record")
        }
    }

    @Test func theReadAsksTheMainScopeForOneBotAndAnOlderAddOnIsNoWeek() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WeekStub.self]
        let api = HermesAPI(gateway: try GatewayURL.normalize("https://week.invalid/hermes"),
                            signer: RequestSigner(authMode: .sessionToken, sessionToken: "week-test-token"),
                            urlSession: URLSession(configuration: configuration))
        WeekStub.handler = { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/hermes/api/plugins/nollie-workflow/week")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(query == [URLQueryItem(name: "bot", value: "career")], "one bot, and never another profile's scope")
            return (200, Data(Self.sample.utf8))
        }
        defer { WeekStub.handler = nil }
        #expect(try await WeekRecord.load(bot: "career", api: api)?.bot == "career")
        WeekStub.handler = { _ in (404, Data(#"{"detail":"Not Found"}"#.utf8)) }
        #expect(try await WeekRecord.load(bot: "career", api: api) == nil)
        WeekStub.handler = { _ in (403, Data(#"{"detail":"The weekly note leaves private bots out."}"#.utf8)) }
        await #expect(throws: HermesAPIError.self) { try await WeekRecord.load(bot: "moss", api: api) }
    }

    // MARK: Empty weeks, private bots, unread weeks

    @Test func anEmptyWeekIsQuietAndSaysWhoHadNothing() {
        let built = note([WeeklyHelperInput(profile: "default", name: "Nollie", record: record("default")),
                          WeeklyHelperInput(profile: "nowhere", name: "Mason", record: record("nowhere"))])
        #expect(built.isQuiet)
        #expect(built.headline == "A quiet week.")
        #expect(built.quiet == ["Nollie", "Mason"])
        #expect(built.news.isEmpty && built.helpers.isEmpty && built.unread.isEmpty)
        #expect(built.short.isEmpty)
    }

    @Test func aStandingSwitchAloneIsNotABusyWeek() {
        let built = note([WeeklyHelperInput(profile: "career", name: "Scout", record: record(), macOn: true)])
        #expect(built.isQuiet)
        #expect(built.quiet == ["Scout"])
    }

    @Test func privateBotsNeverAppearWhateverIsHandedIn() {
        let busy = record("moss", places: [.init(kind: "model", count: 9, firstAt: Self.since + Self.day, provider: "anthropic")],
                          answers: .init(once: 4))
        var secret = busy
        secret.bot = "diary"
        let built = note([WeeklyHelperInput(profile: "moss", name: "Moss", record: busy),
                          WeeklyHelperInput(profile: "private", name: "Private", record: nil),
                          WeeklyHelperInput(profile: "diary", name: "Diary", record: secret)],
                         isPrivate: { $0 == "diary" })
        #expect(built.helpers.isEmpty && built.quiet.isEmpty && built.unread.isEmpty && built.news.isEmpty)
        #expect(built.headline == "No helpers to tell about.", "nothing read is never called a quiet week")
    }

    @Test func aWeekThatCouldntBeReadIsSaidAndNeverGuessed() {
        var wrong = record("default", answers: .init(once: 2))
        wrong.bot = "default"
        let built = note([WeeklyHelperInput(profile: "career", name: "Scout", record: nil),
                          WeeklyHelperInput(profile: "nowhere", name: "Mason", record: wrong)])
        #expect(built.unread == ["Scout", "Mason"], "a record for another bot is not this one's")
        #expect(built.headline == "Couldn't read the week.")
    }

    // MARK: New this week

    @Test func aPlaceIsNewOnlyWhenEarlierWeeksWereRecordedWithoutIt() {
        let places: [WeekRecord.Place] = [.init(kind: "terminal", count: 2, firstAt: Self.since + Self.day, host: "github.com"),
                                          .init(kind: "terminal", count: 5, firstAt: Self.since - 9 * Self.day, host: "pypi.org")]
        let seen = note([WeeklyHelperInput(profile: "career", name: "Scout", record: record(places: places))])
        #expect(seen.helpers[0].left.map(\.isNew) == [true, false])
        #expect(seen.news.map(\.text) == ["Scout reached a new place"])
        #expect(seen.news.map(\.detail) == ["github.com · Commands · twice"])
        // Papertrail began this week: everything is first seen this week, so nothing is called new.
        let begun = note([WeeklyHelperInput(profile: "career", name: "Scout", record: record(recordingWeeksBefore: 0.5, places: places))])
        #expect(begun.news.isEmpty)
        #expect(begun.helpers[0].left.filter(\.isNew).isEmpty)
    }

    @Test func aNewSearchServiceIsSaidAsUsed() {
        let places: [WeekRecord.Place] = [.init(kind: "search", count: 3, firstAt: Self.since + 2 * Self.day, service: "tavily")]
        let built = note([WeeklyHelperInput(profile: "career", name: "Scout", record: record(places: places))])
        #expect(built.news.map(\.text) == ["Scout used something new"])
        #expect(built.news.map(\.detail) == ["Tavily · 3 searches"])
    }

    @Test func aScheduleMadeThisWeekIsNewWithPauseAndRemove() throws {
        let made = WeekRecord.Schedule(id: "abc123", name: "Bin day", createdAt: Self.since + 3 * Self.day,
                                       runs: .init(done: 2))
        let old = WeekRecord.Schedule(id: "def456", name: nil, createdAt: Self.since - 30 * Self.day, runs: .init(done: 1))
        let idle = WeekRecord.Schedule(id: "ghi789", name: "Quiet one", createdAt: Self.since - 30 * Self.day, runs: .init())
        let built = note([WeeklyHelperInput(profile: "career", name: "Scout", record: record(schedules: [made, old, idle]))])
        let lines = built.helpers[0].did
        #expect(lines.map(\.text) == ["Bin day", "A schedule"])
        #expect(lines.map(\.detail) == ["Ran twice", "Ran once"])
        #expect(lines[0].actions == [.pause(bot: "career", job: "abc123"), .remove(bot: "career", job: "abc123")])
        #expect(lines[1].actions == [.pause(bot: "career", job: "def456")])
        #expect(built.news.map(\.text) == ["Scout has a new schedule"])
        #expect(built.news.map(\.detail) == ["\u{201C}Bin day\u{201D} · Ran twice"])
        #expect(built.news[0].actions == lines[0].actions, "the news line has the same taps")
    }

    @Test func aScheduleWithAnOddIDGetsNoLineAtAll() {
        let odd = WeekRecord.Schedule(id: "../../x", name: "Odd", runs: .init(done: 3))
        let built = note([WeeklyHelperInput(profile: "career", name: "Scout", record: record(schedules: [odd]))])
        #expect(built.isQuiet)
    }

    @Test func runsThatCouldntBeReadAreNotCounted() {
        let unknown = WeekRecord.Schedule(id: "abc123", name: "Prices", createdAt: Self.since - 30 * Self.day, runs: nil)
        let built = note([WeeklyHelperInput(profile: "career", name: "Scout", record: record(schedules: [unknown]))])
        #expect(built.isQuiet, "no runs are claimed when the ledger couldn't be read")
    }

    @Test func moreQuestionsThanUsualNeedsEarlierWeeksAndAClearRise() {
        #expect(WeeklyWords.moreThanUsual(5, earlier: [1, 2, 1], hasEarlierWeek: true))
        #expect(!WeeklyWords.moreThanUsual(4, earlier: [1, 2, 1], hasEarlierWeek: true))
        #expect(!WeeklyWords.moreThanUsual(9, earlier: [6, 5, 7], hasEarlierWeek: true))
        #expect(WeeklyWords.moreThanUsual(3, earlier: [0, 0], hasEarlierWeek: true))
        #expect(!WeeklyWords.moreThanUsual(2, earlier: [0, 0], hasEarlierWeek: true), "two questions is never a lot")
        #expect(!WeeklyWords.moreThanUsual(12, earlier: [], hasEarlierWeek: true))
        #expect(!WeeklyWords.moreThanUsual(12, earlier: [1], hasEarlierWeek: false))
    }

    // MARK: Taps

    @Test func everyTapHasOneRealEffectAndItsUndo() {
        let cases: [(WeeklyAction, WeeklyAction.Effect, String, String)] = [
            (.pause(bot: "career", job: "abc"), .gateway(.init(method: "POST", path: "/api/cron/jobs/abc/pause", profile: "career", body: .object([:]))), "Pause", "Paused"),
            (.resume(bot: "career", job: "abc"), .gateway(.init(method: "POST", path: "/api/cron/jobs/abc/resume", profile: "career", body: .object([:]))), "Resume", "Resumed"),
            (.remove(bot: "career", job: "abc"), .gateway(.init(method: "DELETE", path: "/api/cron/jobs/abc", profile: "career", body: nil)), "Remove", "Removed"),
            (.appOff(bot: "career", app: "notes"), .gateway(.init(method: "PUT", path: "/api/plugins/nollie-workflow/week/switch", profile: nil,
                                                                  body: ["bot": "career", "kind": "app", "name": "notes", "on": false])), "Turn off", "Off"),
            (.appOn(bot: "career", app: "notes"), .gateway(.init(method: "PUT", path: "/api/plugins/nollie-workflow/week/switch", profile: nil,
                                                                 body: ["bot": "career", "kind": "app", "name": "notes", "on": true])), "Turn on", "On"),
            (.webOff(bot: "career"), .gateway(.init(method: "PUT", path: "/api/plugins/nollie-workflow/week/switch", profile: nil,
                                                    body: ["bot": "career", "kind": "web", "on": false])), "Turn off web", "Off"),
            (.webOn(bot: "career"), .gateway(.init(method: "PUT", path: "/api/plugins/nollie-workflow/week/switch", profile: nil,
                                                   body: ["bot": "career", "kind": "web", "on": true])), "Turn on web", "On"),
            (.macOff(bot: "career"), .mac(bot: "career", on: false), "Turn off", "Off"),
            (.macOn(bot: "career"), .mac(bot: "career", on: true), "Turn on", "On"),
            (.mute(bot: "career"), .mute(bot: "career", muted: true), "Mute", "Muted here"),
            (.unmute(bot: "career"), .mute(bot: "career", muted: false), "Unmute", "Unmuted"),
        ]
        for (action, effect, label, done) in cases {
            #expect(action.effect == effect, "\(action)")
            #expect((action.label, action.done) == (label, done))
            #expect(action.bot == "career")
            if case .remove = action {
                #expect(action.undo == nil)
                #expect(action.asksFirst, "anything that deletes asks first")
            } else {
                #expect(action.undo?.undo == action, "undoing the undo is the tap itself")
                #expect(action.undo?.effect != action.effect)
                #expect(!action.asksFirst)
            }
        }
    }

    @Test func taps_areOfferedOnlyWhereTheyAreReal() {
        let places: [WeekRecord.Place] = [
            .init(kind: "mcp", count: 2, firstAt: Self.since - 20 * Self.day, host: "mcp.notes.example.com"),
            .init(kind: "mcp", count: 1, firstAt: Self.since - 20 * Self.day, host: "api.unknown.example"),
            .init(kind: "search", count: 2, firstAt: Self.since - 20 * Self.day, service: "exa"),
            .init(kind: "pages", count: 4, firstAt: Self.since - 20 * Self.day),
            .init(kind: "terminal", count: 1, firstAt: Self.since - 20 * Self.day, host: "github.com"),
        ]
        let apps = [WeekRecord.App(name: "notes", host: "mcp.notes.example.com"), WeekRecord.App(name: "files", on: true, host: nil)]
        let on = note([WeeklyHelperInput(profile: "career", name: "Scout", record: record(places: places, apps: apps), macOn: true)])
        let left = on.helpers[0].left
        #expect(left[0].actions == [.appOff(bot: "career", app: "notes")], "an app matched by its own host")
        #expect(left[1].actions.isEmpty, "no app is guessed for a host it doesn't have")
        #expect(left[2].actions == [.webOff(bot: "career")])
        #expect(left[3].actions.isEmpty, "the web tools are offered once")
        #expect(left[4].actions.isEmpty)
        #expect(on.helpers[0].did.last?.actions == [.macOff(bot: "career")])
        // Off already: nothing to turn off. This Mac unread on this device: no line.
        let off = note([WeeklyHelperInput(profile: "career", name: "Scout",
                                          record: record(places: places, apps: [.init(name: "notes", on: false, host: "mcp.notes.example.com")],
                                                         web: .init(on: false)), macOn: nil)])
        #expect(off.helpers[0].left.flatMap(\.actions).isEmpty)
        #expect(!off.helpers[0].did.contains { $0.kind == .mac })
    }

    @Test func muteFollowsWhatThisDeviceKeeps() {
        let busy = record(answers: .init(once: 1))
        #expect(note([WeeklyHelperInput(profile: "career", name: "Scout", record: busy)]).helpers[0].mute == .mute(bot: "career"))
        #expect(note([WeeklyHelperInput(profile: "career", name: "Scout", record: busy, muted: true)]).helpers[0].mute == .unmute(bot: "career"))
    }

    @Test func muteIsKeptPerGatewayAndNeverOfferedForTheMainBot() {
        let defaults = UserDefaults(suiteName: "weekly-mute-\(UUID().uuidString)")!
        let home = UUID(), other = UUID()
        HelperMute.set(true, profile: "Career", connection: home, defaults: defaults)
        #expect(HelperMute.isMuted("career", connection: home, defaults: defaults))
        #expect(!HelperMute.isMuted("career", connection: other, defaults: defaults))
        HelperMute.set(false, profile: "career", connection: home, defaults: defaults)
        #expect(!HelperMute.isMuted("career", connection: home, defaults: defaults))
        #expect(!HelperMute.offered(for: "default"))
        #expect(HelperMute.offered(for: "career"))
    }

    // MARK: Words around it

    @Test func whatLeftIsSaidPlainly() {
        func line(_ replies: WeekRecord.Replies?, papertrail: Bool? = true) -> String {
            var made = record(replies: replies)
            made.papertrail = papertrail
            return WeeklyWords.leftLine(made, name: "Scout")
        }
        #expect(line(.init(stayed: 1, left: 1, online: 1)) == "Went online once. 1 reply stayed on your Mac.")
        #expect(line(.init(stayed: 0, left: 2, online: 0)) == "Stayed on your network.")
        #expect(line(.init(stayed: 3, left: 0, online: 0)) == "Nothing seen leaving. 3 replies stayed on your Mac.")
        #expect(line(nil, papertrail: false) == "Papertrail isn't on for Scout yet.")
    }

    @Test func theFilterIsSaidOnlyWhenItLeavesSomethingUnseen() {
        #expect(WeeklyWords.filter("on") == nil)
        #expect(WeeklyWords.filter(nil) == nil)
        #expect(WeeklyWords.filter("off")?.contains("could go unseen") == true)
        #expect(WeeklyWords.filter("none")?.hasPrefix("This setup has no door") == true)
    }

    @Test func theWatchGetsTheSameCountsInFewerWords() throws {
        let decoded = try JSONCoding.decoder.decode(WeekRecord.self, from: Data(Self.sample.utf8))
        let built = note([WeeklyHelperInput(profile: "career", name: "Scout", record: decoded)])
        #expect(built.short.map(\.detail) == ["6 runs · 3 tasks · asked 5 times · online 10 times · 3 new"])
        #if os(iOS)
        let wrist = try #require(WatchNight.week(built, shown: true))
        #expect(wrist.headline == built.headline)
        #expect(wrist.helpers.map(\.title) == ["Scout"])
        #expect(wrist.hasNews)
        #expect(WatchNight.week(built, shown: false) == nil, "off, or a member's phone: nothing on the wrist")
        #endif
    }

    @Test func theNoteGoesOutOnTheChosenEveningAndItsCardWaitsUntilPutAway() {
        let calendar = Calendar.current
        let sunday = WeeklyNoteTiming.standard
        #expect(sunday.latest(before: Self.now.addingTimeInterval(60)) == Self.now)
        let wednesday = Self.now.addingTimeInterval(3 * Self.day)
        #expect(sunday.latest(before: wednesday) == Self.now)
        #expect(calendar.component(.weekday, from: WeeklyNoteTiming(weekday: 6).latest(before: wednesday)) == 6)
        #expect(sunday.cardShows(now: wednesday, putAwayAt: nil))
        #expect(!sunday.cardShows(now: wednesday, putAwayAt: Self.now.addingTimeInterval(3600)))
        #expect(sunday.cardShows(now: wednesday.addingTimeInterval(5 * Self.day), putAwayAt: Self.now.addingTimeInterval(3600)),
                "next week's note brings it back")
        #expect(WeeklyNoteTiming(weekday: 9).weekday == 1)
    }

    @Test func daysAndRangesReadNaturally() {
        let from = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 28))!
        let to = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 3))!
        #expect(WeeklyNoteDates.range(from, to).contains("to"))
        #expect(WeeklyNoteDates.list(["Scout", "Mason", "Forager"]) == "Scout, Mason and Forager")
        #expect(WeeklyNoteDays.options().count == 7)
        #expect(Set(WeeklyNoteDays.options().map(\.0)) == Set(1...7))
    }
}

private final class WeekStub: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data)?)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let (status, data) = Self.handler?(request) else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
