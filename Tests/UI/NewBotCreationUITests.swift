import XCTest

/// Creates synthetic profiles only in an isolated loopback gateway.
@MainActor
final class NewBotCreationUITests: XCTestCase {
    private var app: XCUIApplication!

    private struct Fixture: Decodable {
        struct Profile: Decodable { let name: String; let provider: String; let model: String }
        struct Request: Decodable {
            let operation: String
            let name: String
            let body: [String: String]
        }
        let profiles: [Profile]
        let requests: [Request]
    }

    private nonisolated static func fixture(_ base: URL, reset: Bool = false, modelFailure: Bool = false) async throws -> Fixture {
        var request = URLRequest(url: base.appendingPathComponent("api/_mock/profile-creation"))
        request.timeoutInterval = 10
        request.setValue("Bearer mock-token", forHTTPHeaderField: "Authorization")
        if reset {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["model_set_failure": modelFailure])
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    private func launch(modelFailure: Bool = false) async throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["HERMES_E2E_URL"], let base = URL(string: address),
              base.scheme == "http", ["127.0.0.1", "localhost", "::1"].contains(base.host ?? ""),
              environment["HERMES_E2E_TOKEN"] == "mock-token" else {
            throw XCTSkip("New bot checks need the local mock gateway")
        }
        let bundle = environment["HERMES_E2E_BUNDLE"] ?? "com.coreykozarski.nollie.demo"
        guard bundle.hasSuffix(".demo") else { throw XCTSkip("New bot checks run only in the demo copy") }
        _ = try await Self.fixture(base, reset: true, modelFailure: modelFailure)
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        XCUIDevice.shared.appearance = .light
        app = XCUIApplication(bundleIdentifier: bundle)
        app.launchArguments = [
            "-nollie-demo-gateway", address, "mock-token", "Studio", "-launchTab", "chats",
            "-companionPromptShown", "YES", "-notificationsSetupCardDone", "YES",
            "-bots.animate", "NO", "-nollie.developerMode", "NO",
        ]
        app.launch()
        addTeardownBlock { [app] in app?.terminate() }
        visible(app.buttons["chats.newBot"].firstMatch, timeout: 30).tap()
        _ = visible(app.textFields["newBot.name"].firstMatch)
        return base
    }

    @discardableResult
    private func visible(_ target: XCUIElement, timeout: TimeInterval = 15,
                         file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        if target.exists, target.isHittable { return target }
        XCTAssertTrue(target.waitForExistence(timeout: timeout), file: file, line: line)
        wait(NSPredicate(format: "hittable == true"), on: target, timeout: timeout, file: file, line: line)
        return target
    }

