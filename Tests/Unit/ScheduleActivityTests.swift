import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

/// Who is working, from the gateway: a schedule's run (Hermes 0.23's `live_execution` on the jobs
/// list) and a Board card, wherever they were started; and Stop on one run.
@Suite struct ScheduleActivityTests {
    init() { PrivateBots.useForTesting(PrivateBots(names: ["private", "moss"], settled: true)) }

    private let now = Date(timeIntervalSince1970: 1_800_050_000)

    private func job(_ id: String, name: String? = "Morning brief", profile: String = "default", live: JSONValue? = nil,
                     latest: JSONValue? = nil) -> JSONValue {
        var row: [String: JSONValue] = ["id": .string(id), "profile": .string(profile), "enabled": true, "state": "scheduled"]
        if let name { row["name"] = .string(name) }
        if let live { row["live_execution"] = live }
        if let latest { row["latest_execution"] = latest }
        return .object(row)
    }

    private func attempt(_ status: String, started: String? = "2027-01-15T03:00:05.123456-05:00",
                         claimed: String = "2027-01-15T03:00:00-05:00") -> JSONValue {
        var row: [String: JSONValue] = ["id": "e-1", "status": .string(status), "claimed_at": .string(claimed)]
        row["started_at"] = started.map(JSONValue.string) ?? nil
        return .object(row)
    }

    @Test func aRunInFlightIsReadWithItsNameBotAndStart() throws {
        let reply: JSONValue = ["jobs": [job("a", live: attempt("running")), job("b", name: nil, profile: "career", live: attempt("claimed", started: nil)),
                                         job("c", live: .null), job("d")]]
        let seen = ScheduleActivity.read(reply, now: now)
        #expect(seen.runs.map(\.jobID) == ["b", "a"])
        let brief = try #require(seen.run(job: "a", now: now))
        #expect(brief.name == "Morning brief")
        #expect(brief.profile == "default")
        #expect(brief.executionID == "e-1")
        // Microseconds and an offset, as Hermes writes them.
        #expect(abs(brief.startedAt.timeIntervalSince1970 - 1_800_000_005.123) < 0.01)
        // A claimed run with no start yet dates from its claim; a nameless job still has a name.
        let claimed = try #require(seen.run(job: "b", now: now))
        #expect(claimed.startedAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(claimed.name == "Schedule")
        #expect(seen.runs(for: "career", now: now).map(\.jobID) == ["b"])
    }

    @Test func aPrivateBotsRunNeverShows() {
        let reply: JSONValue = [job("x", profile: "moss", live: attempt("running")), job("y", profile: "private", live: attempt("running")),
                                job("z", profile: "career", live: attempt("running"))]
        #expect(ScheduleActivity.read(reply, now: now).runs.map(\.profile) == ["career"])
    }

    @Test func hermesSayingNothingRunsIsBelievedOverAnOlderAttempt() {
        // 0.23 lists `live_execution: null` beside a latest attempt a refused Run now left behind.
        #expect(ScheduleActivity.live(job("a", live: .null, latest: attempt("running"))) == nil)
        // An older gateway without `live_execution` is read from its latest attempt.
        #expect(ScheduleActivity.live(job("a", latest: attempt("running")))?.jobID == "a")
        #expect(ScheduleActivity.live(job("a", latest: attempt("completed"))) == nil)
        #expect(ScheduleActivity.live(job("a", live: attempt("completed"))) == nil)
        // The Run now button and the list agree.
        #expect(CronRun.isRunning(job("a", live: attempt("running"))))
        #expect(!CronRun.isRunning(job("a", live: .null, latest: attempt("running"))))
    }

    @Test func anOldLookSaysNothing() {
        let seen = ScheduleActivity.read([job("a", live: attempt("running"))], now: now)
        #expect(seen.current(now: now.addingTimeInterval(60)).count == 1)
        #expect(seen.current(now: now.addingTimeInterval(ScheduleActivity.freshFor + 1)).isEmpty)
        #expect(!seen.isFresh(now: now.addingTimeInterval(ScheduleActivity.freshFor + 1)))
        #expect(ScheduleActivity().current(now: now).isEmpty)
    }

