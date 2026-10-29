import XCTest

/// A phone linked to a Mac, against the mock's door routes. At home, Settings has one Away from home
/// switch, Tailscale's steps until the Mac has it, then Ready. Away without Tailscale, a send shows a
/// card instead of sending. A Mac behind a Tailscale exit node shows a card on its Computer tab until
/// the relay carries the traffic.
final class AwayFromHomeUITests: DemoCase {
    private let linkRoute = "/api/_mock/link"
    private let computerRoute = "/api/_mock/own-computer"

    /// Starts the demo copy as a phone that reaches its Mac `reach` ("home" or "away").
    private func startLinked(_ reach: String, _ extra: [String] = []) throws {
        try requireMock()
        mock(linkRoute, ["reset": true])
        let dark = ProcessInfo.processInfo.environment["HERMES_E2E_APPEARANCE"] == "dark"
        try startDemo(["-nollie-demo-tab", "chats", "-nollie-demo-reach", reach] + extra, look: dark ? .dark : .light)
    }

    /// A picture, named for the flow and the look, also kept as a PNG when HERMES_E2E_SHOTS is set.
    private func picture(_ name: String) {
        let dark = ProcessInfo.processInfo.environment["HERMES_E2E_APPEARANCE"] == "dark"
        shot("away-\(name)-\(dark ? "dark" : "light")")
    }

    /// Turns a switch that may be busy for a moment, and waits until it has moved.
    private func flipWhenReady(_ toggle: XCUIElement) {
        if !toggle.isHittable { app.swipeUp(velocity: .slow) }
        let before = toggle.value as? String
        XCTAssertTrue(poll(15) { toggle.isEnabled }, "the switch stayed busy")
        flip(toggle)
        XCTAssertTrue(poll(8) { toggle.value as? String != before }, "the switch did not move")
    }

