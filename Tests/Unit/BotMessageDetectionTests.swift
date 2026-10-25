import Foundation
import Testing
@testable import NollieCore

/// Spotting one bot handing a message to another, from the command or tool it used.
@Suite struct BotMessageDetectionTests {
    private func target(of command: String, tool: String = "terminal", args: String? = nil) -> String? {
        BotDelivery.parse(name: tool, context: command, argsText: args)?.target
    }

    @Test func aQuietChatRunCarriesItsMessageAlong() {
        let found = BotDelivery.parse(name: "terminal", context: "hermes -p scout chat -q \"Message from 🤖 default: hold the export\"", argsText: nil)
        #expect(found?.target == "scout")
        #expect(found?.message == "hold the export")
    }

    @Test(arguments: [
        ("HERMES_BIN=/opt/hermes/bin/hermes; $HERMES_BIN -p mason chat --in ~ -c \"Bot Chat\" --create-if-missing -Q --query-file /tmp/dm-2/status.md", "mason"),
        ("hermes --profile forager chat -c 'Bot Chat' --create-if-missing", "forager"),
        ("python3 bot_mode_dm.py --run-delivery peer /tmp/dm.md /usr/local/bin/hermes -p mason peer dm laptop/scribe", "scribe"),
        ("hermes peer dm studio/scribe < /tmp/note.md", "scribe"),
    ])
    func severalCommandShapesNameTheirTarget(command: String, expected: String) {
        #expect(target(of: command) == expected)
    }

    @Test func aTruncatedPreviewIsReadFromTheFullArguments() {
        let preview = "/opt/tools/python3 /opt/hermes/tools/bot_mode_dm.py --run-delivery --author '{\"id\":\"mas"
        let full = "{\"command\": \"/opt/tools/python3 /opt/hermes/tools/bot_mode_dm.py --run-delivery --author '{\\\"id\\\":\\\"mason\\\"}' local /opt/profiles/mason/cache/dm-1.md --profile-home /opt/profiles/scout /opt/venv/bin/hermes -p scout chat --in ~ -c 'Bot Chat' --create-if-missing -Q\", \"background\": true}"
        #expect(target(of: preview, args: full) == "scout")
    }

    @Test func theMessageToolNamesItsTargetInLowerCase() {
        let found = BotDelivery.parse(name: "message_agent", context: nil, argsText: "{\"target\": \"@Mx. Reed\", \"message\": \"hello\"}")
        #expect(found?.target == "mx. reed")
        #expect(found?.message == "hello")
    }

    @Test(arguments: ["ls -la /opt/hermes/profiles/", "hermes chat -q \"summarize my inbox\""])
    func everydayCommandsAreNotDeliveries(command: String) {
        #expect(target(of: command) == nil)
    }

    @Test(arguments: [
        ("Message from 🤖 Mason (@mason): all quiet", "mason", "all quiet"),
        ("[Message from agent 'Scout'] inbox clear", "scout", "inbox clear"),
    ])
    func arrivingMessagesAreRecognisedByTheirOpening(line: String, sender: String, text: String) throws {
        let message = try #require(AgentMessage.parse(line))
        #expect(message.key == sender)
        #expect(message.body == text)
    }

    @Test func talkAboutMessagingIsNotAMessage() {
        let aside = AgentMessage.parse("Please message mason for me")
        #expect(aside == nil)
    }
}
