import Foundation
import Testing
@testable import NollieCore

// MARK: - Helpers shared by the suites in this file

/// One JSON value as the text of one WebSocket message.
private func gwctText(_ json: GatewayJSON) -> String {
    String(decoding: (try? json.encoded()) ?? Data(), as: UTF8.self)
}

private func gwctParse(_ text: String) -> GatewayJSON? {
    try? GatewayJSON.parse(Data(text.utf8))
}

private func gwctQuestionFrame(id: String, method: String, session: String = "s1") -> String {
    gwctText(["jsonrpc": "2.0", "id": .string(id), "method": .string(method), "params": ["session_id": .string(session)]])
}

private func gwctEventFrame(type: String, session: String = "", seq: Int? = nil, payload: GatewayJSON? = nil) -> String {
    var params: [String: GatewayJSON] = ["type": .string(type), "session_id": .string(session)]
    if let seq { params["seq"] = .integer(seq) }
    if let payload { params["payload"] = payload }
    return gwctText(["jsonrpc": "2.0", "method": "event", "params": .object(params)])
}

/// The Nollie Link door's rule for a frame without a method (`LinkDoorRPC.decide` in
/// `Services/Runtime/LinkDoorWebSocket.swift`): a string id, exactly one of result or error, and no other keys.
/// Written again here because that file builds only for the Mac.
private func gwctDoorForwardsAnswer(_ text: String) -> Bool {
    guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return false }
    guard object["method"] == nil else { return false }
    let answers = (object["result"] != nil) != (object["error"] != nil)
    return object["id"] is String && answers && Set(object.keys).isSubset(of: ["jsonrpc", "id", "result", "error"])
}

private let gwctWindowMethods = ["preview.act", "preview.read", "terminal.read", "window.read", "tour", "theme.apply"]
private let gwctSecretMethods = ["sudo", "secret", "display.install.sudo", "vault.code", "vault.save_login", "vault.unlock_prompt"]
private let gwctUnknownMethods = ["setup_beat", "theme.pick", "kanban.someday.new"]

/// Drives `GatewayMachine` by hand and keeps every effect it asked for.
private struct GWCTMachine {
    var machine: GatewayMachine
    var log: [GatewayMachine.Effect] = []

    init(_ configuration: GatewayConfiguration = GatewayConfiguration()) {
        machine = GatewayMachine(configuration: configuration)
    }

    var phase: GatewayPhase { machine.phase }

    /// The socket the machine most recently asked to open.
    var socket: Int {
        for effect in log.reversed() { if case .open(let number) = effect { return number } }
        return 0
    }

    @discardableResult
    mutating func feed(_ input: GatewayMachine.Input) -> [GatewayMachine.Effect] {
        let out = machine.handle(input)
        log += out
        return out
    }

    @discardableResult
    mutating func receive(_ text: String) -> [GatewayMachine.Effect] {
        feed(.received(socket: socket, text))
    }

    /// Fires the latest scheduled run of `timer`.
    @discardableResult
    mutating func fire(_ timer: GatewayTimer) -> [GatewayMachine.Effect] {
        for effect in log.reversed() {
            if case .schedule(timer, let generation, _) = effect { return feed(.timerFired(timer, generation: generation)) }
        }
        Issue.record("\(timer) was never scheduled")
        return []
    }

    /// The wire id of the latest call the machine sent for `method`.
    func lastCallId(_ method: String) -> Int? {
        for effect in log.reversed() {
            if case .send(_, let text) = effect, let frame = gwctParse(text), frame["method"]?.stringValue == method {
                return frame["id"]?.intValue
            }
        }
        return nil
    }

    /// Opens the socket the machine asked for and plays Hermes's side of the handshake. `declinesNotShown` nil
    /// leaves the flag out of the capabilities answer, as an older Hermes would.
    @discardableResult
    mutating func handshake(epoch: String = "e1", declinesNotShown: Bool? = true) -> [GatewayMachine.Effect] {
        var out = feed(.opened(socket: socket))
        out += receive(gwctEventFrame(type: "gateway.ready", payload: ["replay_epoch": .string(epoch)]))
        guard let id = lastCallId("client.capabilities") else {
            Issue.record("no client.capabilities call")
            return out
        }
        var answer: [String: GatewayJSON] = ["server_requests": .array(GatewayWire.Questions.all.map(GatewayJSON.string))]
        if let declinesNotShown { answer["declines_not_shown"] = .bool(declinesNotShown) }
        out += receive(gwctText(["jsonrpc": "2.0", "id": .integer(id), "result": .object(answer)]))
        return out
    }

    @discardableResult
    mutating func startReady(epoch: String = "e1", declinesNotShown: Bool? = true) -> [GatewayMachine.Effect] {
        var out = feed(.start)
        out += handshake(epoch: epoch, declinesNotShown: declinesNotShown)
        return out
    }
}

private func gwctSends(_ effects: [GatewayMachine.Effect]) -> [(socket: Int, text: String)] {
    effects.compactMap { if case .send(let socket, let text) = $0 { (socket, text) } else { nil } }
}

private func gwctQuestions(_ effects: [GatewayMachine.Effect]) -> [GatewayIncomingQuestion] {
    effects.compactMap { if case .question(let question) = $0 { question } else { nil } }
}

private func gwctWithdrawn(_ effects: [GatewayMachine.Effect]) -> [String] {
    effects.compactMap { if case .withdrawn(let id) = $0 { id } else { nil } }
}

// MARK: - Questions and declines

