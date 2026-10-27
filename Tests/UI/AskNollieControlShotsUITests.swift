import XCTest

/// The Ask Nollie control: found in the Control Center gallery (and not the old stop-mac control),
/// added, then pressed from Control Center, which opens Nollie on the main chat with the keyboard up.
/// Pictures go to the folder in NOLLIE_CONTROL_SHOTS; without it the flow skips, because it edits
/// the simulator's Control Center.
final class AskNollieControlShotsUITests: DemoCase {
    private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    private func picture(_ name: String) {
        guard let folder = ProcessInfo.processInfo.environment["NOLLIE_CONTROL_SHOTS"] else { return }
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: directory.appendingPathComponent("\(name).png"))
        shot(name)
    }

    /// Pulls Control Center down from the top right corner.
    private func openControlCenter() {
        let corner = springboard.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.005))
        corner.press(forDuration: 0.1, thenDragTo: corner.withOffset(CGVector(dx: 0, dy: 500)))
        pause(1)
    }

    func testTheControlIsInTheGalleryAndOpensTheMainChatWithTheKeyboard() throws {
        guard ProcessInfo.processInfo.environment["NOLLIE_CONTROL_SHOTS"] != nil else {
            throw XCTSkip("Set NOLLIE_CONTROL_SHOTS to a folder to run this one")
        }
        try startDemo()
        XCUIDevice.shared.press(.home)
        pause(1)

        // Into the gallery through the add button, then a search for the control.
        openControlCenter()
        let add = springboard.buttons["Add a Control"]
        if !add.waitForExistence(timeout: 5) {
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).press(forDuration: 1.5)
        }
        XCTAssertTrue(add.waitForExistence(timeout: 10), "no way to add a control")
        add.tap()
        picture("ask-control-gallery")

        let search = springboard.searchFields.firstMatch
        if search.waitForExistence(timeout: 5) {
            search.tap()
            search.typeText("Ask Nollie")
        }
        let control = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Ask Nollie")).firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 10), "Ask Nollie is not in the gallery")
        XCTAssertFalse(springboard.buttons["com.coreykozarski.nollie.stop-mac"].exists, "the old Stop control is still offered")
        control.tap()
        pause(1)
        picture("ask-control-placed")
        if springboard.buttons["Done"].exists { springboard.buttons["Done"].tap() }

        // Press it.
        let placed = springboard.descendants(matching: .button).matching(NSPredicate(format: "label CONTAINS %@", "Ask Nollie")).firstMatch
        expectShown(placed, within: 10, "the control did not stay in Control Center")
        picture("ask-control-in-center")
        placed.tap()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20), "Nollie did not open")
        XCTAssertTrue(find("composer.text").waitForExistence(timeout: 20), "the main chat did not open on the composer")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "the keyboard is not up")
        picture("ask-control-opened")
    }
}
