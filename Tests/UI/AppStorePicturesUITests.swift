import XCTest

/// The App Store pictures, taken from Try a demo in picture mode (`-nollie-demo-picture`): no Demo pill and no
/// demo line, and the Mac named as one at home. Every picture is a screen the app really shows, from the demo's
/// own made-up world. Runs only on the demo copy and only when `NOLLIE_SHOTS` names a folder for the PNGs, so
/// the golden flows never run it.
@MainActor
final class AppStorePicturesUITests: XCTestCase {
    private var app: XCUIApplication!
    private var folder: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let bundle = ProcessInfo.processInfo.environment["HERMES_E2E_BUNDLE"] ?? "com.coreykozarski.nollie.demo"
        guard bundle.hasSuffix(".demo") else { throw XCTSkip("App Store pictures come from the demo copy") }
        guard let path = ProcessInfo.processInfo.environment["NOLLIE_SHOTS"], !path.isEmpty else {
            throw XCTSkip("Name a folder in NOLLIE_SHOTS to take the App Store pictures")
        }
        folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        app = XCUIApplication(bundleIdentifier: bundle)
    }

    private var wide: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    @discardableResult
    private func visible(_ element: XCUIElement, timeout: TimeInterval = 20,
                         file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        if element.exists, element.isHittable { return element }
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "\(element) never showed", file: file, line: line)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed, file: file, line: line)
        return element
    }

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func text(_ fragment: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
    }

    private func settle(_ seconds: TimeInterval = 1.5) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    /// Taps once the element holds still: the list redraws as the demo's bots arrive.
    private func tap(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        for attempt in 1...3 {
            let element = visible(any(id), file: file, line: line)
            settle(0.4)
            if element.exists, element.isHittable { element.tap(); return }
            if attempt == 3 { XCTFail("\(id) never held still", file: file, line: line) }
        }
    }

    /// A bot's chat, from its pinned face or its row, whichever the list shows.
    private func open(_ bot: String) {
        let pinned = any("bots.pinned.\(bot)")
        tap(pinned.waitForExistence(timeout: 5) ? "bots.pinned.\(bot)" : "bots.row.\(bot)")
    }

    private func shot(_ name: String) {
        settle()
        let picture = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: picture)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertNoThrow(try picture.pngRepresentation.write(to: folder.appendingPathComponent(name + ".png")))
    }

    /// A first launch straight into Try a demo, with the online model already allowed as if asked before.
    private func startDemo(_ extra: [String] = []) {
        // The iPad lies on its side, so the chat beside the list has room.
        XCUIDevice.shared.orientation = wide ? .landscapeLeft : .portrait
        app.terminate()
        app.launchArguments = [
            "-nollie.onboarding.progress.v1", "", "-nollie.onboarding.welcomeIntroSeen", "YES",
            "-companionPromptShown", "YES", "-notificationsSetupCardDone", "YES", "-approvals.ownerCheck", "NO",
            "-privacy.onlineModels.allowed", "<dict><key>demo</key><string>The demo's model</string></dict>",
            "-nollie-demo-picture",
        ] + extra
        app.launch()
        visible(app.buttons["onboarding.tryDemo"].firstMatch, timeout: 30).tap()
        visible(any("bots.list"), timeout: 30)
        visible(any(wide ? "bots.row.scout" : "bots.pinned.default"), timeout: 30)
        XCTAssertFalse(any("demo.pill").exists, "picture mode still shows the Demo pill")
        settle(2)
    }

    private func leave() {
        app.terminate()
    }

    /// iPadOS opens apps in windows, with the app's name in the status bar and a corner to drag. Pictures show
    /// the app full screen, so the simulator's own Settings switch to Full Screen Apps first.
    func test0FullScreenApps() throws {
        guard wide else { throw XCTSkip("Only an iPad has windows") }
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.terminate()
        settings.launch()
        let row = settings.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Multitasking'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), settings.debugDescription)
        row.tap()
        let full = settings.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Full-Screen Apps'")).firstMatch
        XCTAssertTrue(full.waitForExistence(timeout: 15), settings.debugDescription)
        full.tap()
        settle(1)
        settings.terminate()
    }

    func test1AskFirst() {
        startDemo()
        open("mason")
        visible(any("approval.askFirst"), timeout: 30)
        shot("01-ask-first")
        leave()
    }

    func test2Research() {
        startDemo()
        open("scout")
        XCTAssertTrue(text("Dustpro 300").waitForExistence(timeout: 20), "Scout's comparison did not show")
        shot("02-research")
        leave()
    }

    /// On the phone from Settings. On iPad from the note at the top of Nollie's chat, which opens beside the chat.
    func test3NightShift() {
        startDemo()
        if wide {
            open("default")
            tap("night.card")
        } else {
            tap("chats.settings")
            tap("settings.summary.night")
        }
        XCTAssertTrue(text("Watch the Aero 5 price").waitForExistence(timeout: 20), "the Night shift card is missing")
        shot("03-night-shift")
        leave()
    }

    func test4Papertrail() {
        startDemo()
        tap("chats.settings")
        tap("settings.summary.left")
        XCTAssertTrue(text("Went online").waitForExistence(timeout: 20), "Papertrail did not open")
        shot("04-papertrail")
        leave()
    }

    func test5NewHelper() {
        startDemo()
        // The demo has no ready-made helpers to offer, so New bot opens on making one: a name and a face.
        tap("chats.newBot")
        visible(any("bot.look.nollie"), timeout: 20)
        shot("05-new-helper")
        leave()
    }

    func test6Chats() {
        startDemo()
        if wide { open("default") }
        shot("06-chats")
        leave()
    }

    /// For App Review: the ask as a real setup shows it, naming the company, which the demo's example ask does not.
    /// Connected to the local mock gateway (started without --neutral-models), whose helpers use Anthropic,
    /// with nothing allowed yet.
    func test9ForReviewTheRealAsk() throws {
        let env = ProcessInfo.processInfo.environment
        guard let address = env["HERMES_E2E_URL"], env["HERMES_E2E_TOKEN"] == "mock-token" else {
            throw XCTSkip("Needs the local mock gateway (HERMES_E2E_URL, HERMES_E2E_TOKEN=mock-token)")
        }
        XCUIDevice.shared.orientation = wide ? .landscapeLeft : .portrait
        app.terminate()
        app.launchArguments = [
            "-companionPromptShown", "YES", "-notificationsSetupCardDone", "YES", "-bots.animate", "NO",
            "-approvals.ownerCheck", "NO", "-nollie-demo-gateway", address, "mock-token", "Studio",
        ]
        app.launch()
        visible(any("bots.list"), timeout: 30)
        open("default")
        let composer = visible(app.textViews["composer.text"].firstMatch, timeout: 30)
        composer.tap()
        composer.typeText("Find me a quiet cafe near the park")
        visible(app.buttons.matching(identifier: "composer.send").firstMatch).tap()
        visible(app.buttons.matching(identifier: "onlineModel.allow").firstMatch, timeout: 20)
        XCTAssertTrue(text("Share with Anthropic?").exists, "the real ask did not name the company")
        shot("review-real-ask")
        app.buttons.matching(identifier: "onlineModel.notNow").firstMatch.tap()
        leave()
    }
}
