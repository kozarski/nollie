import XCTest

/// The chats on a wide screen (an iPad, an iPhone Duo opened out) and on a narrow one. Wide, the
/// list stays on the left, picking a bot swaps the chat beside it with no Back, and extras take the
/// right half in a panel. Narrow, it is the phone's one stack, as before. Each test skips on the
/// other kind of screen. Run with HERMES_E2E_SHOTS=<folder> to keep the pictures.
final class WideLayoutUITests: DemoCase {
    private var isWide: Bool { app.windows.firstMatch.frame.width >= 700 }

    func testTheListBesideTheChatInBothLooks() throws {
        try inBothLooks { mode in
            try startDemo(look: mode)
            guard isWide else { throw XCTSkip("Needs a wide screen") }
            expectShown(find("chats.empty"), "nothing is chosen yet, so the chat side waits")
            look("wide-empty-\(mode)")

            openBot("default")
            XCTAssertFalse(find("chat.back").exists, "beside the list a chat has no Back")
            XCTAssertTrue(find("bots.list").isHittable, "the list stays beside the chat")
            look("wide-chat-\(mode)", after: 1.5)
            expectShown(buttonNamed("Attach"), within: 10, "no + button").tap()
            expectShown(find("attach.files"), within: 5, "the + panel opened")
            look("wide-attach-\(mode)")
            buttonNamed("Close attach panel").tap()
            pause(0.6)

            // Another bot replaces the chat at once, and the list stays put.
            openBot("work")
            XCTAssertTrue(find("bots.list").isHittable)
            look("wide-switched-\(mode)", after: 1.5)

            // Papertrail opens in the right half; the chat moves to the left half.
            // The search field names what sits in it after itself, so the button goes by its label.
            buttonNamed("Papertrail").tap()
            expectShown(find("panel.close"), "Papertrail opens in the panel")
            XCTAssertTrue(find("composer.text").exists, "the chat stays on screen beside the panel")
            look("wide-panel-\(mode)", after: 1.2)
            if find("panel.expand").exists {
                tap("panel.expand")
                look("wide-panel-expanded-\(mode)", after: 1)
                tap("panel.expand")
            }
            tap("panel.close")
            XCTAssertTrue(find("bots.list").waitForExistence(timeout: 5))

            XCUIDevice.shared.orientation = .landscapeLeft
            look("wide-chat-landscape-\(mode)", after: 2)
            XCUIDevice.shared.orientation = .portrait
        }
    }

    func testACardOpensBesideTheChat() throws {
        try inBothLooks { mode in
            // The card opens itself once drawn: a tap on its corner button over the page does not
            // reach the button under automation (on the phone too, where it would open a sheet).
            try startDemo(["-nollie-demo-say", "card for the log host", "-nollie-demo-card-full"], look: mode)
            if isWide {
                expectShown(find("panel.close"), within: 60, "the card opens in the panel")
                look("wide-card-panel-\(mode)", after: 2)
                tap("panel.close")
            } else {
                expectShown(buttonNamed("Card options"), within: 60, "the card opens full screen")
                look("narrow-card-full-\(mode)", after: 2)
            }
        }
    }

    /// An iPad window narrowed with its resize grip turns compact, as an iPhone Duo does when it
    /// is folded shut, and widened again turns back. The chat stays the same chat throughout, still
    /// at the place it was scrolled to; only Back and the list come and go. (No draft is typed: the
    /// keyboard would cover the grip. Drafts are kept for each chat by the composer in any case.)
    func testNarrowingAndWideningKeepsTheChat() throws {
        try startDemo()
        guard isWide else { throw XCTSkip("Needs a wide screen") }
        openBot("default")
        // Read further up, so the thread is away from its end.
        app.swipeDown(velocity: .fast)
        let earlier = text("What I found")
        XCTAssertTrue(earlier.waitForExistence(timeout: 10))
        pause(1)
        look("resize-wide-before")

        resizeWindow(toWidth: 0.4)
        guard !isWide else { throw XCTSkip("This window cannot be resized") }
        expectShown(find("chat.back"), "narrow, the chat has Back")
        XCTAssertTrue(earlier.exists, "the thread stays where it was read")
        look("resize-narrow")

        resizeWindow(toWidth: 1)
        XCTAssertTrue(find("bots.list").waitForExistence(timeout: 10), "wide again, the list is back beside the chat")
        XCTAssertFalse(find("chat.back").exists)
        XCTAssertTrue(earlier.exists, "still where it was read")
        look("resize-wide-after")
    }

    /// Drags the window's corner grip so the window spans `fraction` of the screen's width.
    private func resizeWindow(toWidth fraction: CGFloat) {
        let frame = app.windows.firstMatch.frame
        let screen = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let grip = screen.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.maxX - 6, dy: frame.maxY - 6))
        let target = screen.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.minX + max(320, 1032 * fraction), dy: frame.maxY - 6))
        grip.press(forDuration: 0.6, thenDragTo: target)
        pause(2)
    }

    func testThePhoneKeepsItsOneStack() throws {
        try inBothLooks { mode in
            try startDemo(look: mode)
            guard !isWide else { throw XCTSkip("Needs a narrow screen") }
            XCTAssertFalse(find("chats.empty").exists, "no chat side on a narrow screen")
            look("narrow-list-\(mode)")
            openBot("default")
            XCTAssertFalse(find("bots.list").isHittable, "the chat covers the list")
            look("narrow-chat-\(mode)", after: 1.5)
            // The + panel keeps to the room above the composer.
            expectShown(buttonNamed("Attach"), within: 10, "no + button").tap()
            expectShown(find("attach.files"), within: 5, "the + panel opened")
            look("narrow-attach-\(mode)")
            buttonNamed("Close attach panel").tap()
            pause(0.6)
            tap("chat.back")
            XCTAssertTrue(find("bots.list").waitForExistence(timeout: 10), "Back returns to the list")
        }
    }
}
