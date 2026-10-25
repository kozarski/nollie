import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

// Reattaching a chat reads a snapshot of its session, and turning that snapshot into rows takes a
// while. These tests hold that step open on purpose and let the world move: events arrive, the bot
// asks or withdraws a question, the person answers, a second snapshot overtakes the first.

// MARK: - Test doubles

/// Parks each rows build for a chat until the test releases it. Builds are numbered from zero
/// in the order they show up.
actor RowsLatch {
    private var arrivals = 0
    private var freed = Set<Int>()
    private var sleeping: [Int: CheckedContinuation<Void, Never>] = [:]
    private var watchers: [Int: [CheckedContinuation<Void, Never>]] = [:]

    /// What `ChatSession.beforeSnapshotRows` is set to.
    nonisolated var hook: @Sendable (JSONValue) async -> Void { { _ in await self.park() } }

    private func park() async {
        let mine = arrivals
        arrivals += 1
        for (need, waiting) in watchers where arrivals >= need {
            watchers[need] = nil
            waiting.forEach { $0.resume() }
        }
        guard !freed.contains(mine) else { return }
        await withCheckedContinuation { sleeping[mine] = $0 }
    }

    func waitForArrivals(_ n: Int) async {
        guard arrivals < n else { return }
        await withCheckedContinuation { watchers[n, default: []].append($0) }
    }

    func free(_ index: Int) {
        freed.insert(index)
        sleeping.removeValue(forKey: index)?.resume()
    }
}

/// Gives the chat's own tasks turns until `ready` is true, or a thousand turns have passed.
@MainActor private func pump(_ ready: () -> Bool) async {
    var turns = 0
    while !ready() && turns < 1000 {
        await Task.yield()
        turns += 1
    }
}

/// What the platform was told about cards and finished turns.
@MainActor private final class Ledger: CardNotifying {
    var announced: [String] = []
    var retired: [String] = []
    var finishedTurns = 0
    func cardArrived(_ card: PendingCard, chat: ChatSession) { announced.append(card.id) }
    func cardSettled(_ card: PendingCard, chat: ChatSession) { retired.append(card.id) }
    func turnFinished(chat: ChatSession, error: String?) { finishedTurns += 1 }
}

/// A stand-in for the menu bar's turn activity. Updates before `start` reach nothing.
@MainActor private final class Panel: TurnActivityReporting {
    private(set) var live = false
    private(set) var urgent = false
    private(set) var shownCard: String?
    private(set) var alerts = 0

    func start(for chat: ChatSession) {
        guard !live else { return }
        live = true; urgent = false; shownCard = nil
    }
    func update(for chat: ChatSession, attention: Bool, detail: String?) {
        guard live else { return }
        urgent = attention
        shownCard = attention ? chat.firstCard?.id : nil
        if attention { alerts += 1 }
    }
    func showCards(for chat: ChatSession) {
        guard live else { return }
        urgent = !chat.cards.isEmpty
        shownCard = chat.firstCard?.id
    }
    func end(for chat: ChatSession, phase: String) {
        live = false; urgent = false; shownCard = nil
    }
}

/// The gateway's side of the chat's calls. Methods named in `holding` wait for the test to answer;
/// any other call fails as if the gateway were unreachable.
@MainActor private final class Line {
    private let holding: Set<String>
    private var parkedCalls: [String: [CheckedContinuation<JSONValue, Never>]] = [:]
    private var log: [String] = []
    private var served: [String: Int] = [:]

    init(holding: Set<String>) { self.holding = holding }

    func call(_ method: String) async throws -> JSONValue {
        log.append(method)
        guard holding.contains(method) else { throw URLError(.cannotConnectToHost) }
        let answer = await withCheckedContinuation { parkedCalls[method, default: []].append($0) }
        served[method, default: 0] += 1
        return answer
    }

    func parked(_ method: String) -> Int { parkedCalls[method]?.count ?? 0 }
    func timesCalled(_ method: String) -> Int { log.filter { $0 == method }.count }
    func timesServed(_ method: String) -> Int { served[method] ?? 0 }

    /// Answers the oldest parked call of `method`.
    func serve(_ method: String, _ answer: JSONValue) {
        guard parkedCalls[method]?.isEmpty == false else { return }
        parkedCalls[method]?.removeFirst().resume(returning: answer)
    }
}

/// Counts how many times one particular reply was announced as finished for the chat.
@MainActor private final class ReplyEars {
    private(set) var heard = 0
    private var token: NSObjectProtocol?
    init(reply: String, stored: String) {
        token = NotificationCenter.default.addObserver(forName: .hermesReplyCompleted, object: nil, queue: nil) { [weak self] note in
            guard note.userInfo?["storedID"] as? String == stored, note.userInfo?["text"] as? String == reply else { return }
            MainActor.assumeIsolated { self?.heard += 1 }
        }
    }
    func stop() { if let token { NotificationCenter.default.removeObserver(token) } }
}

/// A bot request this device was asked to answer, and what became of it.
@MainActor private final class Asker {
    enum Fate: Equatable { case waiting, released, answered(JSONValue) }
    private(set) var settled = Fate.waiting

    init(chat: ChatSession, request: ServerRequest) {
        Task {
            let out = await chat.answer(serverRequest: request)
            self.settled = out.map(Fate.answered) ?? .released
        }
    }

    func fate() async -> Fate {
        await pump { settled != .waiting }
        return settled
    }
}

// MARK: - Fixtures

private let sid = "sess-A"
private let chatStoredID = "stored-9"
private let draftPrompt = "Draft the reply"

/// One question the bot can ask, in each of the shapes it reaches the app in.
private struct Ask {
    let method: String
    let number: Int
    let params: JSONValue

