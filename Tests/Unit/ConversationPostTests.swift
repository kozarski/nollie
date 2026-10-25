import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

// The workflow add-on's cards in the main chat: reading posts, where compose() puts them, Turn on and Keep off,
// and the personal parts a share picture hides. See Docs/specs/night-shift.md.

/// The add-on's answer to `GET .../posts`, as the spec writes it, with a kind and fields this build doesn't know.
private let cpWire = #"""
{"version": 1, "posts": [
  {"id": "night-2026-10-21", "kind": "night_shift", "at": 1792562400, "sparkle": true,
   "window": {"from": 1792519200, "to": 1792562400},
   "counts": {"runs": 2, "actions": 5, "held": 1, "stopped": 1, "unrecorded": 0, "later": 9},
   "unwatched": ["Forager"],
   "runs": [
     {"id": "cron:244c3b0b8e42:e-80", "kind": "schedule", "bot": "default", "bot_name": "Nollie",
      "title": "Morning brief", "outcome": "done", "started_at": 1792540800, "finished_at": 1792540868,
      "actions": [
        {"tool": "terminal", "target": "df -h", "status": "done", "at": 1792540810, "receipt": {"kind": "safe"}},
        {"tool": "terminal", "target": "git push origin main", "status": "done", "at": 1792540820,
         "receipt": {"kind": "always", "detail": "git push", "granted_at": 1791900000}},
        {"tool": "computer_use", "target": "click", "status": "blocked", "at": 1792540830,
         "receipt": {"kind": "blocked", "detail": "mac"}},
        {"tool": "web_search", "target": "weather", "status": "done", "at": 1792540840,
         "receipt": {"kind": "a_kind_from_later"}}],
      "more": 3}],
   "more_runs": 48},
  {"id": "weather-1", "kind": "weather", "at": 1792562500, "sky": "clear"},
  {"id": "rehearsal-career-3f2a9c-e-81", "kind": "rehearsal", "at": 1792561000,
   "bot": "career", "bot_name": "Scout", "job_id": "3f2a9c", "title": "Morning prices",
   "schedule": "0 7 * * 1-5", "state": "ready", "check": null, "outcome": "done",
   "held": [{"tool": "send_message", "target": "Price drop on the SSD", "at": 1792560990}],
   "looked": [{"tool": "web_search", "target": "2TB NVMe price", "at": 1792560950}],
   "reply": "The 2TB drive is down to 119. I would have sent you a note about it."},
  {"id": "rehearsal-default-77aa-check", "kind": "rehearsal", "at": 1792561100,
   "bot": "default", "bot_name": "Nollie", "job_id": "77aa", "title": "Tidy downloads",
   "schedule": "0 9 * * *", "state": "kept_off", "outcome": null,
   "check": {"reason": "script", "prompt": "Tidy the downloads folder", "script": "tidy.sh", "hash": "3f2a9c01be44"},
   "held": [], "looked": [], "reply": ""}
]}
"""#

/// Records each request and answers from a handler.
private actor CPCalls {
    private(set) var made: [(method: String, path: String, query: [URLQueryItem])] = []
    func add(_ method: String, _ path: String, _ query: [URLQueryItem]) { made.append((method, path, query)) }
}

@Suite struct ConversationPostDecodingTests {
    @Test func bothKindsAreReadAndUnknownOnesSkipped() async throws {
        let calls = CPCalls()
        let source = HermesConversationPosts { method, path, query in
            await calls.add(method, path, query)
            return (Data(cpWire.utf8), 200)
        }
        let posts = try await source.posts(since: Date(timeIntervalSince1970: 1_792_000_000))
        #expect(posts.map(\.id) == ["night-2026-10-21", "rehearsal-career-3f2a9c-e-81", "rehearsal-default-77aa-check"])

        let request = try #require(await calls.made.first)
        #expect(request.method == "GET")
        #expect(request.path == "/api/plugins/nollie-workflow/posts")
        let query = Dictionary(uniqueKeysWithValues: request.query.map { ($0.name, $0.value ?? "") })
        #expect(query == ["since": "1792000000", "limit": "60", "profile": "default"])

        let night = try #require(posts[0].nightShift)
        #expect(posts[0].at == Date(timeIntervalSince1970: 1_792_562_400))
        #expect(night.from == Date(timeIntervalSince1970: 1_792_519_200))
        #expect(night.counts == ConversationPost.Counts(runs: 2, actions: 5, held: 1, stopped: 1, unrecorded: 0))
        #expect(night.unwatched == ["Forager"])
        #expect(night.moreRuns == 48)
        let run = try #require(night.runs.first)
        #expect(run.botName == "Nollie")
        #expect(run.outcome == .done)
        #expect(run.more == 3)
        #expect(run.finishedAt == Date(timeIntervalSince1970: 1_792_540_868))
        #expect(run.actions.map(\.target) == ["df -h", "git push origin main", "click", "weather"])
        #expect(run.actions[1].receipt == ConversationPost.Receipt(kind: .always, detail: "git push",
                                                                     grantedAt: Date(timeIntervalSince1970: 1_791_900_000)))
        #expect(run.actions[2].status == .blocked)
        #expect(run.actions[2].receipt?.detail == "mac")
        // A receipt kind from a later add-on never reads as a reason it doesn't give.
        #expect(run.actions[3].receipt?.kind == .unknown)

        let rehearsal = try #require(posts[1].rehearsal)
        #expect(rehearsal.botName == "Scout")
        #expect(rehearsal.jobId == "3f2a9c")
        #expect(rehearsal.state == .ready)
        #expect(rehearsal.check == nil)
        #expect(rehearsal.held == [ConversationPost.Action(tool: "send_message", target: "Price drop on the SSD",
                                                           at: Date(timeIntervalSince1970: 1_792_560_990))])
        #expect(rehearsal.looked.map(\.tool) == ["web_search"])
        #expect(rehearsal.reply.hasPrefix("The 2TB drive"))
        #expect(posts[1].pending == nil && posts[1].problem == nil)
    }

    @Test func aCheckCardSaysWhyAndWhatItRuns() async throws {
        let source = HermesConversationPosts { _, _, _ in (Data(cpWire.utf8), 200) }
        let check = try #require(try await source.posts(since: .distantPast).last?.rehearsal)
        #expect(check.state == .keptOff)
        #expect(check.outcome == nil)
        #expect(check.check == ConversationPost.Check(reason: .script, prompt: "Tidy the downloads folder", script: "tidy.sh",
                                                     hash: "3f2a9c01be44"))
        #expect(check.held.isEmpty && check.looked.isEmpty && check.reply.isEmpty)
    }

    @Test func aPostWithoutAnIdOrTimeIsSkipped() {
        #expect(ConversationPost(wire: ["kind": "night_shift", "at": 1]) == nil)
        #expect(ConversationPost(wire: ["id": "n1", "kind": "night_shift"]) == nil)
        #expect(ConversationPost(wire: ["id": "n1", "kind": "night_shift", "at": 1])?.nightShift == ConversationPost.NightShift())
    }

    @Test func turnOnPostsToTheRehearsalAndReadsTheAnswer() async throws {
        let calls = CPCalls()
        let source = HermesConversationPosts { method, path, query in
            await calls.add(method, path, query)
            return (Data(#"{"post": {"id": "rehearsal-career-3f2a9c-e-81", "kind": "rehearsal", "at": 1792561000, "state": "on", "title": "Morning prices"}}"#.utf8), 200)
        }
        let answer = try await source.perform(.turnOn, on: "rehearsal-career-3f2a9c-e-81")
        #expect(answer.rehearsal?.state == .on)
        let request = try #require(await calls.made.first)
        #expect(request.method == "POST")
        #expect(request.path == "/api/plugins/nollie-workflow/rehearsals/rehearsal-career-3f2a9c-e-81/turn-on")
        #expect(request.query.contains(URLQueryItem(name: "profile", value: "default")))

        // An id that could reach another route never leaves the device.
        await #expect(throws: (any Error).self) { try await source.perform(.keepOff, on: "../../private-bots") }
        await #expect(throws: (any Error).self) { try await source.perform(.keepOff, on: "") }
        #expect(await calls.made.count == 1)
    }

    @Test func aChangedScheduleAnswers409WithThePostAsItIsNow() async throws {
        // The add-on sends the post itself as the 409's body; an older shape put it under `post`.
        let changed = #"{"id": "rehearsal-career-3f2a9c-e-81", "kind": "rehearsal", "at": 1792561000, "state": "changed", "title": "Morning prices"}"#
        for body in [changed, #"{"detail": "changed", "post": \#(changed)}"#] {
            let source = HermesConversationPosts { _, _, _ in (Data(body.utf8), 409) }
            let answer = try await source.perform(.turnOn, on: "rehearsal-career-3f2a9c-e-81")
            #expect(answer.rehearsal?.state == .changed, "\(body)")
        }
    }

    @Test func otherRefusalsThrow() async {
        let id = "rehearsal-career-3f2a9c-e-81"
        let answers: [(String, Int)] = [
            (#"{"detail": "changed"}"#, 409),
            (#"{"id": "rehearsal-other-1", "kind": "rehearsal", "at": 1, "state": "changed"}"#, 409),
            (#"{"id": "rehearsal-career-3f2a9c-e-81", "kind": "rehearsal", "at": 1, "state": "on"}"#, 500),
            (#"{"detail": "not found"}"#, 404),
        ]
        for (body, status) in answers {
            let source = HermesConversationPosts { _, _, _ in (Data(body.utf8), status) }
            await #expect(throws: (any Error).self, "\(status) \(body)") { try await source.perform(.turnOn, on: id) }
        }
        let refused = HermesConversationPosts { _, _, _ in (Data(#"{"detail": "default profile only", "posts": []}"#.utf8), 403) }
        await #expect(throws: (any Error).self) { try await refused.posts(since: .distantPast) }
    }
}

// MARK: The engine

/// A pretend add-on: serves posts, answers taps with a handler, and counts what it was asked.
private actor CPFakePosts: ConversationPostSource {
    typealias Answer = @Sendable (ConversationPostAction, String) async throws -> ConversationPost

    var stored: [ConversationPost]
    private var refuse = false
    private var answer: Answer?
    private(set) var fetches = 0
    private(set) var performed: [String] = []

    init(_ posts: [ConversationPost] = []) { stored = posts }

    func set(_ posts: [ConversationPost]) { stored = posts }
    func refuseFetches() { refuse = true }
    func onPerform(_ handler: @escaping Answer) { answer = handler }

    func posts(since: Date) async throws -> [ConversationPost] {
        fetches += 1
        if refuse { throw URLError(.notConnectedToInternet) }
        return stored
    }

    func perform(_ action: ConversationPostAction, on postId: String) async throws -> ConversationPost {
        performed.append("\(action.rawValue) \(postId)")
        guard let answer else { throw URLError(.timedOut) }
        return try await answer(action, postId)
    }
}

private func cpNight(_ id: String, at seconds: Double) -> ConversationPost {
    ConversationPost(id: id, at: Date(timeIntervalSince1970: seconds), kind: .nightShift(ConversationPost.NightShift()))
}

private func cpRehearsal(_ id: String, at seconds: Double, state: ConversationPost.Rehearsal.State = .ready) -> ConversationPost {
    ConversationPost(id: id, at: Date(timeIntervalSince1970: seconds), kind: .rehearsal(ConversationPost.Rehearsal(
        bot: "career", botName: "Scout", jobId: "3f2a9c", title: "Morning prices", state: state)))
}

/// Stored rows 1, 2, ... of segment s0 at these times, alternating the person and the bot.
private func cpRows(_ stamps: [Double?]) -> [ConversationHistoryRow] {
    stamps.enumerated().map { index, stamp in
        let id = index + 1
        return ConversationHistoryRow(address: ConversationRowAddress(segment: "s0", rowId: id),
                                      role: id.isMultiple(of: 2) ? "assistant" : "user", text: "message \(id)", timestamp: stamp)
    }
}

/// Stored rows by row id, posts by `post:<id>`, live rows by their own id.
@MainActor
private func cpShown(_ engine: ConversationEngine) -> [String] {
    engine.transcript.map { row in row.address.map { "\($0.rowId)" } ?? row.id }
}

@MainActor
private func cpEngine(_ rows: [ConversationHistoryRow], posts: CPFakePosts, link: CEFakeLink = CEFakeLink(),
                      pageSize: Int = 100) async -> ConversationEngine {
    await link.on("session.resume") { _ in ceResume() }
    let history = CWFakeHistory(segments: ["s0": rows])
    let window = ConversationWindow.Configuration(pageSize: pageSize, capacity: pageSize * 2, prefetchMargin: 2)
    let engine = ConversationEngine(key: "posts", sessionId: "s0", link: link, history: history, lineageSource: history,
                                    store: MemoryConversationCacheStore(), posts: posts,
                                    configuration: ConversationEngine.Configuration(window: window))
    await engine.start()
    await engine.settle()
    return engine
}

@MainActor
@Suite struct ConversationPostPlacementTests {
    @Test func aPostGoesAfterTheLastRowAtOrBeforeIt() async {
        let posts = CPFakePosts([cpNight("between", at: 250), cpNight("same", at: 300), cpRehearsal("late", at: 450)])
        let engine = await cpEngine(cpRows([100, 200, 300, 400, 500]), posts: posts)
        #expect(await posts.fetches == 1, "fetched on attach")
        #expect(cpShown(engine) == ["1", "2", "post:between", "3", "post:same", "4", "post:late", "5"])
        let row = engine.transcript.first { $0.id == "post:late" }
        #expect(row?.post?.rehearsal?.title == "Morning prices")
        #expect(row?.address == nil)
    }

    @Test func aRowWithoutATimeTakesTheOneBeforeIt() async {
        let posts = CPFakePosts([cpNight("early", at: 150), cpNight("later", at: 350)])
        let engine = await cpEngine(cpRows([100, nil, nil, 400, nil]), posts: posts)
        #expect(cpShown(engine) == ["1", "2", "3", "post:early", "post:later", "4", "5"])
    }

    @Test func aPostOlderThanEveryRowShowsAtTheTopOfTheWholeChat() async {
        let posts = CPFakePosts([cpNight("first", at: 50)])
        // Rows before the first with a time have none to give: the post is older than all of them.
        let engine = await cpEngine(cpRows([nil, 100, 200]), posts: posts)
        // Until the window knows nothing is older, the post may belong to rows above it.
        #expect(!engine.historyAtOldestEnd)
        #expect(cpShown(engine) == ["1", "2", "3"])
        engine.loadOlder()
        await engine.settle()
        #expect(engine.historyAtOldestEnd)
        #expect(cpShown(engine) == ["post:first", "1", "2", "3"])
    }

    @Test func aPostOlderThanTheWindowWaitsForItsRows() async {
        let stamps = (1...50).map { Double($0 * 10) }
        let posts = CPFakePosts([cpNight("oldest", at: 5), cpNight("early", at: 45), cpNight("newest", at: 1000)])
        let engine = await cpEngine(cpRows(stamps), posts: posts, pageSize: 10)
        #expect(!engine.historyAtOldestEnd)
        #expect(cpShown(engine) == (41...50).map(String.init) + ["post:newest"])

        // Up to the first row: the window lets go of the newest rows on the way.
        for _ in 0..<10 where !engine.historyAtOldestEnd {
            engine.loadOlder()
            await engine.settle()
        }
        #expect(engine.historyAtOldestEnd)
        #expect(!engine.historyAtNewestEnd)
        let shown = cpShown(engine)
        #expect(shown.prefix(6) == ["post:oldest", "1", "2", "3", "4", "post:early"])
        #expect(!shown.contains("post:newest"), "a post newer than the window stays outside it")
    }

    @Test func aPostBetweenRowsOutsideTheWindowIsNotShown() async {
        let stamps = (1...50).map { Double($0 * 10) }
        let posts = CPFakePosts([cpNight("outside", at: 455), cpNight("inside", at: 255)])
        let engine = await cpEngine(cpRows(stamps), posts: posts, pageSize: 10)
        #expect(cpShown(engine).contains("post:outside"))
        // Two pages up the window holds rows 21 to 40 and no longer touches the newest end.
        for _ in 0..<2 {
            engine.loadOlder()
            await engine.settle()
        }
        #expect(!engine.historyAtNewestEnd)
        let shown = cpShown(engine)
        #expect(shown.first == "21" && shown.last == "40")
        #expect(!shown.contains("post:outside"))
        #expect(shown.firstIndex(of: "post:inside") == shown.firstIndex(of: "25").map { $0 + 1 })
    }

    @Test func aPostNewerThanEveryRowGoesBeforeTheLiveTail() async throws {
        let link = CEFakeLink()
        await link.on("prompt.submit") { _ in ["status": "streaming"] }
        let posts = CPFakePosts([cpNight("morning", at: 900)])
        let engine = await cpEngine(cpRows([100, 200]), posts: posts, link: link)
        engine.send("Good morning")
        await engine.settle()
        let shown = cpShown(engine)
        let live = try #require(engine.transcript.firstIndex { $0.userText == "Good morning" })
        #expect(shown.prefix(3) == ["1", "2", "post:morning"])
        #expect(shown.firstIndex(of: "post:morning")! < live)
    }

    @Test func theNewestSixtyAreKeptInOrder() async {
        let many = (1...70).reversed().map { cpNight("n\($0)", at: Double(1_000 + $0)) }
        let posts = CPFakePosts(many)
        let engine = await cpEngine(cpRows([100]), posts: posts)
        #expect(engine.posts.count == ConversationEngine.postLimit)
        #expect(engine.posts.first?.id == "n11")
        #expect(engine.posts.last?.id == "n70")
        #expect(engine.posts.map(\.at) == engine.posts.map(\.at).sorted())
    }

    @Test func aFailedFetchKeepsThePostsAndIsNoProblem() async {
        let posts = CPFakePosts([cpNight("night", at: 150)])
        let engine = await cpEngine(cpRows([100, 200]), posts: posts)
        #expect(cpShown(engine) == ["1", "post:night", "2"])
        await posts.refuseFetches()
        engine.refreshHistory()
        await engine.settle()
        #expect(await posts.fetches == 2)
        #expect(cpShown(engine) == ["1", "post:night", "2"])
        #expect(engine.problem == nil)
    }

    @Test func anEngineWithoutASourceShowsNoPosts() async {
        let link = CEFakeLink()
        await link.on("session.resume") { _ in ceResume() }
        let history = CWFakeHistory(segments: ["s0": cpRows([100, 200])])
        let engine = ConversationEngine(key: "plain", sessionId: "s0", link: link, history: history, lineageSource: history,
                                        store: MemoryConversationCacheStore())
        await engine.start()
        await engine.settle()
        #expect(cpShown(engine) == ["1", "2"])
        engine.perform(.turnOn, on: "anything")
        #expect(engine.posts.isEmpty)
    }
}

@MainActor
@Suite struct ConversationPostActionTests {
    @Test func turnOnShowsPendingThenTheAnswer() async throws {
        let posts = CPFakePosts([cpRehearsal("r1", at: 150)])
        let gate = CEGate()
        await posts.onPerform { _, id in
            await gate.pass()
            return cpRehearsal(id, at: 150, state: .on)
        }
        let engine = await cpEngine(cpRows([100, 200]), posts: posts)
        engine.perform(.turnOn, on: "r1")
        #expect(engine.posts.first?.pending == .turnOn)
        #expect(engine.transcript.first { $0.id == "post:r1" }?.post?.pending == .turnOn)
        while await gate.arrivals == 0 { try await Task.sleep(for: .milliseconds(5)) }
        // A second tap while the first is on its way does nothing.
        engine.perform(.keepOff, on: "r1")
        await gate.release()
        await engine.settle()
        #expect(await posts.performed == ["turn-on r1"])
        let shown = try #require(engine.transcript.first { $0.id == "post:r1" }?.post)
        #expect(shown.rehearsal?.state == .on)
        #expect(shown.pending == nil && shown.problem == nil)
        #expect(cpShown(engine) == ["1", "post:r1", "2"])
    }

    @Test func aFailureKeepsThePostWithAProblemAndIsNotRepeated() async throws {
        let posts = CPFakePosts([cpRehearsal("r1", at: 150)])
        await posts.onPerform { _, _ in throw URLError(.networkConnectionLost) }
        let engine = await cpEngine(cpRows([100, 200]), posts: posts)
        engine.perform(.keepOff, on: "r1")
        await engine.settle()
        let shown = try #require(engine.posts.first)
        #expect(shown.rehearsal?.state == .ready)
        #expect(shown.pending == nil)
        #expect(shown.problem?.isEmpty == false)
        #expect(engine.problem == nil)
        #expect(engine.transcript.first { $0.id == "post:r1" }?.post?.problem == shown.problem)

        // The next fetch says nothing new: the problem stays. Nothing was sent again.
        engine.refreshHistory()
        await engine.settle()
        #expect(engine.posts.first?.problem == shown.problem)
        #expect(await posts.performed == ["keep-off r1"])
    }

    @Test func aChangedScheduleComesBackChanged() async throws {
        // The add-on's real answer: a 409 whose body is the post, now `changed`.
        let calls = CPCalls()
        let source = HermesConversationPosts { method, path, query in
            await calls.add(method, path, query)
            if method == "POST" {
                return (Data(#"{"id": "r1", "kind": "rehearsal", "at": 150, "bot": "career", "state": "changed", "title": "Morning prices"}"#.utf8), 409)
            }
            return (Data(#"{"version": 1, "posts": [{"id": "r1", "kind": "rehearsal", "at": 150, "bot": "career", "state": "ready", "title": "Morning prices"}]}"#.utf8), 200)
        }
        let link = CEFakeLink()
        await link.on("session.resume") { _ in ceResume() }
        let history = CWFakeHistory(segments: ["s0": cpRows([100, 200])])
        let engine = ConversationEngine(key: "changed", sessionId: "s0", link: link, history: history, lineageSource: history,
                                        store: MemoryConversationCacheStore(), posts: source)
        await engine.start()
        await engine.settle()
        #expect(engine.posts.first?.rehearsal?.state == .ready)
        engine.perform(.turnOn, on: "r1")
        await engine.settle()
        #expect(engine.posts.first?.rehearsal?.state == .changed)
        #expect(engine.posts.first?.problem == nil)
        #expect(engine.posts.first?.pending == nil)
        #expect(await calls.made.filter { $0.method == "POST" }.count == 1)
    }

    @Test func aFailedTapAsksForThePostsAgain() async throws {
        let posts = CPFakePosts([cpRehearsal("r1", at: 150)])
        await posts.onPerform { _, _ in throw URLError(.networkConnectionLost) }
        let engine = await cpEngine(cpRows([100, 200]), posts: posts)
        #expect(await posts.fetches == 1)
        // Meanwhile the schedule changed: the fetch after the failure shows it, without a second tap.
        await posts.set([cpRehearsal("r1", at: 150, state: .changed)])
        engine.perform(.turnOn, on: "r1")
        await engine.settle()
        #expect(await posts.fetches == 2)
        #expect(engine.posts.first?.rehearsal?.state == .changed)
        #expect(engine.posts.first?.problem == nil)
        #expect(await posts.performed == ["turn-on r1"])
    }

    @Test func aLostAnswerIsToldByTheNextFetch() async throws {
        let posts = CPFakePosts([cpRehearsal("r1", at: 150)])
        await posts.onPerform { _, _ in throw URLError(.timedOut) }
        let engine = await cpEngine(cpRows([100, 200]), posts: posts)
        engine.perform(.turnOn, on: "r1")
        await engine.settle()
        #expect(engine.posts.first?.problem != nil)
        // The tap had landed after all: the add-on's copy says so, and the problem goes.
        await posts.set([cpRehearsal("r1", at: 150, state: .on)])
        engine.refreshHistory()
        await engine.settle()
        #expect(engine.posts.first?.rehearsal?.state == .on)
        #expect(engine.posts.first?.problem == nil)
        #expect(await posts.performed.count == 1)
    }
}

// MARK: Personal details

@Suite struct PrivateDetailsTests {
    private func hidden(_ text: String) -> [String] {
        PrivateDetails.segments(of: text).filter(\.isPrivate).map(\.text)
    }

    @Test func personalPartsAreMarked() {
        #expect(hidden("Mail sam@example.com today") == ["sam@example.com"])
        #expect(hidden("Call +1 (555) 123-4567 or 555-123-4567") == ["+1 (555) 123-4567", "555-123-4567"])
        #expect(hidden("+44 20 7946 0958") == ["+44 20 7946 0958"])
        #expect(hidden("cat /Users/sam/Documents/taxes.pdf") == ["/Users/sam/Documents/taxes.pdf"])
        #expect(hidden("ls /home/sam/notes") == ["/home/sam/notes"])
        #expect(hidden("Saved to ~/Desktop/plan.txt.") == ["~/Desktop/plan.txt"])
        #expect(hidden("open https://example.com/a?b=1, then www.example.org") == ["https://example.com/a?b=1", "www.example.org"])
        #expect(hidden("Read news.example.com/item") == ["news.example.com/item"])
        // Receipts write a page with an empty path as its bare host.
        #expect(hidden("Looked at mybank.com and corey-portfolio.com.") == ["mybank.com", "corey-portfolio.com"])
        #expect(hidden("Opened Shop.Example.CO.UK:8443") == ["Shop.Example.CO.UK:8443"])
        #expect(hidden("ssh 192.168.1.30 and fd7a:115c:a1e0::1") == ["192.168.1.30", "fd7a:115c:a1e0::1"])
        #expect(hidden("ping 2001:0db8:0000:0000:0000:ff00:0042:8329") == ["2001:0db8:0000:0000:0000:ff00:0042:8329"])
        #expect(hidden("Order 12345678 shipped") == ["12345678"])
        #expect(hidden("curl -H [hidden] api") == ["[hidden]"])
    }

    @Test func plainWordsAreLeftAlone() {
        for text in ["Price drop on the SSD", "df -h", "git push origin main", "2TB NVMe price at 7:02", "Ran 3 checks in 2026",
                     "read_file notes.txt", "The 2TB drive is down to 119.", "Morning brief", "Packages/NollieCore/Sources"] {
            #expect(PrivateDetails.segments(of: text) == [PrivateDetails.Segment(text: text, isPrivate: false)], "\(text)")
        }
        #expect(PrivateDetails.segments(of: "").isEmpty)
    }

    @Test func theSegmentsGiveTheTextBack() {
        let text = "Wrote ~/notes/today.md, mailed sam@example.com from 10.0.0.4 about order 99887766 [hidden]."
        let segments = PrivateDetails.segments(of: text)
        #expect(segments.map(\.text).joined() == text)
        #expect(segments.map(\.isPrivate) == [false, true, false, true, false, true, false, true, false, true, false])
    }
}

// MARK: The list

extension ConversationListItemsTests {
    @Test func everyKindHasACell() {
        let rows: [ConversationRow] = [
            ConversationRow(id: "u", kind: .user(text: "hi", delivery: .sent)),
            ConversationRow(id: "b", kind: .assistant(ConversationReply(text: "hello"))),
            ConversationRow(id: "t", kind: .tool(ConversationToolStep(toolId: "c1", name: "terminal"))),
            ConversationRow(id: "n", kind: .note(.interrupted)),
            ConversationRow(id: "e", kind: .error("Context too long.")),
            ConversationRow(id: "post:night", kind: .post(cpNight("night", at: 1))),
            ConversationRow(id: "post:r1", kind: .post(cpRehearsal("r1", at: 2))),
        ]
        let card = ConversationCard(id: "c", method: "approval", kind: .approval(requestId: nil, command: "ls", description: nil, choices: []),
                                    shownAt: 0)
        let items = ConversationListItem.make(transcript: rows, cards: [card], activity: "Thinking", atNewestEnd: true)
        #expect(items.count == 9)
        for item in items { #expect(ConversationListItem.kinds.contains(item.kind), "\(item.kind)") }
        #expect(Set(items.map(\.kind)) == Set(ConversationListItem.kinds))
        #expect(items[5].kind == "nightShift" && items[6].kind == "rehearsal")
    }
}
