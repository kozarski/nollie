import XCTest

/// A reply holding a table wider than the phone. The table scrolls sideways on its own while the
/// thread stays still, assistive tools can read the screen, the full screen view opens, and
/// long-pressing the table brings up the reply menu.
final class TableRenderUITests: DemoCase {
    private func askForWideTable() throws {
        try beginSideChat(saying: "wide table please")
        XCTAssertTrue(text("log-2 is the one to watch").waitForExistence(timeout: 40), "the reply never finished")
        pause(1)
    }

    func testAWideTableScrollsOnItsOwn() throws {
        try askForWideTable()
        let screenWidth = app.windows.firstMatch.frame.width
        let lastHeader = app.staticTexts["Health"].firstMatch
        XCTAssertTrue(lastHeader.exists, "the table's last column is missing")
        XCTAssertGreaterThan(lastHeader.frame.maxX, screenWidth, "the table fits the screen, so nothing is tested")

        // Reading the entire tree must not take the app down.
        keepTree("wide-table-tree")
        XCTAssertEqual(app.state, .runningForeground)

        // A drag along the table moves the table and leaves the thread alone.
        let intro = text("Here is how the two log hosts compare")
        let threadBefore = intro.frame.minY
        let columnBefore = lastHeader.frame.minX
        slide(text("log-1 (primary)"), by: -220)
        pause(1)
        XCTAssertLessThan(lastHeader.frame.minX, columnBefore - 40, "the table did not move sideways")
        XCTAssertEqual(intro.frame.minY, threadBefore, accuracy: 8, "the thread moved with the table")
    }

    func testTheFullScreenViewAndTheReplyMenu() throws {
        try askForWideTable()

        press("Open the table full screen")
        XCTAssertTrue(app.navigationBars["Table"].waitForExistence(timeout: 10), "no sheet titled Table")
        XCTAssertTrue(app.buttons["Copy as Markdown"].exists, "no way to copy the table")
        shot("wide-table-sheet")
        press("Done")
        XCTAssertTrue(poll(10) { !self.app.navigationBars["Table"].exists }, "Done left the sheet up")

        text("log-1 (primary)").press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Copy"].waitForExistence(timeout: 5), "the reply's menu did not come up")
        XCTAssertFalse(app.buttons["Copy as Markdown"].exists, "a table menu took the long press")
    }
}
