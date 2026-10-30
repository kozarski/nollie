import Foundation
import Testing
@testable import NollieCore

// The engine on the real gateway client: reconnect with seq replay, and the endless main chat stitched across
// compressions. See Docs/specs/conversation-engine.md.

/// Waits until `condition` holds. Nothing here is measured against real time, so the limit only stops a test that
/// hangs; ten seconds was short enough for a loaded Mac to run past while the test was working.
@MainActor
private func cetWait(_ what: String, timeout: Duration = .seconds(60), _ condition: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    if await condition() { return }
    Issue.record("timed out waiting for \(what)")
    throw CancellationError()
}

private func cetEvent(_ type: String, seq: Int, _ payload: GatewayJSON = [:]) -> GatewayJSON {
    ["type": .string(type), "session_id": "rt-1", "seq": .integer(seq), "payload": payload]
}

private func cetReplay(_ events: [GatewayJSON], latest: Int) -> GatewayJSON {
    ["events": .array(events), "latest_seq": .integer(latest), "truncated": false, "count": .integer(events.count), "epoch": "e1",
     "open_requests": []]
}

private func cetTexts(_ rows: [ConversationRow]) -> [String] {
    rows.map { row in
        switch row.kind {
        case .user(let text, _): "you: \(text)"
        case .assistant(let reply): "bot: \(reply.text)"
        case .tool(let step): "tool: \(step.name)"
        case .note(.summarized(let into)): "summarized: \(into ?? "?")"
        case .note: "note"
        case .error(let text): "error: \(text)"
        case .post(let post): "post: \(post.id)"
        }
    }
}

@MainActor
@Suite struct ConversationReconnectTests {
    @Test func aDropMidReplyIsCaughtUpWithoutLostOrDoubledRows() async throws {
        let persisted: GatewayJSON = ["row_ids": [11, 12], "complete": true, "user_row_id": 11, "final_assistant_row_id": 12]
        let transport = ScriptedGatewayTransport([
            .accept(ScriptedGatewayTransport.handshake(epoch: "e1") + [
                .expectCall("session.resume", params: ["session_id": "s0", "omit_messages": true], reply: .result(ceResume())),
                .expectCall("session.events.since", reply: .result(cetReplay([], latest: 0))),
                .expectCall("prompt.submit", params: ["session_id": "rt-1", "text": "Tell me a story"],
                            reply: .result(["status": "streaming", "user_row_id": 11])),
                .event(type: "message.start", session: "rt-1", seq: 1),
                .event(type: "message.delta", session: "rt-1", seq: 2, payload: ["text": "Once"]),
                .event(type: "message.delta", session: "rt-1", seq: 3, payload: ["text": " upon"]),
                .drop(code: 1006),
            ]),
            .accept(ScriptedGatewayTransport.handshake(epoch: "e1") + [
                // The client catches up from the last seq it delivered; Hermes repeats seq 3.
                .expectCall("session.events.since", params: ["session_id": "rt-1", "last_seen": 3],
                            reply: .result(cetReplay([cetEvent("message.delta", seq: 3, ["text": " upon"]),
                                                      cetEvent("message.delta", seq: 4, ["text": " a time"])], latest: 4))),
                // Ready again: the engine attaches the chat again, and Hermes carries on live.
                .expectCall("session.resume", params: ["session_id": "s0", "omit_messages": true],
                            reply: .result(ceResume(running: true, inflightUser: "Tell me a story", inflightReply: "Once upon a time"))),
                .event(type: "message.delta", session: "rt-1", seq: 5, payload: ["text": "."]),
                .event(type: "message.complete", session: "rt-1", seq: 6,
                       payload: ["text": "Once upon a time.", "status": "complete", "persisted_turn": persisted]),
            ]),
        ])
        var configuration = GatewayConfiguration()
        configuration.retryBase = .milliseconds(10)
        configuration.retryJitter = 0
        let client = GatewayClient(transport: transport, configuration: configuration) {
            GatewayEndpoint(url: URL(string: "ws://127.0.0.1:9169/api/ws")!)
        }
        let history = CWFakeHistory(segments: [:])
        let engine = ConversationEngine(key: "replay", sessionId: "s0", link: client, history: history,
                                        store: MemoryConversationCacheStore())
        await engine.start()
        let feeding = Task { await engine.run(client.notices) }
        defer { feeding.cancel() }
        await client.start()

        try await cetWait("the first attach") {
            let phase = await client.phase
            return engine.state.runtimeSession == "rt-1" && phase == .ready
        }
        await engine.settle()
        try await cetWait("the position probe") { transport.sent.contains { $0.contains("session.events.since") } }

        engine.send("Tell me a story")
        try await cetWait("the end of the turn") {
            engine.state.turn == 1 && !engine.state.running && engine.state.rows.contains { $0.reply?.ending == .complete }
        }
        await engine.settle()
        #expect(transport.problems.isEmpty, "\(transport.problems)")
        #expect(transport.openCount == 2)
        #expect(cetTexts(engine.transcript) == ["you: Tell me a story", "bot: Once upon a time."])
        let liveIds = engine.transcript.map(\.id)

        // Hermes stored the turn; the stored rows take over from the live ones under the same ids.
        await history.append(ConversationHistoryRow(address: ConversationRowAddress(segment: "s0", rowId: 11), role: "user", text: "Tell me a story"))
        await history.append(ConversationHistoryRow(address: ConversationRowAddress(segment: "s0", rowId: 12), role: "assistant", text: "Once upon a time."))
        engine.refreshHistory()
        await engine.settle()
        #expect(engine.state.rows.isEmpty, "the live tail was absorbed")
        #expect(cetTexts(engine.transcript) == ["you: Tell me a story", "bot: Once upon a time."])
        #expect(engine.transcript.map(\.id) == liveIds)
        #expect(transport.sent.filter { $0.contains("prompt.submit") }.count == 1)
        await client.stop()
    }

