import XCTest

/// Private is a switch in a bot's settings, under its description: off until turned on, explained
/// once on, and off again when turned back.
final class PrivateBotUITests: DemoCase {
    func testABotCanBeMarkedPrivate() throws {
        try requireMock()
        try inBothLooks { look in
            try startDemo(look: look)
            tap("bots.row.work", timeout: 30)
            tap("chat.titlePill", timeout: 30)
            tap("profile.tab.instructions", timeout: 10)

            let toggle = app.switches["bot.editor.private"].firstMatch
            for _ in 0..<6 where !(toggle.exists && toggle.isHittable) { app.swipeUp(velocity: .slow) }
            XCTAssertTrue(toggle.isHittable, "the Private switch cannot be reached")
            // The setting lasts (Keychain and the mock's list), so begin from off.
            if toggle.value as? String == "1" { flip(toggle) }
            XCTAssertEqual(toggle.value as? String, "0", "a bot is not private until marked")

            flip(toggle)
            XCTAssertEqual(toggle.value as? String, "1")
            XCTAssertTrue(app.staticTexts["Hidden from notifications, the chat list and backups."].exists)
            shot("private-bot-\(look)")

            flip(toggle)
            XCTAssertEqual(toggle.value as? String, "0", "it should turn off again")
        }
    }
}
