import XCTest

/// Two ways a model can reason. If the whole answer arrives as reasoning, it still shows as a normal
/// reply (a real table) with no reasoning card next to it, also when the chat is reopened from
/// history. A model that truly thinks first keeps a card that expands, above the full reply.
final class ReasoningReplyUITests: DemoCase {
    private func expectRankingsAsAReply() {
        XCTAssertTrue(app.staticTexts["Superpower"].firstMatch.waitForExistence(timeout: 20), "the table's header is missing")
        XCTAssertTrue(labelled("Lab / Model: ").exists, "the table's cells are missing")
        XCTAssertFalse(text("| Rank |").exists, "the table shows as raw markdown")
        XCTAssertFalse(app.buttons["Show reasoning"].exists, "the answer also shows as a reasoning card")
    }

    func testAnAnswerSentAsReasoningIsTheReply() throws {
        // The main chat is a stored chat the mock serves again to a fresh start.
        try startDemo()
        openBot("default")
        send("power rankings of open models, please")
        expectRankingsAsAReply()
        shot("reasoning-only-live")

        try startDemo()
        openBot("default")
        scrollThread(towardStart: false, times: 3)
        expectRankingsAsAReply()
        shot("reasoning-only-reopened")
    }

    func testRealThinkingKeepsItsCardAboveAWholeReply() throws {
        try beginSideChat(saying: "think it through: how many nginx logs should we keep?")
        let card = app.buttons["Show reasoning"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 60), "no reasoning card for real thinking")
        XCTAssertTrue(text("near 150 MB").waitForExistence(timeout: 60), "the reply never finished")

        // The card must clear the header before it can be touched.
        for _ in 0..<4 where card.frame.minY < threadBand.lowerBound + 10 { scrollThread(towardStart: true) }
        card.tap()
        let hide = app.buttons["Hide reasoning"].firstMatch
        XCTAssertTrue(hide.waitForExistence(timeout: 5), "the card did not open")
        XCTAssertTrue(text("rotate 8").exists || text("Recommend rotate 8").exists, "the thinking was not shown")
        XCTAssertLessThan(hide.frame.minY, text("near 150 MB").frame.minY, "the card is not above the reply")
        XCTAssertTrue(text("Postgres rotates on its own schedule").exists, "the reply under the card is not whole")
        shot("reasoning-opened")
    }
}