    @Test func aReloadAfterARestartAttachesWithTheWholeSnapshot() async throws {
        let link = CEFakeLink()
        let history = CWFakeHistory(segments: ["s0": cwRows("s0", 1...4)])
        let attaches = CECounter()
        // The first attach meets the old process; every one after the restart meets the new one.
        await link.on("session.resume") { _ in await attaches.next() == 1 ? ceResume() : ceResume(runtime: "rt-2") }
        let engine = ceEngine(link, history: history)
        await engine.start()
        await engine.settle()
        #expect(engine.transcript.count == 4)

        // Hermes restarted: the client says reload, then comes back ready.
        engine.receive(.phase(.retrying(attempt: 1, delay: .milliseconds(10))))
        engine.receive(.reload(session: "rt-1", .restarted))
        engine.receive(.phase(.ready))
        await engine.settle()
        let asked = await link.calls.filter { $0.method == "session.resume" }.map { $0.params["omit_messages"]?.boolValue }
        #expect(asked == [true, false])
        #expect(engine.state.runtimeSession == "rt-2")
        #expect(await link.watched == ["rt-2"])
        // Seq numbering starts over in the new process.
        engine.receive(.event(GatewayEventEnvelope(type: "message.delta", sessionId: "rt-2", seq: 1, payload: ["text": "Back."])))
        #expect(engine.transcript.last?.reply?.text == "Back.")
    }
}

@MainActor
@Suite struct ConversationEngineLifecycleTests {
    @Test func aReloadDuringALighterAttachIsFollowedByTheWholeSnapshot() async throws {
        let link = CEFakeLink()
        let gate = CEGate()
        let attaches = CECounter()
        await link.on("session.resume") { _ in
            if await attaches.next() == 2 { await gate.pass() }
            return ceResume()
        }
        let engine = ceEngine(link)
        await engine.start()
        await engine.settle()

        engine.receive(.phase(.retrying(attempt: 1, delay: .milliseconds(10))))
        engine.receive(.phase(.ready))
        while await gate.arrivals == 0 { try await Task.sleep(for: .milliseconds(5)) }
        engine.receive(.reload(session: "rt-1", .truncated))
        await gate.release()
        await engine.settle()
        let asked = await link.calls.filter { $0.method == "session.resume" }.map { $0.params["omit_messages"]?.boolValue }
        #expect(asked == [true, true, false])
    }

    @Test func aClosedEngineSendsNothingMore() async throws {
        let link = CEFakeLink()
        await link.on("session.resume") { _ in ceResume() }
        await link.on("prompt.submit") { _ in ["status": "streaming"] }
        let engine = ceEngine(link)
        await engine.start()
        await engine.settle()
        engine.close()
        engine.send("after close")
        engine.receive(.phase(.ready))
        await engine.settle()
        #expect(await link.count(of: "prompt.submit") == 0)
        #expect(await link.count(of: "session.resume") == 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await link.watched.isEmpty)
    }
}