@Suite struct GatewayQuestionTests {
    /// Asks one question of a ready machine and returns the single reply it sent.
    private func declineReply(_ method: String, declinesNotShown: Bool?, id: String = "srq-1") throws -> (GatewayJSON, String) {
        var harness = GWCTMachine()
        harness.startReady(declinesNotShown: declinesNotShown)
        #expect(harness.phase == .ready)
        let out = harness.receive(gwctQuestionFrame(id: id, method: method))
        #expect(gwctQuestions(out).isEmpty, "\(method) was shown")
        let sends = gwctSends(out)
        try #require(sends.count == 1, "\(method) got \(sends.count) replies")
        #expect(sends[0].socket == harness.socket)
        return (try #require(gwctParse(sends[0].text)), sends[0].text)
    }

    @Test func shownQuestionsReachTheAppAndAreNotAnswered() {
        var harness = GWCTMachine()
        harness.startReady()
        let out = harness.receive(gwctText(["jsonrpc": "2.0", "id": "srq-a1", "method": "approval",
                                            "params": ["session_id": "s1", "command": "ls"]]))
        let questions = gwctQuestions(out)
        #expect(questions.count == 1)
        #expect(questions.first?.id == "srq-a1")
        #expect(questions.first?.method == "approval")
        #expect(questions.first?.sessionId == "s1")
        #expect(questions.first?.params["command"] == "ls")
        #expect(questions.first?.replayed == false)
        #expect(gwctSends(out).isEmpty)

        let clarify = harness.receive(gwctQuestionFrame(id: "srq-c1", method: "clarify"))
        #expect(gwctQuestions(clarify).map(\.id) == ["srq-c1"])
        #expect(gwctSends(clarify).isEmpty)
    }

    @Test(arguments: gwctWindowMethods)
    func windowQuestionsAreDeclinedAsNotShownWhenHermesUnderstands(method: String) throws {
        let (reply, text) = try declineReply(method, declinesNotShown: true)
        #expect(reply["error"]?["code"]?.intValue == 4404)
        #expect(reply["error"]?["message"]?.stringValue?.isEmpty == false)
        #expect(reply["id"] == "srq-1")
        #expect(reply["method"] == nil)
        #expect(reply["result"] == nil)
        #expect(gwctDoorForwardsAnswer(text))
    }

    @Test(arguments: gwctWindowMethods)
    func windowQuestionsGetUnknownMethodWhenHermesSaysNoToNotShown(method: String) throws {
        let (reply, text) = try declineReply(method, declinesNotShown: false)
        #expect(reply["error"]?["code"]?.intValue == -32601)
        #expect(reply["id"] == "srq-1")
        #expect(gwctDoorForwardsAnswer(text))
    }

    @Test func windowQuestionsGetUnknownMethodFromAnOlderHermes() throws {
        // No declines_not_shown in the capabilities answer at all.
        let (reply, text) = try declineReply("preview.act", declinesNotShown: nil)
        #expect(reply["error"]?["code"]?.intValue == -32601)
        #expect(gwctDoorForwardsAnswer(text))
    }

    @Test func windowQuestionsGetUnknownMethodWhenCapabilitiesIsRefused() throws {
        var harness = GWCTMachine()
        harness.feed(.start)
        harness.feed(.opened(socket: harness.socket))
        harness.receive(gwctEventFrame(type: "gateway.ready", payload: ["replay_epoch": "e1"]))
        let id = try #require(harness.lastCallId("client.capabilities"))
        harness.receive(gwctText(["jsonrpc": "2.0", "id": .integer(id), "error": ["code": -32601, "message": "unknown method"]]))
        #expect(harness.phase == .ready)
        let out = harness.receive(gwctQuestionFrame(id: "srq-w", method: "window.read"))
        let reply = try #require(gwctSends(out).first.flatMap { gwctParse($0.text) })
        #expect(reply["error"]?["code"]?.intValue == -32601)
    }

    @Test(arguments: gwctSecretMethods)
    func secretsAreAlwaysDeclinedAsUnknownMethod(method: String) throws {
        let (reply, text) = try declineReply(method, declinesNotShown: true, id: "srq-secret")
        #expect(reply["error"]?["code"]?.intValue == -32601)
        #expect(reply["id"] == "srq-secret")
        #expect(reply["method"] == nil)
        #expect(gwctDoorForwardsAnswer(text))
    }

    @Test(arguments: gwctUnknownMethods)
    func unregisteredQuestionsAreDeclinedAsUnknownMethod(method: String) throws {
        let (reply, text) = try declineReply(method, declinesNotShown: true)
        #expect(reply["error"]?["code"]?.intValue == -32601)
        #expect(gwctDoorForwardsAnswer(text))
    }

    @Test func theAppDecidesWhichQuestionsItShows() throws {
        var configuration = GatewayConfiguration()
        configuration.shownQuestions = ["approval", "theme.pick"]
        var harness = GWCTMachine(configuration)
        harness.startReady()
        let pick = harness.receive(gwctQuestionFrame(id: "srq-p", method: "theme.pick"))
        #expect(gwctQuestions(pick).map(\.method) == ["theme.pick"])
        #expect(gwctSends(pick).isEmpty)
        let clarify = harness.receive(gwctQuestionFrame(id: "srq-c", method: "clarify"))
        #expect(gwctQuestions(clarify).isEmpty)
        let reply = try #require(gwctSends(clarify).first.flatMap { gwctParse($0.text) })
        #expect(reply["error"]?["code"]?.intValue == -32601)
    }

    @Test func aRepeatedQuestionIdIsShownOrDeclinedOnlyOnce() {
        var harness = GWCTMachine()
        harness.startReady()
        let shown = harness.receive(gwctQuestionFrame(id: "srq-1", method: "approval"))
        let again = harness.receive(gwctQuestionFrame(id: "srq-1", method: "approval"))
        #expect(gwctQuestions(shown).count == 1)
        #expect(gwctQuestions(again).isEmpty)
        #expect(gwctSends(again).isEmpty)

        let declined = harness.receive(gwctQuestionFrame(id: "srq-2", method: "sudo"))
        let declinedAgain = harness.receive(gwctQuestionFrame(id: "srq-2", method: "sudo"))
        #expect(gwctSends(declined).count == 1)
        // Hermes asking again means the decline was lost: the same reply goes out again.
        #expect(gwctSends(declinedAgain).map(\.text) == gwctSends(declined).map(\.text))
    }

    @Test func anAnswerGoesOutOnceAsAReplyTheDoorForwards() throws {
        var harness = GWCTMachine()
        harness.startReady()
        harness.receive(gwctQuestionFrame(id: "srq-9", method: "approval"))
        let out = harness.feed(.answer(question: "srq-9", result: ["choice": "once"]))
        let sends = gwctSends(out)
        try #require(sends.count == 1)
        #expect(sends[0].socket == harness.socket)
        let reply = try #require(gwctParse(sends[0].text))
        #expect(reply == ["jsonrpc": "2.0", "id": "srq-9", "result": ["choice": "once"]])
        #expect(gwctDoorForwardsAnswer(sends[0].text))

        #expect(gwctSends(harness.feed(.answer(question: "srq-9", result: ["choice": "deny"]))).isEmpty)
        #expect(gwctSends(harness.feed(.decline(question: "srq-9", message: "no"))).isEmpty)
        // Hermes asking the same id again after it was answered means the reply was lost: it is sent again,
        // and the card is not shown again.
        let again = harness.receive(gwctQuestionFrame(id: "srq-9", method: "approval"))
        #expect(gwctQuestions(again).isEmpty)
        #expect(gwctSends(again).map(\.text) == [sends[0].text])
    }

    @Test(arguments: [(true, 4404), (false, -32601)])
    func anAppDeclineIsAnErrorReplyTheDoorForwards(declinesNotShown: Bool, code: Int) throws {
        var harness = GWCTMachine()
        harness.startReady(declinesNotShown: declinesNotShown)
        harness.receive(gwctQuestionFrame(id: "srq-d", method: "clarify"))
        let out = harness.feed(.decline(question: "srq-d", message: "Not answered on this device."))
        let text = try #require(gwctSends(out).first?.text)
        let reply = try #require(gwctParse(text))
        #expect(reply["id"] == "srq-d")
        // "Not shown" leaves the question to another window when Hermes understands it.
        #expect(reply["error"]?["code"]?.intValue == code)
        #expect(reply["method"] == nil)
        #expect(gwctDoorForwardsAnswer(text))
    }

    @Test func answersToQuestionsNeverShownAreNotSent() {
        var harness = GWCTMachine()
        harness.startReady()
        #expect(harness.feed(.answer(question: "srq-never", result: ["choice": "once"])).isEmpty)
        harness.receive(gwctQuestionFrame(id: "srq-s", method: "sudo"))
        // Already declined by the client itself.
        #expect(gwctSends(harness.feed(.answer(question: "srq-s", result: ["value": "pw"]))).isEmpty)
    }

    @Test func anAnswerAfterHermesCancelsIsDroppedAndTheCardWithdrawn() {
        var harness = GWCTMachine()
        harness.startReady()
        harness.receive(gwctQuestionFrame(id: "srq-c", method: "approval"))
        let cancel = harness.receive(gwctEventFrame(type: "request.cancel", session: "s1", seq: 1,
                                                    payload: ["id": "srq-c", "method": "approval", "reason": "timeout"]))
        #expect(cancel.contains { if case .event(let event) = $0 { event.type == "request.cancel" } else { false } })
        #expect(gwctWithdrawn(cancel) == ["srq-c"])
        #expect(gwctSends(harness.feed(.answer(question: "srq-c", result: ["choice": "once"]))).isEmpty)
        // A cancel for a question the app never saw withdraws nothing.
        let other = harness.receive(gwctEventFrame(type: "request.cancel", session: "s1", seq: 2,
                                                   payload: ["id": "srq-unknown", "method": "approval", "reason": "timeout"]))
        #expect(gwctWithdrawn(other).isEmpty)
    }

    @Test func answersMadeWhileNotReadyWaitForReady() throws {
        var harness = GWCTMachine()
        harness.startReady()
        harness.receive(gwctQuestionFrame(id: "srq-q", method: "approval"))
        harness.feed(.closed(socket: harness.socket, code: 1006))
        guard case .retrying = harness.phase else { Issue.record("not retrying: \(harness.phase)"); return }
        let early = harness.feed(.answer(question: "srq-q", result: ["choice": "session"]))
        #expect(gwctSends(early).isEmpty)

        harness.fire(.retry)
        let oldSocket = harness.socket - 1
        let out = harness.handshake()
        #expect(harness.phase == .ready)
        let answers = gwctSends(out).filter { gwctParse($0.text)?["id"] == "srq-q" }
        try #require(answers.count == 1)
        #expect(answers[0].socket == harness.socket && answers[0].socket != oldSocket)
        #expect(gwctParse(answers[0].text)?["result"] == ["choice": "session"])
        #expect(gwctDoorForwardsAnswer(answers[0].text))
        // Sent once only.
        #expect(gwctSends(harness.log).filter { gwctParse($0.text)?["id"] == "srq-q" }.count == 1)
    }

    @Test func appLevelQuestionsWithAnEmptySessionWork() throws {
        var harness = GWCTMachine()
        harness.startReady()
        let out = harness.receive(gwctQuestionFrame(id: "srq-app", method: "clarify", session: ""))
        let question = try #require(gwctQuestions(out).first)
        #expect(question.sessionId == "")
        let answer = gwctSends(harness.feed(.answer(question: "srq-app", result: ["answer": "yes"])))
        #expect(answer.count == 1)

        // No params at all reads as an app-level question too.
        let bare = harness.receive(gwctText(["jsonrpc": "2.0", "id": "srq-bare", "method": "approval"]))
        #expect(gwctQuestions(bare).first?.sessionId == "")
        let declined = harness.receive(gwctText(["jsonrpc": "2.0", "id": "srq-bare-sudo", "method": "sudo"]))
        let text = try #require(gwctSends(declined).first?.text)
        #expect(gwctDoorForwardsAnswer(text))
    }

    @Test func questionsStillOpenAfterAReplayAreDeliveredOnce() throws {
        var harness = GWCTMachine()
        harness.feed(.watch(session: "s1", profile: nil, from: nil))
        harness.startReady()
        harness.receive(gwctEventFrame(type: "message.delta", session: "s1", seq: 1))
        harness.receive(gwctQuestionFrame(id: "srq-open", method: "approval"))
        harness.receive(gwctQuestionFrame(id: "srq-gone", method: "approval"))
        harness.feed(.closed(socket: harness.socket, code: 1006))
        harness.fire(.retry)
        harness.handshake()
        let replayId = try #require(harness.lastCallId("session.events.since"))
        let open: GatewayJSON = [
            ["id": "srq-open", "method": "approval", "params": ["session_id": "s1"]],
            ["id": "srq-new", "method": "clarify", "params": ["session_id": "s1"]],
            ["id": "srq-sudo", "method": "sudo", "params": ["session_id": "s1"]],
        ]
        let out = harness.receive(gwctText(["jsonrpc": "2.0", "id": .integer(replayId), "result": [
            "events": [], "latest_seq": 1, "truncated": false, "count": 0, "epoch": "e1", "open_requests": open,
        ]]))
        let questions = gwctQuestions(out)
        #expect(questions.map(\.id) == ["srq-new"])
        #expect(questions.first?.replayed == true)
        #expect(gwctWithdrawn(out) == ["srq-gone"])
        let declines = gwctSends(out).compactMap { gwctParse($0.text) }.filter { $0["id"] == "srq-sudo" }
        #expect(declines.count == 1)
        #expect(declines.first?["error"]?["code"]?.intValue == -32601)
        #expect(harness.phase == .ready)
    }
}

// MARK: - Reading and writing frames

@Suite struct GatewayFrameTests {
    @Test func answersReadTheirIdAndResult() {
        #expect(GatewayFrame.read(#"{"jsonrpc": "2.0", "id": 2, "result": {"pong": true}}"#) == [.answer(id: 2, result: ["pong": true])])
        #expect(GatewayFrame.read(#"{"jsonrpc":"2.0","id":5,"result":null}"#) == [.answer(id: 5, result: .null)])
    }

