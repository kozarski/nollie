import XCTest

/// A reader who has scrolled away stays where they are. Nothing drags the thread back to its end
/// while a long reply is coming in, when it has finished, or while earlier messages are read.
/// (A reply that is whole at rest and ends just above the composer is WholeReplyUITests.)
final class ChatScrollUITests: DemoCase {
    private let steps = 120

    /// Notes where a piece of text stands, lets time pass, and checks it has not moved.
    private func expectStill(_ note: String, for seconds: TimeInterval, tolerance: CGFloat = 24) {
        guard let anchor = topmostThreadText() else {
            XCTFail("\(note): nothing in the thread to hold on to")
            return
        }
        poll(seconds, every: 0.5) {
            if let now = self.minY(ofText: anchor.label) {
                XCTAssertLessThanOrEqual(abs(now - anchor.minY), tolerance, "\(note): the thread moved under the reader (\(anchor.label))")
            }
            return false
        }
    }

    /// Scrolls toward the start until the first message can be seen, then holds there for a while:
    /// that row must not move although steps keep arriving below it.
    private func expectFirstMessageStill(for seconds: TimeInterval) {
        let first = find("thread.row.user")
        for _ in 0..<40 where !(first.exists && first.isHittable) { scrollThread(towardStart: true) }
        XCTAssertTrue(first.exists, "the first message was never reached")
        let before = first.frame.minY
        poll(seconds, every: 0.5) {
            if first.exists { XCTAssertLessThanOrEqual(abs(first.frame.minY - before), 24, "while streaming: the thread moved under the reader") }
            return false
        }
    }

    func testAReaderWhoScrolledAwayIsLeftAlone() throws {
        try beginSideChat(saying: "marathon \(steps)")
        XCTAssertTrue(find("thread.row.tool").waitForExistence(timeout: 40), "the turn never started its steps")

        // Away from the end while the steps are still coming in.
        let jump = app.buttons["Jump to latest"]
        expectFirstMessageStill(for: 6)
        XCTAssertTrue(jump.exists, "no way back to the end while away from it")

        // The arrow takes the reader to the end.
        jump.tap()
        XCTAssertTrue(poll(6) { !jump.exists }, "the arrow stayed after going back to the end")

        // The reply comes in whole. Then the reader goes up and is left alone.
        let lastLine = text("Nothing else needed attention")
        XCTAssertTrue(lastLine.waitForExistence(timeout: 240), "the reply never finished")
        pause(1.5)
        scrollThread(towardStart: true, times: 2)
        XCTAssertTrue(jump.waitForExistence(timeout: 5), "no arrow after scrolling up from the finished reply")
        expectStill("after the reply", for: 4)

        // Further up, among the earlier steps, the same.
        scrollThread(towardStart: true, times: 6)
        expectStill("among earlier messages", for: 4)
        shot("chat-scroll-away")
    }
}