    @Test func stopsAnswerIsReadHonestly() throws {
        let stopped = try #require(ScheduleCancel(["success": true, "cancelled": true, "execution_id": "e-9", "status": "running", "pid": 7,
                                                   "detail": "Cancel requested; the run stops at its next cancel check.", "job_id": "a"]))
        #expect(stopped.cancelled && stopped.executionID == "e-9")
        let idle = try #require(ScheduleCancel(["success": true, "cancelled": false, "execution_id": nil, "detail": "nothing", "job_id": "a"]))
        #expect(!idle.cancelled && idle.executionID == nil)
        #expect(ScheduleCancel(["ok": true]) == nil)
        #expect(ScheduleCancel(["success": false, "cancelled": false]) == nil)
        #expect(ScheduleStopWords.words(for: stopped) == "Stopped. The schedule stays on.")
        #expect(ScheduleStopWords.words(for: idle) == "It had already finished.")
        #expect(ScheduleStopWords.words(for: nil) == "Couldn't stop it. Try again.")
        for line in [ScheduleStopWords.stopped, ScheduleStopWords.alreadyDone, ScheduleStopWords.notStopped, ScheduleStopWords.hint,
                     ScheduleStopWords.stopLabel, ScheduleStopWords.stopNamed("Morning brief")] {
            #expect(!line.contains("\u{2014}"))
        }
    }

    @Test func theBoardSaysWhichCardEachBotIsOnSinceWhen() async throws {
        func worker(_ task: String, title: String?, owner: String, started: Int) throws -> KanbanWorker {
            var row: [String: Any] = ["run_id": started, "task_id": task, "task_status": "running", "worker_pid": 42,
                                      "task_assignee": owner, "started_at": started]
            row["task_title"] = title
            let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(KanbanWorker.self, from: JSONSerialization.data(withJSONObject: row))
        }
        let rows = [try worker("t2", title: "Later card", owner: "forager", started: 2_000),
                    try worker("t1", title: "Renew the car insurance", owner: "forager", started: 1_000),
                    try worker("t3", title: nil, owner: "career", started: 1_500),
                    try worker("t4", title: "Diary", owner: "moss", started: 900)]
        let seen = await KanbanActivity.read(boards: ["default"], profiles: ["forager", "career", "moss"], now: now) { _ in rows }
        #expect(seen.activeProfiles == ["forager", "career"])
        let card = try #require(seen.work(for: "forager", now: now))
        #expect(card.taskID == "t1" && card.title == "Renew the car insurance")
        #expect(card.since == Date(timeIntervalSince1970: 1_000))
        #expect(seen.work(for: "career", now: now)?.title == "A Board task")
        #expect(seen.work(for: "moss", now: now) == nil)
        #expect(seen.work(for: "forager", now: now.addingTimeInterval(120)) == nil)
    }

    @Test func howLongReadsInAFewWords() {
        let start = now
        #expect(HelperAtWorkWords.elapsed(since: start, now: start.addingTimeInterval(20)) == "Just started")
        #expect(HelperAtWorkWords.elapsed(since: start, now: start.addingTimeInterval(4 * 60 + 50)) == "4 min")
        #expect(HelperAtWorkWords.elapsed(since: start, now: start.addingTimeInterval(65 * 60)).contains("1 hr"))
        #if os(iOS)
        #expect(WatchWords.on("Morning brief", since: start, now: start.addingTimeInterval(240)) == "Morning brief · 4 min")
        #endif
    }

    @Test func aStoppedRunIsNoFailure() {
        let job = CronJob(id: "a", name: "Morning brief", enabled: true, state: "scheduled", lastStatus: "cancelled")
        #expect(ScheduledWork.status(job, raw: ["id": "a", "live_execution": nil]) == "Scheduled")
        #expect(ScheduledWork.result(job) == "Stopped")
    }

    @Test func theMissedRuleFollowsHermes() {
        #expect(CronJobDetailView.catchesUp(["schedule": ["kind": "cron"]]))
        #expect(!CronJobDetailView.catchesUp(["schedule": ["kind": "once"]]))
        #expect(!CronJobDetailView.catchesUp(["schedule": ["kind": "cron"], "grace_minutes": 30]))
        #expect(CronJobDetailView.catchesUp(["schedule": ["kind": "cron"], "grace_minutes": nil]))
        #expect(CronJobDetailView.catchesUp(["schedule": ["kind": "once"], "catch_up": true]))
        #expect(!CronJobDetailView.catchesUp(["schedule": ["kind": "cron"], "catch_up": false]))
    }

    #if os(iOS)
    @Test func aWatchFromBeforeWorkStillReadsAndANewOneCarriesIt() throws {
        var snapshot = WatchWire.Snapshot.empty(at: now, connected: true)
        snapshot.helpers = [WatchWire.Helper(profile: "default", name: "Nollie", avatar: "", place: nil, since: now, work: "Morning brief")]
        #expect(try WatchWire.snapshot(from: WatchWire.message(snapshot)) == snapshot)
        let old = Data(#"{"version":1,"made":1800050000,"approvals":[],"helpers":[{"profile":"career","name":"Scout","avatar":"","since":1800050000}],"canStop":false,"connected":true}"#.utf8)
        #expect(try #require(WatchWire.decodeSnapshot(old)).helpers.first?.work == nil)
    }
    #endif
}

#if os(iOS)
@MainActor
@Suite struct CrewAtWorkFromTheGatewayTests {
    init() { PrivateBots.useForTesting(PrivateBots(names: ["private", "moss"], settled: true)) }

