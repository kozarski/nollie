import XCTest

/// Read-only navigation against the local mock. Each bot's editor supplies its own
/// Apps & access scope, even while the gateway's main selected bot stays unchanged.
@MainActor
final class AppsAccessUITests: XCTestCase {
    private var app: XCUIApplication!

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @discardableResult
    private func visible(_ target: XCUIElement, timeout: TimeInterval = 15,
                         file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        if target.exists, target.isHittable { return target }
        XCTAssertTrue(target.waitForExistence(timeout: timeout), file: file, line: line)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: target)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed, file: file, line: line)
        return target
    }

    private func tap(_ id: String) { visible(element(id)).tap() }

    private func scrollTo(_ id: String) -> XCUIElement {
        let target = element(id)
        for _ in 0..<7 {
            if target.exists, target.isHittable { return target }
            app.swipeUp(velocity: .slow)
        }
        return visible(target)
    }

    private func back(from title: String) {
        // The underlying Chats bar remains in the accessibility tree while Settings is a sheet.
        visible(app.navigationBars[title].buttons.firstMatch).tap()
    }

    private func assertPlainToolDescriptions() {
        for (tool, raw) in [("web", "web_search, web_extract"), ("terminal", "terminal, process"), ("code", "execute_code")] {
            let row = scrollTo("tool.toggle." + tool)
            XCTAssertFalse(row.label.contains(raw), "Raw tool descriptions belong in Developer Mode: \(raw)")
            XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", raw)).firstMatch.exists,
                           "Raw tool descriptions belong in Developer Mode: \(raw)")
        }
        let connections = element("apps.connections")
        for _ in 0..<7 {
            if connections.exists, connections.isHittable { break }
            app.swipeDown(velocity: .slow)
        }
        visible(connections)
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openApps(for profile: String, name: String) {
        tap("settings.bots.profile." + profile)
        XCTAssertTrue(element("bot.editor." + profile).waitForExistence(timeout: 15))
        let tabs = visible(element("profile.tabs"))
        let apps = app.buttons["profile.tab.apps"].firstMatch
        for _ in 0..<4 {
            if apps.exists, apps.isHittable, tabs.frame.contains(apps.frame) { break }
            tabs.swipeLeft(velocity: .slow)
        }
        visible(apps).tap()
        XCTAssertTrue(apps.isSelected)
        tap("profile.apps")
        XCTAssertTrue(element("settings.tools.page").waitForExistence(timeout: 15))
        visible(element("tool.toggle.web"))
        let description = app.staticTexts["Choose what \(name) can use. You can ask for help in chat."].firstMatch
        XCTAssertTrue(description.waitForExistence(timeout: 10),
                      "Apps & access must describe the bot whose editor was opened")
    }

    func testEachBotsAccessPageKeepsBeginnerDetailsReadable() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["HERMES_E2E_URL"], let url = URL(string: address),
              url.scheme == "http", ["127.0.0.1", "localhost", "::1"].contains(url.host ?? ""),
              environment["HERMES_E2E_TOKEN"] == "mock-token" else {
            throw XCTSkip("Apps & access checks need the local mock gateway")
        }
        let bundle = environment["HERMES_E2E_BUNDLE"] ?? "com.coreykozarski.nollie.demo"
        guard bundle.hasSuffix(".demo") else { throw XCTSkip("Apps & access checks run only in the demo copy") }
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
        visible(element("chats.settings"), timeout: 30).tap()
        XCTAssertFalse(element("settings.row.advanced").exists)
        tap("settings.row.bots")
        let workName = visible(element("settings.bots.profile.work")).label
        let mainName = visible(element("settings.bots.profile.default")).label
        XCTAssertNotEqual(workName, mainName)

        openApps(for: "work", name: workName)
        assertPlainToolDescriptions()
        shot("apps-access-work")
        tap("apps.connections")
        XCTAssertTrue(element("settings.connections.page").waitForExistence(timeout: 15))
        visible(element("apps.connection.filesystem.test"))
        XCTAssertTrue(element("apps.connection.filesystem.enabled").exists)
        for technical in ["Transport", "Host", "Program", "stdio", "npx", "api.githubcopilot.com"] {
            XCTAssertFalse(app.staticTexts[technical].exists, "Technical connection detail leaked into the standard view: \(technical)")
        }
        shot("apps-access-connections")

        back(from: "Connections")
        scrollTo("apps.more").tap()
        let optionalCapability = scrollTo("tool.toggle.vision")
        XCTAssertEqual(optionalCapability.elementType, .switch,
                       "Expanded capabilities must keep their own accessibility identifiers")
        shot("apps-access-more")
        scrollTo("apps.skills").tap()
        XCTAssertTrue(app.navigationBars["Skills"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.switches.matching(NSPredicate(format: "label CONTAINS 'code-review'")).firstMatch.waitForExistence(timeout: 15))
        for provenance in ["bundled", "hub", "agent"] {
            XCTAssertFalse(app.staticTexts[provenance].exists, "Skill installation metadata belongs in Developer Mode")
        }
        shot("apps-access-skills")

        back(from: "Skills")
        back(from: "Apps & access")
        back(from: workName)
        openApps(for: "default", name: mainName)
        XCTAssertFalse(app.staticTexts["Choose what \(workName) can use. You can ask for help in chat."].exists,
                       "The previous bot's identity must not carry into this page")
        shot("apps-access-main")
    }
}
