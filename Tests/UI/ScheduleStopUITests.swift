import XCTest

/// A schedule the Mac's scheduler started shows as its helper at work in the chat list, and Stop on
/// its page ends that one run and leaves the schedule on.
final class ScheduleStopUITests: DemoCase {
    private let runRoute = "/api/_mock/schedule-run"

    override func tearDown() {
        DemoCase.resetMock(runRoute, ["job_id": "morning-brief", "running": false])
        super.tearDown()
    }

    func testARunningScheduleShowsAndStopEndsOnlyThatRun() throws {
        try requireMock()
        _ = mock(runRoute, ["job_id": "morning-brief", "seconds_ago": 245])
        try startDemo()

        let bar = find("chats.atWork")
        XCTAssertTrue(bar.waitForExistence(timeout: 20), "no crew bar for the schedule's run")
        XCTAssertTrue(poll(10) { self.text("Working on “Morning brief”").exists }, "the bot's row does not name the schedule")
        shot("schedule-crew-bar")
        find("chats.atWork.who").tap()
        XCTAssertTrue(poll(5) { self.buttonNamed("Stop “Morning brief”").exists }, "the bar's menu has no Stop for the run")
        shot("schedule-crew-menu")
        app.tap()  // put the menu away

        openBot("default")
        tap("chat.more")
        tap("botmenu.schedules")
        let row = text("Morning brief")
        XCTAssertTrue(row.waitForExistence(timeout: 15), "no Morning brief task listed")
        row.tap()
        let stop = find("schedules.stopRun")
        XCTAssertTrue(stop.waitForExistence(timeout: 15), "the task page has no Stop for its run")
        XCTAssertTrue(find("schedules.runningFor").exists, "the page does not say how long it has run")
        shot("schedule-detail-stop")

        stop.tap()
        XCTAssertTrue(poll(10) { self.text("Stopped. The schedule stays on.").exists }, "no word that the run stopped")
        let job = (mock("/api/cron/jobs")["jobs"] as? [[String: Any]])?.first { $0["job_id"] as? String == "morning-brief" }
        XCTAssertTrue(job?["live_execution"] is NSNull, "the run is still in flight")
        XCTAssertEqual(job?["enabled"] as? Bool, true, "the schedule was turned off")
        XCTAssertTrue(poll(10) { !self.find("schedules.stopRun").exists }, "Stop stayed after the run ended")
        shot("schedule-detail-stopped")
    }
}
