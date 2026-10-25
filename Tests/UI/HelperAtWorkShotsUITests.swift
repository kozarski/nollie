import XCTest

/// Pictures of the Lock Screen Stop, the Live Activity for a helper at work, in its four states:
/// live, stale (the link to the Mac lost), stopping and stopped. Each is photographed in the
/// Dynamic Island, compact and expanded, and on the Lock Screen. Stop is offered while the helper
/// is live or stale and gone once it has been pressed. Needs NOLLIE_ACTIVITY_SHOTS (a folder).
final class HelperAtWorkShotsUITests: DemoCase {
    private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    private func picture(_ name: String) {
        guard let folder = ProcessInfo.processInfo.environment["NOLLIE_ACTIVITY_SHOTS"] else { return }
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: directory.appendingPathComponent("\(name).png"))
        shot(name)
    }

    private func lockTheScreen() {
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        pause(2)
    }

    private func wakeTheScreen() {
        XCUIDevice.shared.press(.home)
        pause(1.5)
    }

    func testTheActivityInEachState() throws {
        guard ProcessInfo.processInfo.environment["NOLLIE_ACTIVITY_SHOTS"] != nil else {
            throw XCTSkip("Set NOLLIE_ACTIVITY_SHOTS to a folder to run this one")
        }
        for state in ["live", "stale", "stopping", "stopped"] {
            try startDemo(["-nollie-preview-helper-at-work", state], withGateway: false)
            pause(4)
            XCUIDevice.shared.press(.home)
            pause(1.5)

            // The Dynamic Island: compact, then held open.
            picture("activity-\(state)-island-compact")
            let island = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.04))
            island.press(forDuration: 1.2)
            pause(1)
            picture("activity-\(state)-island-expanded")
            XCUIDevice.shared.press(.home)

            // The Lock Screen.
            lockTheScreen()
            wakeTheScreen()
            picture("activity-\(state)-lock-screen")
            let stop = springboard.buttons["Stop"].firstMatch
            if state == "live" || state == "stale" {
                XCTAssertTrue(stop.waitForExistence(timeout: 5), "no Stop while the helper is \(state)")
                if state == "live" {
                    stop.tap()
                    XCTAssertTrue(poll(10) { !stop.exists }, "Stop stayed after it was pressed")
                    picture("activity-live-after-stop")
                }
            } else {
                XCTAssertFalse(stop.exists, "Stop is offered while the helper is \(state)")
            }
            app.terminate()
        }
    }
}
