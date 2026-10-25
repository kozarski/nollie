import Foundation
import Testing
@testable import NollieCore

// The conversation reducer, fed frames as Hermes sends them. See Docs/specs/conversation-engine.md.

private let crRuntime = "rt-1"

/// Event frames written the way they come off the socket, one JSON-RPC message per line, read back through the
/// client's own frame reader so the reducer sees exactly what the client would hand it.
private func crFrames(_ lines: String) -> [ConversationInput] {
    lines.split(separator: "\n").flatMap { line -> [ConversationInput] in
        GatewayFrame.read(String(line)).compactMap { frame in
            if case .event(let event) = frame { return .event(event) }
            if case .question(let question) = frame { return .question(question) }
            return nil
        }
    }
}

private func crEvent(_ type: String, seq: Int? = nil, _ payload: GatewayJSON = [:], session: String = crRuntime) -> ConversationInput {
    .event(GatewayEventEnvelope(type: type, sessionId: session, seq: seq, payload: payload))
}

/// A chat attached to `tip` and idle.
private func crAttached(tip: String = "s0") -> ConversationState {
    ConversationReducer.reduce(ConversationState(lineage: ConversationLineage(tip: tip)),
                               .attached(ConversationSnapshot(runtimeSession: crRuntime, storedSession: tip), held: [], requestedAt: 0, full: false))
}

/// The person sends `text` and Hermes takes it as stored row `row`.
private func crSent(_ state: ConversationState, _ text: String, row: Int?) -> ConversationState {
    var next = ConversationReducer.reduce(state, .compose(text: text))
    let id = next.outbox.entries.last!.id
    next = ConversationReducer.reduce(next, [.sendStarted(id: id), .sendFinished(id: id, .accepted(userRowId: row))])
    return next
}

private func crSummaries(_ state: ConversationState) -> [ConversationNote] {
    state.rows.compactMap { if case .note(let note) = $0.kind, case .summarized = note { note } else { nil } }
}

private func crReplies(_ state: ConversationState) -> [ConversationReply] { state.rows.compactMap(\.reply) }

@Suite struct ConversationReducerStreamingTests {
    @Test func aStreamedTurnBecomesOneUserRowAndOneFinishedReply() throws {
        var state = crSent(crAttached(), "What is on the log host?", row: 41)
        #expect(state.running)
        #expect(state.activity == .thinking)
        state = ConversationReducer.reduce(state, crFrames("""
        {"jsonrpc":"2.0","method":"event","params":{"type":"message.start","session_id":"rt-1","seq":1}}
        {"jsonrpc":"2.0","method":"event","params":{"type":"reasoning.delta","session_id":"rt-1","seq":2,"payload":{"text":"Check disk first."}}}
        {"jsonrpc":"2.0","method":"event","params":{"type":"message.delta","session_id":"rt-1","seq":3,"payload":{"text":"The disk is "}}}
        {"jsonrpc":"2.0","method":"event","params":{"type":"message.delta","session_id":"rt-1","seq":4,"payload":{"text":"94% full."}}}
        """))
        #expect(state.activity == .writing)
        let streaming = try #require(crReplies(state).last)
        #expect(streaming.streaming)
        #expect(streaming.text == "The disk is 94% full.")
        #expect(streaming.reasoning == "Check disk first.")

        state = ConversationReducer.reduce(state, crFrames("""
        {"jsonrpc":"2.0","method":"event","params":{"type":"message.complete","session_id":"rt-1","seq":5,"payload":{"text":"The disk is 94% full.","status":"complete","persisted_turn":{"row_ids":[41,42],"complete":true,"user_row_id":41,"final_assistant_row_id":42}}}}
        """))
        #expect(!state.running)
        #expect(state.activity == .idle)
        #expect(state.rows.count == 2)
        #expect(state.rows[0].kind == .user(text: "What is on the log host?", delivery: .sent))
        #expect(state.rows[0].address == ConversationRowAddress(segment: "s0", rowId: 41))
        let reply = try #require(state.rows[1].reply)
        #expect(!reply.streaming)
        #expect(reply.ending == .complete)
        #expect(state.rows[1].address == ConversationRowAddress(segment: "s0", rowId: 42))
        #expect(state.settledTurns == [state.turn])
        #expect(state.outbox.entries.isEmpty)
    }

