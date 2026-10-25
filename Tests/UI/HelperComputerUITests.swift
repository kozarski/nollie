import XCTest

/// "A computer of its own" in Bot settings, on the mock's computer add-on: off by default, the
/// iPhone's plain step while Cua is missing, the switch turning on once the Mac is ready, the
/// computer getting ready, its state, Start fresh under Advanced, then off and Remove under
/// Advanced. Every change reaches the add-on once. Uses only the demo copy and the local mock gateway.
@MainActor
final class HelperComputerUITests: XCTestCase {
    private var app: XCUIApplication!
    private var address = ""

    func testOneSwitchGivesAHelperItsOwnComputer() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["HERMES_E2E_URL"], let url = URL(string: address),
              url.scheme == "http", ["127.0.0.1", "localhost", "::1"].contains(url.host ?? ""),
              environment["HERMES_E2E_TOKEN"] == "mock-token" else {
            throw XCTSkip("Requires the local mock gateway")
        }
        let bundle = environment["HERMES_E2E_BUNDLE"] ?? "com.coreykozarski.nollie.demo"
        guard bundle.hasSuffix(".demo") else { throw XCTSkip("Uses the demo copy only") }
        continueAfterFailure = false
        self.address = address
        try mock(["reset": true, "setup": "no_cua", "ready_after": 3])

        app = XCUIApplication(bundleIdentifier: bundle)
        app.launchArguments = ["-nollie-demo-gateway", address, "mock-token", "Studio", "-companionPromptShown", "YES",
                               "-notificationsSetupCardDone", "YES", "-nollie-demo-tab", "chats",
                               "-nollie-demo-bot-page", "settings", "-nollie-demo-bot-profile", "work",
                               "-nollie-demo-bot-tab", "computer",
                               // Pictures in both appearances: HERMES_E2E_APPEARANCE=dark.
                               "-colorSchemePreference", environment["HERMES_E2E_APPEARANCE"] == "dark" ? "dark" : "light"]
        app.launch()

        let toggle = app.switches["profile.ownComputer"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 30), "no switch")
        XCTAssertTrue(wait { toggle.isEnabled }, "the switch never became ready")
        XCTAssertEqual(toggle.value as? String, "0", "off by default")
        XCTAssertTrue(text("so your files stay out of reach").exists, "no plain line")
        shot("off")

        // No Cua on the Mac: the phone says plainly where to set it up.
        flip(toggle)
        XCTAssertTrue(any("profile.ownComputer.prompt").waitForExistence(timeout: 10), "no guided step")
        XCTAssertTrue(text("Open Nollie on your Mac").exists)
        XCTAssertEqual(toggle.value as? String, "1")
        shot("setup")

        // Cua is set up on the Mac: the switch carries on by itself.
        try mock(["setup": "ready"])
        XCTAssertTrue(any("profile.ownComputer.gettingReady").waitForExistence(timeout: 15), "never getting ready")
        XCTAssertTrue(text("The first time takes a few minutes").exists)
        shot("getting-ready")
        let status = any("profile.ownComputer.status")
        XCTAssertTrue(status.waitForExistence(timeout: 20), "no card")
        XCTAssertTrue(wait { self.shows("Ready") }, "not Ready")
        XCTAssertTrue(any("profile.ownComputer.watch").exists, "no Watch")
        shot("card")

        // Under Advanced: its name, and Start fresh, which asks first.
        openAdvanced()
        XCTAssertTrue(any("profile.ownComputer.info").waitForExistence(timeout: 10), "no computer name")
        let startFresh = any("profile.ownComputer.reset")
        XCTAssertTrue(startFresh.waitForExistence(timeout: 5), "no Start fresh")
        shot("advanced")
        startFresh.tap()
        let reset = app.buttons["Erase and start fresh"]
        XCTAssertTrue(reset.waitForExistence(timeout: 5), "Start fresh didn't ask")
        reset.tap()
        goBack()
        XCTAssertTrue(wait { self.any("profile.ownComputer.gettingReady").exists || (self.shows("Ready")) }, "reset not shown")
        XCTAssertTrue(wait(30) { self.shows("Ready") }, "not Ready after reset")

        // Off leaves its computer; Remove, under Advanced, asks first.
        flip(toggle)
        XCTAssertEqual(toggle.value as? String, "0")
        openAdvanced()
        let remove = any("profile.ownComputer.remove")
        XCTAssertTrue(remove.waitForExistence(timeout: 15), "no Remove its computer")
        remove.tap()
        let confirm = app.buttons["Remove"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Remove didn't ask")
        confirm.tap()
        XCTAssertTrue(wait { !remove.exists }, "still offers Remove")

        let log = try mock([:])["log"] as? [[String: Any]] ?? []
        XCTAssertEqual(log.compactMap { $0["action"] as? String }, ["on", "reset", "off", "remove"], "each change sent once")
        XCTAssertTrue(log.allSatisfy { $0["profile"] as? String == "work" })
    }

    // MARK: Helpers

    /// The Computer tab's Advanced page, scrolled to if it is below the fold.
    private func openAdvanced() {
        let row = any("profile.computer.advanced")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no Advanced row")
        for _ in 0..<4 where !row.isHittable { app.swipeUp(velocity: .slow) }
        row.tap()
        XCTAssertTrue(any("profile.computer.advanced.page").waitForExistence(timeout: 5), "Advanced didn't open")
    }

    /// Back from the Advanced page to the tab.
    private func goBack() {
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(wait(5) { !self.any("profile.computer.advanced.page").exists }, "still on Advanced")
    }

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    /// The card's status word, matched in one query so a redraw can't fail the read.
    private func shows(_ word: String) -> Bool {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'profile.ownComputer.status' AND label == %@", word)).firstMatch.exists
    }

    private func text(_ words: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", words)).firstMatch
    }

    /// A list row's switch: tap its knob once it can be changed, and wait for the new value.
    private func flip(_ toggle: XCUIElement) {
        if !toggle.isHittable { app.swipeUp(velocity: .slow) }
        let before = toggle.value as? String
        XCTAssertTrue(wait { toggle.isEnabled }, "the switch stayed busy")
        let knob = toggle.switches.firstMatch
        (knob.exists ? knob : toggle).tap()
        XCTAssertTrue(wait(5) { toggle.value as? String != before }, "the switch didn't move")
    }

    private func wait(_ seconds: TimeInterval = 15, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "own-computer-" + name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @discardableResult
    private func mock(_ body: [String: Any]) throws -> [String: Any] {
        var request = URLRequest(url: try XCTUnwrap(URL(string: address + "/api/_mock/own-computer")))
        request.httpMethod = body.isEmpty ? "GET" : "POST"
        request.timeoutInterval = 5
        if !body.isEmpty {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let done = expectation(description: "mock answered")
        var answer: [String: Any] = [:]
        var status = 0
        URLSession.shared.dataTask(with: request) { data, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            answer = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 8)
        XCTAssertEqual(status, 200, "the mock gateway took the fixture")
        return answer
    }
}
