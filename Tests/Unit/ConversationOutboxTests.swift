import Foundation
import Testing
@testable import NollieCore

// The outbox and the request book: a message is sent at most once, and a send whose answer was lost is never
// repeated on its own. See "Requests and the outbox" in Docs/specs/conversation-engine.md.

/// A pretend live connection: answers each method with a handler and keeps every call.
actor CEFakeLink: ConversationLink {
    typealias Handler = @Sendable (GatewayJSON) async throws -> GatewayJSON

    private(set) var calls: [(method: String, params: GatewayJSON)] = []
    private(set) var watched: [String] = []
    private(set) var answered: [(id: String, result: GatewayJSON)] = []
    private(set) var declined: [String] = []
    private var handlers: [String: Handler] = [:]
    private var phase: GatewayPhase

    init(phase: GatewayPhase = .ready) {
        self.phase = phase
    }

    func on(_ method: String, _ handler: @escaping Handler) { handlers[method] = handler }
    func setPhase(_ next: GatewayPhase) { phase = next }

    func texts(of method: String) -> [String] {
        calls.filter { $0.method == method }.compactMap { $0.params["text"]?.stringValue }
    }

    func count(of method: String) -> Int { calls.filter { $0.method == method }.count }

    func currentPhase() async -> GatewayPhase { phase }

    func request(_ method: String, _ params: GatewayJSON, timeout: Duration?) async throws -> GatewayJSON {
        calls.append((method, params))
        guard let handler = handlers[method] else {
            throw GatewayCallFailure.refused(GatewayRPCError(code: GatewayRPCError.unknownMethod, message: "no \(method) here"))
        }
        return try await handler(params)
    }

    func answer(question id: String, method: String, result: GatewayJSON) async { answered.append((id, result)) }
    func decline(question id: String) async { declined.append(id) }
    func watch(session: String, profile: String?) async { watched.append(session) }
    func unwatch(session: String) async { watched.removeAll { $0 == session } }
}

/// Parks a call until the test opens the gate.
actor CEGate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var open = false
    private(set) var arrivals = 0

    func pass() async {
        arrivals += 1
        if open { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        open = true
        for continuation in waiting { continuation.resume() }
        waiting.removeAll()
    }
}

/// Counts calls, so a handler can answer the first one differently.
actor CECounter {
    private(set) var value = 0
    func next() -> Int {
        value += 1
        return value
    }
}

func ceResume(runtime: String = "rt-1", running: Bool = false, stored: String = "s0", inflightUser: String? = nil,
              inflightReply: String? = nil) -> GatewayJSON {
    var answer: [String: GatewayJSON] = ["session_id": .string(runtime), "stored_session_id": .string(stored), "running": .bool(running),
                                         "message_count": 0, "messages": [], "info": ["title": "Bot Chat"]]
    if running {
        var inflight: [String: GatewayJSON] = ["streaming": true]
        if let inflightUser { inflight["user"] = .string(inflightUser) }
        if let inflightReply { inflight["assistant"] = .string(inflightReply) }
        answer["inflight"] = .object(inflight)
    }
    return .object(answer)
}

func ceEvent(_ type: String, seq: Int, _ payload: GatewayJSON = [:]) -> GatewayNotice {
    .event(GatewayEventEnvelope(type: type, sessionId: "rt-1", seq: seq, payload: payload))
}

@MainActor
func ceEngine(_ link: CEFakeLink, history: CWFakeHistory = CWFakeHistory(segments: [:]), store: MemoryConversationCacheStore = MemoryConversationCacheStore(),
              key: String = "chat", opening: String = "s0") -> ConversationEngine {
    ConversationEngine(key: key, sessionId: opening, link: link, history: history, lineageSource: history, store: store)
}

/// The engine went through a drop and came back.
@MainActor
func ceReconnect(_ engine: ConversationEngine) async {
    engine.receive(.phase(.retrying(attempt: 1, delay: .milliseconds(500))))
    engine.receive(.phase(.connecting(attempt: 1)))
    engine.receive(.phase(.handshaking(attempt: 1)))
    engine.receive(.phase(.ready))
    await engine.settle()
}