    @Test func theCompletedTextWinsOverWhatStreamed() {
        var state = crSent(crAttached(), "hi", row: nil)
        state = ConversationReducer.reduce(state, [
            crEvent("message.delta", seq: 1, ["text": "Hel"]),
            crEvent("message.complete", seq: 2, ["text": "Hello there.", "status": "complete"]),
        ])
        #expect(crReplies(state).map(\.text) == ["Hello there."])
    }

    @Test func aReplyThatNeverStreamedStillShows() {
        var state = crSent(crAttached(), "hi", row: nil)
        state = ConversationReducer.reduce(state, crEvent("message.complete", seq: 1, ["text": [["type": "text", "text": "Hi!"]], "status": "complete"]))
        #expect(crReplies(state).map(\.text) == ["Hi!"])
    }

    @Test func interimRepliesFinishOrAddRows() {
        var state = crSent(crAttached(), "go", row: nil)
        state = ConversationReducer.reduce(state, [
            crEvent("message.delta", seq: 1, ["text": "First part"]),
            crEvent("message.interim", seq: 2, ["text": "First part.", "already_streamed": true]),
            crEvent("message.interim", seq: 3, ["text": "A note in between.", "already_streamed": false]),
            crEvent("message.delta", seq: 4, ["text": "Last part."]),
            crEvent("message.complete", seq: 5, ["text": "Last part.", "status": "complete"]),
        ])
        #expect(crReplies(state).map(\.text) == ["First part.", "A note in between.", "Last part."])
        #expect(crReplies(state).allSatisfy { !$0.streaming })
    }

    @Test func repeatedAndForeignEventsChangeNothing() {
        let base = crSent(crAttached(), "hi", row: nil)
        let once = ConversationReducer.reduce(base, [crEvent("message.delta", seq: 1, ["text": "A"]), crEvent("message.delta", seq: 2, ["text": "B"])])
        let again = ConversationReducer.reduce(once, [
            crEvent("message.delta", seq: 2, ["text": "B"]),
            crEvent("message.delta", seq: 1, ["text": "A"]),
            crEvent("message.delta", seq: 9, ["text": "other chat"], session: "rt-other"),
            crEvent("message.delta", seq: 3, ["text": "app level"], session: ""),
        ])
        #expect(crReplies(again).map(\.text) == ["AB"])
        #expect(again.rows == once.rows)
    }

    @Test func theSameInputsAlwaysGiveTheSameState() {
        let inputs: [ConversationInput] = [
            .compose(text: "one"), .sendStarted(id: "out-1"), .sendFinished(id: "out-1", .accepted(userRowId: 7)),
            crEvent("message.start", seq: 1), crEvent("tool.start", seq: 2, ["tool_id": "t1", "name": "terminal"]),
            crEvent("tool.complete", seq: 3, ["tool_id": "t1", "name": "terminal", "summary": "ok"]),
            crEvent("message.delta", seq: 4, ["text": "done"]), crEvent("message.complete", seq: 5, ["text": "done", "status": "complete"]),
        ]
        let first = ConversationReducer.reduce(crAttached(), inputs)
        let second = ConversationReducer.reduce(crAttached(), inputs)
        #expect(first == second)
        #expect(first.rows.map(\.id) == second.rows.map(\.id))
    }

    @Test func aRestartedNumberingIsTakenAfterAReset() {
        var state = crSent(crAttached(), "hi", row: nil)
        state = ConversationReducer.reduce(state, crEvent("message.delta", seq: 40, ["text": "before "]))
        // Hermes restarted: the client says reload, and the numbering starts over at 1.
        state = ConversationReducer.reduce(state, [.reset(session: crRuntime), crEvent("message.delta", seq: 1, ["text": "after"])])
        #expect(crReplies(state).map(\.text) == ["before after"])
        #expect(state.needsAttach)
    }
}

