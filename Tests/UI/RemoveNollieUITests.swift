import XCTest

/// Settings, About, Remove: the sheet says what goes and what stays, then removes line by line.
/// The demo copy only pretends, so nothing on the simulator is deleted.
final class RemoveNollieUITests: DemoCase {
    func testRemoveSaysWhatGoesThenRemovesLineByLine() throws {
        try startDemo(["-launchTab", "chats"])
        tap("chats.settings", timeout: 20)
        scrollTo("settings.row.about").tap()
        ready("about.remove").tap()

        let open = ready("settings.remove")
        XCTAssertEqual(open.label, "Remove Nollie's data…")
        open.tap()
        let title = app.staticTexts["remove.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertEqual(title.label, "Remove Nollie's data")
        XCTAssertTrue(app.staticTexts["What goes"].exists)
        XCTAssertTrue(app.staticTexts["What stays"].exists)
        XCTAssertTrue(app.staticTexts["Your bots and chats on your Hermes."].exists)
        let iCloudLine = app.staticTexts["Delete Nollie's alerts in iCloud"]
        XCTAssertFalse(iCloudLine.exists, "the iCloud line shows before it is asked for")
        shot("remove-review")

        let cloud = app.switches["remove.icloud"]
        XCTAssertTrue(cloud.exists)
        flip(cloud)
        XCTAssertTrue(iCloudLine.waitForExistence(timeout: 5), "the iCloud switch added no line")

        // Cancel leaves everything as it was.
        app.buttons["remove.cancel"].tap()
        XCTAssertTrue(app.buttons["settings.remove"].waitForExistence(timeout: 5))
        app.buttons["settings.remove"].tap()
        ready("remove.confirm").tap()

        let finished = app.staticTexts["remove.finished"]
        XCTAssertTrue(finished.waitForExistence(timeout: 20), "the removal never finished")
        XCTAssertEqual(finished.label, "Nollie's data is gone")
        shot("remove-finished")
        app.buttons["remove.done"].tap()
        XCTAssertFalse(finished.waitForExistence(timeout: 3), "the sheet stayed after Done")
    }
}
