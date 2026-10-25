import Foundation
import Testing
@testable import NollieCore

/// JSON-RPC text frames, in and out.
@Suite struct WireFrameTests {
    private func decoded(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    @Test func anEventFrameCarriesTypeSessionAndPayload() throws {
        let frame = InboundFrame.parse(#"{"jsonrpc":"2.0","method":"event","params":{"type":"message.delta","session_id":"abc","payload":{"text":"Morning"}}}"#)
        guard case .event(let event) = frame else { Issue.record("expected an event, got \(frame)"); return }
        #expect([event.type, event.sessionID] == ["message.delta", "abc"])
        #expect(event.payload["text"]?.stringValue == "Morning")
    }

    @Test func anApprovalRequestKeepsItsChoicesAndCanBeAnswered() throws {
        let text = #"{"jsonrpc":"2.0","id":"srq-77","method":"approval","params":{"session_id":"abc","request_id":"r2","command":"make clean","choices":["once","session","always","deny"]}}"#
        guard case .serverRequest(let request) = InboundFrame.parse(text) else { Issue.record("expected a server request"); return }
        #expect(request.id == "srq-77")
        #expect(request.sessionID == "abc")
        let approval = try request.params.decode(ApprovalRequest.self)
        #expect(approval.requestId == "r2" && approval.offeredChoices == ["once", "session", "always", "deny"])
        let reply = try decoded(RPCFrames.response(id: request.id, result: ["choice": "deny"]))
        #expect(reply["id"]?.stringValue == "srq-77")
        #expect(reply["jsonrpc"]?.stringValue == "2.0")
        #expect(reply["result"]?["choice"]?.stringValue == "deny")
    }

    @Test func aResultAndAnErrorAreToldApart() {
        let good = InboundFrame.parse(#"{"jsonrpc":"2.0","id":12,"result":{"pong":true}}"#)
        guard case .response(let id, let result, let failure) = good else { Issue.record("expected a response"); return }
        #expect(id.intValue == 12)
        #expect(result?["pong"]?.boolValue == true)
        #expect(failure == nil)
        let bad = InboundFrame.parse(#"{"jsonrpc":"2.0","id":13,"error":{"code":4001,"message":"nope"}}"#)
        guard case .response(_, _, let reason) = bad else { Issue.record("expected a response"); return }
        #expect(reason?.code == 4001)
    }

    @Test func aRequestFrameNamesItsMethodAndParams() throws {
        let sent = try decoded(RPCFrames.request(id: 9, method: "prompt.submit", params: ["session_id": "abc", "text": "good morning"]))
        #expect(sent["id"]?.intValue == 9)
        #expect(sent["method"]?.stringValue == "prompt.submit")
        #expect(sent["params"]?["session_id"]?.stringValue == "abc")
        #expect(sent["params"]?["text"]?.stringValue == "good morning")
    }
}

/// Putting streamed pieces back together.
@Suite struct StreamAssemblyTests {
    @Test func deltasJoinInOrderUntilTheReplyCompletes() {
        var reply = StreamAssembler()
        reply.start()
        for piece in ["Good ", "morn", "ing"] { reply.appendDelta(piece) }
        #expect(reply.text == "Good morning")
        #expect(reply.isStreaming)
        #expect(reply.complete(finalText: nil) == "Good morning")
        #expect(!reply.isStreaming)
    }

    @Test func theServersFinalTextOutranksWhatStreamed() {
        var reply = StreamAssembler()
        reply.appendDelta("rough draft")
        #expect(reply.complete(finalText: "the real thing") == "the real thing")
    }

    private static let shown = "Looking at the folder.\n\n## Result\n\nTwo big files.\n\n"
    private static let rest = "Both were moved to the archive."

    /// A tool call splits one reply in two. The completed message repeats everything, so only the
    /// part after what is already on screen may be added.
    static let tails: [(sealed: String, final: String, expected: String)] = {
        let whole = shown + rest
        return [
            ("", whole, whole),
            (shown, whole, rest),
            (shown, shown, ""),
            ("some other words", whole, whole),
            (shown + "  ", whole, rest),
            (shown.replacingOccurrences(of: "\n\n", with: "\n"), whole, rest),
        ]
    }()

    @Test(arguments: Self.tails)
    func onlyTheUnshownTailIsAdded(sealed: String, final: String, expected: String) {
        #expect(StreamAssembler.tail(ofFinalText: final, alreadySealed: sealed) == expected)
    }
}