@Suite struct ConversationReducerToolTests {
    @Test func toolsSplitTheReplyIntoRowsInOrder() throws {
        var state = crSent(crAttached(), "Check the disk", row: nil)
        state = ConversationReducer.reduce(state, crFrames("""
        {"jsonrpc":"2.0","method":"event","params":{"type":"message.delta","session_id":"rt-1","seq":1,"payload":{"text":"Let me look."}}}
        {"jsonrpc":"2.0","method":"event","params":{"type":"tool.generating","session_id":"rt-1","seq":2,"payload":{"name":"terminal"}}}
        {"jsonrpc":"2.0","method":"event","params":{"type":"tool.start","session_id":"rt-1","seq":3,"payload":{"tool_id":"call-1","name":"terminal","context":"df -h"}}}
        """))
        #expect(state.activity == .runningTool("terminal"))
        state = ConversationReducer.reduce(state, crFrames("""
        {"jsonrpc":"2.0","method":"event","params":{"type":"tool.complete","session_id":"rt-1","seq":4,"payload":{"tool_id":"call-1","name":"terminal","summary":"41G used","result_text":"/var/log 41G","duration_s":1.5}}}
        {"jsonrpc":"2.0","method":"event","params":{"type":"tool.start","session_id":"rt-1","seq":5,"payload":{"tool_id":"call-2","name":"read_file","args":{"path":"/etc/logrotate.d/nginx"}}}}
        {"jsonrpc":"2.0","method":"event","params":{"type":"tool.complete","session_id":"rt-1","seq":6,"payload":{"tool_id":"call-2","name":"read_file","result":"rotate 52"}}}
        {"jsonrpc":"2.0","method":"event","params":{"type":"message.delta","session_id":"rt-1","seq":7,"payload":{"text":"Rotate weekly."}}}
        {"jsonrpc":"2.0","method":"event","params":{"type":"message.complete","session_id":"rt-1","seq":8,"payload":{"text":"Rotate weekly.","status":"complete"}}}
        """))
        let kinds = state.rows.map { row -> String in
            switch row.kind {
            case .user: "user"
            case .assistant(let reply): "reply:\(reply.text)"
            case .tool(let step): "tool:\(step.name):\(step.done)"
            case .note: "note"
            case .error: "error"
            case .post: "post"
            }
        }
        #expect(kinds == ["user", "reply:Let me look.", "tool:terminal:true", "tool:read_file:true", "reply:Rotate weekly."])
        guard case .tool(let first) = state.rows[2].kind, case .tool(let second) = state.rows[3].kind else {
            Issue.record("no tool rows")
            return
        }
        #expect(first.context == "df -h")
        #expect(first.summary == "41G used")
        #expect(first.resultText == "/var/log 41G")
        #expect(first.seconds == 1.5)
        #expect(second.resultText == "rotate 52")
        #expect(second.argumentsText?.contains("logrotate") == true)
        #expect(state.rows[2].id == "tool:call-1")
    }

    @Test func aToolRightAfterTheStartLeavesNoEmptyReply() {
        var state = crSent(crAttached(), "go", row: nil)
        state = ConversationReducer.reduce(state, [
            crEvent("message.start", seq: 1), crEvent("thinking.delta", seq: 2, ["text": "waiting"]),
            crEvent("tool.start", seq: 3, ["tool_id": "t1", "name": "terminal"]),
        ])
        #expect(crReplies(state).isEmpty)
        #expect(state.rows.count == 2)
    }

    @Test func aRepeatedToolStartUpdatesItsRow() {
        var state = crSent(crAttached(), "go", row: nil)
        state = ConversationReducer.reduce(state, [
            crEvent("tool.start", seq: 1, ["tool_id": "t1", "name": "terminal"]),
            crEvent("tool.start", seq: 2, ["tool_id": "t1", "name": "terminal", "context": "ls"]),
        ])
        #expect(state.rows.filter { if case .tool = $0.kind { true } else { false } }.count == 1)
    }
}

@Suite struct ConversationReducerCardTests {
    private func approval(_ id: String, request: String) -> ConversationInput {
        .question(GatewayIncomingQuestion(id: id, method: "approval", params: [
            "session_id": .string(crRuntime), "request_id": .string(request), "command": "rm -rf build",
            "description": "clean the build folder", "choices": ["once", "session", "deny"],
        ]))
    }

