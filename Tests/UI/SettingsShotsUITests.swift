import XCTest

/// Pictures of Settings for the design record, in both looks: the root, each page at its top, lower
/// down and on its Advanced page, the pages beneath those, the two summaries, every tab of a bot's
/// settings, and the Remove sheet. Nothing is asserted beyond each page being there to photograph.
final class SettingsShotsUITests: DemoCase {
    /// Settings pages by the id their row carries. "away" shows only for a phone linked to a Mac.
    private let pages = ["bots", "appearance", "notifications", "icloud", "voice", "gateways", "away", "about", "advanced"]

    private func goBack() {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists { back.tap() }
        pause(0.6)
    }

    private func openSettings() {
        tap("chats.settings", timeout: 30)
        XCTAssertTrue(find("settings.page").waitForExistence(timeout: 10), "Settings did not open")
    }

    func testEachPageTopLowerAndAdvanced() throws {
        try inBothLooks { look in
            try startDemo(["-nollie-demo-reach", "home", "-nollie.developerMode", "YES"], look: look)
            openSettings()
            shot("settings-root-\(look)")

            for page in pages {
                let row = find("settings.row.\(page)")
                // The list keeps its place between pages: slide it either way until the row shows.
                for turn in 0..<8 where !(row.exists && row.isHittable) {
                    if turn < 4 { app.swipeUp(velocity: .slow) } else { app.swipeDown(velocity: .slow) }
                }
                guard row.exists, row.isHittable else { continue }
                row.tap()
                pause(1)
                shot("settings-\(page)-top-\(look)")
                app.swipeUp(velocity: .slow)
                pause(0.5)
                shot("settings-\(page)-lower-\(look)")

                let advanced = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "identifier ENDSWITH '.advanced'")).firstMatch
                if advanced.exists, advanced.isHittable {
                    advanced.tap()
                    pause(1)
                    shot("settings-\(page)-advanced-\(look)")
                    goBack()
                }
                goBack()
                app.swipeDown(velocity: .fast)
            }
        }
    }

    func testPagesBeneathAndTheTwoSummaries() throws {
        try inBothLooks { look in
            try startDemo(look: look)
            openSettings()

            for tile in ["settings.summary.left", "settings.summary.night"] {
                let summary = find(tile)
                guard summary.waitForExistence(timeout: 10) else { continue }
                summary.tap()
                pause(1)
                shot("\(tile)-\(look)")
                goBack()
            }

            for (row, below) in [("gateways", "settings.connection.models"), ("about", "about.acknowledgements"), ("about", "about.remove")] {
                scrollTo("settings.row.\(row)").tap()
                scrollTo(below).tap()
                pause(1)
                shot("settings-\(below)-\(look)")
                goBack()
                goBack()
            }
        }
    }

    func testEveryTabOfABotsSettings() throws {
        try startDemo()
        openBot("default")
        tap("chat.more")
        tap("botmenu.settings")
        XCTAssertTrue(find("profile.tabs").waitForExistence(timeout: 15), "the bot's settings did not open")
        for tab in ["look", "instructions", "model", "papertrail", "apps", "computer", "display"] {
            tap("profile.tab.\(tab)")
            pause(0.8)
            shot("settings-bot-\(tab)")
        }
    }

    func testTheRemoveSheetInReviewAndFinished() throws {
        try startDemo()
        openSettings()
        scrollTo("settings.row.about").tap()
        scrollTo("about.remove").tap()
        tap("settings.remove")
        XCTAssertTrue(find("remove.sheet").waitForExistence(timeout: 10), "the Remove sheet did not open")
        shot("settings-remove-review")
        tap("remove.confirm")
        XCTAssertTrue(find("remove.finished").waitForExistence(timeout: 20), "the removal never finished")
        shot("settings-remove-finished")
    }
}
