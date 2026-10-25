import XCTest

/// Far down a long thread, the floating header must still receive touches. The Back button, the
/// title pill and the menu each respond where they are drawn (nothing underneath intercepts the
/// tap), and Back exits the chat.
final class HeaderHittableUITests: DemoCase {
    func testTheHeaderControlsTakeTouchesOverALongThread() throws {
        try beginLongThread(steps: 30)
        // Scroll a little so messages pass under the header.
        scrollThread(towardStart: true, times: 2)
        pause(0.5)

        for id in ["chat.back", "chat.titlePill", "chat.more"] {
            let control = find(id)
            XCTAssertTrue(control.exists, "\(id) is missing")
            XCTAssertTrue(control.isHittable, "\(id) is drawn but a touch there would not reach it")
            let frame = control.frame
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertLessThan(frame.minY, 160, "\(id) is not in the header")
        }
        shot("header-over-thread")

        tap("chat.back")
        XCTAssertTrue(poll(10) { !self.text("Nothing else needed attention").exists }, "Back did not leave the chat")
    }
}