    @Test func approvalsShowAndGoTheRightWay() throws {
        var state = crSent(crAttached(), "clean up", row: nil)
        state = ConversationReducer.reduce(state, [approval("srq-1", request: "r1"), approval("srq-1", request: "r1")])
        #expect(state.cards.count == 1)
        let card = try #require(state.cards.first)
        #expect(card.kind == .approval(requestId: "r1", command: "rm -rf build", description: "clean the build folder",
                                       choices: ["once", "session", "deny"]))

        state = ConversationReducer.reduce(state, .answered(cardId: "srq-1", choice: "once"))
        #expect(state.cards.isEmpty)
        #expect(state.rows.last?.note == .answered(choice: "once"))

        state = ConversationReducer.reduce(state, [approval("srq-2", request: "r2"),
                                                   crEvent("request.cancel", seq: 1, ["id": "srq-2", "method": "approval", "reason": "timeout"])])
        #expect(state.cards.isEmpty)
        #expect(state.rows.last?.note == .withdrawn)

        state = ConversationReducer.reduce(state, [approval("srq-3", request: "r3"),
                                                   crEvent("message.complete", seq: 2, ["text": "Done.", "status": "complete"])])
        #expect(state.cards.isEmpty)
        #expect(state.rows.contains { $0.note == .answeredElsewhere })
    }

    @Test func clarifyAndValueQuestionsBecomeCards() {
        var state = crAttached()
        state = ConversationReducer.reduce(state, crFrames("""
        {"jsonrpc":"2.0","id":"srq-a","method":"clarify","params":{"session_id":"rt-1","questions":[{"qid":"q1","question":"Which host?","choices":["web","db"]}]}}
        {"jsonrpc":"2.0","id":"srq-b","method":"sudo","params":{"session_id":"rt-1","prompt":"Password for sudo"}}
        """))
        #expect(state.cards.map(\.kind) == [
            .clarify(questions: [ConversationCard.Question(id: "q1", text: "Which host?", choices: ["web", "db"])]),
            .value(prompt: "Password for sudo", secret: true),
        ])
    }

    @Test func aSnapshotTakesDownOnlyCardsItCouldHaveSeen() {
        var state = crSent(crAttached(), "go", row: nil)
        state = ConversationReducer.reduce(state, approval("srq-old", request: "r-old"))
        let askedAt = state.clock
        state = ConversationReducer.reduce(state, approval("srq-new", request: "r-new"))
        let snapshot = ConversationSnapshot(runtimeSession: crRuntime, storedSession: "s0", running: true,
                                            openRequests: [GatewayIncomingQuestion(id: "srq-listed", method: "approval",
                                                                                   params: ["session_id": .string(crRuntime), "request_id": "r-l"])])
        state = ConversationReducer.reduce(state, .attached(snapshot, held: [], requestedAt: askedAt, full: false))
        #expect(state.cards.map(\.id) == ["srq-new", "srq-listed"])
    }

    @Test func theApprovalQueueCardGivesWayToTheRequest() {
        var state = crAttached()
        let snapshot = ConversationSnapshot(runtimeSession: crRuntime, running: true,
                                            pendingApproval: .init(requestId: "r9", command: "reboot", description: nil, choices: ["once", "deny"]))
        state = ConversationReducer.reduce(state, .attached(snapshot, held: [], requestedAt: state.clock, full: false))
        #expect(state.cards.map(\.id) == ["queue-r9"])
        #expect(state.cards.first?.viaApprovalQueue == true)
        state = ConversationReducer.reduce(state, approval("srq-9", request: "r9"))
        #expect(state.cards.map(\.id) == ["srq-9"])
    }
}

@Suite struct ConversationReducerCompressionTests {
    /// The order Hermes uses: progress lines, the "start over" advice, the new stored id, then done.
    private let compressingTurn = """
    {"jsonrpc":"2.0","method":"event","params":{"type":"message.start","session_id":"rt-1","seq":1}}
    {"jsonrpc":"2.0","method":"event","params":{"type":"status.update","session_id":"rt-1","seq":2,"payload":{"kind":"compacting","text":"Compacting context, summarizing earlier conversation so I can continue..."}}}
    {"jsonrpc":"2.0","method":"event","params":{"type":"status.update","session_id":"rt-1","seq":3,"payload":{"kind":"compacting","text":"Compacting context, still summarizing earlier conversation so I can continue..."}}}
    {"jsonrpc":"2.0","method":"event","params":{"type":"status.update","session_id":"rt-1","seq":4,"payload":{"kind":"lifecycle","text":"Session compressed 3 times, accuracy may degrade. Consider /new to start fresh."}}}
    {"jsonrpc":"2.0","method":"event","params":{"type":"session.info","session_id":"rt-1","seq":5,"payload":{"stored_session_id":"s1","title":"Bot Chat","running":true}}}
    {"jsonrpc":"2.0","method":"event","params":{"type":"status.update","session_id":"rt-1","seq":6,"payload":{"kind":"compacted","text":"Context compaction complete, continuing turn..."}}}
    {"jsonrpc":"2.0","method":"event","params":{"type":"message.delta","session_id":"rt-1","seq":7,"payload":{"text":"Still here."}}}
    {"jsonrpc":"2.0","method":"event","params":{"type":"message.complete","session_id":"rt-1","seq":8,"payload":{"text":"Still here.","status":"complete","warning":"Session compressed 3 times, accuracy may degrade. Consider /new to start fresh."}}}
    """

