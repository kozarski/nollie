import XCTest

/// A gateway the person brings. From a fresh install the person gets to the form, fills it, tests it,
/// saves, lands on the bots, sends one message and sees an answer (or the gateway's own error), and
/// can open Settings. HERMES_E2E_URL and HERMES_E2E_TOKEN name the gateway; the local mock does here.
/// For a gateway behind a user name and password, HERMES_E2E_USER and HERMES_E2E_PASSWORD are used instead
/// of the token. A second flow checks the last row of Settings clears the bottom of the screen.
final class HermesRemoteUITests: DemoCase {
    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    func testFromAFreshInstallToAFirstAnswer() throws {
        try requireMock()
        try startDemo(withGateway: false)

        // Setup is shown only to an install that has never been set up. The demo copy remembers it was.
        guard find("onboarding.continue").waitForExistence(timeout: 20) else {
            throw XCTSkip("Needs a fresh install of the demo copy (Tools/dev/make-demo-app-sim.sh)")
        }
        pause(4)   // the welcome's opening animation
        tap("onboarding.continue")
        pause(1.5)
        tap("onboarding.connectManually", timeout: 30)
        XCTAssertTrue(find("gateway.url").waitForExistence(timeout: 15), "the gateway form did not open")

        if let user = environment["HERMES_E2E_USER"], let password = environment["HERMES_E2E_PASSWORD"] {
            fillPasswordGateway(name: "Remote", address: mockAddress, user: user, password: password)
        } else {
            fillField("gateway.name", with: "Remote")
            fillField("gateway.url", with: mockAddress)
            fillField("gateway.sessionToken", with: environment["HERMES_E2E_TOKEN"] ?? "mock-token")
        }
        runConnectionTestUntilItPasses()
        tap("gateway.save")
        addTeardownBlock { [self] in removeSavedGateway(named: "Remote") }
        // Setup ends on a ready screen once the gateway answers.
        let start = find("onboarding.continue")
        XCTAssertTrue(wait(for: start, "label == 'Start chatting'", timeout: 40), "setup did not reach the ready screen")
        start.tap()
        // Starting lands in the first chat; otherwise the bots are listed and one is opened.
        XCTAssertTrue(poll(40) { self.find("composer.text").exists || self.find("bots.list").exists }, "setup did not lead anywhere")
        if !find("composer.text").exists { openBot("default") }
        send("reply with the single word pong")
        let answered = poll(60) { self.find("thread.row.reply").exists || self.find("thread.row.error").exists }
        XCTAssertTrue(answered, "neither an answer nor an error came back")
        shot("remote-first-answer")

        tap("chat.back")
        tap("chats.settings", timeout: 30)
        XCTAssertTrue(find("settings.page").waitForExistence(timeout: 15), "Settings did not open")
    }

    func testTheLastRowOfSettingsClearsTheBottomOfTheScreen() throws {
        try startDemo()
        tap("chats.settings", timeout: 30)
        XCTAssertTrue(find("settings.page").waitForExistence(timeout: 15))
        // To the very end, then the lowest row there is.
        for _ in 0..<5 { app.swipeUp(velocity: .fast) }
        pause(0.8)
        let screen = app.windows.firstMatch.frame
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "settings.row.")).allElementsBoundByIndex
        let last = rows.filter { $0.exists }.max { $0.frame.maxY < $1.frame.maxY }
        XCTAssertNotNil(last, "no rows in Settings")
        XCTAssertTrue(last?.isHittable == true, "the last row cannot be touched")
        XCTAssertLessThanOrEqual(last?.frame.maxY ?? .infinity, screen.maxY - 24, "the last row sits under the bottom of the screen")
        shot("remote-settings-end")
    }
}
