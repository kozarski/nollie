import XCTest

/// Nollie adds a crew member and says so with a note that offers Meet and Undo; its own ideas come
/// with Add and Not now. Each answer happens in place.
final class CrewNoteUITests: DemoCase {
    func testNollieAddsAndSuggestsCrewMembers() throws {
        try requireMock()
        try inBothLooks { look in
            try startDemo(look: look)
            openBot("default")

            send("crew please")
            XCTAssertTrue(find("crew.meet").waitForExistence(timeout: 30), "no crew note")
            XCTAssertTrue(app.staticTexts["I've added Scout to check new roles each morning."].exists)
            XCTAssertTrue(find("crew.undo").exists)
            shot("crew-added-\(look)")
            tap("crew.undo")
            XCTAssertTrue(text("Removed Scout").waitForExistence(timeout: 10), "Undo did not answer in place")

            send("crew idea")
            XCTAssertTrue(find("crew.add").waitForExistence(timeout: 30), "no suggestion")
            XCTAssertTrue(find("crew.not_now").exists)
            shot("crew-suggestion-\(look)")
            tap("crew.add")
            XCTAssertTrue(text("added Rover").waitForExistence(timeout: 10), "Add did not answer in place")
        }
    }
}
