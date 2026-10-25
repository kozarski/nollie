import XCTest

/// A helper asks to use a saved sign-in. The card names the site and promises the helper is never
/// told the password; Allow once goes through Face ID (the demo copy answers yes) and Deny stops it.
/// A site with nothing saved gets no card at all.
final class SignInUITests: DemoCase {
    func testAHelperSignsInOnlyAfterAYes() throws {
        try requireMock()
        try inBothLooks { look in
            // Only example.com is saved, whatever an earlier run left behind.
            mock("/api/_mock/sign-ins", ["sites": ["example.com"], "history": true])
            try startDemo(["-nollie-demo-biometry", "yes"], look: look)
            openBot("default")

            send("sign in example.com")
            let card = text("wants to sign in to example.com")
            XCTAssertTrue(card.waitForExistence(timeout: 30), "no sign-in card")
            XCTAssertTrue(text("never told the password").exists)
            XCTAssertFalse(text("needs your OK").exists, "the plain approval card showed instead")
            XCTAssertFalse(find("approval.more").exists, "a sign-in must not offer Always")
            shot("sign-in-card-\(look)")

            if look == .light {
                tap("approval.once")
                XCTAssertTrue(text("signed in to example.com").waitForExistence(timeout: 30))
                XCTAssertTrue(text("never told your password").exists)
                shot("sign-in-done-\(look)")
            } else {
                tap("approval.deny")
                XCTAssertTrue(text("I won't sign in").waitForExistence(timeout: 20))
            }
            XCTAssertFalse(card.exists, "the card stayed after it was answered")

            send("sign in other.org")
            XCTAssertTrue(text("no saved sign-in for other.org").waitForExistence(timeout: 30))
            XCTAssertFalse(text("wants to sign in to other.org").exists, "a card appeared for a site with nothing saved")
        }
    }
}
