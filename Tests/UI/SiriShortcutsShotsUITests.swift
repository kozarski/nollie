import XCTest

/// Ask Nollie in the Shortcuts app and the controls in Control Center, as pictures. Pictures go to
/// the folder in NOLLIE_SIRI_SHOTS; without it the flow skips, because it drives system apps and
/// edits the simulator's Control Center.
final class SiriShortcutsShotsUITests: DemoCase {
    private var shortcuts: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.shortcuts") }
    private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    private var folder: URL? {
        ProcessInfo.processInfo.environment["NOLLIE_SIRI_SHOTS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private func picture(_ name: String, of system: XCUIApplication? = nil) {
        guard let folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: folder.appendingPathComponent("\(name).png"))
        if let system {
            try? system.debugDescription.write(to: folder.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
        }
    }

    private func any(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
    }

    private func tapIfThere(_ element: XCUIElement, timeout: TimeInterval = 3) -> Bool {
        guard element.waitForExistence(timeout: timeout) else { return false }
        element.tap()
        return true
    }

    /// Runs Ask Nollie from the Shortcuts app's gallery of app shortcuts with `request`.
    private func runAsk(_ request: String, name: String) {
        shortcuts.launch()
        pause(2)
        _ = tapIfThere(shortcuts.buttons["Continue"])
        _ = tapIfThere(shortcuts.buttons["BackButton"])
        pause(1)
        picture("\(name)-library", of: shortcuts)
        // The app's own shortcuts sit under its name in the library.
        if !tapIfThere(any(shortcuts, "Nollie Demo"), timeout: 5) { picture("\(name)-no-app", of: shortcuts); return }
        pause(1)
        picture("\(name)-app-shortcuts", of: shortcuts)
        let ask = any(shortcuts, "Ask Nollie")
        if !tapIfThere(ask, timeout: 5) { return }
        pause(2)
        // The question and the keyboard's first-time tip are drawn by the system, not by Shortcuts.
        for owner in [springboard, shortcuts] where owner.buttons["Continue"].exists { owner.buttons["Continue"].tap() }
        pause(1)
        picture("\(name)-prompt", of: springboard)
        let field = [springboard.textViews.firstMatch, springboard.textFields.firstMatch,
                     shortcuts.textViews.firstMatch, shortcuts.textFields.firstMatch].first { $0.exists }
        if let field {
            field.tap()
            field.typeText(request)
            picture("\(name)-typed", of: springboard)
            for owner in [springboard, shortcuts] where owner.buttons["Done"].exists {
                owner.buttons["Done"].tap()
                break
            }
        }
        pause(12)
        picture("\(name)-result", of: springboard)
    }

    /// One look per run (NOLLIE_SIRI_LOOK), on a fresh mock: a plain reply, then a turn that stops
    /// at Ask first. The mock remembers the waiting card, so the other look needs a fresh mock.
    func testAskNollieInShortcuts() throws {
        guard folder != nil else { throw XCTSkip("Set NOLLIE_SIRI_SHOTS to a folder to run this one") }
        let look = ProcessInfo.processInfo.environment["NOLLIE_SIRI_LOOK"] == "dark" ? Look.dark : .light
        try startDemo(look: look)
        pause(2)
        runAsk("plan back on track?", name: "ask-reply-\(look)")
        shortcuts.terminate()
        runAsk("ask first email Sam about Thursday", name: "ask-needs-yes-\(look)")
        _ = tapIfThere(springboard.buttons["Done"], timeout: 2)
        pause(4)
        picture("ask-needs-yes-\(look)-opened", of: app)
        shortcuts.terminate()
    }

    /// Pulls Control Center down from the top right corner.
    private func openControlCenter() {
        let corner = springboard.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.005))
        corner.press(forDuration: 0.1, thenDragTo: corner.withOffset(CGVector(dx: 0, dy: 500)))
        pause(1)
    }

    func testTheControlsInTheGallery() throws {
        guard folder != nil else { throw XCTSkip("Set NOLLIE_SIRI_SHOTS to a folder to run this one") }
        for look in Look.allCases {
            XCUIDevice.shared.appearance = look.uiAppearance
            XCUIDevice.shared.press(.home)
            pause(1)
            for (term, name) in [("Ask Nollie", "ask"), ("Stop all helpers", "stop")] {
                openControlCenter()
                let add = springboard.buttons["Add a Control"]
                if !add.waitForExistence(timeout: 5) {
                    springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).press(forDuration: 1.5)
                }
                guard add.waitForExistence(timeout: 10) else { picture("controls-no-add-\(look)", of: springboard); return }
                add.tap()
                pause(2)
                let search = springboard.searchFields.firstMatch
                if search.waitForExistence(timeout: 5) {
                    search.tap()
                    search.typeText(term)
                }
                pause(3)
                picture("controls-gallery-\(name)-\(look)", of: springboard)
                // Placing it shows it in Control Center as people will see it.
                let found = springboard.descendants(matching: .any).matching(NSPredicate(format: "label == %@", term)).firstMatch
                if found.exists, look == .light {
                    found.tap()
                    pause(2)
                    picture("controls-placed-\(name)-\(look)", of: springboard)
                }
                XCUIDevice.shared.press(.home)
                pause(1)
                XCUIDevice.shared.press(.home)
                pause(1)
            }
            openControlCenter()
            pause(1)
            picture("controls-center-\(look)", of: springboard)
            XCUIDevice.shared.press(.home)
            pause(1)
        }
    }
}