    @Test func compressionMovesTheTipWithExactlyOneQuietRow() {
        var state = crSent(crAttached(), "Carry on", row: nil)
        let frames = crFrames(compressingTurn)
        state = ConversationReducer.reduce(state, Array(frames.prefix(3)))
        #expect(state.activity == .summarizing)
        state = ConversationReducer.reduce(state, Array(frames.dropFirst(3)))
        #expect(state.lineage.segments == ["s0", "s1"])
        #expect(state.lineage.tip == "s1")
        #expect(crSummaries(state) == [.summarized(into: "s1")])
        #expect(state.notice == nil, "the advice to start over is never shown")
        #expect(!state.rows.contains { if case .note(.notice(let text)) = $0.kind { text.contains("/new") } else { false } })
        // The note sits before the reply, in the order it happened.
        let noteIndex = state.rows.firstIndex { $0.note == .summarized(into: "s1") }
        let replyIndex = state.rows.firstIndex { $0.reply != nil }
        #expect(noteIndex != nil && replyIndex != nil && noteIndex! < replyIndex!)
    }

    @Test func theNewIdBeforeTheProgressLinesStillGivesOneRow() {
        var state = crSent(crAttached(), "Carry on", row: nil)
        state = ConversationReducer.reduce(state, [
            crEvent("session.info", seq: 1, ["stored_session_id": "s1"]),
            crEvent("status.update", seq: 2, ["kind": "compacted", "text": "done"]),
            crEvent("session.info", seq: 3, ["stored_session_id": "s1"]),
            crEvent("message.complete", seq: 4, ["text": "ok", "status": "complete"]),
        ])
        #expect(crSummaries(state) == [.summarized(into: "s1")])
    }

    @Test func twoCompressionsInOneTurnGiveTwoRows() {
        var state = crSent(crAttached(), "Long job", row: nil)
        state = ConversationReducer.reduce(state, [
            crEvent("status.update", seq: 1, ["kind": "compacting", "text": "Compacting context"]),
            crEvent("session.info", seq: 2, ["stored_session_id": "s1"]),
            crEvent("tool.start", seq: 3, ["tool_id": "t1", "name": "terminal"]),
            crEvent("status.update", seq: 4, ["kind": "compacting", "text": "Compacting context"]),
            crEvent("session.info", seq: 5, ["stored_session_id": "s2"]),
            crEvent("message.complete", seq: 6, ["text": "ok", "status": "complete"]),
        ])
        #expect(crSummaries(state) == [.summarized(into: "s1"), .summarized(into: "s2")])
        #expect(state.lineage.segments == ["s0", "s1", "s2"])
    }

    @Test func aLateOrRepeatedIdNeverMovesTheTipBack() {
        var state = crAttached()
        state = ConversationReducer.reduce(state, [
            crEvent("session.info", seq: 1, ["stored_session_id": "s1"]),
            crEvent("session.info", seq: 2, ["stored_session_id": "s0"]),
        ])
        #expect(state.lineage.tip == "s1")
        #expect(crSummaries(state).count == 1)
    }

    @Test func aWarningThatIsNotAboutCompressionIsKept() {
        var state = crSent(crAttached(), "hi", row: nil)
        state = ConversationReducer.reduce(state, crEvent("message.complete", seq: 1, ["text": "ok", "status": "complete", "warning": "Model credits are low."]))
        #expect(state.notice == "Model credits are low.")
    }
}

@Suite struct ConversationReducerErrorTests {
    @Test func anErrorEventSealsTheReplyAndEndsTheTurn() {
        var state = crSent(crAttached(), "hi", row: nil)
        state = ConversationReducer.reduce(state, [
            crEvent("message.delta", seq: 1, ["text": "Partial"]),
            crEvent("error", seq: 2, ["message": "The model provider is down."]),
        ])
        #expect(!state.running)
        #expect(crReplies(state).first?.ending == .error)
        #expect(crReplies(state).first?.streaming == false)
        #expect(state.rows.last?.kind == .error("The model provider is down."))
    }

