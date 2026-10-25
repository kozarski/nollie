import XCTest

/// The + panel in the composer opens, folds away with its own button and opens again, and the first
/// opening is not noticeably slower than the second.
final class AttachPanelUITests: DemoCase {
    /// Opens the attach panel and returns the seconds until its Files row appears.
    private func openPanel() -> TimeInterval {
        let started = Date()
        expectShown(buttonNamed("Attach"), within: 10, "no + button").tap()
        XCTAssertTrue(find("attach.files").waitForExistence(timeout: 5), "the panel showed no Files row")
        return Date().timeIntervalSince(started)
    }

    private func foldPanel() {
        press("Close attach panel")
        XCTAssertTrue(poll(5) { !self.find("attach.files").exists }, "the panel stayed after Close")
    }

    func testThePanelOpensFoldsAndOpensAgainWithoutLag() throws {
        try startDemo()
        openBot("default")
        startSideChat()

        let first = openPanel()
        shot("attach-panel-open")
        foldPanel()
        let second = openPanel()

        XCTAssertLessThanOrEqual(first, second + 0.5, "the first opening took \(first)s against \(second)s the second time")
        foldPanel()
        shot("attach-panel-folded")
    }
}
