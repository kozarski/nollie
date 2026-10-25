import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

/// Returning to a long turn that kept running during the app's absence (testers on 1.3 watched the
/// app freeze and quit). Socket events arrive at a chat in batches, each run of reply text merged
/// into a single piece. The history inside a snapshot becomes rows away from the main actor, with
/// events that show up in the meantime queued, and the transcript cache is saved on a background thread.
@MainActor @Suite struct ReturningToALongTurnTests {
    private func openChat() throws -> ChatSession { try ChatFixtures.chat(named: "long-turn") }

    private func ev(_ type: String, session: String = "s1", _ fields: [String: JSONValue] = [:], seq: Int? = nil) -> GatewayEvent {
        var event = GatewayEvent(type: type, sessionID: session, payload: .object(fields))
        event.seq = seq
        return event
    }

    private func delta(_ words: String, session: String = "s1") -> GatewayEvent { ev("message.delta", session: session, ["text": .string(words)]) }
    private func words(_ event: GatewayEvent) -> String? { event.payload["text"]?.stringValue }

    // MARK: text merging

    @Test func aRunOfReplyTextBecomesOnePieceInOrder() {
        let batch = [ev("message.start"),
                     ev("message.delta", ["text": "Go"], seq: 1),
                     ev("message.delta", ["text": "od e"], seq: 2),
                     ev("message.delta", ["text": "vening"], seq: 3),
                     ev("tool.start", ["tool_id": "t1", "name": "terminal"]),
                     ev("message.delta", ["text": "later"], seq: 5)]
        let joined = GatewayEvent.coalescingText(batch)
        #expect(joined.map(\.type) == ["message.start", "message.delta", "tool.start", "message.delta"])
        #expect(words(joined[1]) == "Good evening")
        #expect(joined[1].seq == 3, "the piece carries the last sequence number")
        #expect(words(joined[3]) == "later")
    }

    @Test func runsAreNotJoinedAcrossSessionsOrKinds() {
        let batch = [delta("1", session: "a"), delta("2", session: "b"), delta("3", session: "b"),
                     ev("reasoning.delta", session: "b", ["text": "x"]), ev("reasoning.delta", session: "b", ["text": "y"]),
                     delta("4", session: "a")]
        let joined = GatewayEvent.coalescingText(batch)
        #expect(joined.map(\.sessionID) == ["a", "b", "b", "a"])
        #expect(joined.map(\.type) == ["message.delta", "message.delta", "reasoning.delta", "message.delta"])
        #expect(joined.compactMap(words) == ["1", "23", "xy", "4"])
    }

    @Test func theFirstPieceKeepsItsOtherFields() {
        let joined = GatewayEvent.coalescingText([ev("message.delta", ["text": "p", "kind": "marker"]), delta("q")])
        #expect(joined.count == 1)
        #expect(joined[0].payload["kind"]?.stringValue == "marker")
        #expect(words(joined[0]) == "pq")
    }

    @Test func aBatchRefreshesEachListOnlyOnce() {
        let batch = [ev("sessions.changed", session: ""), delta("a"), ev("sessions.changed", session: ""),
                     ev("projects.changed", session: ""), ev("tool.start", ["tool_id": "t"]), ev("sessions.changed", session: "")]
        let thinned = GatewayEvent.droppingRepeatedRefreshes(batch)
        #expect(thinned.map(\.type) == ["message.delta", "projects.changed", "tool.start", "sessions.changed"])
        let alone = [delta("a")]
        #expect(GatewayEvent.droppingRepeatedRefreshes(alone) == alone)
    }

    @Test func aBatchThatWasTakenTakesNoMore() {
        let batch = GatewayEventBatch()
        #expect(batch.add(delta("a")) && batch.add(delta("b")))
        #expect(batch.take().count == 2)
        #expect(!batch.add(delta("c")), "once the app has taken a batch it is closed")
        #expect(batch.take().isEmpty)
    }