    func testOneSwitchThenTailscalesStepsThenReady() throws {
        try startLinked("home")
        XCTAssertTrue(find("link.reach").waitForExistence(timeout: 10), "no status line")
        XCTAssertEqual(find("link.reach").label, "At home")

        tap("chats.settings")
        scrollTo("settings.row.away").tap()
        XCTAssertTrue(find("away.hero").waitForExistence(timeout: 10))
        XCTAssertEqual(find("away.hero").label, "At home")
        XCTAssertEqual(find("away.lead").label, "Everything works.")
        let without = find("away.without").label
        let with = find("away.with").label
        XCTAssertTrue(without.contains("Without Tailscale") && without.contains("Alerts"), without)
        for word in ["With Tailscale", "Chat", "Approve", "Stop", "Watch"] { XCTAssertTrue(with.contains(word), with) }

        let toggle = app.switches["away.switch"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertTrue(poll(15) { toggle.isEnabled }, "the switch never became ready")
        XCTAssertEqual(toggle.value as? String, "0", "a new install starts with the switch off")
        picture("off")

        // Turned on while the Mac has no Tailscale: the steps, plainly.
        flipWhenReady(toggle)
        XCTAssertTrue(find("away.needsTailscale").waitForExistence(timeout: 10), "no steps")
        XCTAssertTrue(text("This needs Tailscale, a free app that links your Mac and iPhone privately.").exists)
        XCTAssertTrue(text("Get Tailscale on your Mac").exists && text("Sign in with the same account on both").exists)
        XCTAssertFalse(find("away.ready").exists)
        app.swipeUp(velocity: .slow)
        picture("needs-setup")

        // Tailscale turns up on the Mac and the page notices by itself.
        mock(linkRoute, ["tailscale": "ready"])
        XCTAssertTrue(find("away.ready").waitForExistence(timeout: 12), "never Ready")
        XCTAssertFalse(find("away.needsTailscale").exists)
        app.swipeDown(velocity: .slow)
        picture("ready")

        flipWhenReady(toggle)
        XCTAssertTrue(poll(15) { !self.find("away.ready").exists })
        XCTAssertEqual(mock(linkRoute)["log"] as? [String], ["on", "off"], "each change should reach the Mac once")
    }

    func testAwayWithoutTailscaleASendShowsTheCardInstead() throws {
        try startLinked("away", ["-nollie-demo-alerts", "-nollie-demo-open-main"])
        XCTAssertTrue(find("link.reach").waitForExistence(timeout: 10), "no status line")
        XCTAssertEqual(find("link.reach").label, "Away · alerts only")
        picture("status-away")

        let composer = typeMessage("Are you there?")
        tap("composer.send", timeout: 5)
        let title = find("awayCard.title")
        XCTAssertTrue(title.waitForExistence(timeout: 5), "no away card")
        XCTAssertEqual(title.label, "You're away from home.")
        XCTAssertEqual(find("awayCard.message").label, "This needs Tailscale to reach your Mac.")
        picture("card")

        tap("awayCard.setUp")
        XCTAssertTrue(find("away.needsTailscale").waitForExistence(timeout: 5), "Set up shows no steps")
        XCTAssertTrue(text("On your Mac, turn on Away from home").exists, "the Mac's switch was not named")
        picture("card-steps")

        tap("awayCard.done")
        XCTAssertTrue(poll(15) { !self.find("awayCard").exists })
        XCTAssertEqual(composer.value as? String, "Are you there?", "the typed words were lost")
    }

    /// Away through iCloud, ready: the page says it works away from home first, with one switch, and
    /// Tailscale waits under Advanced.
    func testThroughICloudThePageSaysItWorksAwayFromHome() throws {
        for look in Look.allCases {
            try requireMock()
            mock(linkRoute, ["reset": true])
            try startDemo(["-nollie-demo-tab", "settings", "-nollie-demo-reach", "home", "-nollie-demo-icloud", "ready",
                           "-nollie-demo-settings", "away"], look: look)
            XCTAssertTrue(find("away.hero").waitForExistence(timeout: 15), "no away page")
            XCTAssertTrue(poll(10) { self.find("away.hero").label == "Works away from home" }, find("away.hero").label)
            XCTAssertEqual(find("away.lead").label, "Through your own iCloud.")
            let facts = find("away.icloud.facts").label
            for word in ["Chat", "Approve", "Stop"] { XCTAssertTrue(facts.contains(word), facts) }
            let toggle = app.switches["away.icloud.switch"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            XCTAssertEqual(toggle.value as? String, "1", "on by default once it is safe")
            XCTAssertFalse(find("away.without").exists, "the old comparison leads no more")
            shot("away-icloud-\(look.rawValue)")
            app.swipeUp(velocity: .slow)
            XCTAssertTrue(find("away.tailscaleHeading").waitForExistence(timeout: 5))
            XCTAssertTrue(app.switches["away.switch"].exists, "Tailscale's switch stays, under Advanced")
            shot("away-icloud-advanced-\(look.rawValue)")

            // Turned off, the page goes back to what works without it.
            app.swipeDown(velocity: .slow)
            flip(toggle)
            XCTAssertTrue(poll(10) { self.find("away.hero").label == "At home" }, "the page did not change")
            shot("away-icloud-off-\(look.rawValue)")
            app.terminate()
        }
    }

    /// Away, with iCloud ready, the bots list says how the phone reaches the Mac.
    func testAwayThroughICloudTheListSaysSo() throws {
        try startLinked("away", ["-nollie-demo-icloud", "ready"])
        XCTAssertTrue(find("link.reach").waitForExistence(timeout: 10), "no status line")
        XCTAssertTrue(poll(10) { self.find("link.reach").label == "Away · through iCloud" }, find("link.reach").label)
        picture("status-icloud")
    }

    /// Opens the Work bot's Computer tab on a Mac that sends everything through an exit node.
    private func startBehindExitNode() throws {
        try startLinked("home", ["-nollie-demo-bot-page", "settings", "-nollie-demo-bot-profile", "work", "-nollie-demo-bot-tab", "computer"])
        mock(computerRoute, ["exit_node": true])
        addTeardownBlock { [self] in _ = mock(computerRoute, ["reset": true]) }
        XCTAssertTrue(find("exitNode.card").waitForExistence(timeout: 40), "no exit node card")
    }

    func testAnExitNodeOnTheMacShowsACardOnTheComputerTab() throws {
        try startBehindExitNode()
        XCTAssertTrue(text("Your Mac sends everything through a Tailscale exit node, so your helpers' computers can't reach the internet. Turn off the exit node in Tailscale on your Mac.").exists)
        XCTAssertFalse(find("exitNode.open").exists, "the iPhone has no Tailscale to open")
        picture("exit-node")
    }

    func testTheExitNodeCardLeavesOnceTheRelayCarriesTheTraffic() throws {
        try startBehindExitNode()
        let card = find("exitNode.card")
        mock(computerRoute, ["relay": true])
        XCTAssertTrue(poll(40) { !card.exists }, "the card stayed although the relay carries the traffic")
        XCTAssertTrue(find("profile.ownComputer").exists)
        picture("exit-node-relay")
    }
}
