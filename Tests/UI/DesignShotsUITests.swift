import XCTest

/// The reference pictures for the design record. Each test walks a part of the app and keeps what
/// it sees; only the walk itself can fail, nothing about the pictures is judged here. Run with
/// HERMES_E2E_SHOTS=<folder> to get the PNGs as files.
final class DesignShotsUITests: DemoCase {
    /// Pinning is remembered by the demo copy, so a flow that pins leaves the Work bot as it found it.
    private func unpinWorkIfPinned() {
        let tile = find("bots.pinned.work")
        guard tile.waitForExistence(timeout: 5) else { return }
        tile.press(forDuration: 1.2)
        if find("botmenu.pin").waitForExistence(timeout: 5) { find("botmenu.pin").tap() }
        pause(1)
    }

    func testTheBotsListInBothLooks() throws {
        try inBothLooks { look in
            try startDemo(look: look)
            pause(1)
            shot("design-bots-\(look)")
        }
    }

    func testPressingARowAndAPinnedTile() throws {
        try startDemo()
        unpinWorkIfPinned()
        addTeardownBlock { [self] in unpinWorkIfPinned() }
        ready("bots.row.work", timeout: 40).press(forDuration: 1.2)
        look("design-row-menu")
        // The menu goes away with a tap on the empty page below the list.
        tapAt(0.5, 0.92)
        pause(0.8)

        // Pin one so there is a tile to press, then press it.
        ready("bots.row.work", timeout: 40).press(forDuration: 1.2)
        if find("botmenu.pin").waitForExistence(timeout: 3) { find("botmenu.pin").tap() }
        let tile = find("bots.pinned.work")
        if tile.waitForExistence(timeout: 5) {
            tile.press(forDuration: 1.2)
            look("design-pinned-tile-menu")
            tapAt(0.5, 0.92)
        }
    }

    func testTheMainChatItsMenuAndItsTitle() throws {
        try startDemo()
        openBot("default")
        pause(1)
        shot("design-main-chat")
        tap("chat.more")
        look("design-chat-menu")
        tapAt(0.08, 0.5)
        pause(0.8)
        tap("chat.titlePill")
        XCTAssertTrue(find("profile.header").waitForExistence(timeout: 10))
        shot("design-chat-title-tap")
    }

    func testAnApprovalInTheThreadInBothLooks() throws {
        try inBothLooks { look in
            try startDemo(["-nollie-demo-say", "clean-up-the-log-host"], look: look)
            ready("approval.once", timeout: 60)
            shot("design-approval-\(look)")
        }
    }

    func testTheByHandPathFromTypingToHistory() throws {
        try startDemo()
        openBot("default")
        send("Please clean up the log host")
        ready("approval.once", timeout: 60)
        shot("design-by-hand-approval")
        tap("approval.once")
        _ = text("4.2 GB freed").waitForExistence(timeout: 60)
        tap("chat.back")
        XCTAssertTrue(find("bots.list").waitForExistence(timeout: 10))
        find("bots.row.default").press(forDuration: 1.2)
        press("History")
        XCTAssertTrue(find("history.row").waitForExistence(timeout: 10))
        shot("design-by-hand-history")
    }

    func testAPinnedTileOpensItsChatFromTheFaceAndTheName() throws {
        try startDemo()
        unpinWorkIfPinned()
        addTeardownBlock { [self] in unpinWorkIfPinned() }
        ready("bots.row.work", timeout: 40).press(forDuration: 1.2)
        tap("botmenu.pin")
        let tile = find("bots.pinned.work")
        XCTAssertTrue(tile.waitForExistence(timeout: 10), "pinning made no tile")
        shot("design-pinned")
        tile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        XCTAssertTrue(find("composer.text").waitForExistence(timeout: 20), "the face did not open the chat")
        tap("chat.back")
        tile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
        XCTAssertTrue(find("composer.text").waitForExistence(timeout: 20), "the name did not open the chat")
        tap("chat.back")

        // And put back as it was.
        find("bots.pinned.work").press(forDuration: 1.2)
        tap("botmenu.pin")
        XCTAssertTrue(poll(10) { !self.find("bots.pinned.work").exists })
        shot("design-unpinned")
    }

    func testABotsOwnPages() throws {
        for (flag, name) in [("history", "history"), ("knows", "knows"), ("settings", "settings")] {
            try startDemo(["-nollie-demo-bot-page", flag])
            pause(4)
            shot("design-bot-\(name)")
        }
        try startDemo(["-nollie-demo-bot-page", "settings", "-nollie-demo-bot-tab", "computer"])
        pause(4)
        shot("design-bot-computer-tab")
    }

    func testTheNewBotSheet() throws {
        try startDemo()
        tap("chats.newBot")
        pause(1)
        shot("design-new-bot")
    }

    func testPapertrailInBothLooks() throws {
        try inBothLooks { look in
            try startDemo(look: look)
            press("Papertrail")
            pause(2)
            shot("design-papertrail-\(look)")
        }
    }
}