    @Test func aJoinedBatchStreamsTheSameReplyAsPiecesOneByOne() throws {
        let piecemeal = try openChat(), joined = try openChat()
        let pieces = (0..<1000).map { "term\($0) " }
        let all = [ev("message.start")] + pieces.map { delta($0) } + [ev("message.complete", ["text": .string(pieces.joined())])]
        all.forEach { piecemeal.handle(event: $0) }

        let merged = GatewayEvent.coalescingText(all)
        #expect(merged.count == 3)
        merged.forEach { joined.handle(event: $0) }

        func finished(_ chat: ChatSession) -> String? {
            chat.items.compactMap { item -> String? in
                if case .assistant(let text, _, false) = item.kind { return text } else { return nil }
            }.last
        }
        #expect(finished(piecemeal) == pieces.joined())
        #expect(finished(joined) == finished(piecemeal))
    }

    @Test func theLongerTheReplyTheLessOftenItRedraws() {
        // Short replies redraw about 25 times a second; long ones cost more per redraw, so at most 4.
        let expected: [(Int, Duration)] = [(0, .milliseconds(40)), (4_000, .milliseconds(40)), (16_384, .milliseconds(128)),
                                           (60_000, .milliseconds(250)), (5_000_000, .milliseconds(250))]
        for (size, interval) in expected { #expect(ChatSession.streamingInterval(utf8Count: size) == interval, "at \(size) bytes") }
    }

    @Test func whileAwayTheReplyGathersAndIsDrawnOnReturn() async throws {
        let chat = try openChat()
        chat.runtime.isAway = true
        chat.handle(event: ev("message.start"))
        chat.handle(event: delta("Before the tool. "))
        chat.handle(event: ev("tool.start", ["tool_id": "t1", "name": "terminal"]))
        chat.handle(event: delta("After "))
        chat.handle(event: delta("the tool."))
        try await Task.sleep(for: .milliseconds(200))
        func shown() -> [String] { chat.items.compactMap { if case .assistant(let text, _, _) = $0.kind { return text }; return nil } }
        // A tool call still closes off what was said earlier, but the live row isn't redrawn.
        #expect(shown() == ["Before the tool. ", ""], "the streaming row was redrawn during the absence")

        chat.cameBack()
        #expect(shown() == ["Before the tool. ", "After the tool."])

        chat.runtime.isAway = false
        chat.handle(event: delta(" And more."))
        // Redrawing picks up within a few frames; on a busy test run, wait for that rather than a set delay.
        for _ in 0..<40 where shown().last != "After the tool. And more." { try await Task.sleep(for: .milliseconds(50)) }
        #expect(shown().last == "After the tool. And more.")
    }

    // MARK: snapshots of history

    /// A long chat made of `exchanges` rounds of prompt, tool call and reply, plus a turn still in
    /// progress whose reply has begun.
    private func longSnapshot(exchanges: Int, streaming: String = "First half") -> JSONValue {
        let now = Date().timeIntervalSince1970
        let begin = now - Double(exchanges) * 60
        func row(_ fields: [String: JSONValue]) -> JSONValue { .object(fields) }
        let messages: [JSONValue] = (0..<exchanges).flatMap { n -> [JSONValue] in
            let at = begin + Double(n) * 60
            let padding = String(repeating: "dolor sit ", count: 30)
            return [
                row(["role": "user", "text": .string("Ask \(n)"), "timestamp": .number(at), "row_id": .number(Double(3 * n + 1))]),
                row(["role": "tool", "name": "terminal", "context": .string("ls /data/\(n)"), "timestamp": .number(at + 5)]),
                row(["role": "assistant", "text": .string("Reply \(n): " + padding), "timestamp": .number(at + 10), "row_id": .number(Double(3 * n + 3))]),
            ]
        }
        let header: [String: JSONValue] = ["session_id": "s1", "stored_session_id": "stored-1", "running": true, "turn_started_at": .number(now - 5)]
        let live: JSONValue = .object(["user": "Next ask", "assistant": .string(streaming), "streaming": true])
        return .object(header.merging(["messages": .array(messages), "info": .object(["title": "A very long chat", "running": true]), "inflight": live]) { $1 })
    }

    @Test func snapshotRowsFollowTheHistoryAndKeepShownIDs() {
        let snapshot = longSnapshot(exchanges: 50)
        func rowsFor(_ shown: [TranscriptItem]) -> (built: [TranscriptItem], paired: [TranscriptItem]) {
            ChatSession.snapshotRows(snapshot, running: true, shown: shown, streamingID: nil)
        }
        let rows = rowsFor([])
        #expect(rows.built.count == 3 * 50)
        #expect(rows.paired.map(\.id) == rows.built.map(\.id))
        guard case .user(let firstPrompt, _) = rows.built.first?.kind else { Issue.record("the first row is not a prompt"); return }
        #expect(firstPrompt == "Ask 0")

        // Visible rows retain their ids as long as the snapshot restates them unchanged.
        var onScreen = rows.built
        onScreen[0].id = "on-screen-first"
        #expect(rowsFor(onScreen).paired.first?.id == "on-screen-first")
    }

    @Test func aSnapshotLandsWithTheTurnStillRunning() async throws {
        let chat = try openChat()
        await chat.apply(snapshot: longSnapshot(exchanges: 20))
        #expect(chat.isRunning)
        #expect(chat.title == "A very long chat")
        // 20 rounds of three rows each, the prompt in flight, then its streaming reply.
        #expect(chat.items.count == 62)
        guard case .assistant(let text, _, true) = chat.items.last?.kind else { Issue.record("no streaming reply last"); return }
        #expect(text == "First half")
        #expect(!chat.isBuildingSnapshot)
    }

    /// Events arriving during the row build are applied after it, in order. If they were applied
    /// first, the snapshot would erase them.
    @Test func eventsThatArriveMidSnapshotComeAfterIt() async throws {
        let chat = try openChat()
        let huge = longSnapshot(exchanges: 3000)
        let landing = Task { await chat.apply(snapshot: huge) }
        var spins = 0
        while !chat.isBuildingSnapshot, spins < 200 { await Task.yield(); spins += 1 }
        try #require(chat.isBuildingSnapshot, "the snapshot finished before an event could arrive")

        chat.handle(event: ev("tool.start", ["tool_id": "t-late", "name": "terminal", "context": "uptime"]))
        chat.handle(event: ev("tool.complete", ["tool_id": "t-late", "name": "terminal", "summary": "up 9 days"]))
        #expect(!chat.items.contains { $0.id == "tool-t-late" }, "held back until the rows are in")

        await landing.value
        #expect(!chat.isBuildingSnapshot)
        guard let last = chat.items.last, last.id == "tool-t-late", case .tool(let activity) = last.kind else {
            Issue.record("the event from mid-snapshot is not the last row"); return
        }
        #expect(activity.status == .done)
        #expect(activity.summary == "up 9 days")
        guard case .assistant(let text, _, _) = chat.items[chat.items.count - 2].kind else { Issue.record("the streaming reply is gone"); return }
        #expect(text == "First half", "the reply being streamed sits just above the tool call")
    }

    // MARK: transcript cache

    @Test func theTranscriptCacheIsWrittenInTheBackgroundAndReadsBack() throws {
        let link = UUID()
        let rows = (0..<300).map { TestRows.user("row\($0)", "message \($0)") }
        defer {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            if let folder = caches?.appending(path: "transcripts/\(link.uuidString)") { try? FileManager.default.removeItem(at: folder) }
        }
        TranscriptCache.save(rows, connection: link, storedID: "cache-check")
        TranscriptCache.flush()
        let loaded = try #require(TranscriptCache.load(connection: link, storedID: "cache-check"))
        // Only the newest 200 are kept.
        #expect(loaded.count == 200)
        #expect(loaded.first?.text == "message 100")
        #expect(loaded.last?.text == "message 299")
    }
}