    var id: String { "rq-\(number)" }
    var approvalID: String { "ap-\(number)" }
    var queueCardID: String { "queue-" + approvalID }
    var isApproval: Bool { method == "approval" }

    static func approval(_ n: Int, command: String = "git clean -fd build") -> Ask {
        Ask(method: "approval", number: n, params: .object([
            "session_id": .string(sid), "request_id": .string("ap-\(n)"),
            "command": .string(command), "description": "Remove build leftovers"]))
    }
    static func question(_ n: Int, method: String = "clarify", text: String = "Send it to Dana too?") -> Ask {
        Ask(method: method, number: n, params: .object(["session_id": .string(sid), "question": .string(text)]))
    }
    static func make(_ method: String, _ n: Int = 1) -> Ask { method == "approval" ? approval(n) : question(n, method: method) }

    /// As a request arriving on its own.
    var request: ServerRequest { ServerRequest(id: id, method: method, params: params) }
    /// As an entry in a snapshot's list of open requests.
    var listed: JSONValue { .object(["id": .string(id), "method": .string(method), "params": params]) }
    /// As the gateway's approval queue holds it.
    var queued: JSONValue? {
        guard isApproval else { return nil }
        return .object(["request_id": .string(approvalID), "command": params["command"] ?? .null,
                        "description": params["description"] ?? .null])
    }
    /// What the person's tap sends back.
    var tap: JSONValue { isApproval ? .object(["choice": "once"]) : .object(["answer": "yes"]) }
}

/// A session snapshot as the gateway would answer `session.resume`.
private struct Look {
    static let origin = Date().timeIntervalSince1970 - 30

    var session = sid
    var running: Bool
    var prompt: String?
    var partial: String?
    var rows: [JSONValue] = []
    var open: [Ask] = []
    var pending: JSONValue?

    static func row(_ role: String, _ text: String?, id: Int, at offset: Double, extra: [String: JSONValue] = [:]) -> JSONValue {
        var fields: [String: JSONValue] = ["role": .string(role), "timestamp": .number(origin + offset), "row_id": .number(Double(id))]
        if let text { fields["text"] = .string(text) }
        return .object(fields.merging(extra) { _, new in new })
    }

    var json: JSONValue {
        var all = [Look.row("user", "Summarise the inbox", id: 1, at: -100),
                    Look.row("assistant", "Three unread from Dana.", id: 2, at: -90)]
        all.append(contentsOf: rows)
        var body: [String: JSONValue] = [
            "session_id": .string(session), "stored_session_id": .string(chatStoredID),
            "running": .bool(running), "messages": .array(all),
            "info": .object(["title": "Inbox", "running": .bool(running)]),
            "open_requests": .array(open.map(\.listed)),
        ]
        if let pending { body["pending_approval"] = pending }
        if let prompt {
            body["turn_started_at"] = .number(Look.origin)
            body["inflight"] = .object(["user": .string(prompt), "assistant": .string(partial ?? ""),
                                        "streaming": .bool(partial != nil)])
        }
        return .object(body)
    }

    /// A turn in progress.
    static func turn(partial: String? = nil, open: [Ask] = [], pending: JSONValue? = nil) -> Look {
        Look(running: true, prompt: draftPrompt, partial: partial, open: open, pending: pending)
    }
    static let idle = Look(running: false)
}

/// A chat wired into a runtime, with the doubles above attached.
@MainActor private final class Bench {
    let rt: GatewayRuntime
    let chat: ChatSession
    let latch: RowsLatch
    let ledger: Ledger
    let panel: Panel
    let line: Line?

    /// `latched`: every rows build waits on `latch`. `holding`: the chat's gateway calls go to a `Line`
    /// that parks these methods; without it the chat has no stand-in at all.
    init(latched: Bool = false, holding: Set<String>? = nil) throws {
        let connection = GatewayConnection(name: "unit", gateway: try GatewayURL.normalize("https://127.0.0.1:1"), authMode: .sessionToken)
        let runtime = GatewayRuntime(connection: connection, store: ConnectionStore())
        let ledger = Ledger(), panel = Panel(), latch = RowsLatch()
        runtime.cardNotifier = ledger
        runtime.activityReporterFactory = { panel }
        let chat = ChatSession(runtime: runtime, storedID: chatStoredID, title: nil)
        runtime.registry.add(chat)
        if latched { chat.beforeSnapshotRows = latch.hook }
        var line: Line?
        if let holding {
            let made = Line(holding: holding)
            line = made
            chat.gatewayStandIn = { name, _ in try await made.call(name) }
        }
        self.rt = runtime
        self.chat = chat
        self.latch = latch
        self.ledger = ledger
        self.panel = panel
        self.line = line
    }

    func show(_ look: Look, listedAt: Date? = nil) async {
        if let listedAt { await chat.apply(snapshot: look.json, listedAt: listedAt) }
        else { await chat.apply(snapshot: look.json) }
    }

    /// Starts applying a snapshot without waiting for it.
    func showLater(_ look: Look) -> Task<Void, Never> { Task { await show(look) } }

    func resumeLater() -> Task<Void, Error> { Task { try await chat.resume() } }

    func emit(_ type: String, _ payload: [String: JSONValue] = [:], session: String = sid) {
        rt.handle(batch: [GatewayEvent(type: type, sessionID: session, payload: .object(payload))])
    }

    func emitAll(_ events: [(String, [String: JSONValue])]) {
        rt.handle(batch: events.map { GatewayEvent(type: $0.0, sessionID: sid, payload: .object($0.1)) })
    }

