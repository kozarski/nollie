import XCTest

/// Inert pairing previews exercise the phone's pairing screens without a camera or a real invitation.
final class DevicePairingUITests: DemoCase {
    private func startPreview(scanner: Bool = false, link: Bool = false, look: Look = .light) throws {
        var flags = ["-nollie-show-welcome", "-nollie-demo-pairing"]
        if scanner { flags.append("-nollie-demo-pairing-scanner") }
        if link { flags.append("-nollie-demo-link") }
        try startDemo(flags, look: look, waitForBots: false)
    }

    func testThePairingConfirmationNamesTheMacAndNeverRedeems() throws {
        try startPreview()
        XCTAssertTrue(find("pairing.preview").waitForExistence(timeout: 20))
        XCTAssertTrue(find("pairing.name").label.contains("Studio Mac"))
        XCTAssertEqual(find("pairing.address").label, "https://studio.example.invalid")
        let connect = app.buttons["pairing.confirm"]
        XCTAssertTrue(connect.exists)
        XCTAssertFalse(connect.isEnabled, "a preview must never redeem an invitation")
        XCTAssertFalse(find("pairing.camera").exists)
        shot("pairing-confirmation-preview")

        app.buttons["pairing.manual"].tap()
        XCTAssertTrue(app.textFields["gateway.name"].waitForExistence(timeout: 10), "manual setup did not open the gateway form")
        XCTAssertFalse(app.buttons["gateway.save"].isEnabled, "manual setup must still need a real connection test")
    }

    func testTheLinkConfirmationNamesTheMacAndNeverLinks() throws {
        try startPreview(link: true)
        XCTAssertTrue(find("pairing.preview").waitForExistence(timeout: 20))
        XCTAssertEqual(find("link.name").label, "Link to Studio Mac?")
        let link = app.buttons["link.confirm"]
        XCTAssertTrue(link.exists)
        XCTAssertFalse(link.isEnabled, "a preview must never link")
        XCTAssertFalse(find("pairing.camera").exists)
        shot("link-confirmation-preview")
    }

    func testTheScannerExplainsTheCameraBeforeAskingAndClosesToTheNextStep() throws {
        try startPreview(scanner: true, look: .dark)
        // The camera is asked for only after the reason is read: no live picture yet, an Allow button.
        expectShown(find("pairing.camera.reason"), within: 20, "the scanner gave no reason for the camera")
        XCTAssertTrue(find("pairing.camera.allow").exists, "no way to allow the camera")
        XCTAssertFalse(find("pairing.camera").exists, "the live camera is showing before it was allowed")
        shot("pairing-scanner-preview-dark")

        app.buttons["pairing.close"].tap()
        let next = app.buttons["onboarding.continue"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        next.tap()
        XCTAssertEqual(find("onboarding.title").label, "Set up Nollie on your Mac.")
        XCTAssertEqual(next.label, "Scan QR code")
        XCTAssertTrue(app.buttons["onboarding.connectManually"].exists)
        XCTAssertFalse(app.buttons["onboarding.route.new"].exists)
        XCTAssertFalse(app.buttons["onboarding.route.importCopy"].exists)
        shot("phone-mac-pairing-step")
    }
}