    private func runtime() throws -> GatewayRuntime {
        let runtime = try ChatFixtures.runtime(named: "crew-gw-\(UUID().uuidString)")
        runtime.profiles = [ProfileInfo(name: "default", displayName: "Nollie"), ProfileInfo(name: "career", displayName: "Scout"),
                            ProfileInfo(name: "moss", displayName: "Moss")]
        return runtime
    }

    private func run(_ job: String, _ name: String, _ profile: String, minutesAgo: Double, now: Date) -> ScheduleActivity.Run {
        ScheduleActivity.Run(jobID: job, name: name, profile: profile, startedAt: now.addingTimeInterval(-minutesAgo * 60))
    }

    @Test func aScheduleTheMacStartedShowsAsItsHelperWithHowLong() throws {
        let runtime = try runtime()
        let now = Date()
        runtime.schedules.show(ScheduleActivity(runs: [run("brief", "Morning brief", "default", minutesAgo: 4, now: now),
                                                       run("diary", "Diary", "moss", minutesAgo: 9, now: now)], checkedAt: now))
        let members = CrewAtWork.members(in: runtime, now: now)
        // Moss's run stays off; Nollie is on its schedule.
        #expect(members.map(\.helper.name) == ["Nollie"])
        let nollie = try #require(members.first)
        #expect(nollie.step == "Working on “Morning brief”")
        #expect(nollie.work?.jobID == "brief")
        #expect(nollie.helper.work == "Morning brief")
        #expect(nollie.helper.since == now.addingTimeInterval(-240))
        #expect(nollie.line(now: now) == "Working on “Morning brief” · 4 min")
    }

    @Test func aChatOpenHereStillSpeaksForTheBot() throws {
        let runtime = try runtime()
        let now = TestRows.epoch.addingTimeInterval(60)
        runtime.schedules.show(ScheduleActivity(runs: [run("jobs", "Job alerts", "career", minutesAgo: 30, now: now)], checkedAt: now))
        let chat = ChatSession(runtime: runtime, storedID: "chat-1", title: "Roles", profile: "career")
        chat.items = [TestRows.user("u1", "Find roles", at: 10)]
        chat.isRunning = true
        chat.statusLine = "Running web_search"
        runtime.registry.add(chat)
        let scout = try #require(CrewAtWork.members(in: runtime, now: now).first)
        #expect(scout.step == "Searching the web…")
        #expect(scout.work == nil && scout.helper.work == nil)
        #expect(scout.line(now: now) == "Searching the web…")
    }

    @Test func whenTheRunEndsTheHelperIsNoLongerWorking() throws {
        let runtime = try runtime()
        let now = Date()
        runtime.schedules.show(ScheduleActivity(runs: [run("brief", "Morning brief", "default", minutesAgo: 1, now: now)], checkedAt: now))
        #expect(CrewAtWork.members(in: runtime, now: now).count == 1)
        runtime.schedules.show(ScheduleActivity(runs: [], checkedAt: now))
        #expect(CrewAtWork.members(in: runtime, now: now).isEmpty)
    }

    @Test func stoppingOneRunSaysSoInTheBar() {
        #expect(CrewAtWorkBar.short(ScheduleStopWords.stopped) == ScheduleStopWords.stopped)
        #expect(CrewAtWorkBar.short(ScheduleStopWords.notStopped) == ScheduleStopWords.notStopped)
    }
}
#endif

#if os(macOS)
/// The Mac's menu bar lists a schedule's run as a row of its own, with Stop, beside the chats' turns.
@MainActor
@Suite struct MenuBarGatewayWorkTests {
    init() { PrivateBots.useForTesting(PrivateBots(names: ["private", "moss"], settled: true)) }

    @Test func aRunningScheduleIsARowAndAPrivateBotsIsNot() throws {
        let runtime = try ChatFixtures.runtime(named: "menubar-gw-\(UUID().uuidString)")
        runtime.profiles = [ProfileInfo(name: "default", displayName: "Nollie"), ProfileInfo(name: "moss", displayName: "Moss")]
        let now = Date()
        runtime.schedules.show(ScheduleActivity(runs: [
            ScheduleActivity.Run(jobID: "brief", name: "Morning brief", profile: "default", startedAt: now.addingTimeInterval(-240)),
            ScheduleActivity.Run(jobID: "diary", name: "Diary", profile: "moss", startedAt: now)], checkedAt: now))
        let rows = TurnBoard.gatewayTurns(runtime, now: now)
        #expect(rows.map(\.title) == ["Morning brief"])
        let row = try #require(rows.first)
        #expect(row.bot == "Nollie" && row.jobID == "brief" && !row.attention)
        #expect(row.id.hasPrefix(TurnBoard.gatewayPrefix))
        #expect(row.startedAt == now.addingTimeInterval(-240))
        #expect(TurnBoard.gatewayTurns(runtime, now: now.addingTimeInterval(ScheduleActivity.freshFor + 1)).isEmpty)
        #expect(TurnBoard.gatewayTurns(nil).isEmpty)
    }
}
#endif
