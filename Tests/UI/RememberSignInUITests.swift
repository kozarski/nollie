import XCTest

/// Keeping a username and password login. With the mock's password gate enabled, the sign-in form
/// asks whether to remember it (off by default), saving signs in, and Settings lists the saved
/// login with a Forget row. When the gateway ends every session, Reconnect logs in unprompted; after
/// Forget, that same expiry asks the user.
final class RememberSignInUITests: DemoCase {
    private let user = "corey"
    private let secret = "mock-pass"

    private func authLog() -> [String] { mock("/api/_mock/auth-log")["log"] as? [String] ?? [] }

    private func gate(_ on: Bool) {
        mock("/api/_mock/password-auth", ["enabled": on, "username": user, "password": secret])
    }

    func testARememberedSignInComesBackByItselfUntilForgotten() throws {
        try requireMock()
        gate(true)
        addTeardownBlock { [self] in gate(false) }

        try startDemo(["-nollie-demo-biometry", "yes"])
        openAddGatewayForm()
        fillPasswordGateway(name: "Remote", address: mockAddress, user: user, password: secret)

        // The switch starts off; turned on it says where the sign-in is kept.
        let remember = ready("gateway.rememberSignIn")
        XCTAssertTrue(remember.waitForExistence(timeout: 5))
        XCTAssertEqual(remember.value as? String, "0", "remembering should start off")
        flip(remember)
        XCTAssertTrue(wait(for: remember, "value == '1'", timeout: 5), "the switch did not turn on")
        let note = find("gateway.rememberFootnote").label
        XCTAssertTrue(note.contains("Keychain") && note.contains("Never synced"), "the line under the switch is wrong: \(note)")

        runConnectionTestUntilItPasses()
        tap("gateway.save")
        addTeardownBlock { [self] in removeSavedGateway(named: "Remote") }

        // Settings lists the remembered sign-in.
        XCTAssertTrue(find("settings.connection.add").waitForExistence(timeout: 15) || find("gateway.forgetSignIn").waitForExistence(timeout: 15))
        let forget = scrollTo("gateway.forgetSignIn")
        XCTAssertTrue(forget.exists, "Settings did not list the saved sign-in with a Forget row")

        // Every session ends at the gateway; Reconnect signs in again without asking.
        mock("/api/_mock/expire-sessions", [:])
        scrollTo("settings.connection.reconnect").tap()
        XCTAssertTrue(poll(40) { self.authLog().contains("password-login") && self.authLog().last == "password-login" },
                      "Reconnect did not sign in by itself: \(authLog())")
        XCTAssertTrue(authLog().contains("refresh expired"), "the old session was not tried first: \(authLog())")
        XCTAssertFalse(text("Sign in again").exists, "the person was asked although the sign-in is remembered")

        // After Forget, the identical expiry prompts the user.
        scrollTo("gateway.forgetSignIn").tap()
        mock("/api/_mock/expire-sessions", [:])
        scrollTo("settings.connection.reconnect").tap()
        XCTAssertTrue(poll(40) { self.authLog().last == "refresh expired" }, "the expiry was not noticed: \(authLog())")
        XCTAssertTrue(text("Sign in again").waitForExistence(timeout: 30), "nothing asked the person to sign in")
        XCTAssertEqual(authLog().last, "refresh expired", "it signed in without a remembered sign-in")
    }
}
