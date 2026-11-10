import XCTest

/// What's new: the note opens, More tells the longer story, Got it closes it, and About opens it again.
final class WhatsNewUITests: DemoCase {
    func testTheNoteOpensTellsMoreAndCloses() throws {
        try startDemo(["-launchTab", "chats", "-nollie-demo-whats-new"])
        XCTAssertTrue(find("whatsNew.title").waitForExistence(timeout: 20), "the note never opened")
        XCTAssertTrue(find("whatsNew.item.watch-board").exists)
        shot("whats-new")

        XCTAssertFalse(find("whatsNew.more.watch-board").exists, "the detail was open before More")
        tap("whatsNew.toggle.watch-board")
        XCTAssertTrue(find("whatsNew.more.watch-board").waitForExistence(timeout: 5), "More did not open the detail")
        shot("whats-new-more")

        tap("whatsNew.done")
        XCTAssertFalse(find("whatsNew.title").waitForExistence(timeout: 2), "Got it did not close the note")

        // The same note, again, from Settings.
        tap("chats.settings", timeout: 20)
        scrollTo("settings.row.about").tap()
        scrollTo("about.whatsNew").tap()
        XCTAssertTrue(find("whatsNew.title").waitForExistence(timeout: 10), "About did not open the note")
        tap("whatsNew.done")
    }
}
