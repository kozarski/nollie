import XCTest

/// Tapping a link inside an HTML card hands it to the browser; the card never navigates itself.
final class CardLinkUITests: DemoCase {
    func testALinkInACardOpensOutsideTheApp() throws {
        try beginSideChat(saying: "card please")
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 60), "the card never showed")
        let heading = web.staticTexts["/var/log, last 7 days"]
        XCTAssertTrue(heading.waitForExistence(timeout: 20), "the card's heading is missing")

        let link = web.links.firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 10), "the card has no link")
        // The link sits at the foot of a tall card: keyboard away, thread up until it can be touched.
        dismissKeyboard()
        for _ in 0..<6 where !link.isHittable { scrollThread(towardStart: false) }
        XCTAssertTrue(link.isHittable, "the card's link cannot be reached")
        link.tap()
        XCTAssertTrue(poll(15) { self.app.state != .runningForeground }, "the link did not take the person out of the app")

        app.activate()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.webViews.firstMatch.staticTexts["/var/log, last 7 days"].exists, "the card lost its own page")
        XCTAssertFalse(app.webViews.firstMatch.staticTexts["Example Domain"].exists, "the card followed the link instead of handing it off")
    }
}
