import XCTest

/// Returning after a long turn. During the absence the gateway keeps the turn running and the sockets
/// die; on return the chat must respond to taps quickly and display the completed report.
/// HERMES_E2E_AWAY sets the time away in seconds (default 60) and HERMES_E2E_STEPS the run length.
final class LongTurnReturnUITests: DemoCase {
    private func setting(_ name: String, default value: Int) -> Int {
        ProcessInfo.processInfo.environment[name].flatMap { Int($0) } ?? value
    }

    func testAChatStillAnswersAfterALongTurnAndATimeAway() throws {
        let steps = setting("HERMES_E2E_STEPS", default: 600)
        let awaySeconds = setting("HERMES_E2E_AWAY", default: 60)
        try beginSideChat(saying: "marathon \(steps)")
        XCTAssertTrue(find("thread.row.tool").waitForExistence(timeout: 40), "the run never got going")

        // Home Screen for a while; on a real phone the sockets die in that time.
        XCUIDevice.shared.press(.home)
        pause(TimeInterval(awaySeconds))
        mock("/mock/drop-sockets", [:])

        let returned = Date()
        app.activate()
        XCTAssertEqual(app.state, .runningForeground, "the app did not come back to the front")

        // The chat answers a touch: the + panel opens.
        expectShown(buttonNamed("Attach"), within: 12, "no + button within 12 seconds of returning").tap()
        let fold = expectShown(buttonNamed("Close attach panel"), within: 12, "the + panel did not open within 12 seconds")
        let panelAfter = Date().timeIntervalSince(returned)
        fold.tap()

        // The report must end up visible, either by itself or after tapping the arrow.
        let lastLine = text("Nothing else needed attention")
        let reached = poll(TimeInterval(steps) / 2 + 120, every: 1) {
            if lastLine.exists && lastLine.isHittable { return true }
            let jump = self.app.buttons["Jump to latest"]
            if jump.exists && jump.isHittable { jump.tap() }
            return false
        }
        XCTAssertTrue(reached, "the end of the report was never reached")
        XCTAssertEqual(app.state, .runningForeground)
        print("LONG-TURN steps=\(steps) away=\(awaySeconds)s panel=\(String(format: "%.1f", panelAfter))s end=\(String(format: "%.1f", Date().timeIntervalSince(returned)))s")
        shot("long-turn-return")
    }
}