@MainActor
private func ceUserRows(_ engine: ConversationEngine) -> [ConversationRow.Kind] {
    engine.transcript.filter { $0.userText != nil }.map(\.kind)
}

@Suite struct ConversationOutboxReducerTests {
    private func attached() -> ConversationState {
        ConversationReducer.reduce(ConversationState(lineage: ConversationLineage(tip: "s0")),
                                   .attached(ConversationSnapshot(runtimeSession: "rt-1"), held: [], requestedAt: 0, full: false))
    }

    @Test func oneMessageGoesAtATimeAndInOrder() {
        var state = ConversationReducer.reduce(attached(), [.compose(text: "one"), .compose(text: "  "), .compose(text: "two")])
        #expect(state.outbox.entries.map(\.text) == ["one", "two"])
        let first = state.outbox.next(canSend: true)
        #expect(first?.text == "one")
        #expect(state.outbox.next(canSend: false) == nil)
        state = ConversationReducer.reduce(state, .sendStarted(id: first!.id))
        #expect(state.outbox.next(canSend: true) == nil, "nothing else while one is in flight")
        #expect(state.rows.map(\.kind) == [.user(text: "one", delivery: .sending)])
    }

    @Test func anUncertainSendIsNeverOfferedAgain() {
        var state = ConversationReducer.reduce(attached(), .compose(text: "hello"))
        let id = state.outbox.entries[0].id
        state = ConversationReducer.reduce(state, [.sendStarted(id: id), .sendFinished(id: id, .uncertain)])
        #expect(state.outbox[id]?.state == .uncertain)
        #expect(state.rows.map(\.kind) == [.user(text: "hello", delivery: .uncertain)])
        #expect(state.outbox.next(canSend: true) == nil)
        // A second answer for the same send changes nothing.
        state = ConversationReducer.reduce(state, .sendFinished(id: id, .notSent))
        #expect(state.outbox[id]?.state == .uncertain)
        #expect(state.outbox.next(canSend: true) == nil)
    }

    @Test func onlyThePersonSendsItAgainAndThenAsANewMessage() {
        var state = ConversationReducer.reduce(attached(), .compose(text: "hello"))
        let id = state.outbox.entries[0].id
        state = ConversationReducer.reduce(state, [.sendStarted(id: id), .sendFinished(id: id, .uncertain), .resend(id: id)])
        #expect(state.outbox[id] == nil)
        let again = state.outbox.next(canSend: true)
        #expect(again?.text == "hello")
        #expect(again?.id != id)
        #expect(state.rows.isEmpty)
    }

    @Test func refusalsAndUnsentCallsSortThemselves() {
        var state = ConversationReducer.reduce(attached(), [.compose(text: "a"), .compose(text: "b"), .compose(text: "c")])
        let ids = state.outbox.entries.map(\.id)
        state = ConversationReducer.reduce(state, [.sendStarted(id: ids[0]), .sendFinished(id: ids[0], .refused("The agent is starting.", retryable: true))])
        #expect(state.outbox[ids[0]]?.state == .waiting)
        #expect(state.rows.isEmpty)
        state = ConversationReducer.reduce(state, [.sendStarted(id: ids[0]), .sendFinished(id: ids[0], .refused("Too long.", retryable: false))])
        #expect(state.outbox[ids[0]]?.state == .failed("Too long."))
        #expect(state.rows.map(\.kind) == [.user(text: "a", delivery: .notSent("Too long."))])
        state = ConversationReducer.reduce(state, [.sendStarted(id: ids[1]), .sendFinished(id: ids[1], .notSent)])
        #expect(state.outbox[ids[1]]?.state == .waiting)
        #expect(!state.running)
        state = ConversationReducer.reduce(state, .discard(id: ids[0]))
        #expect(state.rows.isEmpty)
        #expect(state.outbox.entries.map(\.text) == ["b", "c"])
    }

