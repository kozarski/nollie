import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

/// The "Reasoning" item in a chat's menu: the levels it lists, the line it shows, and which
/// bot's model list the chat looks at.
@Suite struct ReasoningMenuTests {
    @Test func levelsComeInOrderOfStrengthWithStrangersLast() {
        let cases: [(offered: [String]?, listed: [String], why: String)] = [
            (nil, ["low", "medium", "high"], "with nothing offered, the plain three"),
            (["", "minimal", "low", "medium", "high", "xhigh", "max"], ["minimal", "low", "medium", "high", "xhigh", "max"], "a full list, blank entry dropped"),
            (["max", " ", "high", "xhigh", "max"], ["low", "medium", "high", "xhigh", "max"], "any order in, strength order out; repeats and blanks gone"),
            (["ultra", "max", "deep"], ["low", "medium", "high", "max", "ultra", "deep"], "levels only the gateway knows go last, as it listed them"),
        ]
        for entry in cases { #expect(ReasoningEffort.levels(offered: entry.offered) == entry.listed, "\(entry.why)") }
    }

    @Test(arguments: [("medium", "Reasoning: medium"), (nil, "Reasoning: not set"), (" ", "Reasoning: not set")] as [(String?, String)])
    func theMenuLineNamesTheLevelOrSaysNoneIsSet(current: String?, line: String) {
        #expect(ReasoningEffort.title(current: current) == line)
    }

    @Test func theOfferedLevelsComeFromTheConfigSchema() throws {
        func decode(_ json: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) }
        let withEffort = try decode(#"{"fields": {"model": {"type": "string"}, "agent.reasoning_effort": {"type": "select", "options": ["", "low", "medium", "high", "max"]}}}"#)
        #expect(ReasoningEffort.offered(in: withEffort) == ["", "low", "medium", "high", "max"])
        #expect(ReasoningEffort.offered(in: try decode(#"{"fields": {}}"#)) == nil)
    }

    @Test func aChatAsksItsOwnBotForModelsNotTheOneOnShow() {
        let readFrom: [(chat: String?, selected: String?, bot: String?)] = [("scout", "mason", "scout"), (nil, "mason", "mason"), (nil, nil, nil)]
        for entry in readFrom {
            let bot = ChatSession.modelOptionsProfile(chat: entry.chat, selected: entry.selected)
            #expect(bot == entry.bot)
        }
    }
}
