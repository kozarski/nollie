import XCTest

/// "Ask first" holds a send until the person says yes. The card names what kind of thing it is and
/// shows all of it; for a click it names the button about to be pressed on a line of its own; there
/// is never an Always. Allow once sends, Deny does not.
final class AskFirstUITests: DemoCase {
    /// Taps an answer and waits for one more reply with these words than the chat had before.
    private func answer(_ id: String, expecting words: String) {
        let replies = texts(words)
        let before = replies.count
        tap(id)
        let grew = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count > %d", before), object: replies)
        XCTAssertEqual(XCTWaiter.wait(for: [grew], timeout: 20), .completed, "no new reply with \"\(words)\"")
    }

    func testAnActionWaitsForAYes() throws {
        try requireMock()
        try inBothLooks { look in
            try startDemo(look: look)
            openBot("default")

            // An email: the card says what it is and shows the recipient.
            send("ask first email")
            let card = find("approval.askFirst")
            XCTAssertTrue(card.waitForExistence(timeout: 30), "no Ask first card")
            XCTAssertTrue(text("wants to send something").exists)
            XCTAssertTrue(text("to: sam@example.com").exists)
            XCTAssertFalse(text("needs your OK").exists, "the plain approval card showed instead")
            XCTAssertFalse(text("plugin approval rule").exists, "the gateway's own rule words leaked")
            XCTAssertFalse(find("approval.more").exists, "Ask first must not offer Always")
            XCTAssertFalse(find("approval.askFirst.check").exists, "an email has no button to name")
            shot("ask-first-\(look)")
            // The chat keeps earlier replies, so each answer waits for one more of its kind.
            if look == .light { answer("approval.once", expecting: "Sent.") } else { answer("approval.deny", expecting: "didn't send") }
            let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: card)
            XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 10), .completed, "the card stayed after it was answered")

            // A click: the card names the button and hides the raw tool details.
            send("ask first click")
            let check = find("approval.askFirst.check")
            XCTAssertTrue(check.waitForExistence(timeout: 30), "no line naming the button")
            XCTAssertTrue(check.label.contains("You're about to press “Send”."), check.label)
            XCTAssertEqual(find("approval.askFirst.summary").label, "Press “Send” on its computer.")
            XCTAssertFalse(text("local:nollie-career").exists, "a raw tool name showed")
            XCTAssertFalse(text("Click at (640, 410).").exists, "raw coordinates showed")
            XCTAssertFalse(find("approval.more").exists)
            shot("ask-first-check-\(look)")
            if look == .light { answer("approval.deny", expecting: "didn't send") } else { answer("approval.once", expecting: "Sent.") }
        }
    }

    /// Turning Ask first off for a bot says what stays: sending, buying, posting and deleting still ask.
    func testTurningItOffSaysTheFourStillAsk() throws {
        try requireMock()
        try inBothLooks { look in
            mock("/api/_mock/ask-first", [:])
            try startDemo(["-nollie-demo-bot-page", "settings", "-nollie-demo-bot-tab", "instructions"], look: look)
            flip(scrollTo("profile.askFirst"))
            let still = text("Sending, buying, posting and deleting still wait for your yes. Steps Nollie can't read won't ask.")
            XCTAssertTrue(still.waitForExistence(timeout: 10), "the turn-off question doesn't say what still asks")
            XCTAssertFalse(text("It will send, buy, post and delete without asking.").exists)
            shot("ask-first-turn-off-\(look)")
            press("Cancel")
        }
    }
}
