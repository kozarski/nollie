import XCTest

/// The chat's menu names the reasoning level it runs at and lists the six levels, weakest first.
final class ReasoningMenuUITests: DemoCase {
    private let levels = ["minimal", "low", "medium", "high", "xhigh", "max"]

    private func openReasoning() -> XCUIElement {
        tap("chat.more")
        press("This chat")
        // Items inside a menu carry no identifier; the item is found by its words.
        let item = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reasoning")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10), "the menu has no Reasoning item")
        return item
    }

    func testTheMenuListsSixLevelsInOrderAndHighCanBeChosen() throws {
        try startDemo()
        openBot("default")
        startSideChat()

        let item = openReasoning()
        XCTAssertTrue(item.label.contains("medium"), "the item does not name the level: \(item.label)")
        item.tap()

        var heights: [CGFloat] = []
        for level in levels {
            let choice = app.buttons[level].firstMatch
            XCTAssertTrue(choice.waitForExistence(timeout: 5), "no \(level) level")
            heights.append(choice.frame.minY)
        }
        XCTAssertEqual(heights, heights.sorted(), "the levels are not listed from weakest to strongest")
        shot("reasoning-levels")

        // The mock does not echo the new level back, so choosing it is judged by the menu closing
        // and the chat carrying on.
        press("high")
        XCTAssertTrue(poll(10) { !self.app.buttons["minimal"].exists }, "the levels stayed open after choosing high")
        XCTAssertTrue(find("composer.text").exists, "the chat did not carry on after choosing high")
    }
}