    func withdraw(_ asks: Ask..., reason: String = "timeout") {
        rt.handle(batch: asks.map {
            GatewayEvent(type: "request.cancel", sessionID: sid, payload: .object(["id": .string($0.id), "reason": .string(reason)]))
        })
    }

    /// The bot asks; returns once its card shows.
    func bot(asks ask: Ask, cardID: String? = nil) async -> Asker {
        let asker = Asker(chat: chat, request: ask.request)
        let wanted = cardID ?? ask.id
        await pump { chat.cards.contains { $0.id == wanted } }
        return asker
    }

    var cardIDs: [String] { chat.cards.map(\.id) }
    var attentive: Bool { rt.needsAttention.contains(chatStoredID) }

    /// Waits until `n` rows builds have been parked.
    func buildsParked(_ n: Int) async { await latch.waitForArrivals(n) }

    /// Waits for the streaming row to catch up with what the events said.
    func waitForRedraw(last: String) async throws {
        for _ in 0..<60 where describe().last != last { try await Task.sleep(for: .milliseconds(50)) }
    }

    func describe() -> [String] {
        chat.items.map { item in
            switch item.kind {
            case .user(let text, _): "me: \(text)"
            case .assistant(let text, _, let live): live ? "typing: \(text)" : "bot: \(text)"
            case .tool(let activity): "tool: \(activity.context ?? activity.name)"
            case .error(let text): "error: \(text)"
            case .system(let text, _): "note: \(text)"
            default: "other"
            }
        }
    }
}

/// A push or notification tap asking to answer an approval.
private func tapRoute(request: String?) throws -> PendingRoute {
    var info: [String: Any] = ["session_id": chatStoredID, "kind": "approval"]
    if let request { info["request_id"] = request }
    return try #require(PendingRoute(notification: ["hermes": info]))
}

// MARK: - Tests

@MainActor @Suite struct ReattachRaceTests {
    // MARK: events while rows are built

