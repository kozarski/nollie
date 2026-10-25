import XCTest

/// Settings, Bots lists each bot, and opening one shows the shared Look editor (there is no separate
/// glass-for-all row or studio glass control). Nothing is changed.
final class BotsSettingsUITests: DemoCase {
    func testBotsOwnsTheSharedLookEditor() throws {
        try startDemo()
        tap("chats.settings", timeout: 30)
        tap("settings.row.bots")
        let work = find("settings.bots.profile.work")
        XCTAssertTrue(work.waitForExistence(timeout: 10), "the Work bot is not listed")
        XCTAssertFalse(find("settings.bots.glassAll").exists, "the glass-for-all row came back")

        work.tap()
        XCTAssertTrue(find("profile.tab.look").waitForExistence(timeout: 10), "no Look tab")
        let editor = find("bot.editor.look.section")
        for _ in 0..<4 where !editor.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(editor.exists, "no shared look editor")
        XCTAssertFalse(find("studio.glass").exists, "the studio glass control came back")
        shot("bots-shared-look-editor")
    }
}
