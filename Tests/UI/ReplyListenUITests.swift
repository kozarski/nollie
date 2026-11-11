import XCTest

/// Every finished reply can be heard. The last reply of a run keeps its play button; an older one in the same run
/// stays quiet and offers Listen in its menu instead.
final class ReplyListenUITests: DemoCase {
    func testAnOlderReplyOffersListenInItsMenu() throws {
        // "tools…": an opener, tool steps with remarks between, then a write-up: one run of several replies.
        try beginSideChat(saying: "tools check the host")
        XCTAssertTrue(text("The host, top to bottom").waitForExistence(timeout: 120), "the run never finished")
        pause(1)
        let buttons = app.buttons.matching(identifier: "reply.listen")
        XCTAssertEqual(buttons.count, 1, "only the last reply of the run shows its play button")

        scrollThread(towardStart: true, times: 6)
        let opener = text("I'll check the whole host before changing anything")
        XCTAssertTrue(opener.waitForExistence(timeout: 10), "the run's first reply is not on screen")
        opener.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Listen"].waitForExistence(timeout: 5), "the older reply's menu has no Listen")
        XCTAssertTrue(app.buttons["Copy"].exists, "the reply's menu lost its other items")
        shot("reply-listen-menu-iphone")
    }
}
