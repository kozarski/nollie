import XCTest

/// A picture in a reply opens in the viewer and Save to Photos works: the Photos prompt is allowed,
/// the button turns to Saved and switches off, and the app keeps running (it once quit on every
/// phone). The prompt only appears while unanswered, so reset it before a run with
/// `xcrun simctl privacy <device> reset photos com.coreykozarski.nollie.demo`.
final class SaveToPhotosUITests: DemoCase {
    func testSavingAPictureToPhotos() throws {
        try beginSideChat(saying: "please look at the log host disk")
        // The answer to the approval lets the bot finish, and its reply carries the picture.
        ready("approval.once", timeout: 60).tap()

        let picture = expectShown(buttonNamed("Image disk-before-after.png"), within: 60, "the reply has no picture")

        addUIInterruptionMonitor(withDescription: "Photos permission") { alert in
            for label in ["Allow Full Access", "Allow", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }

        picture.tap()
        expectShown(buttonNamed("Save to Photos"), within: 20, "no Save to Photos button in the viewer").tap()
        app.tap()   // lets the interruption monitor see the question

        let saved = app.buttons["Saved"].firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 20), "the button never read Saved")
        XCTAssertFalse(saved.isEnabled, "Saved should be off")
        shot("save-to-photos-saved")

        pause(5)
        XCTAssertEqual(app.state, .runningForeground, "the app stopped after saving")
    }
}