    private func wait(_ predicate: NSPredicate, on target: XCUIElement, timeout: TimeInterval = 15,
                      file: StaticString = #filePath, line: UInt = #line) {
        let expected = XCTNSPredicateExpectation(predicate: predicate, object: target)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: timeout), .completed, file: file, line: line)
    }

    private func reveal(_ target: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        var from = 0.85
        for _ in 0..<12 {
            if target.exists, target.isHittable, target.frame.maxY < create.frame.minY,
               target.frame.minY > form.frame.minY { return }
            let before = target.frame.minY
            // Above the form's top means the last drag went too far: bring it back down a little.
            if target.exists, target.frame.minY <= form.frame.minY { scrollForm(up: false) } else { scrollForm(up: true, from: from) }
            // A sideways picker under the start point keeps the drag, and a busy simulator can
            // read a quick drag as a tap: start somewhere else, then try a slow system swipe.
            if target.frame.minY == before {
                from = from > 0.5 ? 0.45 : 0.85
                form.swipeUp(velocity: .slow)
            }
        }
        _ = visible(target, file: file, line: line)
        wait(NSPredicate { _, _ in target.frame.maxY < self.create.frame.minY }, on: target, file: file, line: line)
    }

    private var create: XCUIElement { app.buttons["newBot.create"].firstMatch }
    private var form: XCUIElement { app.scrollViews.containing(.textField, identifier: "newBot.name").firstMatch }

    private func scrollFormUp() { scrollForm(up: true) }

    /// `from` is where an upward drag starts, as a share of the visible form's height.
    private func scrollForm(up: Bool, from: Double = 0.85) {
        // The scroll view extends behind the keyboard and pinned Create button. Keep the
        // gesture inside its visible content instead of sending it into those overlays.
        let frame = form.frame
        let top = frame.minY + 24
        let bottom = min(frame.maxY, create.frame.minY) - 24
        let origin = app.coordinate(withNormalizedOffset: .zero)
        // Down the middle: the edges hold sideways pickers (eyes, colours) that keep the drag.
        // A short drag down keeps a target that went past the top from bouncing out again.
        let start = origin.withOffset(CGVector(dx: frame.midX, dy: up ? top + (bottom - top) * from : top))
        let end = origin.withOffset(CGVector(dx: frame.midX, dy: up ? top : top + (bottom - top) / 3))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .default, thenHoldForDuration: 0.1)
    }

    private func enterName(_ name: String) {
        let field = visible(app.textFields["newBot.name"].firstMatch)
        field.tap()
        field.typeText(name)
        wait(NSPredicate(format: "value == %@", name), on: field)
        field.typeText("\n")
        scrollFormUp()
    }

    private func chooseModel() {
        let more = app.buttons["newBot.more"].firstMatch
        reveal(more)
        more.tap()
        let menu = app.buttons["newBot.model"].firstMatch
        reveal(menu)
        wait(NSPredicate { _, _ in menu.isHittable && menu.frame.maxY < self.create.frame.minY }, on: menu)
        menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        // The neutral fixture's explicit route differs from the selected bot's Workshop model.
        // System menus may drop an item's identifier, so its name finds it too.
        let option = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@",
                                                      "newBot.model.local.local/assistant-mini", "local/assistant-mini")).firstMatch
        if !option.waitForExistence(timeout: 2) {
            // Opening the disclosure can still be settling when the menu first reports hittable.
            menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        visible(option).tap()
        wait(NSPredicate(format: "label == 'assistant-mini'"), on: menu)
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testFreshBotRequiresExplicitModelAndVerifiesSavedRoute() async throws {
        let base = try await launch()
        shot("new-bot-empty")
        enterName("demo-research")
        XCTAssertFalse(create.isEnabled, "The current bot's model must not silently become the new bot's model")
        let before = try await Self.fixture(base)
        XCTAssertTrue(before.requests.isEmpty)
        chooseModel()
        XCTAssertTrue(create.isEnabled)
        shot("new-bot-model-selected")
        create.tap()
        _ = visible(app.buttons["chats.newBot"].firstMatch, timeout: 20)
        XCTAssertFalse(app.textFields["newBot.name"].exists)
        let saved = try await Self.fixture(base)
        let profile = try XCTUnwrap(saved.profiles.first { $0.name == "demo-research" })
        XCTAssertEqual(profile.provider, "local")
        XCTAssertEqual(profile.model, "local/assistant-mini")
        XCTAssertEqual(saved.requests.map(\.operation), ["create", "read_model"])
        XCTAssertEqual(saved.requests.first?.body["provider"], "local")
        XCTAssertEqual(saved.requests.first?.body["model"], "local/assistant-mini")
        XCTAssertNil(saved.requests.first?.body["clone_from"])
    }

    func testPartialModelFailureRetriesExistingBotWithoutDuplicateCreation() async throws {
        let base = try await launch(modelFailure: true)
        enterName("demo-retry")
        chooseModel()
        create.tap()
        wait(NSPredicate(format: "label == 'Retry setup' AND enabled == true"), on: create)
        let issue = app.staticTexts["newBot.issue"].firstMatch
        reveal(issue)
        XCTAssertTrue(issue.label.contains("model"))
        XCTAssertFalse(app.textFields["newBot.name"].firstMatch.isEnabled)
        shot("new-bot-model-retry")
        let partial = try await Self.fixture(base)
        XCTAssertEqual(partial.profiles.map(\.name), ["demo-retry"])
        XCTAssertEqual(partial.requests.map(\.operation), ["create"])
        XCTAssertEqual(partial.profiles.first?.model, "")
        create.tap()
        _ = visible(app.buttons["chats.newBot"].firstMatch, timeout: 20)
        let repaired = try await Self.fixture(base)
        XCTAssertEqual(repaired.profiles.map(\.name), ["demo-retry"])
        XCTAssertEqual(repaired.requests.map(\.operation), ["create", "set_model", "read_model"])
        XCTAssertTrue(repaired.requests.allSatisfy { $0.name == "demo-retry" })
        XCTAssertEqual(repaired.profiles.first?.provider, "local")
        XCTAssertEqual(repaired.profiles.first?.model, "local/assistant-mini")
    }
}
