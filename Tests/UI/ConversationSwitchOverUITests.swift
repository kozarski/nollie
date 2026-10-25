import XCTest

/// The default bot's chat on the new conversation screen (Developer Mode and Settings, Advanced,
/// New chat view on). It shows its list, bot pill and own composer; a message streams with a tool
/// step; the approval card is answered and leaves a quiet row; and a compressed chat carries on
/// with one summary row. Once in each look.
final class ConversationSwitchOverUITests: DemoCase {
    private let switchedOn = ["-nollie.developerMode", "YES", "-nollie.newChatView", "YES"]

    private func say(_ words: String) {
        let field = find("conversation.composer")
        XCTAssertTrue(field.waitForExistence(timeout: 20), "no composer on the conversation screen")
        field.tap()
        field.typeText(words)
        tap("conversation.send", timeout: 5)
    }

    func testTheNewScreenRunsAMessageAnApprovalAndACompression() throws {
        try inBothLooks { look in
            try startDemo(switchedOn, look: look)
            openBotOnNewScreen()
            XCTAssertTrue(find("conversation.list").exists && find("conversation.botPill").exists, "the new screen is missing its list or bot pill")
            XCTAssertTrue(find("conversation.send").exists)

            say("Please clean up the log host")
            XCTAssertTrue(text("Ran a command").waitForExistence(timeout: 40), "no tool step in the thread")
            ready("card.allowOnce", timeout: 60).tap()
            XCTAssertTrue(text("Allowed").waitForExistence(timeout: 20), "no quiet row after the answer")
            XCTAssertTrue(text("4.2 GB freed").waitForExistence(timeout: 60), "the reply never finished")

            say("compress")
            XCTAssertTrue(text("Carrying on").waitForExistence(timeout: 40), "the reply after compression did not arrive")
            XCTAssertEqual(texts("Earlier messages summarized").count, 1, "expected exactly one summary row")
            shot("switch-over-\(look.rawValue)")
        }
    }

    /// The bot's row opens its chat; this screen has no `composer.text`.
    private func openBotOnNewScreen() {
        tap("bots.row.default", timeout: 30)
        XCTAssertTrue(find("conversation.composer").waitForExistence(timeout: 30), "the default chat did not open on the new screen")
    }
}