    @Test func aMessageThatWasGoingOutReadsBackAsUncertain() {
        let saved = ConversationOutbox(entries: [.init(id: "out-1", text: "going", state: .sending), .init(id: "out-2", text: "next")])
        let restored = ConversationOutbox.restored(saved)
        #expect(restored.entries.map(\.state) == [.uncertain, .waiting])
        #expect(restored.next(canSend: true)?.id == "out-2")
    }
}

@Suite struct ConversationRequestBookTests {
    @Test func lostAnswersAreUnknownAndOnlyOneSendFlies() throws {
        var book = ConversationRequestBook()
        let firstSubmit = book.begin(.submit(outboxId: "out-1"))
        let secondSubmit = book.begin(.submit(outboxId: "out-2"))
        let firstAttach = book.begin(.attach(full: false))
        let secondAttach = book.begin(.attach(full: true))
        let submit = try #require(firstSubmit)
        let attach = try #require(firstAttach)
        #expect(secondSubmit == nil)
        #expect(secondAttach == nil)
        #expect(book.finish(submit, .failure(GatewayCallFailure.connectionLost)) == .unknown)
        #expect(book.finish(submit, .failure(GatewayCallFailure.connectionLost)) == nil, "finished once")
        #expect(book.finish(attach, .failure(GatewayCallFailure.closed)) == .notSent)
        #expect(ConversationRequestBook.classify(.failure(GatewayCallFailure.timedOut)) == .unknown)
        #expect(ConversationRequestBook.classify(.failure(GatewayCallFailure.cancelled)) == .unknown)
        let refusal = GatewayRPCError(code: 4001, message: "session not found")
        #expect(ConversationRequestBook.classify(.failure(GatewayCallFailure.refused(refusal))) == .refused(refusal))
        #expect(ConversationRequestBook.Purpose.submit(outboxId: "x").mutates)
        #expect(!ConversationRequestBook.Purpose.attach(full: false).mutates)
        #expect(book.count == 0)
    }
}

@MainActor
@Suite struct ConversationOutboxEngineTests {
    @Test func anUncertainSendIsNeverRepeatedAcrossReconnects() async throws {
        let link = CEFakeLink()
        let submits = CECounter()
        await link.on("session.resume") { _ in ceResume() }
        await link.on("prompt.submit") { _ in
            if await submits.next() == 1 { throw GatewayCallFailure.connectionLost }
            return ["status": "streaming"]
        }
        let engine = ceEngine(link)
        await engine.start()
        await engine.settle()

        engine.send("hello")
        await engine.settle()
        #expect(await link.texts(of: "prompt.submit") == ["hello"])
        #expect(ceUserRows(engine) == [.user(text: "hello", delivery: .uncertain)])

        await ceReconnect(engine)
        await ceReconnect(engine)
        #expect(await link.count(of: "session.resume") == 3)
        #expect(await link.texts(of: "prompt.submit") == ["hello"], "an uncertain send went out again")
        #expect(ceUserRows(engine) == [.user(text: "hello", delivery: .uncertain)])

        // Later messages still go, once each.
        engine.send("next")
        await engine.settle()
        #expect(await link.texts(of: "prompt.submit") == ["hello", "next"])
        engine.receive(ceEvent("message.complete", seq: 1, ["text": "ok", "status": "complete"]))
        await engine.settle()
        #expect(await link.texts(of: "prompt.submit") == ["hello", "next"])

        // Sending it again is the person's call, and it goes as a new message.
        let doubtful = try #require(engine.state.outbox.uncertain.first)
        engine.sendAgain(doubtful.id)
        await engine.settle()
        #expect(await link.texts(of: "prompt.submit") == ["hello", "next", "hello"])
    }

    @Test func aSnapshotShowingTheMessageLandedSettlesIt() async throws {
        let link = CEFakeLink()
        await link.on("session.resume") { _ in ceResume() }
        await link.on("prompt.submit") { _ in throw GatewayCallFailure.timedOut }
        let engine = ceEngine(link)
        await engine.start()
        await engine.settle()
        engine.send("Tell me about the logs")
        await engine.settle()
        #expect(ceUserRows(engine) == [.user(text: "Tell me about the logs", delivery: .uncertain)])

        await link.on("session.resume") { _ in ceResume(running: true, inflightUser: "Tell me about the logs", inflightReply: "They") }
        await ceReconnect(engine)
        #expect(ceUserRows(engine) == [.user(text: "Tell me about the logs", delivery: .sent)])
        #expect(engine.state.outbox.uncertain.isEmpty)
        #expect(engine.transcript.compactMap(\.reply).map(\.text) == ["They"])
        #expect(await link.count(of: "prompt.submit") == 1)
    }

