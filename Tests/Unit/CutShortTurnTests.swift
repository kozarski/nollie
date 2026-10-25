import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

/// Turns the gateway ended early, and the grace period it gives a missing app first.
@Suite struct CutShortTurnTests {
    private func config(_ json: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) }

    @Test func onlyTheGatewaysOwnSentenceBecomesACard() {
        #expect(["Operation interrupted.", "  Operation interrupted \n"].allSatisfy { InterruptedTurn.parse($0) == InterruptedTurn() })
        let withDetail: [(String, String)] = [
            ("Operation interrupted: waiting for model response (9.1s elapsed).", "waiting for model response (9.1s elapsed)"),
            ("Operation interrupted during retry (rate limit, attempt 3/5).", "during retry (rate limit, attempt 3/5)"),
        ]
        for (sentence, doing) in withDetail { #expect(InterruptedTurn.parse(sentence)?.doing == doing) }
        // A message only quoting the phrase, or continuing beyond it, remains an ordinary message.
        let ordinary = ["The log shows \"Operation interrupted.\" twice.", "Operation interrupted.\nHere is what I had so far: …",
                        "Operation interrupted by the proxy setting you changed", ""]
        for words in ordinary { #expect(InterruptedTurn.parse(words) == nil, "\(words)") }
    }

    @Test func theGatewaysPatienceIsReadFromItsConfig() throws {
        let wrapped = try config(#"{"config": {"dashboard": {"ws_orphan_reap_grace_s": 7200}}}"#)
        #expect(AwayGrace.read(config: wrapped).seconds == 7200)
        #expect(!AwayGrace.read(config: wrapped).isShort)

        // Unset means the gateway falls back to its built-in twenty seconds, which counts as short.
        let unset = AwayGrace.read(config: try config(#"{"config": {"dashboard": {}}}"#))
        #expect(unset.seconds == nil && unset.effective == 20 && unset.isShort)

        // A bare config without the wrapper, with the number as text, like a config edited by hand.
        #expect(AwayGrace.read(config: try config(#"{"dashboard": {"ws_orphan_reap_grace_s": "900"}}"#)).seconds == 900)
        // Zero tells the gateway never to end a turn over this.
        #expect(AwayGrace(seconds: 0).isShort == false)
    }

    @Test func theChoiceIsWrittenWhereTheGatewayReadsIt() {
        let written = AwayGrace.writeBody(seconds: 28_800)["config"]?["dashboard"]?["ws_orphan_reap_grace_s"]
        #expect(written?.doubleValue == 28_800)
        let labels = AwayGrace.choices.map { AwayGrace.label($0) }
        #expect(labels == ["20 seconds", "10 minutes", "1 hour", "8 hours", "Never stop it"])
    }
}