    @Test func refusalsReadWithAndWithoutAnId() {
        let withId = GatewayFrame.read(#"{"jsonrpc": "2.0", "id": 20, "error": {"code": 4001, "message": "session not found"}}"#)
        #expect(withId == [.refusal(id: 20, error: GatewayRPCError(code: 4001, message: "session not found"))])
        let nullId = GatewayFrame.read(#"{"jsonrpc": "2.0", "id": null, "error": {"code": -32700, "message": "parse error"}}"#)
        #expect(nullId == [.refusal(id: nil, error: GatewayRPCError(code: -32700, message: "parse error"))])
        let noId = GatewayFrame.read(#"{"jsonrpc": "2.0", "error": {"code": -32600, "message": "invalid request"}}"#)
        #expect(noId == [.refusal(id: nil, error: GatewayRPCError(code: -32600, message: "invalid request"))])
        let withData = GatewayFrame.read(#"{"jsonrpc": "2.0", "id": 3, "error": {"code": 5032, "message": "starting", "data": {"retry": 2}}}"#)
        #expect(withData == [.refusal(id: 3, error: GatewayRPCError(code: 5032, message: "starting", data: ["retry": 2]))])
    }

    @Test func eventsReadWithAndWithoutSeq() {
        let session = GatewayFrame.read(gwctEventFrame(type: "message.delta", session: "s1", seq: 7, payload: ["text": "hi"]))
        #expect(session == [.event(GatewayEventEnvelope(type: "message.delta", sessionId: "s1", seq: 7, payload: ["text": "hi"]))])
        let app = GatewayFrame.read(#"{"jsonrpc": "2.0", "method": "event", "params": {"type": "sessions.changed", "session_id": "", "payload": {}}}"#)
        #expect(app == [.event(GatewayEventEnvelope(type: "sessions.changed", sessionId: "", seq: nil, payload: [:]))])
        let bare = GatewayFrame.read(#"{"jsonrpc": "2.0", "method": "event", "params": {"type": "gateway.ready"}}"#)
        #expect(bare == [.event(GatewayEventEnvelope(type: "gateway.ready"))])
    }

    @Test func questionsReadTheirStringIdMethodAndParams() {
        let frames = GatewayFrame.read(#"{"jsonrpc": "2.0", "id": "srq-1f2e", "method": "approval", "params": {"session_id": "s1", "command": "ls"}}"#)
        let expected = GatewayIncomingQuestion(id: "srq-1f2e", method: "approval", params: ["session_id": "s1", "command": "ls"])
        #expect(frames == [.question(expected)])
        #expect(expected.sessionId == "s1")
        let bare = GatewayFrame.read(#"{"jsonrpc": "2.0", "id": "srq-2", "method": "window.read"}"#)
        #expect(bare == [.question(GatewayIncomingQuestion(id: "srq-2", method: "window.read", params: [:]))])
    }

    @Test(arguments: [
        "not json",
        "42",
        #""a string""#,
        #"[{"jsonrpc": "2.0", "id": 1, "result": {}}]"#,
        #"{"jsonrpc": "2.0"}"#,
        #"{"jsonrpc": "2.0", "id": "srq-1", "result": {}}"#,
        #"{"jsonrpc": "2.0", "id": 4, "method": "approval", "params": {}}"#,
        #"{"jsonrpc": "2.0", "id": 1, "result": {}, "error": {"code": 1, "message": "both"}}"#,
        #"{"jsonrpc": "2.0", "method": "event", "params": {"session_id": "s1"}}"#,
        #"{"jsonrpc": "2.0", "method": "event"}"#,
        #"{"jsonrpc": "2.0", "method": "approval", "params": {}}"#,
        #"{"jsonrpc": "2.0", "id": 1, "result": {"#,
    ])
    func unreadableInputReadsAsUnreadable(text: String) {
        #expect(GatewayFrame.read(text) == [.unreadable])
    }

    @Test func lineSeparatorsInsideStringsDoNotSplitAFrame() {
        // Hermes writes JSON with ensure_ascii off, so these separators arrive raw inside strings.
        for separator in ["\u{2028}", "\u{2029}", "\u{0085}"] {
            let text = #"{"jsonrpc":"2.0","id":3,"result":{"text":"one"# + separator + #"two"}}"#
            #expect(GatewayFrame.read(text) == [.answer(id: 3, result: ["text": .string("one" + separator + "two")])])
        }
    }

    @Test func severalFramesInOneMessageReadInOrder() {
        let text = [
            #"{"jsonrpc": "2.0", "id": 1, "result": {}}"#,
            gwctEventFrame(type: "message.delta", session: "s1", seq: 1),
            gwctQuestionFrame(id: "srq-1", method: "clarify"),
        ].joined(separator: "\n") + "\n"
        let frames = GatewayFrame.read(text)
        #expect(frames.count == 3)
        #expect(frames.first == .answer(id: 1, result: [:]))
        #expect(frames.dropFirst().first == .event(GatewayEventEnvelope(type: "message.delta", sessionId: "s1", seq: 1)))
        if case .question(let question)? = frames.last { #expect(question.id == "srq-1") } else { Issue.record("last is \(String(describing: frames.last))") }
        // Windows line endings work the same.
        #expect(GatewayFrame.read(text.replacingOccurrences(of: "\n", with: "\r\n")) == frames)
    }

    @Test func blankLinesAndSurroundingSpaceAreSkipped() {
        #expect(GatewayFrame.read("").isEmpty)
        #expect(GatewayFrame.read("\n\n  \n\t\n").isEmpty)
        let padded = "\n   " + #"{"jsonrpc": "2.0", "id": 9, "result": true}"# + " \t\n\n  \n"
        #expect(GatewayFrame.read(padded) == [.answer(id: 9, result: true)])
    }

    @Test func everyRecordedFrameReads() throws {
        var answerIds: Set<Int> = [], refusalIds: Set<Int> = [], events: [GatewayEventEnvelope] = []
        for text in gatewayRecordedFrames {
            let frames = GatewayFrame.read(text)
            try #require(frames.count == 1, "\(text.prefix(80)) read as \(frames.count) frames")
            switch frames[0] {
            case .answer(let id, _): answerIds.insert(id)
            case .refusal(let id?, _): refusalIds.insert(id)
            case .event(let event): events.append(event)
            case .unreadable: Issue.record("unreadable: \(text.prefix(120))")
            case .refusal(nil, _), .question: Issue.record("unexpected: \(text.prefix(120))")
            }
        }
        #expect(answerIds.union(refusalIds) == Set(gatewayRecordedCalls.map(\.id)))
        #expect(answerIds.isDisjoint(with: refusalIds))
        #expect(refusalIds == [6, 19, 20])
        #expect(events.first?.type == "gateway.ready")
        #expect(events.count >= 5)
        // Session events carry seq; app-level ones do not.
        for event in events {
            #expect((event.seq != nil) == !event.sessionId.isEmpty, "\(event.type) in '\(event.sessionId)' has seq \(String(describing: event.seq))")
        }
        // All of them in one message read the same way.
        let together = GatewayFrame.read(gatewayRecordedFrames.joined(separator: "\n"))
        #expect(together == gatewayRecordedFrames.flatMap(GatewayFrame.read))
    }

    @Test func outgoingCallsRoundTrip() throws {
        let params: GatewayJSON = ["session_id": "s1", "last_seen": 4, "text": "héllo / ☤ \"quoted\"\nnext line"]
        let text = GatewayFrame.call(id: 7, method: "session.events.since", params: params)
        #expect(!text.contains("\n"), "one frame must stay on one line")
        let json = try #require(gwctParse(text))
        #expect(json == ["jsonrpc": "2.0", "id": 7, "method": "session.events.since", "params": params])
        #expect(json["id"] == .integer(7))
        #expect(GatewayFrame.call(id: 1, method: "ping", params: [:]) == #"{"id":1,"jsonrpc":"2.0","method":"ping","params":{}}"#)
    }

    @Test func outgoingRepliesRoundTripAndPassTheDoor() throws {
        let result = GatewayFrame.reply(to: "srq-1", result: ["choice": "once", "all": false])
        #expect(try #require(gwctParse(result)) == ["jsonrpc": "2.0", "id": "srq-1", "result": ["choice": "once", "all": false]])
        #expect(gwctDoorForwardsAnswer(result))

        let plain = GatewayFrame.reply(to: "srq-2", error: GatewayRPCError(code: 4404, message: "not shown"))
        #expect(try #require(gwctParse(plain)) == ["jsonrpc": "2.0", "id": "srq-2", "error": ["code": 4404, "message": "not shown"]])
        #expect(gwctDoorForwardsAnswer(plain))

        let detailed = GatewayFrame.reply(to: "srq-3", error: GatewayRPCError(code: -32601, message: "no", data: ["why": "secret"]))
        #expect(try #require(gwctParse(detailed))["error"] == ["code": -32601, "message": "no", "data": ["why": "secret"]])
        #expect(gwctDoorForwardsAnswer(detailed))
    }

    @Test func theDoorRuleRefusesWhatItShould() {
        // Checks the rule written again in this file, so the decline tests above mean something.
        #expect(!gwctDoorForwardsAnswer(#"{"jsonrpc":"2.0","id":1,"result":{}}"#))
        #expect(!gwctDoorForwardsAnswer(#"{"jsonrpc":"2.0","id":"a","result":{},"error":{"code":1}}"#))
        #expect(!gwctDoorForwardsAnswer(#"{"jsonrpc":"2.0","id":"a"}"#))
        #expect(!gwctDoorForwardsAnswer(#"{"jsonrpc":"2.0","id":"a","result":{},"extra":1}"#))
        #expect(!gwctDoorForwardsAnswer(#"{"jsonrpc":"2.0","id":"a","method":"x","error":{"code":1}}"#))
        #expect(gwctDoorForwardsAnswer(#"{"jsonrpc":"2.0","id":"a","error":{"code":1,"message":"m"}}"#))
    }
}

// MARK: - The client end to end

/// Collects every notice a client gives, so a test can wait for one without owning the stream's iterator.
private final class GWCTNotices: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [GatewayNotice] = []
    private var watchers: [Int: (done: @Sendable (GWCTNotices) -> Bool, wake: CheckedContinuation<Bool, Never>)] = [:]
    private var nextWatcher = 0

    init(_ client: GatewayClient) {
        let stream = client.notices
        Task { [self] in
            for await notice in stream { add(notice) }
        }
    }

    private func add(_ notice: GatewayNotice) {
        lock.withLock { items.append(notice) }
        let watching = lock.withLock { watchers.map { (id: $0.key, done: $0.value.done) } }
        // Conditions read the notices, so they are asked outside the lock.
        for watcher in watching where watcher.done(self) { end(watcher.id, true) }
    }

    private func end(_ id: Int, _ outcome: Bool) {
        lock.withLock { watchers.removeValue(forKey: id) }?.wake.resume(returning: outcome)
    }

    var all: [GatewayNotice] { lock.withLock { items } }

    var phases: [GatewayPhase] { all.compactMap { if case .phase(let phase) = $0 { phase } else { nil } } }
    var events: [GatewayEventEnvelope] { all.compactMap { if case .event(let event) = $0 { event } else { nil } } }
    var readyCount: Int { phases.filter { $0 == .ready }.count }

    func seqs(_ session: String) -> [Int] {
        events.filter { $0.sessionId == session }.compactMap(\.seq)
    }

    /// Waits until `done` holds for the notices so far. It is asked again as each notice arrives, so the wait has no
    /// timer of its own; only a client stuck for `gwctHangLimit` makes it give up and return false.
    func wait(_ done: @escaping @Sendable (GWCTNotices) -> Bool) async -> Bool {
        let id = lock.withLock { nextWatcher += 1; return nextWatcher }
        let hang = Task { [weak self] in
            guard (try? await Task.sleep(for: gwctHangLimit)) != nil else { return }
            self?.end(id, false)
        }
        defer { hang.cancel() }
        return await withCheckedContinuation { wake in
            lock.withLock { watchers[id] = (done, wake) }
            if done(self) { end(id, true) }
        }
    }
}

/// How long a wait goes on before the test calls it a hang. Nothing in these tests runs on real time (the client's
/// timers run on `SteppedClock`), so this ends only a broken test, and it is long enough that a busy computer never
/// ends a working one. It used to be five seconds of real time, which a loaded Mac ran past.
private let gwctHangLimit: Duration = .seconds(60)

/// Waits until `condition` holds, asking every few milliseconds, for things that send no notice (what the pretend
/// Hermes has heard, the clock's timers). False only after `gwctHangLimit`.
private func gwctEventually(_ condition: @Sendable () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let end = clock.now.advanced(by: gwctHangLimit)
    while clock.now < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

private func gwctFastConfiguration() -> GatewayConfiguration {
    var configuration = GatewayConfiguration()
    configuration.retryBase = .milliseconds(5)
    configuration.retryCap = .milliseconds(20)
    configuration.heartbeatInterval = .seconds(600)
    configuration.silenceLimit = .seconds(600)
    configuration.connectDeadline = .seconds(10)
    configuration.callDeadline = .seconds(10)
    return configuration
}

/// A client on a scripted Hermes, its timers on `clock`. Time stands still unless the test moves the clock, so a
/// retry, a heartbeat or a deadline happens only where the test says.
private func gwctMakeClient(_ dials: [ScriptedGatewayTransport.Dial], clock: SteppedClock = SteppedClock(),
                            _ tune: (inout GatewayConfiguration) -> Void = { _ in })
    -> (GatewayClient, ScriptedGatewayTransport, GWCTNotices) {
    var configuration = gwctFastConfiguration()
    tune(&configuration)
    let transport = ScriptedGatewayTransport(dials)
    let client = GatewayClient(transport: transport, configuration: configuration, clock: clock) {
        GatewayEndpoint(url: URL(string: "ws://127.0.0.1:9119/api/ws")!)
    }
    return (client, transport, GWCTNotices(client))
}

private func gwctSentFrames(_ transport: ScriptedGatewayTransport) -> [GatewayJSON] {
    transport.sent.compactMap(gwctParse)
}

/// The probe the client sends for a watched session it has no position for, answered with `latest`.
private func gwctProbe(_ session: String, latest: Int, epoch: String = "e1") -> ScriptedGatewayTransport.Step {
    .expectCall("session.events.since",
                params: ["session_id": .string(session), "last_seen": .integer(GatewayMachine.probeLastSeen)],
                reply: .result(gwctReplayAnswer(events: [], latest: latest, epoch: epoch)))
}

private func gwctReplayAnswer(events: [GatewayJSON], latest: Int, truncated: Bool = false, epoch: String = "e1") -> GatewayJSON {
    ["events": .array(events), "latest_seq": .integer(latest), "truncated": .bool(truncated), "count": .integer(events.count),
     "epoch": .string(epoch), "open_requests": []]
}

private func gwctEvent(_ session: String, _ seq: Int, type: String = "message.delta") -> GatewayJSON {
    ["type": .string(type), "session_id": .string(session), "seq": .integer(seq), "payload": ["text": .string("part \(seq)")]]
}

@Suite struct GatewayClientTests {
    @Test func connectsAndReachesReady() async throws {
        let (client, transport, notices) = gwctMakeClient([.accept(ScriptedGatewayTransport.handshake(epoch: "e1"))])
        await client.start()
        #expect(await notices.wait { $0.phases.contains(.ready) })
        #expect(notices.phases == [.connecting(attempt: 1), .handshaking(attempt: 1), .ready])
        #expect(notices.events.first?.type == "gateway.ready")
        #expect(await client.phase == .ready)
        let first = try #require(gwctSentFrames(transport).first)
        #expect(first["method"] == "client.capabilities")
        #expect(first["id"] == .integer(1))
        #expect(first["params"] == ["server_requests": true])
        #expect(transport.problems.isEmpty, "\(transport.problems)")
        #expect(transport.finished)
        await client.stop()
    }

    @Test func aTypedCallReturnsItsTypedResult() async throws {
        let steps = ScriptedGatewayTransport.handshake(epoch: "e1") + [
            .expectCall("ping", params: [:], reply: .result(["pong": true])),
            .expectCall("session.close", params: ["session_id": "gone"], reply: .error(code: 4001, message: "session not found")),
        ]
        let (client, transport, notices) = gwctMakeClient([.accept(steps)])
        await client.start()
        #expect(await notices.wait { $0.phases.contains(.ready) })
        let pong = try await client.call(GatewayWire.Calls.ping, GatewayWire.PingParams())
        #expect(pong.pong)
        await #expect(throws: GatewayCallFailure.refused(GatewayRPCError(code: 4001, message: "session not found"))) {
            _ = try await client.callRaw("session.close", ["session_id": "gone"])
        }
        // Client ids count up from 1 on each connection: capabilities was 1.
        #expect(gwctSentFrames(transport).compactMap { $0["id"]?.intValue } == [1, 2, 3])
        #expect(transport.problems.isEmpty, "\(transport.problems)")
        await client.stop()
    }

    @Test func callsMadeBeforeReadyWaitAndAreSentAfterTheHandshake() async throws {
        let steps = ScriptedGatewayTransport.handshake(epoch: "e1") + [.expectCall("ping", reply: .result(["pong": true]))]
        let (client, transport, _) = gwctMakeClient([.accept(steps)])
        let call = Task { try await client.call(GatewayWire.Calls.ping, GatewayWire.PingParams()) }
        try await Task.sleep(for: .milliseconds(20))
        #expect(transport.openCount == 0)
        await client.start()
        let pong = try await call.value
        #expect(pong.pong)
        #expect(gwctSentFrames(transport).map { $0["method"]?.stringValue } == ["client.capabilities", "ping"])
        #expect(transport.problems.isEmpty, "\(transport.problems)")
        await client.stop()
    }

    @Test func aCallThatGetsNoAnswerTimesOut() async {
        let clock = SteppedClock()
        let (client, _, _) = gwctMakeClient([], clock: clock)
        let call = Task { try await client.callRaw("ping", [:], timeout: .milliseconds(30)) }
        // Just short of its deadline it still waits; at the deadline it gives up.
        #expect(await gwctEventually { clock.waiting == [.milliseconds(30)] })
        clock.advance(by: .milliseconds(29))
        #expect(clock.waiting == [.milliseconds(1)])
        clock.advance(by: .milliseconds(1))
        await #expect(throws: GatewayCallFailure.timedOut) { _ = try await call.value }
        await client.stop()
    }

    @Test func cancellingTheCallerCancelsTheCall() async throws {
        let steps = ScriptedGatewayTransport.handshake(epoch: "e1") + [.expectCall("ping", reply: .silence)]
        let (client, transport, notices) = gwctMakeClient([.accept(steps)])
        await client.start()
        #expect(await notices.wait { $0.phases.contains(.ready) })
        let call = Task { try await client.callRaw("ping", [:]) }
        #expect(await gwctEventually { transport.finished })
        call.cancel()
        await #expect(throws: GatewayCallFailure.cancelled) { _ = try await call.value }
        #expect(transport.problems.isEmpty, "\(transport.problems)")
        await client.stop()
    }

    @Test func serverEventsArriveAsNoticesInOrderWithoutRepeats() async {
        let steps = ScriptedGatewayTransport.handshake(epoch: "e1") + [
            .event(type: "message.delta", session: "s1", seq: 1, payload: ["text": "hi"]),
            .event(type: "message.delta", session: "s1", seq: 1, payload: ["text": "hi"]),
            .event(type: "sessions.changed", payload: [:]),
            .event(type: "message.complete", session: "s1", seq: 2, payload: ["text": "hi there"]),
        ]
        let (client, transport, notices) = gwctMakeClient([.accept(steps)])
        await client.start()
        #expect(await notices.wait { $0.events.contains { $0.type == "message.complete" } })
        let events = notices.events.filter { $0.type != "gateway.ready" }
        #expect(events.map(\.type) == ["message.delta", "sessions.changed", "message.complete"])
        #expect(events.first?.payload == ["text": "hi"])
        #expect(events.dropFirst().first?.seq == nil)
        #expect(notices.seqs("s1") == [1, 2])
        #expect(transport.problems.isEmpty, "\(transport.problems)")
        await client.stop()
    }

    @Test func aDropThenReconnectReplaysAWatchedSessionOnce() async {
        let first = ScriptedGatewayTransport.handshake(epoch: "e1") + [
            // The app gave no position for s1, so the first connection asks where it stands.
            gwctProbe("s1", latest: 0),
            .event(type: "message.delta", session: "s1", seq: 1),
            .event(type: "message.delta", session: "s1", seq: 2),
            .drop(code: 1006),
        ]
        let second = ScriptedGatewayTransport.handshake(epoch: "e1") + [
            .expectCall("session.events.since", params: ["session_id": "s1", "last_seen": 2],
                        reply: .result(gwctReplayAnswer(events: [gwctEvent("s1", 3), gwctEvent("s1", 2), gwctEvent("s1", 4)], latest: 4))),
            .event(type: "message.delta", session: "s1", seq: 4),
            .event(type: "message.delta", session: "s1", seq: 5),
        ]
        let clock = SteppedClock()
        let (client, transport, notices) = gwctMakeClient([.accept(first), .accept(second)], clock: clock)
        await client.watch(session: "s1")
        await client.start()
        // The drop sets a retry; it fires when the clock moves.
        #expect(await clock.fireNext(within: .milliseconds(20)))
        #expect(await notices.wait { $0.seqs("s1").contains(5) })
        #expect(notices.seqs("s1") == [1, 2, 3, 4, 5])
        #expect(notices.readyCount == 2)
        #expect(notices.phases.contains { if case .retrying = $0 { true } else { false } })
        #expect(!notices.all.contains { if case .reload = $0 { true } else { false } })
        #expect(transport.openCount == 2)
        #expect(transport.problems.isEmpty, "\(transport.problems)")
        await client.stop()
    }

    @Test func aRestartedHermesMeansReloadNotReplay() async {
        let first = ScriptedGatewayTransport.handshake(epoch: "e1") + [
            gwctProbe("s1", latest: 2),
            .event(type: "message.delta", session: "s1", seq: 3),
            .drop(code: 1001),
        ]
        // After the restart the old position means nothing: s1 reloads and its new numbering is learned.
        let second = ScriptedGatewayTransport.handshake(epoch: "e2") + [
            gwctProbe("s1", latest: 0, epoch: "e2"),
            .event(type: "message.delta", session: "s1", seq: 1),
        ]
        let clock = SteppedClock()
        let (client, transport, notices) = gwctMakeClient([.accept(first), .accept(second)], clock: clock)
        await client.watch(session: "s1")
        await client.start()
        // The drop sets a retry; it fires when the clock moves.
        #expect(await clock.fireNext(within: .milliseconds(20)))
        #expect(await notices.wait { $0.seqs("s1").count == 2 })
        #expect(notices.all.contains(.reload(session: "s1", .restarted)))
        #expect(notices.seqs("s1") == [3, 1])
        // An unexpected session.events.since would show up as a problem.
        #expect(transport.problems.isEmpty, "\(transport.problems)")
        await client.stop()
    }

    @Test func aTruncatedReplayReloadsAndSkipsWhatItCovers() async {
        let first = ScriptedGatewayTransport.handshake(epoch: "e1") + [
            gwctProbe("s1", latest: 0),
            .event(type: "message.delta", session: "s1", seq: 1),
            .drop(code: 1006),
        ]
        let second = ScriptedGatewayTransport.handshake(epoch: "e1") + [
            .expectCall("session.events.since", params: ["session_id": "s1", "last_seen": 1],
                        reply: .result(gwctReplayAnswer(events: [], latest: 10, truncated: true))),
            .event(type: "message.delta", session: "s1", seq: 9),
            .event(type: "message.delta", session: "s1", seq: 11),
        ]
        let clock = SteppedClock()
        let (client, transport, notices) = gwctMakeClient([.accept(first), .accept(second)], clock: clock)
        await client.watch(session: "s1")
        await client.start()
        // The drop sets a retry; it fires when the clock moves.
        #expect(await clock.fireNext(within: .milliseconds(20)))
        #expect(await notices.wait { $0.seqs("s1").contains(11) })
        #expect(notices.all.contains(.reload(session: "s1", .truncated)))
        #expect(notices.seqs("s1") == [1, 11])
        #expect(transport.problems.isEmpty, "\(transport.problems)")
        await client.stop()
    }

    @Test func aFailedReplayReloadsAndStillGetsReady() async {
        let first = ScriptedGatewayTransport.handshake(epoch: "e1") + [
            gwctProbe("s1", latest: 0),
            .event(type: "message.delta", session: "s1", seq: 1),
            .drop(code: 1006),
        ]
        let second = ScriptedGatewayTransport.handshake(epoch: "e1") + [
            .expectCall("session.events.since", reply: .error(code: -32601, message: "unknown method")),
        ]
        let clock = SteppedClock()
        let (client, transport, notices) = gwctMakeClient([.accept(first), .accept(second)], clock: clock)
        await client.watch(session: "s1")
        await client.start()
        // The drop sets a retry; it fires when the clock moves.
        #expect(await clock.fireNext(within: .milliseconds(20)))
        #expect(await notices.wait { $0.readyCount == 2 })
        #expect(notices.all.contains(.reload(session: "s1", .replayFailed)))
        #expect(transport.problems.isEmpty, "\(transport.problems)")
        await client.stop()
    }

    @Test func aRefusedDialClosesForGood() async {
        let clock = SteppedClock()
        let (client, transport, notices) = gwctMakeClient([.refuse(.refused(status: 403))], clock: clock)
        await client.start()
        #expect(await notices.wait { $0.phases.contains(.closed(.refused(code: 403))) })
        // Nothing is left to fire: no retry, no deadline.
        #expect(await gwctEventually { clock.waiting.isEmpty })
        clock.advance(by: .seconds(3600))
        #expect(transport.openCount == 1)
        #expect(notices.phases == [.connecting(attempt: 1), .closed(.refused(code: 403))])
        await #expect(throws: GatewayCallFailure.closed) { _ = try await client.callRaw("ping", [:]) }
        #expect(transport.problems.isEmpty, "\(transport.problems)")
    }

    @Test func aRefusedCloseCodeClosesForGood() async {
        let steps = ScriptedGatewayTransport.handshake(epoch: "e1") + [.drop(code: 4401)]
        let clock = SteppedClock()
        let (client, transport, notices) = gwctMakeClient([.accept(steps)], clock: clock)
        await client.start()
        #expect(await notices.wait { $0.phases.contains(.closed(.refused(code: 4401))) })
        #expect(await gwctEventually { clock.waiting.isEmpty })
        clock.advance(by: .seconds(3600))
        #expect(transport.openCount == 1)
        #expect(transport.problems.isEmpty, "\(transport.problems)")
    }

    @Test func anUnreachableHermesIsRetriedUntilTheBudgetRunsOut() async {
        let clock = SteppedClock()
        let (client, transport, notices) = gwctMakeClient([.refuse(.unreachable("down")), .refuse(.unreachable("down"))], clock: clock) {
            $0.maxAttempts = 2
        }
        await client.start()
        #expect(await clock.fireNext(within: .milliseconds(20)))
        #expect(await notices.wait { $0.phases.contains(.closed(.gaveUp)) })
        #expect(transport.openCount == 2)
        #expect(notices.phases.contains { if case .retrying(2, _) = $0 { true } else { false } })
        #expect(transport.problems.isEmpty, "\(transport.problems)")
    }

    @Test func aFailedOpenIsRetried() async {
        let clock = SteppedClock()
        let (client, transport, notices) = gwctMakeClient([.refuse(.unreachable("down")),
                                                           .accept(ScriptedGatewayTransport.handshake(epoch: "e1"))], clock: clock)
        await client.start()
        #expect(await clock.fireNext(within: .milliseconds(20)))
        #expect(await notices.wait { $0.phases.contains(.ready) })
        #expect(transport.openCount == 2)
        #expect(notices.phases.contains(.connecting(attempt: 2)))
        #expect(transport.problems.isEmpty, "\(transport.problems)")
        await client.stop()
    }

    @Test func aCallInFlightWhenTheLineDropsFailsAsConnectionLostAndIsNotRepeated() async {
        let first = ScriptedGatewayTransport.handshake(epoch: "e1") + [.expectCall("prompt.submit", reply: .silence), .drop(code: 1006)]
        let clock = SteppedClock()
        let (client, transport, notices) = gwctMakeClient([.accept(first), .accept(ScriptedGatewayTransport.handshake(epoch: "e1"))],
                                                          clock: clock)
        await client.start()
        #expect(await notices.wait { $0.phases.contains(.ready) })
        await #expect(throws: GatewayCallFailure.connectionLost) {
            _ = try await client.callRaw("prompt.submit", ["session_id": "s1", "text": "hello"])
        }
        #expect(await clock.fireNext(within: .milliseconds(20)))
        #expect(await notices.wait { $0.readyCount == 2 })
        try? await Task.sleep(for: .milliseconds(30))
        // The second socket's script expects only the handshake, so a repeated prompt.submit would be a problem.
        #expect(gwctSentFrames(transport).filter { $0["method"] == "prompt.submit" }.count == 1)
        #expect(transport.problems.isEmpty, "\(transport.problems)")
        await client.stop()
    }

    @Test func stopMakesAQueuedCallThrowClosed() async {
        let (client, transport, _) = gwctMakeClient([])
        let call = Task { try await client.callRaw("ping", [:]) }
        try? await Task.sleep(for: .milliseconds(20))
        await client.stop()
        await #expect(throws: GatewayCallFailure.closed) { _ = try await call.value }
        #expect(transport.openCount == 0)
    }

    @Test func stopMakesACallWaitingForItsAnswerThrowConnectionLost() async {
        let steps = ScriptedGatewayTransport.handshake(epoch: "e1") + [.expectCall("ping", reply: .silence)]
        let (client, transport, notices) = gwctMakeClient([.accept(steps)])
        await client.start()
        #expect(await notices.wait { $0.phases.contains(.ready) })
        let call = Task { try await client.callRaw("ping", [:]) }
        #expect(await gwctEventually { transport.finished })
        await client.stop()
        // The call was sent, so Hermes may have acted on it: the outcome is unknown.
        await #expect(throws: GatewayCallFailure.connectionLost) { _ = try await call.value }
        #expect(notices.phases.last == .closed(.stopped))
        #expect(transport.problems.isEmpty, "\(transport.problems)")
    }

    @Test func declinedQuestionsReachHermesAsErrorReplies() async {
        let steps = ScriptedGatewayTransport.handshake(epoch: "e1", declinesNotShown: true) + [
            .push(gwctQuestionFrame(id: "srq-sudo", method: "sudo")),
            .expectAnswer(id: "srq-sudo", errorCode: -32601),
            .push(gwctQuestionFrame(id: "srq-prev", method: "preview.act")),
            .expectAnswer(id: "srq-prev", errorCode: 4404),
            .push(gwctQuestionFrame(id: "srq-beat", method: "setup_beat", session: "")),
            .expectAnswer(id: "srq-beat", errorCode: -32601),
        ]
        let (client, transport, notices) = gwctMakeClient([.accept(steps)])
        await client.start()
        #expect(await gwctEventually { transport.finished })
        let replies = transport.sent.filter { gwctParse($0)?["method"] == nil }
        #expect(replies.count == 3)
        #expect(replies.allSatisfy(gwctDoorForwardsAnswer))
        #expect(!notices.all.contains { if case .question = $0 { true } else { false } })
        #expect(transport.problems.isEmpty, "\(transport.problems)")
        await client.stop()
    }

    @Test func windowQuestionsGetUnknownMethodWhenHermesCannotTakeNotShown() async {
        let steps = ScriptedGatewayTransport.handshake(epoch: "e1", declinesNotShown: false) + [
            .push(gwctQuestionFrame(id: "srq-tour", method: "tour")),
            .expectAnswer(id: "srq-tour", errorCode: -32601),
        ]
        let (client, transport, _) = gwctMakeClient([.accept(steps)])
        await client.start()
        #expect(await gwctEventually { transport.finished })
        #expect(transport.problems.isEmpty, "\(transport.problems)")
        await client.stop()
    }

    @Test func shownQuestionsAreAnsweredAndDeclinedThroughTheClient() async throws {
        let steps = ScriptedGatewayTransport.handshake(epoch: "e1") + [
            .push(gwctQuestionFrame(id: "srq-ok", method: "approval")),
            .push(gwctQuestionFrame(id: "srq-no", method: "clarify")),
            .expectAnswer(id: "srq-ok", result: ["choice": "once"]),
            // Hermes said it understands "not shown", so a dismissed card leaves the question to other windows.
            .expectAnswer(id: "srq-no", errorCode: 4404),
        ]
        let (client, transport, notices) = gwctMakeClient([.accept(steps)])
        await client.start()
        #expect(await notices.wait { $0.all.filter { if case .question = $0 { true } else { false } }.count == 2 })
        try await client.answer(GatewayWire.Questions.approval, id: "srq-ok", with: GatewayWire.ApprovalResult(choice: .once))
        await client.decline(id: "srq-no")
        #expect(await gwctEventually { transport.finished })
        let replies = transport.sent.filter { gwctParse($0)?["method"] == nil }
        #expect(replies.count == 2)
        #expect(replies.allSatisfy(gwctDoorForwardsAnswer))
        #expect(transport.problems.isEmpty, "\(transport.problems)")
        await client.stop()
    }

    @Test func theHeartbeatSendsPing() async {
        let steps = ScriptedGatewayTransport.handshake(epoch: "e1") + [
            .expectCall("ping", params: [:], reply: .result(["pong": true])),
            // Left unanswered, so no third ping goes out while this one is outstanding.
            .expectCall("ping", params: [:], reply: .silence),
        ]
        let clock = SteppedClock()
        let (client, transport, notices) = gwctMakeClient([.accept(steps)], clock: clock) { $0.heartbeatInterval = .milliseconds(20) }
        await client.start()
        #expect(await notices.wait { $0.phases.contains(.ready) })
        // Each beat is one move of the clock: the first ping is answered, the second is not, the third beat sends nothing.
        for _ in 0..<3 { #expect(await clock.fireNext(within: .milliseconds(20))) }
        // The beat is set again only after the third one was handled.
        #expect(await gwctEventually { clock.waiting.first == .milliseconds(20) })
        #expect(transport.finished)
        #expect(gwctSentFrames(transport).filter { $0["method"] == "ping" }.count == 2)
        #expect(notices.readyCount == 1)
        #expect(transport.problems.isEmpty, "\(transport.problems)")
        await client.stop()
    }

    @Test func aSilentSocketLeadsToAReconnect() async {
        let silent = ScriptedGatewayTransport.handshake(epoch: "e1") + [.expectCall("ping", reply: .silence)]
        let clock = SteppedClock()
        let (client, transport, notices) = gwctMakeClient([.accept(silent), .accept(silent)], clock: clock) {
            $0.heartbeatInterval = .milliseconds(20)
            $0.silenceLimit = .milliseconds(300)
        }
        await client.start()
        #expect(await notices.wait { $0.phases.contains(.ready) })
        // A beat sends a ping that is never answered; 300 ms after the last word from Hermes the socket is given up.
        #expect(await clock.fireNext(within: .milliseconds(20)))
        #expect(await gwctEventually { transport.openCount == 1 && clock.waiting.first == .milliseconds(20) })
        clock.advance(by: .milliseconds(280))
        #expect(await notices.wait { $0.phases.contains { if case .retrying(2, _) = $0 { true } else { false } } })
        #expect(await clock.fireNext(within: .milliseconds(20)))
        #expect(await notices.wait { $0.readyCount == 2 })
        // The new socket beats too. The clock stops here, so it is never found silent.
        #expect(await clock.fireNext(within: .milliseconds(20)))
        #expect(await gwctEventually { transport.finished })
        await client.stop()
        #expect(transport.openCount == 2)
        #expect(transport.problems.isEmpty, "\(transport.problems)")
    }
}
