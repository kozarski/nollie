import XCTest

/// Turning the phone over while a chat is open with the keyboard up: the app stays in front, the
/// header keeps its Back, typing still works, and turned back everything is where it was.
final class RotationUITests: DemoCase {
    private func typesStill(_ note: String) {
        let composer = expectShown(chatField, within: 10, "\(note): no composer")
        if !app.keyboards.firstMatch.exists { composer.tap() }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "\(note): no keyboard")
        let before = composer.value as? String ?? ""
        composer.typeText("x")
        XCTAssertTrue(poll(5) { (composer.value as? String ?? "") != before }, "\(note): typing did nothing (\"\(before)\")")
    }

    func testTheChatSurvivesTurningTheScreenOverAndBack() throws {
        try startDemo()
        openBot("default")
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        typeMessage("hello")

        XCUIDevice.shared.orientation = .landscapeLeft
        pause(1.5)
        XCTAssertEqual(app.state, .runningForeground, "the app left the front when the phone was turned")
        XCTAssertTrue(find("chat.back").waitForExistence(timeout: 10), "no Back in landscape")
        typesStill("landscape")
        shot("rotation-landscape")

        XCUIDevice.shared.orientation = .portrait
        pause(1.5)
        let back = find("chat.back")
        XCTAssertTrue(back.waitForExistence(timeout: 10), "no Back after turning back")
        XCTAssertLessThan(back.frame.minY, 140, "Back is not near the top of the screen")
        typesStill("portrait")

        back.tap()
        XCTAssertTrue(find("bots.list").waitForExistence(timeout: 10), "Back did not leave the chat")
    }
}
