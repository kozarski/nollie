import XCTest

/// Pictures of the header on a long chat at the moments it can go wrong (thread end, scrolled
/// back, mid-fling, landscape), plus one check that tapping the status bar jumps to the top.
final class HeaderShotsUITests: DemoCase {
    func testTheHeaderOverALongChat() throws {
        try beginLongThread(steps: 40)
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        shot("header-at-end")

        scrollThread(towardStart: true, times: 3)
        pause(0.5)
        shot("header-scrolled-up")

        // A fling, caught while it still runs.
        app.swipeDown(velocity: .fast)
        shot("header-flinging")
        pause(1.5)

        XCUIDevice.shared.orientation = .landscapeLeft
        pause(1.5)
        shot("header-landscape")
        XCUIDevice.shared.orientation = .portrait
        pause(1.5)

        // Tapping the status bar scrolls to the start.
        tapAt(0.5, 0.014)
        let first = text("Step 1 of 40")
        XCTAssertTrue(first.waitForExistence(timeout: 10), "the status bar tap did not reach the start of the thread")
        XCTAssertLessThan(first.frame.midY, app.windows.firstMatch.frame.height / 2, "the first step is not in the top half")
        shot("header-after-status-bar-tap")
    }
}
