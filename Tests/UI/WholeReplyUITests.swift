import XCTest

/// A reply arrives like a message: the typing bubble and the turn's tool steps while it is written,
/// then the whole bubble at once, its end resting just above the composer.
final class WholeReplyUITests: DemoCase {
    func testAReplyArrivesWholeAfterTheTypingBubble() throws {
        try startDemo(["-launchTab", "chats"])
        openBot("default")
        startSideChat()
        send("marathon 8")

        let typing = find("thread.typing")
        XCTAssertTrue(typing.waitForExistence(timeout: 15), "no typing bubble while the reply was written")
        XCTAssertTrue(find("thread.row.tool").waitForExistence(timeout: 30), "the tool steps did not show as the turn ran")
        shot("whole-reply-typing")

        // The report's first heading must never be on screen without its last line.
        let heading = text("Shard 001")
        let lastLine = text("Nothing else needed attention")
        poll(90, every: 0.3) {
            if heading.exists { XCTAssertTrue(lastLine.exists, "part of the reply showed before the whole of it") }
            return lastLine.exists
        }
        XCTAssertTrue(lastLine.waitForExistence(timeout: 5), "the reply never arrived")

        // At rest: the end sits just above the composer, the thread still following.
        pause(1.5)
        let composer = chatField
        XCTAssertFalse(typing.exists, "the typing bubble stayed after the reply arrived")
        XCTAssertTrue(lastLine.isHittable, "the end of the reply is off screen")
        XCTAssertLessThanOrEqual(lastLine.frame.maxY, composer.frame.minY, "the end of the reply is under the composer")
        XCTAssertLessThanOrEqual(composer.frame.minY - lastLine.frame.maxY, 80, "a gap opened below the reply")
        XCTAssertFalse(app.buttons["Jump to latest"].exists, "the thread was left away from its end")
        shot("whole-reply-arrived")
    }
}
