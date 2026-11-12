import XCTest

/// What's new: the note opens, More tells the longer story, Got it closes it, and About opens it again.
final class WhatsNewUITests: DemoCase {
    func testTheNoteOpensTellsMoreAndCloses() throws {
        try startDemo(["-launchTab", "chats", "-nollie-demo-whats-new"])
        XCTAssertTrue(find("whatsNew.title").waitForExistence(timeout: 20), "the note never opened")
        XCTAssertTrue(find("whatsNew.item.who-is-working").exists)
        XCTAssertTrue(find("whatsNew.item.link-iphone").exists, "linking an iPhone is news on the iPhone too")
        XCTAssertFalse(find("whatsNew.item.local-models").exists, "a Mac-only change showed on the iPhone")
        shot("whats-new")

        XCTAssertFalse(find("whatsNew.more.who-is-working").exists, "the detail was open before More")
        tap("whatsNew.toggle.who-is-working")
        XCTAssertTrue(find("whatsNew.more.who-is-working").waitForExistence(timeout: 5), "More did not open the detail")
        shot("whats-new-more")

        // The last change the iPhone has a part in, at the end of the note.
        _ = scrollTo("whatsNew.item.listen")
        shot("whats-new-end")

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
