import XCTest

/// A whole conversation the way a person has one, start to finish: a message, the bot at work, a
/// question that needs an answer, the answer, the reply, and a look at the chat's context. Then a
/// seeded chat opened from the list. (The old tab bar and chat list tours are gone with those screens;
/// the list and the bot's page are covered by ChatNavigationUITests and ProfileCardUITests.)
final class ChatShowcaseUITests: DemoCase {
    func testAMessageWorkAnApprovalAndAReply() throws {
        try beginSideChat(saying: "The log host is nearly full. Please clean it up.")

        XCTAssertTrue(find("thread.typing").waitForExistence(timeout: 20), "no sign the bot was at work")
        XCTAssertTrue(find("thread.row.tool").waitForExistence(timeout: 30), "no terminal step in the thread")

        // The bot stops to ask before it deletes anything.
        let once = ready("approval.once", timeout: 60)
        XCTAssertTrue(find("approval.deny").exists, "an approval offers a way to say no")
        XCTAssertTrue(text("needs your OK").exists, "the card does not say who is asking")
        shot("showcase-approval")
        once.tap()
        XCTAssertTrue(poll(15) { !self.find("approval.once").exists }, "the card stayed after the answer")

        XCTAssertTrue(text("4.2 GB freed").waitForExistence(timeout: 60), "the reply never came")

        // The chat's context, from its menu: a sheet that Done closes.
        tap("chat.more")
        press("This chat")
        let usage = labelled("Context usage")
        XCTAssertTrue(usage.waitForExistence(timeout: 5), "no context item in the chat menu")
        usage.tap()
        expectShown(text("By category"), "the context sheet shows no categories")
        shot("showcase-context")
        press("Done")
        XCTAssertTrue(poll(10) { !self.text("By category").exists }, "Done left the context sheet up")
    }

    func testASeededChatOpensWithItsHistoryAtOnceAndGoesBack() throws {
        try startDemo()
        openBot("default")
        XCTAssertTrue(text("The log host is at 94% disk").waitForExistence(timeout: 10), "the history was not there on opening")
        XCTAssertTrue(find("composer.text").exists)

        tap("chat.back")
        XCTAssertTrue(find("bots.list").waitForExistence(timeout: 10), "Back did not return to the bots")
        XCTAssertTrue(find("bots.row.default").exists)
    }
}
