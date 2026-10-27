import XCTest

/// Everyday things from the iPhone and iPad: who is working, with Stop, at the foot of the chat list,
/// and moving a Board card from its own sheet. Runs on a phone or an iPad simulator alike.
final class PocketUITests: DemoCase {
    private let card = "Remove rotated logs older than 90 days"

    /// Linked to a Mac (the demo plays one with `-nollie-demo-reach`), the bar shows who is working
    /// and Stop; Stop says what a real Stop says.
    func testTheCrewBarShowsWhoIsWorkingAndStops() throws {
        try inBothLooks { look in
            try startDemo(["-nollie-demo-reach", "home"], look: look)
            _ = expectShown(find("chats.atWork"), within: 30, "no bar while a helper works")
            let who = find("chats.atWork.who")
            XCTAssertTrue(who.label.contains("is working") || who.label.contains("helpers working"), who.label)
            pause(1)
            shot("pocket-bar-\(look.rawValue)")
            tap("chats.atWork.stop")
            XCTAssertTrue(poll(10) { self.find("chats.atWork.who").label.contains("Stopping on your Mac") }, "Stop did not say how it went")
            pause(1)
            shot("pocket-bar-stopped-\(look.rawValue)")
        }
    }

    /// At the largest text size the words stay whole and Stop sits under them.
    func testTheBarAtTheLargestTextSize() throws {
        try startDemo(["-nollie-demo-reach", "home", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        _ = expectShown(find("chats.atWork.stop"), within: 30, "no Stop at the largest text size")
        let who = find("chats.atWork.who").frame, stop = find("chats.atWork.stop").frame
        XCTAssertGreaterThanOrEqual(stop.minY, who.maxY - 1, "Stop overlaps the words")
        pause(1)
        shot("pocket-bar-ax5")
    }

    /// Not linked: who is working, and no Stop with nowhere to go.
    func testWithoutAMacTheBarHasNoStop() throws {
        try startDemo()
        _ = expectShown(find("chats.atWork"), within: 30, "no bar while a helper works")
        XCTAssertFalse(find("chats.atWork.stop").exists, "Stop offered with no Mac to stop")
    }

    /// The task sheet's Move: a plain move goes straight through and back; Done asks for its note first.
    func testATaskMovesFromItsSheet() throws {
        try inBothLooks { look in
            try startDemo(look: look)
            openBoard()
            pageToCard(card).tap()
            tap("task.move")
            XCTAssertTrue(find("task.move.todo").waitForExistence(timeout: 5), "no Move menu")
            XCTAssertFalse(find("task.move.running").exists, "Running is the gateway's to set")
            shot("pocket-move-menu-\(look.rawValue)")
            tap("task.move.todo")
            XCTAssertTrue(poll(15) { self.text("To do").exists }, "the move to To do did not show")
            shot("pocket-moved-\(look.rawValue)")

            tap("task.move")
            tap("task.move.done")
            XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5), "Done did not ask for its note")
            shot("pocket-move-done-asks-\(look.rawValue)")
            app.alerts.buttons["Cancel"].tap()

            // Put it back where the other flows expect it.
            tap("task.move")
            tap("task.move.ready")
            XCTAssertTrue(poll(15) { self.text("Ready").exists }, "the card did not go back to Ready")
        }
    }
}
