import XCTest

/// The Run now button on a scheduled task. A quick double tap starts one run, not two. If the gateway
/// says the task is already going (someone else started it), the app explains that in everyday
/// words and the button comes back.
final class CronRunNowUITests: DemoCase {
    private let triggerRoute = "/api/_mock/cron-triggers"

    private func runCount() -> Int {
        (mock(triggerRoute)["triggers"] as? [Any])?.count ?? 0
    }

    /// Opens the Morning brief task from the default bot's Schedules page.
    private func openMorningBrief() throws {
        try startDemo()
        openBot("default")
        tap("chat.more")
        tap("botmenu.schedules")
        let row = text("Morning brief")
        XCTAssertTrue(row.waitForExistence(timeout: 15), "no Morning brief task listed")
        row.tap()
        XCTAssertTrue(find("cron.runNow").waitForExistence(timeout: 10), "the task page has no Run now")
    }

    func testPressingRunNowTwiceRunsTheTaskOnce() throws {
        try openMorningBrief()
        let button = app.buttons["cron.runNow"]
        let before = runCount()

        button.tap()
        XCTAssertTrue(poll(3) { button.label.contains("Running") }, "the button did not say it was running")
        XCTAssertFalse(button.isEnabled, "the button stayed pressable while the run was out")
        if button.isHittable { button.tap() }

        XCTAssertTrue(poll(30) { button.label.contains("Finished") || button.label.contains("Started") }, "no word that the run went through")
        XCTAssertEqual(runCount() - before, 1, "the gateway was asked for more than one run")
        XCTAssertFalse(text("Not checked yet").exists, "the last check was not updated")
        shot("run-now-done")

        XCTAssertTrue(poll(15) { button.label == "Run now" && button.isEnabled }, "the button did not come back")
    }

    func testARefusalForATaskAlreadyRunningReadsPlainly() throws {
        try openMorningBrief()
        let button = app.buttons["cron.runNow"]

        // Another client starts the same task just ahead of us.
        var request = URLRequest(url: URL(string: mockAddress + "/api/cron/jobs/morning-brief/trigger")!)
        request.httpMethod = "POST"
        request.setValue("Bearer mock-token", forHTTPHeaderField: "Authorization")
        let elsewhere = URLSession.shared.dataTask(with: request) { _, _, _ in }
        elsewhere.resume()
        addTeardownBlock { elsewhere.cancel() }
        pause(1)

        button.tap()
        XCTAssertTrue(text("already running").waitForExistence(timeout: 15),
                      "the refusal never turned into an everyday sentence")
        XCTAssertTrue(poll(10) { button.label == "Run now" && button.isEnabled }, "the button was not ready again")
        shot("run-now-refused")
    }
}