    @Test func eventsForTheSessionArriveWhileTheFirstSnapshotIsBuilt() async throws {
        let b = try Bench(latched: true)
        #expect(b.chat.runtimeID.isEmpty)
        let applying = b.showLater(.turn(partial: "Checking"))
        await b.buildsParked(1)
        #expect(b.chat.runtimeID == sid, "the session id is known before any row exists")
        b.emitAll([
            ("message.delta", ["text": " the calendar."]),
            ("tool.start", ["tool_id": "c1", "name": "search", "context": "calendar next week"]),
            ("tool.complete", ["tool_id": "c1", "name": "search", "summary": "2 events"]),
            ("message.delta", ["text": "Found two meetings."]),
            ("message.complete", ["text": "Checking the calendar.Found two meetings.", "status": "complete"]),
        ])
        #expect(!b.chat.items.contains { $0.id == "tool-c1" }, "events wait for the rows")
        await b.latch.free(0)
        await applying.value
        #expect(b.describe() == ["me: Summarise the inbox", "bot: Three unread from Dana.", "me: \(draftPrompt)",
                                 "bot: Checking the calendar.", "tool: calendar next week", "bot: Found two meetings."])
        let row = try #require(b.chat.items.first { $0.id == "tool-c1" })
        guard case .tool(let activity) = row.kind else { Issue.record("not a tool row"); return }
        #expect(activity.status == .done)
        #expect(!b.chat.isRunning)
    }

    @Test func aNewSessionIDTakesOverBeforeItsRowsExist() async throws {
        let b = try Bench(latched: true)
        await b.latch.free(0)
        await b.show(Look(session: "sess-old", running: false))
        #expect(b.chat.runtimeID == "sess-old")
        let applying = b.showLater(Look(session: "sess-new", running: true, prompt: draftPrompt, partial: ""))
        await b.buildsParked(2)
        #expect(b.chat.runtimeID == "sess-new")
        b.emit("tool.start", ["tool_id": "n9", "name": "search", "context": "weather"], session: "sess-new")
        await b.latch.free(1)
        await applying.value
        #expect(b.chat.items.last?.id == "tool-n9")
        #expect(b.chat.isRunning)
    }

    // MARK: questions asked or withdrawn while rows are built

    @Test func aQuestionAskedMidBuildOutlivesTheSnapshotAndStillReachesTheBot() async throws {
        let b = try Bench(latched: true)
        let stale = Ask.question(7, text: "Which folder?")
        await b.latch.free(0)
        await b.show(.turn(open: [stale]))
        #expect(b.cardIDs == [stale.id])
        // Another device answered the old one; the next snapshot lists nothing.
        let applying = b.showLater(.turn())
        await b.buildsParked(2)
        let fresh = Ask.question(8)
        let asker = Asker(chat: b.chat, request: fresh.request)
        await pump { b.cardIDs.contains(fresh.id) }
        try #require(b.cardIDs.contains(fresh.id))
        await b.latch.free(1)
        await applying.value
        #expect(b.cardIDs == [fresh.id])
        await b.chat.respond(card: try #require(b.chat.cards.first), result: fresh.tap)
        #expect(await asker.fate() == .answered(fresh.tap))
    }

    @Test func aQuestionWithdrawnMidBuildIsGoneAfterwards() async throws {
        let b = try Bench(latched: true)
        let applying = b.showLater(.turn())
        await b.buildsParked(1)
        let ask = Ask.question(1)
        let asker = await b.bot(asks: ask)
        b.withdraw(ask)
        await b.latch.free(0)
        await applying.value
        #expect(b.chat.cards.isEmpty)
        let fate = await asker.fate()
        #expect(fate == .released || fate == .answered(.null))
    }

    @Test(arguments: ["approval", "clarify"])
    func aCardAnsweredMidBuildStaysAnswered(method: String) async throws {
        let b = try Bench(latched: true)
        let ask = Ask.make(method)
        await b.latch.free(0)
        await b.show(.turn(open: [ask], pending: ask.queued))
        #expect(b.cardIDs == [ask.id])
        #expect(b.attentive)
        let card = try #require(b.chat.cards.first)
        // The snapshot being built was read before the person answered, so it still lists the card.
        let applying = b.showLater(.turn(open: [ask], pending: ask.queued))
        await b.buildsParked(2)
        await b.chat.respond(card: card, result: ask.tap)
        #expect(b.chat.cards.isEmpty)
        await b.latch.free(1)
        await applying.value
        #expect(b.chat.cards.isEmpty)
        #expect(!b.attentive)
        #expect(b.ledger.announced == [ask.id])
        let approvalNotes = b.describe().filter { $0.hasPrefix("note: Approval") }
        #expect(approvalNotes == (ask.isApproval ? ["note: Approval: once"] : []))
    }

    @Test(arguments: ["approval", "clarify"])
    func aCardAnsweredBeforeTheSnapshotReplyStaysAnswered(method: String) async throws {
        let b = try Bench(holding: ["session.resume"])
        let line = try #require(b.line)
        let ask = Ask.make(method)
        await b.show(.turn(open: [ask], pending: ask.queued))
        let card = try #require(b.chat.cards.first)
        let resuming = b.resumeLater()
        await pump { line.parked("session.resume") == 1 }
        try #require(line.parked("session.resume") == 1)
        await b.chat.respond(card: card, result: ask.tap)
        // The gateway read its list before the answer reached it.
        line.serve("session.resume", Look.turn(open: [ask], pending: ask.queued).json)
        try await resuming.value
        #expect(b.chat.cards.isEmpty)
        #expect(!b.attentive)
        #expect(b.ledger.announced == [ask.id])
    }

    // MARK: cards that a newer snapshot drops

    @Test(arguments: ["approval", "clarify"])
    func aCardMissingFromTheNewerSnapshotIsSettled(method: String) async throws {
        let b = try Bench()
        let ask = Ask.make(method)
        var asker: Asker?
        if ask.isApproval {
            await b.show(.turn(open: [ask], pending: ask.queued))
        } else {
            asker = await b.bot(asks: ask)
        }
        try #require(b.cardIDs == [ask.id])
        #expect(b.attentive)
        await b.show(.turn())
        #expect(b.chat.cards.isEmpty)
        #expect(!b.attentive)
        #expect(b.ledger.retired == [ask.id])
        if let asker { #expect(await asker.fate() == .released) }
    }

    @Test(arguments: ["approval", "clarify"])
    func aWithdrawnQuestionClearsWhatWasPostedForIt(method: String) async throws {
        let b = try Bench()
        let ask = Ask.make(method)
        await b.show(.turn())
        let asker = await b.bot(asks: ask)
        try #require(b.panel.live && b.panel.urgent)
        b.withdraw(ask)
        #expect(b.chat.cards.isEmpty)
        #expect(b.ledger.retired == [ask.id])
        #expect(!b.panel.urgent)
        #expect(!b.attentive)
        #expect(await asker.fate() == .answered(.null))
    }

    @Test(arguments: ["answered", "withdrawn", "unlisted"])
    func theMenuBarMovesToTheNextCardWhenItsCardGoes(how: String) async throws {
        let b = try Bench()
        let first = Ask.approval(1)
        let second = Ask.question(2, text: "Keep the newest copy?")
        await b.show(.turn())
        let firstAsker = await b.bot(asks: first)
        let secondAsker = await b.bot(asks: second)
        try #require(b.cardIDs.count == 2)
        try #require(b.panel.urgent && b.panel.shownCard == first.id)
        let alertsBefore = b.panel.alerts
        switch how {
        case "answered":
            await b.chat.respond(card: try #require(b.chat.cards.first), result: first.tap)
            #expect(await firstAsker.fate() == .answered(first.tap))
        case "withdrawn":
            b.withdraw(first)
            #expect(await firstAsker.fate() == .answered(.null))
        default:
            // Idle, so the snapshot itself puts no cards in the menu bar.
            await b.show(Look(running: false, open: [second]))
            #expect(await firstAsker.fate() == .released)
        }
        #expect(b.cardIDs == [second.id])
        #expect(b.panel.urgent && b.panel.shownCard == second.id)
        #expect(b.panel.alerts == alertsBefore, "no new alert: the card was announced when it came")
        b.withdraw(second)
        #expect(!b.panel.urgent && b.panel.shownCard == nil)
        #expect(await secondAsker.fate() == .answered(.null))
    }

    // MARK: questions that are newer than the snapshot

    /// Resumes mid-turn while the bot asks `method` ahead of the reply. The reply was read before
    /// the question existed, so it leaves the question out.
    private func askWhileResuming(_ method: String) async throws -> (bench: Bench, asker: Asker) {
        let b = try Bench(holding: ["session.resume"])
        let line = try #require(b.line)
        await b.show(.turn())
        let resuming = b.resumeLater()
        await pump { line.parked("session.resume") == 1 }
        try #require(line.parked("session.resume") == 1)
        let asker = await b.bot(asks: Ask.make(method))
        try #require(b.cardIDs == ["rq-1"])
        line.serve("session.resume", Look.turn().json)
        try await resuming.value
        return (b, asker)
    }

    @Test(arguments: ["approval", "clarify", "sudo"])
    func aQuestionNewerThanTheSnapshotListStays(method: String) async throws {
        let (b, asker) = try await askWhileResuming(method)
        #expect(b.cardIDs == ["rq-1"])
        #expect(b.attentive)
        #expect(b.ledger.announced == ["rq-1"] && b.ledger.retired.isEmpty)
        #expect(await asker.fate() == .waiting)
        let ask = Ask.make(method)
        await b.chat.respond(card: try #require(b.chat.cards.first), result: ask.tap)
        #expect(await asker.fate() == .answered(ask.tap))
    }

    @Test(arguments: ["approval", "clarify"])
    func aLaterListThatLacksTheQuestionLetsItGo(method: String) async throws {
        let (b, asker) = try await askWhileResuming(method)
        let line = try #require(b.line)
        let again = b.resumeLater()
        await pump { line.parked("session.resume") == 1 }
        line.serve("session.resume", Look.turn().json)
        try await again.value
        #expect(b.chat.cards.isEmpty)
        #expect(!b.attentive)
        #expect(b.ledger.retired == ["rq-1"])
        #expect(await asker.fate() == .released)
    }

    @Test func anOlderSnapshotAppliedLastDoesNotDropANewerQuestion() async throws {
        let b = try Bench()
        let askedFor = Date()
        let ask = Ask.question(1)
        let asker = await b.bot(asks: ask)
        await b.show(.turn(open: [ask]), listedAt: Date())
        await b.show(.turn(), listedAt: askedFor)
        #expect(b.cardIDs == [ask.id])
        #expect(await asker.fate() == .waiting)
    }

    @Test func aCardListedRepeatedlyIsAnnouncedOnce() async throws {
        let b = try Bench(holding: [])
        let line = try #require(b.line)
        let approval = Ask.approval(1)
        let extra = Ask.question(2, text: "Keep the newest copy?")
        await b.show(.turn(open: [approval]))
        await pump { line.timesCalled("approval.received") == 1 }
        await b.show(.turn(open: [approval]))
        await b.show(.turn(open: [approval, extra]))
        for _ in 0..<100 { await Task.yield() }
        #expect(b.cardIDs == [approval.id, extra.id])
        #expect(b.ledger.announced == [approval.id, extra.id])
        #expect(line.timesCalled("approval.received") == 1)
        #expect(b.ledger.retired.isEmpty)
        #expect(b.attentive)
    }

    @Test(arguments: [false, true])
    func aSnapshotThatStartsTheMenuBarShowsTheWaitingCard(askedFirst: Bool) async throws {
        let b = try Bench()
        let approval = Ask.approval(1)
        var asker: Asker?
        if askedFirst {
            await b.show(.idle)
            asker = await b.bot(asks: approval)
            try #require(!b.panel.live)
        }
        await b.show(.turn(open: [approval], pending: approval.queued))
        #expect(b.cardIDs == [approval.id])
        #expect(b.panel.live)
        #expect(b.panel.urgent && b.panel.shownCard == approval.id)
        #expect(b.panel.alerts == 0)
        // Coming back to the app reads the chat again; still no alert.
        await b.show(.turn(open: [approval], pending: approval.queued))
        #expect(b.panel.urgent && b.panel.shownCard == approval.id)
        #expect(b.panel.alerts == 0)
        if let asker {
            b.withdraw(approval)
            #expect(await asker.fate() == .answered(.null))
        }
    }

    // MARK: pending approval lookups

    @Test func aSlowLookupCannotResurrectAnAnsweredApproval() async throws {
        let b = try Bench(holding: ["approval.pending"])
        let line = try #require(b.line)
        let approval = Ask.approval(1)
        let entry = try #require(approval.queued)
        await b.show(.turn(pending: entry))
        #expect(b.cardIDs == [approval.queueCardID])
        await pump { line.parked("approval.pending") == 1 }
        try #require(line.parked("approval.pending") == 1)
        await b.chat.respond(card: try #require(b.chat.cards.first), result: approval.tap)
        let newer = Task { await b.chat.pollPendingApprovals() }
        await pump { line.parked("approval.pending") == 2 }
        await b.show(.turn())
        await pump { line.parked("approval.pending") == 3 }
        // The first lookup returns last, with a list read before the answer got there.
        line.serve("approval.pending", .object(["approvals": .array([entry])]))
        await pump { line.timesServed("approval.pending") == 1 }
        #expect(b.chat.cards.isEmpty)
        #expect(!b.attentive)
        #expect(b.ledger.announced == [approval.queueCardID])
        for _ in 0..<2 { line.serve("approval.pending", .object(["approvals": .array([])])) }
        await newer.value
    }

    // MARK: one approval, two ids

    @Test func theRequestTakesOverItsQueueCard() async throws {
        let b = try Bench(holding: [])
        let line = try #require(b.line)
        let approval = Ask.approval(1)
        let entry = try #require(approval.queued)
        await b.show(.turn(pending: entry))
        let other = Ask.question(2, text: "Keep the newest copy?")
        let otherAsker = await b.bot(asks: other)
        try #require(b.cardIDs == [approval.queueCardID, other.id])
        let asker = await b.bot(asks: approval)
        #expect(b.cardIDs == [approval.id, other.id], "one card, in the queue card's place")
        #expect(b.ledger.announced == [approval.queueCardID, other.id])
        await pump { line.timesCalled("approval.received") == 1 }
        #expect(line.timesCalled("approval.received") == 1)
        // A list that holds the approval under both ids still shows only one card.
        await b.show(.turn(open: [approval, other], pending: entry))
        #expect(b.cardIDs == [approval.id, other.id])
        #expect(b.ledger.announced == [approval.queueCardID, other.id] && b.ledger.retired.isEmpty)
        await b.chat.respond(card: try #require(b.chat.cards.first), result: approval.tap)
        #expect(await asker.fate() == .answered(approval.tap))
        #expect(line.timesCalled("approval.respond") == 0, "answered as the request, not through the queue")
        #expect(b.cardIDs == [other.id])
        b.withdraw(other)
        #expect(await otherAsker.fate() == .answered(.null))
    }

    @Test func aQueueEntryNeverJoinsTheRequestsOwnCard() async throws {
        let b = try Bench(holding: ["approval.pending"])
        let line = try #require(b.line)
        let approval = Ask.approval(1)
        let entry = try #require(approval.queued)
        await b.show(.turn())
        await pump { line.parked("approval.pending") == 1 }
        try #require(line.parked("approval.pending") == 1)
        let asker = await b.bot(asks: approval)
        line.serve("approval.pending", .object(["approvals": .array([entry])]))
        await pump { line.timesServed("approval.pending") == 1 }
        #expect(b.cardIDs == [approval.id])
        await b.show(.turn(pending: entry))
        #expect(b.cardIDs == [approval.id])
        #expect(b.ledger.announced == [approval.id])
        await pump { line.parked("approval.pending") == 1 }
        line.serve("approval.pending", .object(["approvals": .array([entry])]))
        await pump { line.timesServed("approval.pending") == 2 }
        #expect(b.cardIDs == [approval.id])
        b.withdraw(approval)
        #expect(await asker.fate() == .answered(.null))
    }

    @Test func answeringByTheQueueCardsIdReachesTheRequest() async throws {
        let b = try Bench(holding: [])
        let line = try #require(b.line)
        let approval = Ask.approval(1)
        await b.show(.turn(pending: approval.queued))
        let held = try #require(b.chat.cards.first)
        try #require(held.id == approval.queueCardID)
        let asker = await b.bot(asks: approval)
        try #require(b.cardIDs == [approval.id])
        #expect(b.chat.approvalCard(named: [held.id])?.id == approval.id)
        await b.chat.respond(card: held, result: approval.tap)
        #expect(await asker.fate() == .answered(approval.tap))
        #expect(line.timesCalled("approval.respond") == 0)
        #expect(b.chat.cards.isEmpty)
        #expect(!b.attentive)
    }

    // MARK: approving from a notification

    @Test func aNotificationTapFindsTheApprovalItWasPostedFor() async throws {
        let b = try Bench()
        let approval = Ask.approval(1)
        let asker = await b.bot(asks: approval)
        let newer = Ask.approval(2, command: "rm -rf /tmp/cache")
        await b.show(.turn(open: [approval], pending: newer.queued))
        try #require(b.cardIDs == [approval.id, newer.queueCardID])
        for card in b.chat.cards {
            let userInfo = LocalNotifier.userInfo(chat: b.chat, kind: card.method, card: card)
            let route = try #require(PendingRoute(notification: userInfo))
            #expect(await AppModel.approvalCard(for: route, in: b.chat, wait: 0)?.id == card.id)
        }
        let pushes = [(newer.approvalID, newer.queueCardID), (approval.approvalID, approval.id), (approval.queueCardID, approval.id)]
        for (named, expected) in pushes {
            #expect(await AppModel.approvalCard(for: try tapRoute(request: named), in: b.chat, wait: 0)?.id == expected)
        }
        b.withdraw(approval)
        #expect(await asker.fate() == .answered(.null))
    }

    @Test func aTapForAnApprovalThatIsGoneAnswersNothing() async throws {
        let b = try Bench()
        await b.show(.turn())
        let old = Ask.approval(1)
        let oldAsker = await b.bot(asks: old)
        let staleInfo = LocalNotifier.userInfo(chat: b.chat, kind: "approval", card: try #require(b.chat.cards.first))
        b.withdraw(old)
        #expect(await oldAsker.fate() == .answered(.null))
        let current = Ask.approval(3, command: "rm -rf /tmp/cache")
        let currentAsker = await b.bot(asks: current)
        try #require(b.cardIDs == [current.id])
        let stale = try #require(PendingRoute(notification: staleInfo))
        #expect(await AppModel.approvalCard(for: stale, in: b.chat, wait: 0.3) == nil)
        #expect(await AppModel.approvalCard(for: try tapRoute(request: old.approvalID), in: b.chat, wait: 0) == nil)
        #expect(await currentAsker.fate() == .waiting)
        b.withdraw(current)
        #expect(await currentAsker.fate() == .answered(.null))
    }

    @Test func aTapWhileTheChatIsOpeningWaitsForTheApproval() async throws {
        let b = try Bench()
        await b.show(.turn())
        let approval = Ask.approval(1)
        let route = try tapRoute(request: approval.approvalID)
        let finding = Task { await AppModel.approvalCard(for: route, in: b.chat, wait: 5) }
        let asker = Asker(chat: b.chat, request: approval.request)
        #expect(await finding.value?.id == approval.id)
        b.withdraw(approval)
        #expect(await asker.fate() == .answered(.null))
    }

    @Test func aTapNamingNoApprovalOnlyAnswersALoneOne() async throws {
        let b = try Bench()
        await b.show(.turn())
        let unnamed = try tapRoute(request: nil)
        let blank = try tapRoute(request: "")
        let question = Ask.question(2, text: "Keep the newest copy?")
        let questionAsker = await b.bot(asks: question)
        #expect(await AppModel.approvalCard(for: unnamed, in: b.chat, wait: 0) == nil, "a question is not an approval")
        let finding = Task { await AppModel.approvalCard(for: unnamed, in: b.chat, wait: 5) }
        let approval = Ask.approval(1)
        let asker = Asker(chat: b.chat, request: approval.request)
        #expect(await finding.value?.id == approval.id)
        #expect(await AppModel.approvalCard(for: blank, in: b.chat, wait: 0)?.id == approval.id)
        #expect(await AppModel.approvalCard(for: try tapRoute(request: "ap-0"), in: b.chat, wait: 0) == nil,
                "a named approval that is gone is not swapped for another")
        // With a second approval waiting, an unnamed tap cannot tell which was meant.
        let second = Ask.approval(5, command: "rm -rf /tmp/cache")
        await b.show(.turn(open: [approval, question], pending: second.queued))
        try #require(b.cardIDs == [question.id, approval.id, second.queueCardID])
        #expect(await AppModel.approvalCard(for: unnamed, in: b.chat, wait: 0) == nil)
        #expect(await AppModel.approvalCard(for: try tapRoute(request: second.approvalID), in: b.chat, wait: 0)?.id == second.queueCardID)
        #expect(await asker.fate() == .waiting)
        b.withdraw(approval, question)
        #expect(await asker.fate() == .answered(.null))
        #expect(await questionAsker.fate() == .answered(.null))
    }

    // MARK: two snapshots in flight

    @Test(arguments: [false, true])
    func eachEventShowsOnceWhenSnapshotsOverlap(newerFirst: Bool) async throws {
        let b = try Bench(latched: true)
        let first = b.showLater(.turn(partial: "Checking"))
        await b.buildsParked(1)
        // Between the replies: the text goes on and a tool begins.
        b.emitAll([("message.delta", ["text": " the calendar."]),
                   ("tool.start", ["tool_id": "c1", "name": "search", "context": "calendar next week"])])
        // The second reply already holds both, as stored rows.
        let secondLook = Look(running: true, prompt: draftPrompt, rows: [
            Look.row("user", draftPrompt, id: 3, at: 0),
            Look.row("assistant", "Checking the calendar.", id: 4, at: 1),
            Look.row("tool", nil, id: 5, at: 2, extra: ["name": "search", "context": "calendar next week"]),
        ])
        let second = b.showLater(secondLook)
        await b.buildsParked(2)
        // After the second reply.
        b.emitAll([("tool.start", ["tool_id": "c2", "name": "search", "context": "room bookings"]),
                   ("message.delta", ["text": "Two rooms are free."])])
        if newerFirst {
            await b.latch.free(1)
            await second.value
            #expect(b.chat.isBuildingSnapshot, "the first build is still parked")
            await b.latch.free(0)
            await first.value
        } else {
            await b.latch.free(0)
            await first.value
            await b.latch.free(1)
            await second.value
        }
        #expect(!b.chat.isBuildingSnapshot)
        try await b.waitForRedraw(last: "typing: Two rooms are free.")
        #expect(b.describe() == ["me: Summarise the inbox", "bot: Three unread from Dana.", "me: \(draftPrompt)",
                                 "bot: Checking the calendar.", "tool: calendar next week", "tool: room bookings",
                                 "typing: Two rooms are free."])
        #expect(!b.chat.items.contains { $0.id == "tool-c1" }, "the stored row stands for that call")
        #expect(Set(b.chat.items.map(\.id)).count == b.chat.items.count)
    }

    @Test(arguments: [false, true])
    func aTurnThatEndedBetweenSnapshotsStillEndsHere(newerFirst: Bool) async throws {
        let b = try Bench(latched: true)
        await b.latch.free(0)
        await b.show(.turn(partial: "Checking"))
        #expect(b.chat.isRunning)
        _ = await b.chat.send("Then archive them")
        #expect(b.chat.queue.map(\.text) == ["Then archive them"])
        // Each case uses its own reply text, because the two cases run side by side.
        let reply = newerFirst ? "Checking the calendar. Two rooms are free." : "Checking the calendar. Three rooms are free."
        let ears = ReplyEars(reply: reply, stored: chatStoredID)
        defer { ears.stop() }
        let first = b.showLater(.turn(partial: "Checking the calendar."))
        await b.buildsParked(2)
        b.emit("message.complete", ["text": .string(reply), "status": "complete"])
        let second = b.showLater(Look(running: false, rows: [
            Look.row("user", draftPrompt, id: 3, at: 0),
            Look.row("assistant", reply, id: 4, at: 5),
        ]))
        await b.buildsParked(3)
        let order = newerFirst ? [2, 1] : [1, 2]
        for index in order {
            await b.latch.free(index)
            await (index == 2 ? second : first).value
        }
        #expect(ears.heard == 1)
        #expect(b.ledger.finishedTurns == 1)
        await pump { b.describe().contains("me: Then archive them") }
        #expect(b.chat.queue.isEmpty)
        #expect(b.describe() == ["me: Summarise the inbox", "bot: Three unread from Dana.", "me: \(draftPrompt)",
                                 "bot: \(reply)", "me: Then archive them"])
        #expect(b.chat.isRunning, "the queued message begins the next turn")
    }

    @Test func aQuestionWithdrawnBetweenSnapshotsIsReleased() async throws {
        let b = try Bench(latched: true)
        let first = b.showLater(.turn())
        await b.buildsParked(1)
        let ask = Ask.question(1)
        let asker = await b.bot(asks: ask)
        try #require(b.cardIDs == [ask.id])
        b.withdraw(ask)
        let second = b.showLater(.turn())
        await b.buildsParked(2)
        await b.latch.free(1)
        await second.value
        await b.latch.free(0)
        await first.value
        #expect(b.chat.cards.isEmpty)
        let fate = await asker.fate()
        #expect(fate == .released || fate == .answered(.null))
    }

    // MARK: held withdrawals and turn ends

    @Test func aWithdrawalBeforeTheReplyStillTakesTheCardDown() async throws {
        let b = try Bench(latched: true, holding: ["session.resume"])
        let line = try #require(b.line)
        let first = b.showLater(.turn())
        await b.buildsParked(1)
        let resuming = b.resumeLater()
        await pump { line.parked("session.resume") == 1 }
        try #require(line.parked("session.resume") == 1)
        let ask = Ask.question(1)
        let asker = await b.bot(asks: ask)
        b.withdraw(ask)
        #expect(b.cardIDs == [ask.id], "held while the first rows are built")
        line.serve("session.resume", Look.turn().json)
        await b.buildsParked(2)
        await b.latch.free(1)
        try await resuming.value
        #expect(b.cardIDs == [ask.id], "the reply, read earlier, leaves it up")
        await b.latch.free(0)
        await first.value
        #expect(b.chat.cards.isEmpty)
        #expect(!b.attentive)
        let lastNote = try #require(b.describe().last)
        #expect(lastNote.hasPrefix("note: Request withdrawn") && lastNote.contains("(timeout)"))
        #expect(await asker.fate() != .waiting)
    }

    @Test(arguments: ["message.complete", "error"])
    func aTurnEndBeforeTheReplyTakesDownTheCardTheReplyLeftUp(end: String) async throws {
        let b = try Bench(latched: true, holding: ["session.resume"])
        let line = try #require(b.line)
        let first = b.showLater(.turn())
        await b.buildsParked(1)
        let resuming = b.resumeLater()
        await pump { line.parked("session.resume") == 1 }
        try #require(line.parked("session.resume") == 1)
        let approval = Ask.approval(1)
        let asker = await b.bot(asks: approval)
        let payload: [String: JSONValue] = end == "error" ? ["message": "The model is unavailable"]
                                                          : ["text": "Stopped there.", "status": "complete"]
        b.emit(end, payload)
        line.serve("session.resume", Look.idle.json)
        await b.buildsParked(2)
        await b.latch.free(1)
        try await resuming.value
        #expect(b.cardIDs == [approval.id], "left up by the reply while the end is held")
        await b.latch.free(0)
        await first.value
        #expect(b.chat.cards.isEmpty)
        #expect(!b.attentive)
        #expect(b.ledger.retired == [approval.id])
        b.emit("request.cancel", ["id": .string(approval.id), "reason": "turn ended"])
        #expect(await asker.fate() == .answered(.null))
    }

    @Test func aQuestionFromTheNextTurnSurvivesTheEarlierTurnsEnd() async throws {
        let b = try Bench(latched: true, holding: ["session.resume"])
        let line = try #require(b.line)
        let first = b.showLater(.turn())
        await b.buildsParked(1)
        let resuming = b.resumeLater()
        await pump { line.parked("session.resume") == 1 }
        try #require(line.parked("session.resume") == 1)
        let old = Ask.approval(1)
        let oldAsker = await b.bot(asks: old)
        b.emit("message.complete", ["text": "Stopped there.", "status": "complete"])
        let next = Ask.question(2, text: "Keep the newest copy?")
        let nextAsker = await b.bot(asks: next)
        try #require(b.cardIDs.count == 2)
        line.serve("session.resume", Look.idle.json)
        await b.buildsParked(2)
        await b.latch.free(1)
        try await resuming.value
        #expect(b.cardIDs == [old.id, next.id])
        await b.latch.free(0)
        await first.value
        #expect(b.cardIDs == [next.id], "only the card from before the end goes")
        #expect(b.attentive)
        #expect(b.ledger.retired == [old.id])
        #expect(await nextAsker.fate() == .waiting)
        b.emit("request.cancel", ["id": .string(old.id), "reason": "turn ended"])
        b.withdraw(next)
        #expect(await oldAsker.fate() == .answered(.null))
        #expect(await nextAsker.fate() == .answered(.null))
    }

    // MARK: sending meanwhile

    @Test func aMessageSentMidBuildKeepsItsPlaceAndItsTurn() async throws {
        let b = try Bench(latched: true)
        await b.latch.free(0)
        await b.show(.idle)
        #expect(!b.chat.isRunning)
        let applying = b.showLater(.idle)
        await b.buildsParked(2)
        // The send waits for a gateway that is not there; its row is shown first.
        Task { await b.chat.send("Draft the reply") }
        await pump { b.describe().contains("me: Draft the reply") }
        try #require(b.describe().contains("me: Draft the reply"))
        #expect(b.chat.isRunning)
        b.emitAll([("message.start", [:]), ("message.delta", ["text": "On it."])])
        await b.latch.free(1)
        await applying.value
        try await b.waitForRedraw(last: "typing: On it.")
        #expect(b.describe() == ["me: Summarise the inbox", "bot: Three unread from Dana.", "me: Draft the reply", "typing: On it."])
        #expect(b.chat.isRunning, "an older snapshot saying idle does not end a newer turn")
        #expect(Set(b.chat.items.map(\.id)).count == b.chat.items.count)
    }

    @Test func rowsFromAnotherSnapshotAreNotCountedAsSentHere() async throws {
        let b = try Bench(latched: true)
        let first = b.showLater(.idle)
        await b.buildsParked(1)
        let second = b.showLater(.idle)
        await b.buildsParked(2)
        let expected = ["me: Summarise the inbox", "bot: Three unread from Dana."]
        await b.latch.free(0)
        await first.value
        #expect(b.describe() == expected)
        await b.latch.free(1)
        await second.value
        #expect(b.describe() == expected)
    }
}
