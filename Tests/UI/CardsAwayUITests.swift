import XCTest

/// Off-screen HTML cards release their web views and rebuild them when scrolled back into reach.
final class CardsAwayUITests: DemoCase {
    func testWebViewsGoWhenFarAwayAndReturnOnTheWayBack() throws {
        try beginSideChat(saying: "card please")
        XCTAssertTrue(text("nginx is still the one growing").waitForExistence(timeout: 40), "the first card never finished")
        send("card again please")
        XCTAssertTrue(poll(60) { self.texts("nginx is still the one growing").count >= 2 || self.app.webViews.count >= 2 }, "the second card never came")
        XCTAssertGreaterThan(app.webViews.count, 0, "a card on screen has no web view")

        // Ten plain replies push both cards far above the screen.
        for turn in 1...10 {
            send("table number \(turn)")
            XCTAssertTrue(poll(40) { !self.find("thread.typing").exists && !self.find("composer.stop").exists },
                          "table reply \(turn) never finished")
        }
        pause(2)
        XCTAssertEqual(app.webViews.count, 0, "web views were kept for cards far off screen")

        // Back up to them, and they are drawn again.
        let cameBack = poll(60, every: 0.5) {
            self.scrollThread(towardStart: true, times: 3)
            return self.app.webViews.count > 0
        }
        XCTAssertTrue(cameBack, "the cards were not drawn again on the way back up")
        shot("cards-away-back")
    }
}