    @Test func storedHistoryShowingTheMessageSettlesItWithoutShowingItTwice() async throws {
        let link = CEFakeLink()
        let history = CWFakeHistory(segments: ["s0": cwRows("s0", 1...2)])
        await link.on("session.resume") { _ in ceResume() }
        await link.on("prompt.submit") { _ in throw GatewayCallFailure.connectionLost }
        let engine = ceEngine(link, history: history)
        await engine.start()
        await engine.settle()
        engine.send("Where are we?")
        await engine.settle()

        await history.append(ConversationHistoryRow(address: ConversationRowAddress(segment: "s0", rowId: 3), role: "user", text: "Where are we?"))
        await history.append(ConversationHistoryRow(address: ConversationRowAddress(segment: "s0", rowId: 4), role: "assistant", text: "Here."))
        await ceReconnect(engine)
        #expect(engine.state.outbox.entries.isEmpty)
        #expect(ceUserRows(engine) == [.user(text: "message 1", delivery: .sent), .user(text: "Where are we?", delivery: .sent)])
        #expect(engine.transcript.first { $0.userText == "Where are we?" }?.id == "user:out-1", "the row keeps its id")
        #expect(await link.count(of: "prompt.submit") == 1)
    }

    @Test func aMessageInFlightWhenTheAppStoppedIsNotSentByTheNextLaunch() async throws {
        let store = MemoryConversationCacheStore()
        let gate = CEGate()
        let first = CEFakeLink()
        await first.on("session.resume") { _ in ceResume() }
        await first.on("prompt.submit") { _ in
            await gate.pass()
            return ["status": "streaming"]
        }
        let before = ceEngine(first, store: store)
        await before.start()
        await before.settle()
        before.send("Restart the export")
        var waited = 0
        while await gate.arrivals == 0, waited < 500 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        try #require(await gate.arrivals == 1)

        // The app stops here, with the send in flight. The next launch reads the same cache.
        let second = CEFakeLink()
        await second.on("session.resume") { _ in ceResume() }
        await second.on("prompt.submit") { _ in ["status": "streaming"] }
        let after = ceEngine(second, store: store)
        await after.start()
        await after.settle()
        #expect(after.state.outbox.entries.map(\.state) == [.uncertain])
        #expect(await second.count(of: "prompt.submit") == 0)

        await gate.release()
        await before.settle()
    }

    @Test func messagesTypedOfflineGoOnceEachInOrder() async throws {
        let link = CEFakeLink(phase: .connecting(attempt: 1))
        let rows = CECounter()
        await link.on("session.resume") { _ in ceResume() }
        await link.on("prompt.submit") { _ in ["status": "streaming", "user_row_id": .integer(await rows.next() + 100)] }
        let engine = ceEngine(link)
        await engine.start()
        engine.send("first")
        engine.send("second")
        await engine.settle()
        #expect(await link.calls.isEmpty, "nothing goes before the line is ready")
        #expect(engine.state.outbox.waiting.map(\.text) == ["first", "second"])

        engine.receive(.phase(.ready))
        await engine.settle()
        #expect(await link.texts(of: "prompt.submit") == ["first"])
        engine.receive(ceEvent("message.complete", seq: 1, ["text": "One.", "status": "complete"]))
        await engine.settle()
        #expect(await link.texts(of: "prompt.submit") == ["first", "second"])
        engine.receive(ceEvent("message.complete", seq: 2, ["text": "Two.", "status": "complete"]))
        await ceReconnect(engine)
        #expect(await link.texts(of: "prompt.submit") == ["first", "second"])
        #expect(engine.state.outbox.entries.isEmpty)
    }
}
