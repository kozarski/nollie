import XCTest

/// Settings, About, Diagnostics offers a file to share and says private details are left out.
final class DiagnosticsUITests: DemoCase {
    func testDiagnosticsOffersAFileToShare() throws {
        try startDemo(["-launchTab", "chats"])
        tap("chats.settings", timeout: 20)
        XCTAssertTrue(app.buttons["settings.done"].waitForExistence(timeout: 10))
        scrollTo("settings.row.about").tap()
        scrollTo("about.diagnostics").tap()

        XCTAssertTrue(find("diagnostics.hero").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["A file with what Nollie did today, to share if something went wrong. Private details are left out."].exists)
        XCTAssertTrue(app.buttons["diagnostics.share"].waitForExistence(timeout: 20), "no Share button")
        shot("diagnostics")
    }
}
