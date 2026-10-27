import XCTest

/// A card's full screen button is a full fingertip square: a tap anywhere on it opens the card, not
/// only on its small drawn circle, and the page under it does not take the tap instead.
final class CardFullScreenUITests: DemoCase {
    func testTheFullScreenButtonTakesATapAnywhereOnIt() throws {
        try beginSideChat(saying: "card for the log host")
        let button = buttonNamed("Open the card full screen")
        expectShown(button, within: 60, "no full screen button on the card")
        // The thread's start, with the card's top in view clear of the chat's header. Closing the card
        // brings the keyboard back and the thread to its end, so each tap comes back here first.
        func bringBack() -> CGRect {
            for _ in 0..<3 where !(button.isHittable && button.frame.minY > 160) {
                app.swipeDown(velocity: .fast)
                pause(1)
            }
            return button.frame
        }
        XCTAssertGreaterThan(bringBack().minY, 160, "the button is not in view: \(button.frame)")
        pause(1)
        look("card-button")

        let frame = button.frame
        XCTAssertGreaterThanOrEqual(frame.width, 44, "the button is \(frame.width) points wide")
        XCTAssertGreaterThanOrEqual(frame.height, 44, "the button is \(frame.height) points tall")

        // Each corner of the fingertip square three points in, where the drawn circle doesn't reach,
        // then the middle.
        let spots: [(name: String, dx: CGFloat, dy: CGFloat)] = [
            ("top left", -19, -19), ("bottom left", -19, 19), ("bottom right", 19, 19), ("top right", 19, -19), ("middle", 0, 0),
        ]
        for spot in spots {
            let now = bringBack()
            XCTAssertGreaterThan(now.minY, 160, "the button is not in view for the \(spot.name) tap")
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: now.midX + spot.dx, dy: now.midY + spot.dy)).tap()
            let options = buttonNamed("Card options")
            XCTAssertTrue(options.waitForExistence(timeout: 5), "a tap on the button's \(spot.name) did not open the card")
            if spot.name == "middle" { look("card-full") }
            press("Done")
            XCTAssertTrue(poll(10) { !options.exists }, "the card stayed open after Done")
            pause(1.5)
        }
    }
}
