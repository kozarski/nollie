import XCTest

/// About shows only Nollie's own identity. The version and Developer Mode wait behind Advanced.
final class AboutSourceUITests: DemoCase {
    func testAboutShowsOnlyNollieIdentity() throws {
        try startDemo(["-launchTab", "chats"])
        tap("chats.settings", timeout: 20)
        XCTAssertTrue(app.buttons["settings.done"].waitForExistence(timeout: 10))
        scrollTo("settings.row.about").tap()

        XCTAssertTrue(find("about.wordmark").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Your own crew of helpers, on your Mac and iPhone."].exists)
        XCTAssertTrue(app.buttons["about.acknowledgements"].exists)
        XCTAssertTrue(app.buttons["about.remove"].exists)
        XCTAssertFalse(app.links["Send feedback"].exists, "a feedback link is back")
        shot("about-nollie")

        scrollTo("about.advanced").tap()
        let version = app.staticTexts["about.version"]
        XCTAssertTrue(version.waitForExistence(timeout: 10))
        XCTAssertTrue(version.label.hasPrefix("Version "), version.label)
        XCTAssertTrue(app.switches["settings.developerMode"].exists)
        shot("about-advanced")
    }
}
