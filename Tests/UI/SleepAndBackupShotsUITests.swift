import XCTest

/// Pictures of the sleep notes and the backup model, in both looks: the Night shift card when the Mac slept, a
/// schedule whose last run waited for it, the chat line when the backup took over and when the plan came back,
/// and the Models page's "If my plan runs out" switch.
final class SleepAndBackupShotsUITests: DemoCase {
    private func goBack() {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists { back.tap() }
        pause(0.6)
    }

    func testTheNightShiftCardSaysWhenTheMacSlept() throws {
        try inBothLooks { look in
            try requireMock()
            mock("/api/_mock/night-shift", [:])
            try startDemo(look: look)
            tap("chats.settings", timeout: 30)
            tap("settings.summary.night", timeout: 20)
            let note = expectShown(find("post.nightShift.sleep"), within: 30, "the sleep line")
            XCTAssertTrue(note.label.hasPrefix("Your Mac was asleep from "), note.label)
            XCTAssertTrue(note.label.hasSuffix("One run waited until it woke and three were skipped."), note.label)
            XCTAssertTrue(find("post.nightShift.missed.c71d02").exists, "the schedule that missed its times")
            shot("sleep-night-shift-\(look)")
            app.swipeUp(velocity: .slow)
            pause(0.6)
            shot("sleep-night-shift-lower-\(look)")
        }
    }

    func testAScheduleSaysWhyItsLastRunWasLate() throws {
        try inBothLooks { look in
            try startDemo(look: look)
            tap("bots.row.default", timeout: 30)
            tap("chat.more", timeout: 30)
            tap("botmenu.schedules")
            tap("schedules.task.morning-brief")
            let line = expectShown(find("schedules.lateRun"), within: 20, "why the last run was late")
            XCTAssertTrue(line.label.hasPrefix("Your Mac was asleep at "), line.label)
            shot("sleep-schedule-\(look)")
        }
    }

    func testTheChatSaysWhenTheBackupTookOverAndWhenThePlanCameBack() throws {
        try inBothLooks { look in
            try startDemo(["-nollie-demo-say", "Backup-check-on-the-backups"], look: look)
            let line = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "so Nollie is using Llama")).firstMatch
            XCTAssertTrue(line.waitForExistence(timeout: 40), "the backup line")
            pause(1)
            shot("backup-chat-\(look)")
        }
    }

    func testTheModelsPageOffersABackup() throws {
        try inBothLooks { look in
            try requireMock()
            mock("/api/config?profile=default", ["config": ["fallback_providers": []]], method: "PUT")
            try startDemo(look: look)
            tap("chats.settings", timeout: 30)
            scrollTo("settings.row.gateways").tap()
            scrollTo("settings.connection.models").tap()
            let backup = scrollTo("models.backup")
            pause(1)
            shot("backup-models-off-\(look)")
            backup.switches.firstMatch.tap()
            XCTAssertTrue(find("models.backup.choice").waitForExistence(timeout: 15), "the backup's choice")
            pause(1)
            shot("backup-models-on-\(look)")
            mock("/api/config?profile=default", ["config": ["fallback_providers": []]], method: "PUT")
        }
    }
}