@MainActor
@Suite struct ConversationLineageStitchingTests {
    @Test func threeCompressionsWhileWatchingLeaveOneQuietRowEach() async throws {
        let link = CEFakeLink()
        let history = CWFakeHistory(segments: ["s0": cwRows("s0", 1...2)], parents: ["s1": "s0", "s2": "s1", "s3": "s2"])
        let userRows = CECounter()
        await link.on("session.resume") { _ in ceResume() }
        await link.on("prompt.submit") { _ in ["status": "streaming", "user_row_id": .integer(await userRows.next() * 2 + 1)] }
        let engine = ceEngine(link, history: history)
        await engine.start()
        await engine.settle()

        var seq = 0
        func next() -> Int { seq += 1; return seq }
        for (turn, segment) in ["s1", "s2", "s3"].enumerated() {
            let user = turn * 2 + 3, reply = turn * 2 + 4
            engine.send("question \(turn + 1)")
            await engine.settle()
            engine.receive(ceEvent("message.start", seq: next()))
            engine.receive(ceEvent("status.update", seq: next(), ["kind": "compacting", "text": "Compacting context"]))
            engine.receive(ceEvent("status.update", seq: next(), ["kind": "lifecycle", "text": .string("Session compressed \(turn + 1) times. Consider /new to start fresh.")]))
            engine.receive(ceEvent("session.info", seq: next(), ["stored_session_id": .string(segment), "running": true]))
            engine.receive(ceEvent("status.update", seq: next(), ["kind": "compacted", "text": "Context compaction complete"]))
            engine.receive(ceEvent("message.delta", seq: next(), ["text": .string("answer \(turn + 1)")]))
            #expect(engine.transcript.filter { if case .note(.summarized) = $0.kind { true } else { false } }.count == turn + 1)
            await history.append(ConversationHistoryRow(address: ConversationRowAddress(segment: segment, rowId: user), role: "user", text: "question \(turn + 1)"))
            await history.append(ConversationHistoryRow(address: ConversationRowAddress(segment: segment, rowId: reply), role: "assistant", text: "answer \(turn + 1)"))
            engine.receive(ceEvent("message.complete", seq: next(), [
                "text": .string("answer \(turn + 1)"), "status": "complete",
                "persisted_turn": ["row_ids": [.integer(user), .integer(reply)], "complete": true, "user_row_id": .integer(user),
                                   "final_assistant_row_id": .integer(reply)],
            ]))
            await engine.settle()
        }
        #expect(engine.state.lineage.segments == ["s0", "s1", "s2", "s3"])
        #expect(engine.state.rows.isEmpty, "every settled turn came back from storage")
        #expect(cetTexts(engine.transcript) == [
            "you: message 1", "bot: message 2", "summarized: s1", "you: question 1", "bot: answer 1",
            "summarized: s2", "you: question 2", "bot: answer 2", "summarized: s3", "you: question 3", "bot: answer 3",
        ])
        #expect(Set(engine.transcript.map(\.id)).count == engine.transcript.count, "ids are unique")
        #expect(await link.count(of: "prompt.submit") == 3)
    }

    @Test func openingAtTheRootAfterThreeCompressionsScrollsBackThroughAllOfThem() async throws {
        let link = CEFakeLink()
        var segments: [String: [ConversationHistoryRow]] = [:]
        for (index, name) in ["s0", "s1", "s2", "s3"].enumerated() { segments[name] = cwRows(name, (index * 4 + 1)...(index * 4 + 4)) }
        let history = CWFakeHistory(segments: segments, parents: ["s3": "s2", "s2": "s1", "s1": "s0"])
        // The app knows the chat by its first id; Hermes resolves it to the tip three compressions on.
        await link.on("session.resume") { _ in ceResume(stored: "s3") }
        let engine = ceEngine(link, history: history, key: "root", opening: "s0")
        await engine.start()
        await engine.settle()
        #expect(engine.state.lineage.tip == "s3")
        #expect(cetTexts(engine.transcript) == (13...16).map { $0.isMultiple(of: 2) ? "bot: message \($0)" : "you: message \($0)" })

        var steps = 0
        while !engine.historyAtOldestEnd, steps < 10 {
            engine.loadOlder()
            await engine.settle()
            steps += 1
        }
        #expect(engine.historyAtOldestEnd)
        #expect(engine.state.lineage.segments == ["s0", "s1", "s2", "s3"])
        #expect(engine.state.lineage.rootKnown)
        let texts = cetTexts(engine.transcript)
        #expect(texts.filter { $0.hasPrefix("summarized") } == ["summarized: s1", "summarized: s2", "summarized: s3"])
        #expect(texts.filter { !$0.hasPrefix("summarized") } == (1...16).map { $0.isMultiple(of: 2) ? "bot: message \($0)" : "you: message \($0)" })
        #expect(texts.firstIndex(of: "summarized: s2") == 9)
    }
}