    @Test func aCompletionWithAnErrorAddsOneErrorRow() {
        var state = crSent(crAttached(), "hi", row: nil)
        state = ConversationReducer.reduce(state, crEvent("message.complete", seq: 1, ["text": "", "status": "error", "error": "Context too long."]))
        #expect(state.rows.compactMap { if case .error(let text) = $0.kind { text } else { nil } } == ["Context too long."])
        #expect(crReplies(state).isEmpty)
        #expect(state.settledTurns.isEmpty)
    }

    @Test func anInterruptedTurnSaysSo() {
        var state = crSent(crAttached(), "hi", row: nil)
        state = ConversationReducer.reduce(state, [
            crEvent("message.delta", seq: 1, ["text": "Working on"]),
            crEvent("message.complete", seq: 2, ["text": "Working on", "status": "interrupted"]),
        ])
        #expect(crReplies(state).first?.ending == .interrupted)
        #expect(state.rows.last?.note == .interrupted)
    }

    @Test func aReclaimedSessionAsksForAFreshAttach() {
        var state = crSent(crAttached(), "hi", row: nil)
        state = ConversationReducer.reduce(state, crEvent("session.reclaimed", seq: 1, ["session_id": "rt-1", "stored_session_id": "s0", "reason": "idle"]))
        #expect(!state.running)
        #expect(state.needsAttach)
    }
}

@Suite struct ConversationReducerSnapshotTests {
    @Test func heldDeltasTheSnapshotAlreadyHasAreSkipped() {
        var state = crSent(crAttached(), "Tell me", row: nil)
        state = ConversationReducer.reduce(state, crEvent("message.delta", seq: 1, ["text": "Hel"]))
        let snapshot = ConversationSnapshot(runtimeSession: crRuntime, storedSession: "s0", running: true,
                                            inflightUser: "Tell me", inflightReply: "Hello wor")
        let held = [GatewayEventEnvelope(type: "message.delta", sessionId: crRuntime, seq: 2, payload: ["text": "lo"]),
                    GatewayEventEnvelope(type: "message.delta", sessionId: crRuntime, seq: 3, payload: ["text": " wor"]),
                    GatewayEventEnvelope(type: "message.delta", sessionId: crRuntime, seq: 4, payload: ["text": "ld"])]
        state = ConversationReducer.reduce(state, .attached(snapshot, held: held, requestedAt: state.clock, full: false))
        #expect(crReplies(state).map(\.text) == ["Hello world"])
        #expect(state.rows.filter { $0.userText != nil }.count == 1)
        #expect(state.watermarks[crRuntime] == 4)
    }

    @Test func aTurnSentElsewhereGetsItsPromptFromTheSnapshot() {
        var state = crAttached()
        state = ConversationReducer.reduce(state, [crEvent("message.start", seq: 1), crEvent("message.delta", seq: 2, ["text": "Sure"])])
        #expect(state.turnNeedsPrompt)
        let snapshot = ConversationSnapshot(runtimeSession: crRuntime, running: true, inflightUser: "From the Mac", inflightReply: "Sure")
        state = ConversationReducer.reduce(state, .attached(snapshot, held: [], requestedAt: state.clock, full: false))
        #expect(!state.turnNeedsPrompt)
        #expect(state.rows.map(\.userText) == ["From the Mac", nil])
    }

    @Test func aFullSnapshotDropsEndedTurnsButKeepsSendsInDoubt() {
        var state = crSent(crAttached(), "first", row: 1)
        state = ConversationReducer.reduce(state, crEvent("message.complete", seq: 1, ["text": "One.", "status": "complete"]))
        state = ConversationReducer.reduce(state, .compose(text: "second"))
        let id = state.outbox.entries.last!.id
        state = ConversationReducer.reduce(state, [.sendStarted(id: id), .sendFinished(id: id, .uncertain)])
        let snapshot = ConversationSnapshot(runtimeSession: "rt-2", storedSession: "s0", running: false)
        state = ConversationReducer.reduce(state, .attached(snapshot, held: [], requestedAt: state.clock, full: true))
        #expect(state.rows.map(\.kind) == [.user(text: "second", delivery: .uncertain)])
        #expect(state.runtimeSession == "rt-2")
        #expect(state.watermarks["rt-1"] == nil)
    }
}
