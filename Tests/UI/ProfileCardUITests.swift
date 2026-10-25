import XCTest

/// The bot card opens from a chat's title pill. Each tab shows its own page, the chat can be renamed
/// from the card, from the chat menu and by long-pressing the pill, and Close dismisses the card.
/// Run once in every look.
final class ProfileCardUITests: DemoCase {
    /// What each tab must show once it is chosen: the tab, then something only that page has.
    private let pages: [(tab: String, mark: String)] = [
        ("look", "bot.editor.reset"),
        ("instructions", "profile.instructions"),
        ("model", "profile.model.advanced"),
        ("display", "profile.display.hero"),
        ("thisChat", "profile.rename"),
    ]

    /// Begins a side chat using the default bot and opens that bot's card on top.
    private func openCard(_ look: Look) throws {
        try startDemo(look: look)
        openBot("default")
        startSideChat()
        tap("chat.titlePill")
        XCTAssertTrue(find("profile.header").waitForExistence(timeout: 10), "the card did not open")
    }

    /// The card's own round buttons. They carry the card's identifier, so they are told apart by label.
    private func cardButton(_ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'bot.editor.' AND label == %@", label)).firstMatch
    }

    /// Chooses a tab, sliding the row sideways first when the tab is off its edge.
    private func choose(tab: String) {
        let pill = find("profile.tab.\(tab)")
        for turn in 0..<8 where !(pill.exists && pill.isHittable) {
            if turn < 4 { find("profile.tabs").swipeLeft() } else { find("profile.tabs").swipeRight() }
        }
        tap("profile.tab.\(tab)")
    }

    private func cancelRename() {
        XCTAssertTrue(find("rename.name").waitForExistence(timeout: 5), "the rename dialog did not open")
        press("Cancel")
        XCTAssertTrue(poll(5) { !self.find("rename.name").exists }, "Cancel left the rename dialog open")
    }

    func testEveryTabShowsItsOwnPageAndCloseEndsTheCard() throws {
        try inBothLooks { look in
            try openCard(look)
            XCTAssertTrue(cardButton("Close").exists && cardButton("More").exists, "the card lacks Close or the more menu")
            XCTAssertTrue(find("profile.tabs").exists, "no row of tabs")
            XCTAssertTrue(find("profile.rename").waitForExistence(timeout: 5), "from a chat the card opens on This chat")

            for page in pages {
                choose(tab: page.tab)
                XCTAssertTrue(find(page.mark).waitForExistence(timeout: 10), "the \(page.tab) tab shows no \(page.mark)")
            }
            choose(tab: "instructions")
            XCTAssertTrue(find("profile.description").exists, "no description field on the instructions page")
            choose(tab: "model")
            XCTAssertTrue(find("profile.model.hero").exists, "the model page lacks its heading")
            shot("profile-card-\(look.rawValue)")

            cardButton("Close").tap()
            XCTAssertTrue(poll(10) { !self.find("profile.header").exists }, "Close left the card up")
        }
    }

    func testTheCardCanRenameTheChatTwoWays() throws {
        try openCard(.light)
        tap("profile.rename")
        cancelRename()

        cardButton("More").tap()
        press("Rename chat")
        cancelRename()
    }

    func testRenamingFromTheChatShowsInTheHeader() throws {
        try startDemo()
        openBot("default")
        startSideChat()

        // Rename through the chat menu.
        tap("chat.more")
        press("This chat")
        press("Rename…")
        let field = find("rename.name")
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no rename dialog from the menu")
        field.typeText("Disk talk")
        press("Save")
        XCTAssertTrue(poll(10) { self.find("chat.titlePill").label.contains("Disk talk") }, "the header kept the old name")

        // Long-pressing the title gives the same option.
        find("chat.titlePill").press(forDuration: 1.2)
        press("Rename chat")
        XCTAssertTrue(find("rename.name").waitForExistence(timeout: 5), "a long press on the title did not offer Rename chat")
        press("Cancel")
        shot("profile-card-renamed")
    }
}
