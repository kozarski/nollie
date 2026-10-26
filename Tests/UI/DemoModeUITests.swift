import XCTest

/// "Try a demo" from the first screen: the demo opens, a chat takes a message and answers it, an
/// Ask first card can be answered, and leaving the demo goes back to the first screen. It needs no
/// gateway at all, because the demo runs inside the app. Runs on the demo copy.
@MainActor
final class DemoModeUITests: XCTestCase {
    private var app: XCUIApplication!

    @discardableResult
    private func visible(_ element: XCUIElement, timeout: TimeInterval = 20,
                         file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        if element.exists, element.isHittable { return element }
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "\(element) never showed", file: file, line: line)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed, file: file, line: line)
        return element
    }

    private func any(_ id: String) -> XCUIElement {
        let everything = app.descendants(matching: .any)
        return everything[id].firstMatch
    }

    /// Taps once the element has settled. The list redraws as the demo's bots arrive, so a tap that
    /// finds the row gone tries again.
    private func tap(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        for attempt in 1...3 {
            let element = visible(any(id), file: file, line: line)
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            if element.exists, element.isHittable {
                element.tap()
                return
            }
            if attempt == 3 { XCTFail("\(id) never held still", file: file, line: line) }
        }
    }

    private func text(_ fragment: String) -> XCUIElement {
        let withFragment = NSPredicate(format: "label CONTAINS %@", fragment)
        let labels = app.staticTexts.matching(withFragment)
        return labels.firstMatch
    }

    /// Kept with the test results, and written to `NOLLIE_SHOTS` too when that folder is named.
    private func shot(_ name: String) {
        let picture = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: picture)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["NOLLIE_SHOTS"], !folder.isEmpty {
            try? picture.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
    }

    private func demoBundle() throws -> String {
        let bundle = ProcessInfo.processInfo.environment["HERMES_E2E_BUNDLE"] ?? "com.coreykozarski.nollie.demo"
        guard bundle.hasSuffix(".demo") else { throw XCTSkip("Demo mode checks run only in the demo copy") }
        return bundle
    }

    /// A first launch: no saved gateway and no setup under way, with the intro already seen.
    private func launch(_ bundle: String) {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication(bundleIdentifier: bundle)
        app.launchArguments = [
            "-nollie.onboarding.progress.v1", "", "-nollie.onboarding.welcomeIntroSeen", "YES",
            "-companionPromptShown", "YES", "-notificationsSetupCardDone", "YES", "-bots.animate", "NO",
            "-approvals.ownerCheck", "NO",
        ]
        app.launch()
    }

    func testTryADemoOpensAChatThatAnswers() throws {
        let bundle = try demoBundle()

        launch(bundle)

        // The first screen: the main path first, the demo after it.
        let start = visible(app.buttons["onboarding.continue"].firstMatch, timeout: 30)
        let demo = visible(app.buttons["onboarding.tryDemo"].firstMatch)
        XCTAssertLessThan(start.frame.minY, demo.frame.minY, "the demo must come after the main path")
        shot("demo-1-first-screen")
        demo.tap()

        // The demo: bots, and a pill that says so.
        visible(any("demo.pill"))
        // Four bots, so the first three are pinned along the top once, as Messages does.
        visible(any("bots.pinned.default"))
        visible(any("bots.pinned.mason"))
        visible(any("bots.row.scout"))
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        shot("demo-2-chats")

        // A chat answers, typing bubble first and then the whole reply.
        tap("bots.pinned.default")
        let composer = visible(app.textViews["composer.text"].firstMatch)
        composer.tap()
        let prompt = "Find me a quiet cafe near the park"
        composer.typeText(prompt)
        visible(app.buttons.matching(identifier: "composer.send").firstMatch).tap()
        XCTAssertTrue(any("thread.typing").waitForExistence(timeout: 15), "no typing bubble while the reply was written")
        XCTAssertTrue(text("In your own Nollie").waitForExistence(timeout: 30), "the reply never arrived")
        XCTAssertTrue(text("Searched").waitForExistence(timeout: 5), "the steps of the turn did not show")
        shot("demo-3-reply")

        // Ask first: Mason is waiting on a yes, and Allow once sends it.
        visible(app.buttons.matching(identifier: "chat.back").firstMatch).tap()
        tap("bots.pinned.mason")
        let card = visible(any("approval.askFirst"), timeout: 30)
        shot("demo-4-ask-first")
        XCTAssertTrue(card.exists)
        visible(app.buttons.matching(identifier: "approval.once").firstMatch).tap()
        XCTAssertTrue(text("Sent.").waitForExistence(timeout: 30), "the note was not sent after Allow once")
        shot("demo-5-sent")

        // Leaving goes back to the first screen.
        visible(app.buttons.matching(identifier: "chat.back").firstMatch).tap()
        visible(any("demo.pill")).tap()
        visible(app.buttons.matching(identifier: "demo.leave").firstMatch).tap()
        visible(app.buttons["onboarding.tryDemo"].firstMatch, timeout: 30)
        XCTAssertFalse(any("demo.pill").exists, "the demo pill stayed after leaving")
        // The demo copy is shared with the other flows, which expect no setup under way.
        visible(app.buttons["onboarding.skip"].firstMatch).tap()
    }

    func testTheDemoBoardAndSettingsHaveTheirCards() throws {
        launch(try demoBundle())
        visible(app.buttons["onboarding.tryDemo"].firstMatch, timeout: 30).tap()
        visible(any("demo.pill"))
        visible(any("bots.pinned.default"))

        // The Board has cards, and one of them waits on a yes.
        visible(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Board'")).firstMatch).tap()
        let found = text("Plan Saturday and Sunday").waitForExistence(timeout: 20)
        shot("demo-6-board")
        XCTAssertTrue(found, "the Board shows no cards")
        visible(app.buttons.matching(identifier: "board.close").firstMatch).tap()

        // Settings: the way out, and the Night shift card.
        tap("chats.settings")
        visible(any("settings.leaveDemo"))
        let night = visible(any("settings.summary.night"))
        shot("demo-7-settings")
        night.tap()
        let priceWatch = text("Watch the Aero 5 price")
        XCTAssertTrue(priceWatch.waitForExistence(timeout: 20), "the Night shift card is missing")
        shot("demo-8-night-shift")

        // Back out through Settings' own way out, and leave the shared demo copy with no setup under way.
        let backCorner = app.coordinate(withNormalizedOffset: CGVector(dx: 0.095, dy: 0.114))
        backCorner.tap()
        visible(any("settings.leaveDemo")).tap()
        visible(app.buttons["onboarding.skip"].firstMatch, timeout: 30).tap()
    }
}
