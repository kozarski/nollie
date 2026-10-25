import XCTest

/// A bot's settings, Papertrail tab, on the mock: today's answer at the top, the week's two counts
/// and its rows. Nothing is changed.
final class PapertrailUITests: DemoCase {
    func testPapertrailShowsTheWeek() throws {
        try startDemo(["-nollie-demo-tab", "chats", "-nollie-demo-bot-page", "settings"], waitForBots: false)
        // The default bot's settings open by themselves a few seconds after launch.
        let tab = find("profile.tab.papertrail")
        XCTAssertTrue(tab.waitForExistence(timeout: 30), "no Papertrail tab")

        // The sheet may still be rising and the tab may sit past the row's edge: try a few times.
        let stayed = find("papertrail.stayed")
        for _ in 0..<3 {
            pause(1)
            if !tab.isHittable { find("profile.tabs").swipeLeft() }
            tab.tap()
            if stayed.waitForExistence(timeout: 8) { break }
        }
        XCTAssertTrue(find("papertrail.hero").exists, "no answer for today at the top")
        XCTAssertTrue(stayed.exists, "no On this Mac count")
        XCTAssertTrue(find("papertrail.online").exists, "no Online count")

        let row = find("papertrail.row.0")
        for _ in 0..<4 where !row.exists { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no Papertrail rows")
        XCTAssertFalse(find("papertrail.off").exists, "Papertrail shows as off")
        shot("papertrail-week")
    }
}
