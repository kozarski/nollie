import XCTest

/// Exercises draft preparation in a fresh chat using only the local demo gateway.
@MainActor
final class FirstTaskUITests: XCTestCase {
    private var app: XCUIApplication!

    private func button(_ id: String) -> XCUIElement {
        app.buttons.matching(identifier: id).firstMatch
    }

    @discardableResult
    private func visible(_ element: XCUIElement, timeout: TimeInterval = 15,
                         file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        if element.exists, element.isHittable { return element }
        XCTAssertTrue(element.waitForExistence(timeout: timeout), file: file, line: line)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed, file: file, line: line)
        return element
    }

    private func assertDraft(_ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        let composer = app.textViews["composer.text"].firstMatch
        if composer.value as? String == expected { return }
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: composer)
        XCTAssertEqual(XCTWaiter.wait(for: [matches], timeout: 10), .completed,
                       "The composer must contain the exact expected unsent draft", file: file, line: line)
    }

    private func assertNoTurn(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'thread.row.'")).firstMatch.exists,
            "Preparing an idea must not add a message to the conversation", file: file, line: line)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "thread.typing").firstMatch.exists,
                       "Preparing an idea must not start the assistant", file: file, line: line)
    }

    private func dismissKeyboard() {
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists {
            // Start inside the transcript, above the composer, then use its interactive dismissal.
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: app.frame.midX, dy: keyboard.frame.minY - 120))
            let end = origin.withOffset(CGVector(dx: app.frame.midX, dy: keyboard.frame.maxY - 40))
            start.press(forDuration: 0.01, thenDragTo: end)
        }
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: keyboard)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 10), .completed,
                       "Dismiss the keyboard before choosing an idea below the composer")
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testIdeasOnlyFillAnEmptyDraftAndNeverSend() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["HERMES_E2E_URL"], let url = URL(string: address),
              url.scheme == "http", ["127.0.0.1", "localhost", "::1"].contains(url.host ?? ""),
              environment["HERMES_E2E_TOKEN"] == "mock-token" else {
            throw XCTSkip("First-task checks need the local mock gateway")
        }
        let bundle = environment["HERMES_E2E_BUNDLE"] ?? "com.coreykozarski.nollie.demo"
        guard bundle.hasSuffix(".demo") else { throw XCTSkip("First-task checks run only in the demo copy") }

        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        XCUIDevice.shared.appearance = .light
        app = XCUIApplication(bundleIdentifier: bundle)
        app.launchArguments = [
            "-nollie-demo-gateway", address, "mock-token", "Studio", "-launchTab", "chats",
            "-companionPromptShown", "YES", "-notificationsSetupCardDone", "YES", "-bots.animate", "NO",
        ]
        app.launch()
        let defaultBot = app.descendants(matching: .any).matching(identifier: "bots.row.default").firstMatch
        visible(defaultBot, timeout: 30).tap()
        visible(button("chat.more"), timeout: 30).tap()
        visible(button("botmenu.sideChat")).tap()
        visible(button("firstTask.purchase"), timeout: 30)
        assertNoTurn()
        shot("first-task-ideas")

        let composer = visible(app.textViews["composer.text"].firstMatch)
        let original = "Keep my own draft intact."
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        // Let each edit settle through the native field before synthesizing the next key.
        var typed = ""
        for character in original {
            composer.typeText(String(character))
            typed.append(character)
            assertDraft(typed)
        }
        assertDraft(original)
        let ideasHidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                                    object: button("firstTask.purchase"))
        XCTAssertEqual(XCTWaiter.wait(for: [ideasHidden], timeout: 10), .completed,
                       "Ideas must not offer to replace an existing draft")
        assertDraft(original)
        assertNoTurn()
        shot("first-task-existing-draft")

        // Only this explicit user edit makes the ideas available again.
        for _ in original {
            composer.typeText(XCUIKeyboardKey.delete.rawValue)
            typed.removeLast()
            assertDraft(typed)
        }
        assertDraft("")
        dismissKeyboard()
        visible(button("firstTask.purchase")).tap()
        assertDraft("Can you help me find a better price?")
        XCTAssertFalse(button("firstTask.use").exists, "Choosing an idea must stay in the conversation without a form")
        XCTAssertFalse(app.textFields["firstTask.details"].exists)
        assertNoTurn()
        shot("first-task-prepared-draft")
    }
}
