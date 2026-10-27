import XCTest

/// Nollie adds a crew member and says so with a note that offers Meet and Undo; its own ideas come
/// with Add and Not now. Each answer happens in place.
final class CrewNoteUITests: DemoCase {
    /// One mock gateway serves every flow in a run: the crew members added here go again, so the
    /// flows after this one find the demo's own two bots (a fourth would pin the first three to the top).
    override func tearDownWithError() throws {
        DemoCase.resetMock("api/_mock/profile-creation", [:])
        try super.tearDownWithError()
    }

    func testNollieAddsAndSuggestsCrewMembers() throws {
        try requireMock()
        try inBothLooks { look in
            // Each look starts with the demo's own bots, without the member the last one added.
            _ = mock("/api/_mock/profile-creation", [:])
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
